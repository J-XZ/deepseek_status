import Foundation

protocol GrokBotUsageFetching: Sendable {
  func fetchUsage(accessToken: String) async throws -> GrokBotUsageSnapshot
}

struct GrokBotUsageClient: GrokBotUsageFetching {
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
      string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus"
    )!,
    session: URLSession = .shared,
    timeoutInterval: TimeInterval = 15
  ) {
    self.baseURL = baseURL
    self.session = session
    self.timeoutInterval = timeoutInterval
  }

  func fetchUsage(accessToken: String) async throws -> GrokBotUsageSnapshot {
    let request = CursorConnectRPC.postRequest(
      url: baseURL,
      accessToken: accessToken,
      timeoutInterval: timeoutInterval
    )

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
        return try GrokBotUsageParser.parse(data)
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

enum GrokBotUsageParser {
  static func parse(_ data: Data) throws -> GrokBotUsageSnapshot {
    let wire = try JSONDecoder().decode(WireResponse.self, from: data)
    return classify(wire)
  }

  private static func classify(_ wire: WireResponse) -> GrokBotUsageSnapshot {
    let planDisplayName = wire.grokPlanLabel?.nonEmpty ?? wire.includedUsageSuperGrokPlan?.nonEmpty
    let resetAt = wire.nextResetTimestampUtc

    if wire.usesPooledEnterpriseAllowance == true {
      return GrokBotUsageSnapshot(weekly: .enterprisePooled, planDisplayName: planDisplayName)
    }

    if let trialExpiresAt = wire.sandTrialExpiresAt {
      let trial = GrokBotTrial(
        expiresAt: trialExpiresAt,
        isCancelable: wire.sandTrialCancelable ?? false
      )
      return GrokBotUsageSnapshot(weekly: .trial(trial), planDisplayName: planDisplayName)
    }

    if wire.hasNonZeroIncludedLimit == false || wire.usagePercent == nil {
      return GrokBotUsageSnapshot(weekly: .noIncludedLimit, planDisplayName: planDisplayName)
    }

    let usedPercent = clampUsedPercent(wire.usagePercent)
    let quota = GrokBotWeeklyQuota(usedPercent: usedPercent, resetsAt: resetAt)
    return GrokBotUsageSnapshot(weekly: .metered(quota), planDisplayName: planDisplayName)
  }

  private static func clampUsedPercent(_ value: Double?) -> Int {
    guard let value, value.isFinite else { return 0 }
    return max(0, min(100, Int(value.rounded())))
  }
}

enum ConnectTimestampDecoder {
  static func decode<K: CodingKey>(
    _ container: KeyedDecodingContainer<K>,
    forKey key: K
  ) -> Date? {
    guard container.contains(key) else { return nil }

    if let timestamp = try? container.decode(ProtobufTimestamp.self, forKey: key) {
      return timestamp.dateValue
    }

    if let string = try? container.decode(String.self, forKey: key),
      let date = parseRFC3339(string)
    {
      return date
    }

    if let seconds = try? container.decode(Double.self, forKey: key) {
      guard seconds > 0 else { return nil }
      return Date(timeIntervalSince1970: seconds)
    }

    if let seconds = try? container.decode(Int64.self, forKey: key) {
      guard seconds > 0 else { return nil }
      return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    return nil
  }

  private static func parseRFC3339(_ string: String) -> Date? {
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFraction.date(from: string) {
      return date
    }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: string)
  }
}

private struct ProtobufTimestamp: Decodable {
  let seconds: Int64
  let nanos: Int32

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let stringSeconds = try? container.decode(String.self, forKey: .seconds),
      let parsed = Int64(stringSeconds)
    {
      seconds = parsed
    } else if let intSeconds = try? container.decode(Int64.self, forKey: .seconds) {
      seconds = intSeconds
    } else {
      throw DecodingError.dataCorruptedError(
        forKey: .seconds,
        in: container,
        debugDescription: "Invalid protobuf seconds"
      )
    }
    nanos = (try? container.decode(Int32.self, forKey: .nanos)) ?? 0
  }

  enum CodingKeys: String, CodingKey {
    case seconds
    case nanos
  }

  var dateValue: Date? {
    guard seconds > 0 else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanos) / 1_000_000_000)
  }
}

private struct WireResponse: Decodable {
  let usagePercent: Double?
  let hasNonZeroIncludedLimit: Bool?
  let usesPooledEnterpriseAllowance: Bool?
  let sandTrialCancelable: Bool?
  let grokPlanLabel: String?
  let includedUsageSuperGrokPlan: String?
  let sandTrialExpiresAt: Date?
  let nextResetTimestampUtc: Date?

  enum CodingKeys: String, CodingKey {
    case usagePercent
    case hasNonZeroIncludedLimit
    case usesPooledEnterpriseAllowance
    case sandTrialExpiresAt
    case sandTrialCancelable
    case grokPlanLabel
    case includedUsageSuperGrokPlan
    case nextResetTimestampUtc
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    usagePercent = try container.decodeIfPresent(Double.self, forKey: .usagePercent)
    hasNonZeroIncludedLimit = try container.decodeIfPresent(
      Bool.self,
      forKey: .hasNonZeroIncludedLimit
    )
    usesPooledEnterpriseAllowance = try container.decodeIfPresent(
      Bool.self,
      forKey: .usesPooledEnterpriseAllowance
    )
    sandTrialCancelable = try container.decodeIfPresent(Bool.self, forKey: .sandTrialCancelable)
    grokPlanLabel = try container.decodeIfPresent(String.self, forKey: .grokPlanLabel)
    includedUsageSuperGrokPlan = try container.decodeIfPresent(
      String.self,
      forKey: .includedUsageSuperGrokPlan
    )
    sandTrialExpiresAt = ConnectTimestampDecoder.decode(container, forKey: .sandTrialExpiresAt)
    nextResetTimestampUtc = ConnectTimestampDecoder.decode(container, forKey: .nextResetTimestampUtc)
  }
}

private extension String {
  var nonEmpty: String? {
    isEmpty ? nil : self
  }
}
