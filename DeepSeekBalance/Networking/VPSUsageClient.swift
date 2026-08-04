import Foundation

protocol VPSUsageFetching: Sendable {
  func fetchUsage(config: VPSUsageConfig, now: Date) async throws -> VPSUsageSnapshot
}

/// Vultr API 客户端。
///
/// 带宽沿用 vps_usage 项目的 MTD 口径；额外请求 `/account` 读取账户美元余额，
/// `/instances/{id}` 只用于实例名称和按创建日期推导当前月度周期。
struct VultrUsageClient: VPSUsageFetching {
  enum APIError: Error, Equatable, Sendable {
    case missingConfig
    case unauthorized
    case rateLimited
    case httpError(statusCode: Int)
    case server(statusCode: Int)
    case noNetwork
    case timedOut
    case decodingFailed
    case invalidResponse
    case cycleUnavailable
    case cancelled
  }

  private let baseURL: URL
  private let session: URLSession

  init(
    session: URLSession? = nil,
    baseURL: URL = URL(string: "https://api.vultr.com/v2")!
  ) {
    self.baseURL = baseURL
    if let session {
      self.session = session
    } else {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.urlCache = nil
      configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
      self.session = URLSession(configuration: configuration)
    }
  }

  func fetchUsage(config: VPSUsageConfig, now: Date) async throws -> VPSUsageSnapshot {
    guard config.isComplete else { throw APIError.missingConfig }

    async let accountRoot = requestJSON(path: "account", token: config.apiToken)
    async let bandwidthRoot = requestJSON(path: "account/bandwidth", token: config.apiToken)
    async let instanceRoot = requestJSON(
      path: "instances/\(config.instanceID)",
      token: config.apiToken
    )

    let account = try await accountRoot
    let bandwidth = try await bandwidthRoot
    let instance = try await instanceRoot

    let balance = try Self.parseAccountBalance(from: account)
    let (totalGB, usedGB) = try Self.parseMonthToDateUsage(from: bandwidth)
    let details = try Self.parseInstanceDetails(from: instance)
    guard let createdAt = details.createdAt else {
      throw APIError.cycleUnavailable
    }
    let cycle = try Self.billingCycleFromInstanceCreated(anchor: createdAt, now: now)

    return VPSUsageSnapshot(
      instanceID: config.instanceID,
      instanceLabel: details.label,
      cycleStart: cycle.start,
      cycleEnd: cycle.end,
      totalBandwidthGB: totalGB,
      usedBandwidthGB: usedGB,
      remainingCreditUSD: abs(balance),
      refreshedAt: now
    )
  }

  static func parseAccountBalance(from object: Any) throws -> Double {
    guard let root = object as? [String: Any] else {
      throw APIError.invalidResponse
    }
    let account = root["account"] as? [String: Any] ?? root
    guard let balance = asDouble(account["balance"]) else {
      throw APIError.decodingFailed
    }
    return balance
  }

  static func parseMonthToDateUsage(from object: Any) throws -> (totalGB: Double, usedGB: Double) {
    guard let root = object as? [String: Any],
      let bandwidth = root["bandwidth"] as? [String: Any],
      let monthToDate = bandwidth["current_month_to_date"] as? [String: Any],
      let totalGB = asDouble(monthToDate["instance_bandwidth_credits"]),
      let usedGB = asDouble(monthToDate["gb_out"])
    else {
      throw APIError.decodingFailed
    }
    return (totalGB, usedGB)
  }

  static func parseInstanceDetails(from object: Any) throws -> (createdAt: Date?, label: String?) {
    guard let root = object as? [String: Any] else {
      throw APIError.invalidResponse
    }
    let instance = root["instance"] as? [String: Any] ?? root
    return (
      parseISODate(instance["date_created"]),
      instance["label"] as? String
    )
  }

  static func billingCycleFromInstanceCreated(
    anchor: Date,
    now: Date,
    calendar: Calendar = Calendar(identifier: .gregorian)
  ) throws -> (start: Date, end: Date) {
    guard anchor <= now else { throw APIError.cycleUnavailable }
    var start = anchor
    guard var end = calendar.date(byAdding: .month, value: 1, to: start) else {
      throw APIError.cycleUnavailable
    }

    var iterations = 0
    while end <= now && iterations < 500 {
      start = end
      guard let next = calendar.date(byAdding: .month, value: 1, to: end) else {
        throw APIError.cycleUnavailable
      }
      end = next
      iterations += 1
    }
    guard end > start else { throw APIError.cycleUnavailable }
    return (start, end)
  }

  private func requestJSON(path: String, token: String) async throws -> Any {
    let url = path
      .split(separator: "/", omittingEmptySubsequences: true)
      .reduce(baseURL) { partial, component in
        partial.appendingPathComponent(String(component), isDirectory: false)
      }

    for attempt in 0...3 {
      do {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
          throw APIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
          throw Self.httpError(for: http.statusCode)
        }
        do {
          return try JSONSerialization.jsonObject(with: data)
        } catch {
          throw APIError.decodingFailed
        }
      } catch let error as APIError {
        guard shouldRetry(error), attempt < 3 else { throw error }
        try await retryDelay(attempt: attempt)
      } catch is CancellationError {
        throw APIError.cancelled
      } catch let error as URLError {
        let mapped: APIError = error.code == .timedOut ? .timedOut : .noNetwork
        guard attempt < 3 else { throw mapped }
        try await retryDelay(attempt: attempt)
      } catch {
        guard attempt < 3 else { throw APIError.noNetwork }
        try await retryDelay(attempt: attempt)
      }
    }

    throw APIError.invalidResponse
  }

  private func retryDelay(attempt: Int) async throws {
    try await Task.sleep(nanoseconds: UInt64(500_000_000) * UInt64(1 << attempt))
  }

  private func shouldRetry(_ error: APIError) -> Bool {
    switch error {
    case .rateLimited, .server, .noNetwork, .timedOut:
      return true
    default:
      return false
    }
  }

  private static func httpError(for statusCode: Int) -> APIError {
    switch statusCode {
    case 401, 403:
      return .unauthorized
    case 429:
      return .rateLimited
    case 500...599:
      return .server(statusCode: statusCode)
    default:
      return .httpError(statusCode: statusCode)
    }
  }

  private static func asDouble(_ value: Any?) -> Double? {
    if let number = value as? NSNumber { return number.doubleValue }
    if let string = value as? String { return Double(string) }
    return nil
  }

  private static func parseISODate(_ value: Any?) -> Date? {
    guard let string = value as? String else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: string) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: string)
  }
}
