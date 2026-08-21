import Foundation

protocol GrokBotHistoryStoring: Sendable {
  func upsert(samples: [GrokBotUsageSample], credentialID: String) async throws
  func fetch(credentialID: String, from: Date, to: Date) async throws -> [GrokBotUsageSample]
  func prune(before: Date) async throws
  func deleteHistory(credentialID: String?) async throws
}

struct UnavailableGrokBotHistoryStore: GrokBotHistoryStoring {
  func upsert(samples: [GrokBotUsageSample], credentialID: String) async throws {
    throw LevelDBError.unavailable
  }

  func fetch(credentialID: String, from: Date, to: Date) async throws -> [GrokBotUsageSample] {
    throw LevelDBError.unavailable
  }

  func prune(before: Date) async throws {
    throw LevelDBError.unavailable
  }

  func deleteHistory(credentialID: String?) async throws {
    throw LevelDBError.unavailable
  }
}

enum GrokBotHistoryKeyCodec {
  static let schemaPrefix = "grokbot/v1/"
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

struct GrokBotHistoryValue: Codable, Equatable, Sendable {
  static let currentVersion = 1

  let version: Int
  let credentialID: String
  let bucketStart: Date
  let observedAt: Date
  let remainingPercent: Int

  init(sample: GrokBotUsageSample) {
    version = Self.currentVersion
    credentialID = sample.credentialID
    bucketStart = sample.bucketStart
    observedAt = sample.observedAt
    remainingPercent = sample.remainingPercent
  }

  func makeSample() -> GrokBotUsageSample? {
    guard version == Self.currentVersion else { return nil }
    return GrokBotUsageSample(
      credentialID: credentialID,
      bucketStart: bucketStart,
      observedAt: observedAt,
      remainingPercent: remainingPercent
    )
  }
}

enum GrokBotHistoryValueCodec {
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

  static func encode(sample: GrokBotUsageSample) throws -> Data {
    try encoder.encode(GrokBotHistoryValue(sample: sample))
  }

  static func decode(_ data: Data) throws -> GrokBotUsageSample? {
    try decoder.decode(GrokBotHistoryValue.self, from: data).makeSample()
  }
}

struct GrokBotHistoryService: Sendable {
  let store: any GrokBotHistoryStoring
  let clock: any DateProviding
  private let pruneGate: PruneGate

  init(store: any GrokBotHistoryStoring, clock: any DateProviding) {
    self.store = store
    self.clock = clock
    self.pruneGate = PruneGate()
  }

  func makeSample(
    remainingPercent: Int,
    credentialID: String,
    at date: Date
  ) -> GrokBotUsageSample {
    GrokBotUsageSample(
      credentialID: credentialID,
      bucketStart: TimeBucket.bucketStart(for: date),
      observedAt: date,
      remainingPercent: remainingPercent
    )
  }

  func save(sample: GrokBotUsageSample) async throws {
    try await store.upsert(samples: [sample], credentialID: sample.credentialID)
  }

  func recentSamples(
    credentialID: String,
    hours: Int = UsageHistoryWindow.hours
  ) async throws -> [GrokBotUsageSample] {
    let now = clock.now()
    return try await store.fetch(
      credentialID: credentialID,
      from: now.addingTimeInterval(-Double(hours) * 3600),
      to: now
    )
  }

  func pruneAll(before: Date) async throws {
    try await store.prune(before: before)
  }

  func pruneThrottled(interval: TimeInterval = 6 * 3600) async throws {
    let now = clock.now()
    guard await pruneGate.shouldBegin(now: now, interval: interval) else { return }
    do {
      try await store.prune(before: now.addingTimeInterval(-UsageHistoryWindow.seconds))
      await pruneGate.finish(success: true, at: now)
    } catch {
      await pruneGate.finish(success: false, at: now)
      throw error
    }
  }

  func clear(credentialID: String) async throws {
    try await store.deleteHistory(credentialID: credentialID)
  }
}
