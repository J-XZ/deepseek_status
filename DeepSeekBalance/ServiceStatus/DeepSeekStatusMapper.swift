import Foundation

/// 把 Flashcat 官方状态 JSON 映射为展示模型。
enum DeepSeekStatusMapper {
  static func map(_ response: FlashcatStatusResponse) -> DeepSeekServiceStatus {
    // 缺少顶层 data/page 时视为未知，避免空包被误判为“全部正常”。
    guard let data = response.data, let page = data.page else {
      return DeepSeekServiceStatus(
        overall: .unknown,
        overallDescription: "",
        updatedAt: nil,
        apiComponents: [],
        webChatComponents: [],
        otherComponents: [],
        incidents: [],
        scheduledMaintenances: []
      )
    }

    let components = page.components ?? []
    let sections = page.sections ?? []
    var sectionNames: [String: String] = [:]
    for section in sections {
      guard let id = section.sectionID, let name = section.name else { continue }
      if sectionNames[id] == nil {
        sectionNames[id] = name
      }
    }

    let changes = data.activeChanges ?? []
    let unresolvedChanges = changes.filter {
      let status = IncidentStatus.from(raw: $0.status)
      return status != .resolved && status != .postmortem
    }

    // 每个组件当前状态：由未解决变更的 affected_components 推导；无变更则 operational。
    var componentStatusByID: [String: ComponentStatus] = [:]
    var worstSeverity = 0
    var sawUnknownStatus = false
    for change in unresolvedChanges {
      for affected in change.affectedComponents ?? [] {
        guard let id = affected.componentID else { continue }
        let raw = affected.status
        let status = ComponentStatus.from(raw: raw)
        if status == .unknown, raw != nil {
          sawUnknownStatus = true
        }
        componentStatusByID[id] = Self.worse(status, componentStatusByID[id])
        worstSeverity = max(worstSeverity, Self.severity(forRawAffectedStatus: raw))
      }
    }

    let mappedComponents: [DeepSeekServiceStatus.Component] = components.compactMap {
      component -> DeepSeekServiceStatus.Component? in
      guard let name = component.name?.trimmingCharacters(in: .whitespacesAndNewlines),
        !name.isEmpty
      else {
        return nil
      }
      let id = component.componentID ?? name
      return DeepSeekServiceStatus.Component(
        id: id,
        name: name,
        status: componentStatusByID[id] ?? .operational
      )
    }

    let apiComponents = mappedComponents.filter { isAPIComponent($0.name) }
    let webChatComponents = mappedComponents.filter {
      !isAPIComponent($0.name)
        && isWebChatComponent($0.name, sections: sectionNames, components: components)
    }
    let otherComponents = mappedComponents.filter {
      !isAPIComponent($0.name)
        && !isWebChatComponent($0.name, sections: sectionNames, components: components)
    }

    var incidents: [DeepSeekServiceStatus.Incident] = []
    var maintenances: [DeepSeekServiceStatus.Maintenance] = []
    var hasMaintenance = false

    for change in unresolvedChanges {
      let isMaintenance = change.type?.lowercased() == "maintenance"
      hasMaintenance = hasMaintenance || isMaintenance
      let title = change.title ?? "Unknown"
      let updatedAt = latestTimestamp(change)
      let latestBody = change.updates?.last?.description

      if isMaintenance {
        maintenances.append(
          DeepSeekServiceStatus.Maintenance(
            id: String(change.changeID ?? 0),
            title: title,
            status: IncidentStatus.from(raw: change.status),
            updatedAt: updatedAt
          )
        )
      } else {
        // 事故影响按该变更自身 affected 组件计算，不套用全局最差值。
        let changeSeverity = (change.affectedComponents ?? []).compactMap { affected -> Int? in
          guard affected.componentID != nil else { return nil }
          return Self.severity(forRawAffectedStatus: affected.status)
        }.max() ?? 0
        incidents.append(
          DeepSeekServiceStatus.Incident(
            id: String(change.changeID ?? 0),
            title: title,
            status: IncidentStatus.from(raw: change.status),
            impact: impact(forSeverity: changeSeverity),
            updatedAt: updatedAt,
            latestUpdateBody: latestBody
          )
        )
      }
    }

    // 故障严重度优先于维护：存在 critical/major 时不应被维护黄标掩盖。
    let overall: OverallIndicator
    if worstSeverity >= 4 {
      overall = .critical
    } else if worstSeverity == 3 {
      overall = .major
    } else if hasMaintenance {
      overall = .maintenance
    } else if worstSeverity > 0 {
      overall = .minor
    } else if !incidents.isEmpty || sawUnknownStatus {
      overall = .unknown
    } else {
      overall = .none
    }

    return DeepSeekServiceStatus(
      overall: overall,
      overallDescription: "",
      updatedAt: nil,
      apiComponents: apiComponents,
      webChatComponents: webChatComponents,
      otherComponents: otherComponents,
      incidents: incidents,
      scheduledMaintenances: maintenances
    )
  }

  static func severity(_ status: ComponentStatus) -> Int {
    switch status {
    case .operational, .unknown:
      return 0
    case .degradedPerformance, .underMaintenance:
      return 1
    case .partialOutage:
      return 2
    case .majorOutage:
      return 3
    }
  }

  /// critical 映射为 majorOutage（组件层无独立 critical 枚举），严重度记为 4。
  static func severity(forRawAffectedStatus raw: String?) -> Int {
    if raw?.lowercased() == "critical" {
      return 4
    }
    return severity(ComponentStatus.from(raw: raw))
  }

  private static func worse(_ lhs: ComponentStatus, _ rhs: ComponentStatus?) -> ComponentStatus {
    guard let rhs else { return lhs }
    return severity(lhs) >= severity(rhs) ? lhs : rhs
  }

  private static func impact(forSeverity severity: Int) -> IncidentImpact {
    switch severity {
    case 4:
      return .critical
    case 3:
      return .major
    case 1...2:
      return .minor
    default:
      return .unknown
    }
  }

  private static func latestTimestamp(_ change: FlashcatStatusChange) -> Date? {
    if let at = change.updates?.compactMap({ $0.atSeconds }).max() {
      return Date(timeIntervalSince1970: TimeInterval(at))
    }
    if let start = change.startAtSeconds {
      return Date(timeIntervalSince1970: TimeInterval(start))
    }
    return nil
  }

  // MARK: - 组件分类

  /// 识别 API 组件：名称标准化后包含独立 `api` token。
  static func isAPIComponent(_ name: String) -> Bool {
    let parts = tokens(name)
    return parts.contains("api") || normalize(name).contains("api服务")
  }

  /// 识别 Web Chat 组件：名称或所属 section 名称匹配对话/chat 特征。
  static func isWebChatComponent(
    _ name: String,
    sections: [String: String] = [:],
    components: [FlashcatComponent] = []
  ) -> Bool {
    if matchesWebChatName(name) {
      return true
    }
    guard let component = components.first(where: { $0.name == name }),
      let sectionID = component.sectionID,
      let sectionName = sections[sectionID]
    else {
      return false
    }
    return matchesWebChatName(sectionName)
  }

  private static func matchesWebChatName(_ name: String) -> Bool {
    let parts = tokens(name)
    let normalized = normalize(name)
    return (parts.contains("web") && parts.contains("chat"))
      || normalized.contains("webchat")
      || normalized.contains("网页对话")
      || normalized == "对话服务"
      || normalized.contains("对话服务")
      || normalized.contains("chatservice")
  }

  static func tokens(_ name: String) -> [String] {
    name
      .lowercased()
      .folding(options: [.widthInsensitive, .caseInsensitive], locale: .current)
      .replacingOccurrences(of: "-", with: " ")
      .replacingOccurrences(of: "_", with: " ")
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
  }

  static func normalize(_ name: String) -> String {
    tokens(name).joined()
  }
}
