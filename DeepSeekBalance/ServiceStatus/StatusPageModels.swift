import Foundation

/// Atlassian Statuspage `/api/v2/status.json` 响应。
struct StatusPageStatusResponse: Codable, Sendable {
  struct Page: Codable, Sendable {
    let name: String?
    let url: String?
  }

  struct Status: Codable, Sendable {
    let indicator: String?
    let description: String?
  }

  let page: Page?
  let status: Status?
}

/// Atlassian Statuspage `/api/v2/components.json` 响应。
struct StatusPageComponentsResponse: Codable, Sendable {
  let components: [StatusPageComponent]?
}

struct StatusPageComponent: Codable, Sendable {
  let id: String?
  let name: String?
  let status: String?
  let description: String?
  let group: Bool?
}

/// Atlassian Statuspage `/api/v2/incidents/unresolved.json` 响应。
struct StatusPageIncidentsResponse: Codable, Sendable {
  let incidents: [StatusPageIncident]?
}

struct StatusPageIncident: Codable, Sendable {
  let id: String?
  let name: String?
  let status: String?
  let impact: String?
  let updatedAt: String?
  let incidentUpdates: [StatusPageIncidentUpdate]?

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case status
    case impact
    case updatedAt = "updated_at"
    case incidentUpdates = "incident_updates"
  }
}

struct StatusPageIncidentUpdate: Codable, Sendable {
  let body: String?
  let status: String?
  let updatedAt: String?

  enum CodingKeys: String, CodingKey {
    case body
    case status
    case updatedAt = "updated_at"
  }
}

/// 三个端点汇总，供映射层使用。
struct StatusPageSummaryResponse: Sendable {
  let status: StatusPageStatusResponse
  let components: StatusPageComponentsResponse
  let incidents: StatusPageIncidentsResponse
}
