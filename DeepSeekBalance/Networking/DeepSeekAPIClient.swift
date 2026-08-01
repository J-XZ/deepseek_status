import Foundation

/// 余额获取抽象，便于测试注入可控实现。
protocol BalanceFetching: Sendable {
  func fetchBalance(apiKey: String) async throws -> BalanceResponse
}

/// DeepSeek 余额接口客户端。使用 `async/await` + `URLSession`。
struct DeepSeekAPIClient {
  enum APIError: Error, Equatable {
    case unauthorized
    case insufficientBalance
    case rateLimited
    case httpError(statusCode: Int)
    case server(statusCode: Int)
    case noNetwork
    case timedOut
    case decodingFailed
    case cancelled

    /// 语义化映射：状态层只保存错误种类，翻译由 UI 层按当前语言生成。
    func asDisplayError() -> AppDisplayError {
      switch self {
      case .unauthorized:
        return .unauthorized
      case .insufficientBalance:
        return .insufficientBalance
      case .rateLimited:
        return .rateLimited
      case .httpError(let code):
        return .http(code)
      case .server(let code):
        return .server(code)
      case .noNetwork:
        return .noNetwork
      case .timedOut:
        return .timeout
      case .decodingFailed:
        return .decoding
      case .cancelled:
        return .unknown
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
      throw APIError.httpError(statusCode: http.statusCode)
    }
  }
}

extension DeepSeekAPIClient: BalanceFetching {}
