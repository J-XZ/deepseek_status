import Foundation

/// Statuspage `summary.json` 宽松模型：所有字段 optional，
/// 未知枚举值在映射层回退为 `.unknown`，新增字段自动忽略。
struct StatusPageSummary: Codable, Sendable {
  let page: StatusPagePage?
  let status: StatusPageStatus?
  let components: [StatusPageComponent]?
  let incidents: [StatusPageIncident]?
  let scheduledMaintenances: [StatusPageScheduledMaintenance]?

  enum CodingKeys: String, CodingKey {
    case page
    case status
    case components
    case incidents
    case scheduledMaintenances = "scheduled_maintenances"
  }
}

struct StatusPagePage: Codable, Sendable {
  let id: String?
  let name: String?
  let url: String?
  let timeZone: String?
  let updatedAt: String?

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case url
    case timeZone = "time_zone"
    case updatedAt = "updated_at"
  }
}

struct StatusPageStatus: Codable, Sendable {
  let indicator: String?
  let description: String?
}

struct StatusPageComponent: Codable, Sendable {
  let id: String?
  let name: String?
  let status: String?
  let group: Bool?
  let groupID: String?
  let createdAt: String?
  let updatedAt: String?

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case status
    case group
    case groupID = "group_id"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }
}

struct StatusPageIncident: Codable, Sendable {
  let id: String?
  let name: String?
  let status: String?
  let impact: String?
  let createdAt: String?
  let updatedAt: String?
  let incidentUpdates: [StatusPageIncidentUpdate]?

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case status
    case impact
    case createdAt = "created_at"
    case updatedAt = "updated_at"
    case incidentUpdates = "incident_updates"
  }
}

struct StatusPageIncidentUpdate: Codable, Sendable {
  let status: String?
  let body: String?
  let createdAt: String?
  let updatedAt: String?

  enum CodingKeys: String, CodingKey {
    case status
    case body
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }
}

struct StatusPageScheduledMaintenance: Codable, Sendable {
  let id: String?
  let name: String?
  let status: String?
  let impact: String?
  let createdAt: String?
  let updatedAt: String?
  let incidentUpdates: [StatusPageIncidentUpdate]?

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case status
    case impact
    case createdAt = "created_at"
    case updatedAt = "updated_at"
    case incidentUpdates = "incident_updates"
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
    guard let raw else { return .unknown }
    return ComponentStatus(rawValue: raw.lowercased()) ?? .unknown
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
