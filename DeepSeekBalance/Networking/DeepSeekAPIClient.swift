import Foundation

/// DeepSeek 余额接口客户端。使用 `async/await` + `URLSession`。
struct DeepSeekAPIClient {
  enum APIError: Error, LocalizedError, Equatable {
    case unauthorized
    case insufficientBalance
    case rateLimited
    case server(statusCode: Int)
    case otherHTTP(statusCode: Int)
    case noNetwork
    case timedOut
    case decodingFailed
    case cancelled

    var errorDescription: String? {
      switch self {
      case .unauthorized:
        return "API Key 无效（401）"
      case .insufficientBalance:
        return "余额不足（402）"
      case .rateLimited:
        return "请求过于频繁，请稍后再试（429）"
      case .server(let code):
        return "DeepSeek 服务暂时不可用（\(code)）"
      case .otherHTTP(let code):
        return "服务返回错误（\(code)）"
      case .noNetwork:
        return "无法连接网络，请检查网络连接"
      case .timedOut:
        return "请求超时，请稍后重试"
      case .decodingFailed:
        return "无法解析服务端响应"
      case .cancelled:
        return "请求已取消"
      }
    }
  }

  let baseURL: URL
  let session: URLSession
  let timeoutInterval: TimeInterval

  init(
    baseURL: URL = URL(string: "https://api.deepseek.com")!,
    session: URLSession = .shared,
    timeoutInterval: TimeInterval = 15
  ) {
    self.baseURL = baseURL
    self.session = session
    self.timeoutInterval = timeoutInterval
  }

  func fetchBalance(apiKey: String) async throws -> BalanceResponse {
    var request = URLRequest(url: baseURL.appendingPathComponent("user/balance"))
    request.httpMethod = "GET"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
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
        return try JSONDecoder().decode(BalanceResponse.self, from: data)
      } catch {
        throw APIError.decodingFailed
      }
    case 401:
      throw APIError.unauthorized
    case 402:
      throw APIError.insufficientBalance
    case 429:
      throw APIError.rateLimited
    case 500...599:
      throw APIError.server(statusCode: http.statusCode)
    default:
      throw APIError.otherHTTP(statusCode: http.statusCode)
    }
  }
}
