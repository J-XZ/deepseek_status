import Foundation

/// DeepSeek 官方状态页（Flashcat 托管）`summary/active` 宽松模型：
/// 所有字段 optional，未知枚举值在映射层回退为 `.unknown`，新增字段自动忽略。
struct FlashcatStatusResponse: Codable, Sendable {
  let requestID: String?
  let data: FlashcatStatusData?

  enum CodingKeys: String, CodingKey {
    case requestID = "request_id"
    case data
  }
}

struct FlashcatStatusData: Codable, Sendable {
  let page: FlashcatStatusPage?
  let activeChanges: [FlashcatStatusChange]?

  enum CodingKeys: String, CodingKey {
    case page
    case activeChanges = "active_changes"
  }
}

struct FlashcatStatusPage: Codable, Sendable {
  let pageID: Int64?
  let name: String?
  let urlName: String?
  let customDomain: String?
  let components: [FlashcatComponent]?
  let sections: [FlashcatSection]?

  enum CodingKeys: String, CodingKey {
    case pageID = "page_id"
    case name
    case urlName = "url_name"
    case customDomain = "custom_domain"
    case components
    case sections
  }
}

struct FlashcatComponent: Codable, Sendable {
  let componentID: String?
  let name: String?
  let description: String?
  let sectionID: String?
  let availableSinceSeconds: Int64?
  let orderID: Int?

  enum CodingKeys: String, CodingKey {
    case componentID = "component_id"
    case name
    case description
    case sectionID = "section_id"
    case availableSinceSeconds = "available_since_seconds"
    case orderID = "order_id"
  }
}

struct FlashcatSection: Codable, Sendable {
  let sectionID: String?
  let name: String?
  let description: String?
  let orderID: Int?

  enum CodingKeys: String, CodingKey {
    case sectionID = "section_id"
    case name
    case description
    case orderID = "order_id"
  }
}

/// 进行中的事故或计划维护。
struct FlashcatStatusChange: Codable, Sendable {
  let changeID: Int64?
  let type: String?
  let title: String?
  let description: String?
  let status: String?
  let startAtSeconds: Int64?
  let closeAtSeconds: Int64?
  let affectedComponents: [FlashcatAffectedComponent]?
  let updates: [FlashcatChangeUpdate]?

  enum CodingKeys: String, CodingKey {
    case changeID = "change_id"
    case type
    case title
    case description
    case status
    case startAtSeconds = "start_at_seconds"
    case closeAtSeconds = "close_at_seconds"
    case affectedComponents = "affected_components"
    case updates
  }
}

struct FlashcatAffectedComponent: Codable, Sendable {
  let componentID: String?
  let name: String?
  let status: String?

  enum CodingKeys: String, CodingKey {
    case componentID = "component_id"
    case name
    case status
  }
}

struct FlashcatChangeUpdate: Codable, Sendable {
  let atSeconds: Int64?
  let status: String?
  let description: String?

  enum CodingKeys: String, CodingKey {
    case atSeconds = "at_seconds"
    case status
    case description
  }
}

/// 整体服务状态。未知值映射为 `.unknown`，不导致解码失败。
enum OverallIndicator: String, Equatable, Sendable {
  case none
  case minor
  case major
  case critical
  case maintenance
  case unknown

  static func from(raw: String?) -> OverallIndicator {
    guard let raw else { return .unknown }
    return OverallIndicator(rawValue: raw.lowercased()) ?? .unknown
  }
}

/// 组件状态。
enum ComponentStatus: String, Equatable, Sendable {
  case operational
  case degradedPerformance = "degraded_performance"
  case partialOutage = "partial_outage"
  case majorOutage = "major_outage"
  case underMaintenance = "under_maintenance"
  case unknown

  static func from(raw: String?) -> ComponentStatus {
    switch raw?.lowercased() {
    case "operational":
      return .operational
    case "degraded", "degraded_performance":
      return .degradedPerformance
    case "partial_outage":
      return .partialOutage
    case "major_outage", "outage", "critical":
      // Flashcat 的 critical 在组件层映射为 major_outage；整体严重度另计为 4。
      return .majorOutage
    case "under_maintenance", "maintenance":
      return .underMaintenance
    default:
      return .unknown
    }
  }
}

/// 事故阶段。
enum IncidentStatus: String, Equatable, Sendable {
  case investigating
  case identified
  case monitoring
  case resolved
  case postmortem
  case unknown

  static func from(raw: String?) -> IncidentStatus {
    guard let raw else { return .unknown }
    return IncidentStatus(rawValue: raw.lowercased()) ?? .unknown
  }
}

/// 事故影响范围。
enum IncidentImpact: String, Equatable, Sendable {
  case none
  case minor
  case major
  case critical
  case unknown

  static func from(raw: String?) -> IncidentImpact {
    guard let raw else { return .unknown }
    return IncidentImpact(rawValue: raw.lowercased()) ?? .unknown
  }
}

/// 展示用服务状态模型。
struct DeepSeekServiceStatus: Equatable, Sendable {
  struct Component: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let status: ComponentStatus
  }

  struct Incident: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let status: IncidentStatus
    let impact: IncidentImpact
    let updatedAt: Date?
    let latestUpdateBody: String?
  }

  struct Maintenance: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let status: IncidentStatus
    let updatedAt: Date?
  }

  let overall: OverallIndicator
  let overallDescription: String
  let updatedAt: Date?
  let apiComponents: [Component]
  let webChatComponents: [Component]
  let otherComponents: [Component]
  let incidents: [Incident]
  let scheduledMaintenances: [Maintenance]
}
