import Foundation

/// Atlassian Statuspage 状态获取抽象（Codex / Cursor 官方状态页均为该托管格式）。
protocol StatusPageFetching: Sendable {
  func fetchSummary() async throws -> StatusPageSummaryResponse
}

/// Atlassian Statuspage 客户端（status.cursor.com、status.openai.com 等）。
/// 请求不携带 Authorization，也不记录完整响应正文。
struct StatusPageClient: StatusPageFetching {
  enum StatusError: Error, Equatable {
    case noNetwork
    case timedOut
    case http(Int)
    case decoding
    case cancelled
  }

  /// 官方状态页根 URL，例如 https://status.cursor.com
  let baseURL: URL
  let session: URLSession
  let timeoutInterval: TimeInterval

  init(
    baseURL: URL,
    session: URLSession = .shared,
    timeoutInterval: TimeInterval = 12
  ) {
    self.baseURL = baseURL
    self.session = session
    self.timeoutInterval = timeoutInterval
  }

  /// 抓取整体状态、组件与未解决事故，合并为一次汇总。
  /// 各端点独立请求；单个端点失败不影响其他（组件/事故缺失时用空数组）。
  func fetchSummary() async throws -> StatusPageSummaryResponse {
    async let statusResult = try fetchStatus()
    async let componentsResult = try fetchComponents()
    async let incidentsResult = try fetchIncidents()
    let (status, components, incidents) = try await (statusResult, componentsResult, incidentsResult)
    return StatusPageSummaryResponse(
      status: status,
      components: components,
      incidents: incidents
    )
  }

  private func fetchStatus() async throws -> StatusPageStatusResponse {
    try await requestJSON(path: "api/v2/status.json", as: StatusPageStatusResponse.self)
  }

  private func fetchComponents() async throws -> StatusPageComponentsResponse {
    try await requestJSON(path: "api/v2/components.json", as: StatusPageComponentsResponse.self)
  }

  /// 事故端点为可选数据源：解码失败或结构不符时返回空，避免整个状态不可用。
  private func fetchIncidents() async throws -> StatusPageIncidentsResponse {
    let url = baseURL.appendingPathComponent("api/v2/incidents/unresolved.json")
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.timeoutInterval = timeoutInterval

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch let error as URLError where error.code == .cancelled {
      throw StatusError.cancelled
    } catch {
      return StatusPageIncidentsResponse(incidents: [])
    }
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      return StatusPageIncidentsResponse(incidents: [])
    }
    guard let decoded = try? JSONDecoder().decode(StatusPageIncidentsResponse.self, from: data) else {
      return StatusPageIncidentsResponse(incidents: [])
    }
    return decoded
  }

  private func requestJSON<Response: Decodable>(
    path: String,
    as type: Response.Type
  ) async throws -> Response {
    let url = baseURL.appendingPathComponent(path)
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.timeoutInterval = timeoutInterval
    // 官方状态接口无需鉴权：绝不附加 Authorization。

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch let error as URLError {
      switch error.code {
      case .cancelled:
        throw StatusError.cancelled
      case .timedOut:
        throw StatusError.timedOut
      default:
        throw StatusError.noNetwork
      }
    } catch {
      throw StatusError.noNetwork
    }

    guard let http = response as? HTTPURLResponse else {
      throw StatusError.noNetwork
    }
    guard (200...299).contains(http.statusCode) else {
      throw StatusError.http(http.statusCode)
    }

    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw StatusError.decoding
    }
  }
}
