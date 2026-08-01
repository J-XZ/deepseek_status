import Foundation

/// Cursor 用量获取抽象，便于测试注入可控实现。
protocol CursorUsageFetching: Sendable {
  func fetchUsage(accessToken: String) async throws -> CursorUsageResponse
}

/// `api2.cursor.sh` DashboardService.GetCurrentPeriodUsage 客户端。
/// 使用 `async/await` + `URLSession`；契约来自 Cursor 客户端内部端点，非公开文档。
struct CursorUsageClient: CursorUsageFetching {
  enum APIError: Error, Equatable {
    case unauthorized
    case httpError(statusCode: Int)
    case server(statusCode: Int)
    case noNetwork
    case timedOut
    case decodingFailed
    case cancelled
  }

  let baseURL: URL
  let session: URLSession
  let timeoutInterval: TimeInterval

  init(
    baseURL: URL = URL(
      string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
    )!,
    session: URLSession = .shared,
    timeoutInterval: TimeInterval = 15
  ) {
    self.baseURL = baseURL
    self.session = session
    self.timeoutInterval = timeoutInterval
  }

  func fetchUsage(accessToken: String) async throws -> CursorUsageResponse {
    var request = URLRequest(url: baseURL)
    request.httpMethod = "POST"
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    // Cursor 客户端后端要求该协议版本头。
    request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
    request.httpBody = Data("{}".utf8)
    request.timeoutInterval = timeoutInterval

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch let error as URLError {
      switch error.code {
      case .cancelled:
        throw APIError.cancelled
      case .timedOut:
        throw APIError.timedOut
      default:
        throw APIError.noNetwork
      }
    } catch {
      throw APIError.noNetwork
    }

    guard let http = response as? HTTPURLResponse else {
      throw APIError.noNetwork
    }

    switch http.statusCode {
    case 200...299:
      do {
        return try JSONDecoder().decode(CursorUsageResponse.self, from: data)
      } catch {
        throw APIError.decodingFailed
      }
    case 401:
      throw APIError.unauthorized
    case 500...599:
      throw APIError.server(statusCode: http.statusCode)
    default:
      throw APIError.httpError(statusCode: http.statusCode)
    }
  }
}
