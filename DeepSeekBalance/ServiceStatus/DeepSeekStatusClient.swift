import Foundation

/// 状态获取抽象：与余额网络层完全分离，不依赖 API Key。
protocol DeepSeekStatusFetching: Sendable {
  func fetchSummary() async throws -> FlashcatStatusResponse
}

/// DeepSeek 官方状态页客户端（官方域名，Flashcat 托管）。
/// 请求不携带 Authorization，也不记录完整响应正文。
struct DeepSeekStatusClient: DeepSeekStatusFetching {
  enum StatusError: Error, Equatable {
    case noNetwork
    case timedOut
    case http(Int)
    case decoding
    case cancelled
  }

  /// 官方状态页真实公开 JSON 接口（页面 HTML 中的 page_id=6410630422455）。
  static let defaultURL =
    URL(string: "https://status.deepseek.com/api/status-page/6410630422455/summary/active")!

  let url: URL
  let session: URLSession
  let timeoutInterval: TimeInterval

  init(
    url: URL = DeepSeekStatusClient.defaultURL,
    session: URLSession = .shared,
    timeoutInterval: TimeInterval = 12
  ) {
    self.url = url
    self.session = session
    self.timeoutInterval = timeoutInterval
  }

  func fetchSummary() async throws -> FlashcatStatusResponse {
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
      return try JSONDecoder().decode(FlashcatStatusResponse.self, from: data)
    } catch {
      throw StatusError.decoding
    }
  }
}
