import Foundation

enum XSubscriptionConnectRPC {
  static let emptyJSONBody = Data("{}".utf8)

  static func postRequest(
    url: URL,
    accessToken: String,
    timeoutInterval: TimeInterval,
    body: Data = emptyJSONBody
  ) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
    request.httpBody = body
    request.timeoutInterval = timeoutInterval
    return request
  }
}

enum XSubscriptionDailySpendRequest {
  static let groupByProduct = 5
  static let spendTypeAll = 3

  static func utcStartOfDay(_ date: Date) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.startOfDay(for: date)
  }

  static func epochMsString(_ date: Date) -> String {
    String(Int64((date.timeIntervalSince1970 * 1000).rounded()))
  }

  static func body(userId: Int64, periodStart: Date, periodEnd: Date) throws -> Data {
    try JSONEncoder().encode(
      Body(
        userId: userId,
        periodStartMs: epochMsString(utcStartOfDay(periodStart)),
        periodEndMs: epochMsString(periodEnd),
        groupBy: groupByProduct,
        spendType: spendTypeAll,
        includeCreditUsage: true
      )
    )
  }

  private struct Body: Encodable {
    let userId: Int64
    let periodStartMs: String
    let periodEndMs: String
    let groupBy: Int
    let spendType: Int
    let includeCreditUsage: Bool
  }
}

enum XSubscriptionPercent {
  /// Dashboard 用量字段（usagePercent / *PercentUsed）已经是 0...100 的百分比，
  /// 例如 0.84 表示 0.84%（官方显示“已用 1%”），不能再乘 100。
  static func usedPercent(from raw: Double?) -> Int? {
    guard let raw, raw.isFinite else { return nil }
    return max(0, min(100, Int(raw.rounded())))
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

  static func parseRFC3339(_ string: String) -> Date? {
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

enum ConnectFlexibleInt64 {
  static func decode<K: CodingKey>(
    _ container: KeyedDecodingContainer<K>,
    forKey key: K
  ) -> Int64? {
    guard container.contains(key) else { return nil }
    if let asString = try? container.decode(String.self, forKey: key) {
      return Int64(asString)
    }
    if let asNumber = try? container.decode(Int64.self, forKey: key) {
      return asNumber
    }
    if let asDouble = try? container.decode(Double.self, forKey: key), asDouble.isFinite {
      return Int64(asDouble.rounded())
    }
    return nil
  }

  static func dateFromEpochMs(_ millis: Int64?) -> Date? {
    guard let millis, millis > 0 else { return nil }
    return Date(timeIntervalSince1970: Double(millis) / 1000)
  }
}

struct ProtobufTimestamp: Decodable {
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
