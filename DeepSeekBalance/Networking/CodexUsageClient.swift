import Foundation

/// Codex 用量获取抽象，便于测试注入可控实现。
protocol CodexUsageFetching: Sendable {
  func fetchUsage(accessToken: String) async throws -> CodexUsageResponse
}

/// ChatGPT `/backend-api/wham/usage` 客户端。使用 `async/await` + `URLSession`。
struct CodexUsageClient: CodexUsageFetching {
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
    baseURL: URL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
    session: URLSession = .shared,
    timeoutInterval: TimeInterval = 15
  ) {
    self.baseURL = baseURL
    self.session = session
    self.timeoutInterval = timeoutInterval
  }

  func fetchUsage(accessToken: String) async throws -> CodexUsageResponse {
    var request = URLRequest(url: baseURL)
    request.httpMethod = "GET"
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    // wham/usage 对无 UA 的请求会拒绝（403）。
    request.setValue(
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36",
      forHTTPHeaderField: "User-Agent"
    )
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
        return try JSONDecoder().decode(CodexUsageResponse.self, from: data)
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
