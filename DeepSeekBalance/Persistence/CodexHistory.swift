import Foundation

/// Codex 用量历史存储抽象。实现必须保证并发安全且不阻塞调用方线程。
protocol CodexHistoryStoring: Sendable {
  func upsert(samples: [CodexUsageSample], credentialID: String) async throws
  func fetch(credentialID: String, from: Date, to: Date) async throws -> [CodexUsageSample]
  func prune(before: Date) async throws
  func deleteHistory(credentialID: String?) async throws
}

/// LevelDB 不可用时使用的空实现：用量展示不受影响，历史记录静默丢弃。
struct UnavailableCodexHistoryStore: CodexHistoryStoring {
  func upsert(samples: [CodexUsageSample], credentialID: String) async throws {
    throw LevelDBError.unavailable
  }

  func fetch(credentialID: String, from: Date, to: Date) async throws -> [CodexUsageSample] {
    throw LevelDBError.unavailable
  }

  func prune(before: Date) async throws {
    throw LevelDBError.unavailable
  }

  func deleteHistory(credentialID: String?) async throws {
    throw LevelDBError.unavailable
  }
}

/// Codex 历史 LevelDB key 编解码。
/// 格式：`codex/v1/<credentialID>/<10位UTC桶秒>`，
/// 时间戳使用固定宽度十进制，保证字典序与时间序一致。
enum CodexHistoryKeyCodec {
  static let schemaPrefix = "codex/v1/"
  private static let width = 10

  static func validCredentialID(_ credentialID: String) -> Bool {
    !credentialID.isEmpty
      && !credentialID.contains("/")
      && !credentialID.contains("\0")
      && !credentialID.contains("\\")
      && !credentialID.contains(":")
  }

  static func key(credentialID: String, bucketStart: Date) -> String {
    let seconds = Int64(bucketStart.timeIntervalSince1970)
    return "\(schemaPrefix)\(credentialID)/\(padded(seconds))"
  }

  static func credentialPrefix(credentialID: String) -> String {
    "\(schemaPrefix)\(credentialID)/"
  }

  static func schemaPrefixKey() -> String {
    schemaPrefix
  }

  static func padded(_ seconds: Int64) -> String {
    String(format: "%0\(width)lld", seconds)
  }

  static func parse(key: String) -> (credentialID: String, bucketSeconds: Int64)? {
    guard key.hasPrefix(schemaPrefix) else { return nil }
    let rest = key.dropFirst(schemaPrefix.count)
    let parts = rest.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, let seconds = Int64(parts[1]) else { return nil }
    return (String(parts[0]), seconds)
  }
}

/// 版本化 value 结构。损坏或未知版本记录会被跳过，不影响其他记录。
struct CodexHistoryValue: Codable, Equatable, Sendable {
  static let currentVersion = 1

  let version: Int
  let credentialID: String
  let bucketStart: Date
  let observedAt: Date
  let remainingPercent: Int

  init(sample: CodexUsageSample) {
    version = Self.currentVersion
    credentialID = sample.credentialID
    bucketStart = sample.bucketStart
    observedAt = sample.observedAt
    remainingPercent = sample.remainingPercent
  }

  func makeSample() -> CodexUsageSample? {
    guard version == Self.currentVersion else { return nil }
    return CodexUsageSample(
      credentialID: credentialID,
      bucketStart: bucketStart,
      observedAt: observedAt,
      remainingPercent: remainingPercent
    )
  }
}

enum CodexHistoryValueCodec {
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

  static func encode(sample: CodexUsageSample) throws -> Data {
    try encoder.encode(CodexHistoryValue(sample: sample))
  }

  static func decode(_ data: Data) throws -> CodexUsageSample? {
    try decoder.decode(CodexHistoryValue.self, from: data).makeSample()
  }
}
