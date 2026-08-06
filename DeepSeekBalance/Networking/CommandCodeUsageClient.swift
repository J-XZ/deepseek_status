import Foundation

/// Command Code 用量获取抽象，便于测试注入可控实现。
protocol CommandCodeUsageFetching: Sendable {
  func fetchUsage(apiKey: String) async throws -> CommandCodeUsageResponse
}

/// `api.commandcode.ai` 用量客户端。
/// 使用 `async/await` + `URLSession`；契约来自 Command Code CLI 源码（/alpha/* 端点）。
struct CommandCodeUsageClient: CommandCodeUsageFetching {
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
    baseURL: URL = URL(string: "https://api.commandcode.ai")!,
    session: URLSession = .shared,
    timeoutInterval: TimeInterval = 15
  ) {
    self.baseURL = baseURL
    self.session = session
    self.timeoutInterval = timeoutInterval
  }

  /// 并行请求 whoami、credits、subscriptions、usage/summary，合并为一次用量响应。
  func fetchUsage(apiKey: String) async throws -> CommandCodeUsageResponse {
    async let whoamiTask = getJSON(apiKey: apiKey, path: "/alpha/whoami")
    async let creditsTask = getJSON(apiKey: apiKey, path: "/alpha/billing/credits")
    async let subscriptionsTask = getJSON(
      apiKey: apiKey,
      path: "/alpha/billing/subscriptions"
    )
    async let summaryTask = getJSON(apiKey: apiKey, path: "/alpha/usage/summary")

    let whoamiData: Data
    let creditsData: Data
    let subscriptionsData: Data
    let summaryData: Data
    do {
      (whoamiData, creditsData, subscriptionsData, summaryData) = try await (
        whoamiTask,
        creditsTask,
        subscriptionsTask,
        summaryTask
      )
    } catch {
      throw error
    }

    let decoder = JSONDecoder()
    // whoami: 顶层 success/user/org；credits: 顶层 credits/windowLimits；
    // subscriptions: 顶层 success/data；summary: 顶层直接是指标。
    let user: CommandCodeUser? = decodeEnvelope(CommandCodeUserEnvelope.self, from: whoamiData)?.user
    let credits: CommandCodeCredits? = decodeEnvelope(
      CommandCodeCreditsEnvelope.self,
      from: creditsData
    )?.credits
    let windowLimits: CommandCodeWindowLimits? = decodeEnvelope(
      CommandCodeCreditsEnvelope.self,
      from: creditsData
    )?.windowLimits
    let subscription: CommandCodeSubscription? = decodeEnvelope(
      CommandCodeSubscriptionEnvelope.self,
      from: subscriptionsData
    )?.data
    let summary = try? decoder.decode(CommandCodeUsageSummary.self, from: summaryData)

    return CommandCodeUsageResponse(
      credits: credits,
      windowLimits: windowLimits,
      subscription: subscription,
      summary: summary,
      user: user
    )
  }

  private func getJSON(apiKey: String, path: String) async throws -> Data {
    var request = URLRequest(url: baseURL.appendingPathComponent(path))
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
      return data
    case 401:
      throw APIError.unauthorized
    case 500...599:
      throw APIError.server(statusCode: http.statusCode)
    default:
      throw APIError.httpError(statusCode: http.statusCode)
    }
  }

  private func decodeEnvelope<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
    try? JSONDecoder().decode(type, from: data)
  }
}

// 响应信封（与 Command Code API 实际结构一致）。
struct CommandCodeUserEnvelope: Decodable {
  let user: CommandCodeUser?
}

struct CommandCodeCreditsEnvelope: Decodable {
  let credits: CommandCodeCredits?
  let windowLimits: CommandCodeWindowLimits?
}

struct CommandCodeSubscriptionEnvelope: Decodable {
  let data: CommandCodeSubscription?
}
