import Foundation

/// 版本化 value 结构。损坏或未知版本记录会被跳过，不影响其他记录。
struct HistoryValue: Codable, Equatable, Sendable {
  static let currentVersion = 1

  let version: Int
  let credentialID: String
  let bucketStart: Date
  let observedAt: Date
  let currency: String
  let totalBalance: String
  let grantedBalance: String
  let toppedUpBalance: String
  let isAvailable: Bool

  init(sample: BalanceSample) {
    version = Self.currentVersion
    credentialID = sample.credentialID
    bucketStart = sample.bucketStart
    observedAt = sample.observedAt
    currency = sample.currency
    totalBalance = sample.totalBalance
    grantedBalance = sample.grantedBalance
    toppedUpBalance = sample.toppedUpBalance
    isAvailable = sample.isAvailable
  }

  func makeSample() -> BalanceSample? {
    guard version == Self.currentVersion else { return nil }
    return BalanceSample(
      credentialID: credentialID,
      bucketStart: bucketStart,
      observedAt: observedAt,
      currency: currency,
      totalBalance: totalBalance,
      grantedBalance: grantedBalance,
      toppedUpBalance: toppedUpBalance,
      isAvailable: isAvailable
    )
  }
}

enum HistoryValueCodec {
  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    return encoder
  }()

  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return decoder
  }()

  static func encode(sample: BalanceSample) throws -> Data {
    try encoder.encode(HistoryValue(sample: sample))
  }

  static func decode(_ data: Data) throws -> BalanceSample? {
    try decoder.decode(HistoryValue.self, from: data).makeSample()
  }
}
