import Foundation

/// 把宽松的 Statuspage JSON 映射为展示模型。
enum DeepSeekStatusMapper {
  /// 解析 Statuspage 的 ISO8601 时间（含小数秒变体）。
  static let defaultDateParser: (String?) -> Date? = { raw in
    guard let raw, !raw.isEmpty else { return nil }
    let formatters = [
      ISO8601DateFormatter(),
      ISO8601DateFormatter(),
      ISO8601DateFormatter(),
    ]
    formatters[1].formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatters[2].formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withColonSeparatorInTimeZone]
    for formatter in formatters {
      if let date = formatter.date(from: raw) {
        return date
      }
    }
    return nil
  }

  static func map(
    _ summary: StatusPageSummary,
    dateParser: (String?) -> Date? = defaultDateParser
  ) -> DeepSeekServiceStatus {
    let overall = OverallIndicator.from(raw: summary.status?.indicator)
    let allComponents =
      summary.components?
      .filter { $0.group != true }
      .compactMap { component -> DeepSeekServiceStatus.Component? in
        guard let name = component.name?.trimmingCharacters(in: .whitespacesAndNewlines),
          !name.isEmpty
        else {
          return nil
        }
        return DeepSeekServiceStatus.Component(
          id: component.id ?? name,
          name: name,
          status: ComponentStatus.from(raw: component.status)
        )
      } ?? []

    let apiComponents = allComponents.filter { isAPIComponent($0.name) }
    let webChatComponents = allComponents.filter { isWebChatComponent($0.name) }
    let otherComponents = allComponents.filter {
      !isAPIComponent($0.name) && !isWebChatComponent($0.name)
    }

    let incidents: [DeepSeekServiceStatus.Incident] =
      summary.incidents?
      .filter {
        let status = IncidentStatus.from(raw: $0.status)
        return status != .resolved && status != .postmortem
      }
      .compactMap { incident -> DeepSeekServiceStatus.Incident? in
        guard let id = incident.id, let title = incident.name, !title.isEmpty else {
          return nil
        }
        let updates = incident.incidentUpdates ?? []
        let latestBody = updates.last?.body?
          .trimmingCharacters(in: .whitespacesAndNewlines)
        let latestBodyCleaned = latestBody.flatMap { body -> String? in
          body.isEmpty ? nil : body
        }
        return DeepSeekServiceStatus.Incident(
          id: id,
          title: title,
          status: IncidentStatus.from(raw: incident.status),
          impact: IncidentImpact.from(raw: incident.impact),
          updatedAt: dateParser(incident.updatedAt ?? updates.last?.updatedAt),
          latestUpdateBody: latestBodyCleaned
        )
      } ?? []

    let maintenances: [DeepSeekServiceStatus.Maintenance] =
      summary.scheduledMaintenances?
      .compactMap { maintenance -> DeepSeekServiceStatus.Maintenance? in
        guard let id = maintenance.id, let title = maintenance.name, !title.isEmpty else {
          return nil
        }
        let updates = maintenance.incidentUpdates ?? []
        return DeepSeekServiceStatus.Maintenance(
          id: id,
          title: title,
          status: IncidentStatus.from(raw: maintenance.status),
          updatedAt: dateParser(maintenance.updatedAt ?? updates.last?.updatedAt)
        )
      } ?? []

    return DeepSeekServiceStatus(
      overall: overall,
      overallDescription: summary.status?.description ?? "",
      updatedAt: summary.page?.updatedAt.flatMap { dateParser($0) },
      apiComponents: apiComponents,
      webChatComponents: webChatComponents,
      otherComponents: otherComponents,
      incidents: incidents,
      scheduledMaintenances: maintenances
    )
  }

  /// 识别 API 组件：名称标准化后包含独立 `api` token。
  static func isAPIComponent(_ name: String) -> Bool {
    let parts = tokens(name)
    return parts.contains("api") || normalize(name).contains("api服务")
  }

  /// 识别 Web Chat 组件。
  static func isWebChatComponent(_ name: String) -> Bool {
    let parts = tokens(name)
    let normalized = normalize(name)
    return (parts.contains("web") && parts.contains("chat"))
      || normalized.contains("webchat")
      || normalized.contains("网页对话")
      || normalized == "对话服务"
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
