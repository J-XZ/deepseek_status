import Foundation

/// 把 Atlassian Statuspage 官方状态 JSON 映射为展示模型。
/// 复用 `DeepSeekServiceStatus` 展示结构，三种供应商状态卡片视觉一致。
enum StatusPageMapper {
  static func map(_ response: StatusPageSummaryResponse) -> DeepSeekServiceStatus {
    // 整体状态：Atlassian 用 indicator 字段，取值与 OverallIndicator 一致。
    let indicatorRaw = response.status.status?.indicator
    let overall = OverallIndicator.from(raw: indicatorRaw)
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

    // 组件最差状态：低于 overall indicator 时以整体状态为准（如整体 major）。
    let worstComponentSeverity = mappedComponents
      .map { DeepSeekStatusMapper.severity($0.status) }
      .max() ?? 0

    let effectiveOverall: OverallIndicator
    if overall != .unknown {
      effectiveOverall = overall
    } else if worstComponentSeverity == 3 {
      effectiveOverall = .major
    } else if worstComponentSeverity == 2 {
      effectiveOverall = .minor
    } else if sawIncidents {
      effectiveOverall = .unknown
    } else {
      effectiveOverall = .none
    }

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
