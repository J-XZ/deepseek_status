import Foundation

/// 把 Atlassian Statuspage 官方状态 JSON 映射为展示模型。
/// 复用 `DeepSeekServiceStatus` 展示结构，三种供应商状态卡片视觉一致。
enum StatusPageMapper {
  static func map(_ response: StatusPageSummaryResponse) -> DeepSeekServiceStatus {
    // 整体状态：Atlassian 用 indicator 字段，取值与 OverallIndicator 一致。
    let indicatorRaw = response.status.status?.indicator
    let reportedOverall = OverallIndicator.from(raw: indicatorRaw)
    let overallDescription = response.status.status?.description ?? ""

    // 组件：group 分组组件跳过（其下子组件已有独立状态）。
    let components = (response.components.components ?? []).filter {
      !($0.group ?? false)
    }

    let mappedComponents: [DeepSeekServiceStatus.Component] = components.compactMap {
      component -> DeepSeekServiceStatus.Component? in
      guard let name = component.name?.trimmingCharacters(in: .whitespacesAndNewlines),
        !name.isEmpty
      else {
        return nil
      }
      let id = component.id ?? name
      return DeepSeekServiceStatus.Component(
        id: id,
        name: name,
        status: ComponentStatus.from(raw: component.status)
      )
    }

    let apiComponents = mappedComponents.filter { DeepSeekStatusMapper.isAPIComponent($0.name) }
    let webChatComponents = mappedComponents.filter {
      !DeepSeekStatusMapper.isAPIComponent($0.name)
        && DeepSeekStatusMapper.isWebChatComponent($0.name)
    }
    let otherComponents = mappedComponents.filter {
      !DeepSeekStatusMapper.isAPIComponent($0.name)
        && !DeepSeekStatusMapper.isWebChatComponent($0.name)
    }

    // 事故：只展示未解决事故（investigating / identified / monitoring）。
    let incidents = (response.incidents.incidents ?? [])
      .compactMap { incident -> DeepSeekServiceStatus.Incident? in
        let status = IncidentStatus.from(raw: incident.status)
        guard status == .investigating || status == .identified || status == .monitoring,
          let name = incident.name, !name.isEmpty
        else {
          return nil
        }
        return DeepSeekServiceStatus.Incident(
          id: incident.id ?? name,
          title: name,
          status: status,
          impact: IncidentImpact.from(raw: incident.impact),
          updatedAt: parseDate(incident.updatedAt),
          latestUpdateBody: incident.incidentUpdates?.last?.body
        )
      }
      .sorted { $0.updatedAt ?? .distantPast > $1.updatedAt ?? .distantPast }

    let sawIncidents = !incidents.isEmpty

    // 取整体 indicator 与组件最差状态中更严重的一方（含 severity 1 的 degraded）。
    let worstComponentSeverity = mappedComponents
      .map { DeepSeekStatusMapper.severity($0.status) }
      .max() ?? 0
    let fromComponents = indicator(fromComponentSeverity: worstComponentSeverity)
    let effectiveOverall = mergeOverall(
      reported: reportedOverall,
      fromComponents: fromComponents,
      sawIncidents: sawIncidents
    )

    return DeepSeekServiceStatus(
      overall: effectiveOverall,
      overallDescription: overallDescription,
      updatedAt: parseDate(nil),
      apiComponents: apiComponents,
      webChatComponents: webChatComponents,
      otherComponents: otherComponents,
      incidents: incidents,
      scheduledMaintenances: []
    )
  }

  /// 组件严重度 → 整体指示：1/2 → minor，3 → major。
  private static func indicator(fromComponentSeverity severity: Int) -> OverallIndicator {
    switch severity {
    case 3:
      return .major
    case 1, 2:
      return .minor
    default:
      return .none
    }
  }

  private static func rank(_ indicator: OverallIndicator) -> Int {
    switch indicator {
    case .unknown:
      return -1
    case .none:
      return 0
    case .maintenance:
      return 1
    case .minor:
      return 2
    case .major:
      return 3
    case .critical:
      return 4
    }
  }

  private static func mergeOverall(
    reported: OverallIndicator,
    fromComponents: OverallIndicator,
    sawIncidents: Bool
  ) -> OverallIndicator {
    if reported == .unknown && fromComponents == .none {
      return sawIncidents ? .unknown : .none
    }
    if reported == .unknown {
      return fromComponents
    }
    return rank(fromComponents) > rank(reported) ? fromComponents : reported
  }

  /// Atlassian 时间戳是 ISO8601（如 2026-08-01T09:30:00.000Z），解析失败返回 nil。
  static func parseDate(_ string: String?) -> Date? {
    guard let string else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: string) {
      return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string)
  }
}
