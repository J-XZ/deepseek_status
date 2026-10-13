import Foundation

protocol XSubscriptionHistoryStoring: Sendable {
  func upsert(samples: [XSubscriptionUsageSample], credentialID: String) async throws
  func fetch(credentialID: String, from: Date, to: Date) async throws -> [XSubscriptionUsageSample]
  func prune(before: Date) async throws
  func deleteHistory(credentialID: String?) async throws
}

struct UnavailableXSubscriptionHistoryStore: XSubscriptionHistoryStoring {
  func upsert(samples: [XSubscriptionUsageSample], credentialID: String) async throws {
    throw LevelDBError.unavailable
  }

  func fetch(
    credentialID: String,
    from: Date,
    to: Date
  ) async throws -> [XSubscriptionUsageSample] {
    throw LevelDBError.unavailable
  }

  func prune(before: Date) async throws {
    throw LevelDBError.unavailable
  }

  func deleteHistory(credentialID: String?) async throws {
    throw LevelDBError.unavailable
  }
}

enum XSubscriptionHistoryKeyCodec {
  static let schemaPrefix = "xsubscription/v1/"
  static let legacyWeeklyPrefix = "grokbot/v1/"
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
    parse(key: key, prefix: schemaPrefix)
  }

  static func parse(key: String, prefix: String) -> (credentialID: String, bucketSeconds: Int64)? {
    guard key.hasPrefix(prefix) else { return nil }
    let rest = key.dropFirst(prefix.count)
    let parts = rest.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, let seconds = Int64(parts[1]) else { return nil }
    return (String(parts[0]), seconds)
  }
}

struct XSubscriptionHistoryValue: Codable, Equatable, Sendable {
  static let currentVersion = 1

  let version: Int
  let credentialID: String
  let bucketStart: Date
  let observedAt: Date
  let remainingPercent: Int

  init(sample: XSubscriptionUsageSample) {
    version = Self.currentVersion
    credentialID = sample.credentialID
    bucketStart = sample.bucketStart
    observedAt = sample.observedAt
    remainingPercent = sample.remainingPercent
  }

  func makeSample(rewritingCredentialID: String? = nil) -> XSubscriptionUsageSample? {
    guard version == Self.currentVersion else { return nil }
    guard (0...100).contains(remainingPercent) else { return nil }
    return XSubscriptionUsageSample(
      credentialID: rewritingCredentialID ?? credentialID,
      bucketStart: bucketStart,
      observedAt: observedAt,
      remainingPercent: remainingPercent
    )
  }
}

enum XSubscriptionHistoryValueCodec {
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

  static func encode(sample: XSubscriptionUsageSample) throws -> Data {
    try encoder.encode(XSubscriptionHistoryValue(sample: sample))
  }

  static func decode(
    _ data: Data,
    rewritingCredentialID: String? = nil
  ) throws -> XSubscriptionUsageSample? {
    try decoder.decode(XSubscriptionHistoryValue.self, from: data)
      .makeSample(rewritingCredentialID: rewritingCredentialID)
  }
}

struct XSubscriptionHistoryService: Sendable {
  let store: any XSubscriptionHistoryStoring
  let clock: any DateProviding
  private let pruneGate: PruneGate

  init(store: any XSubscriptionHistoryStoring, clock: any DateProviding) {
    self.store = store
    self.clock = clock
    self.pruneGate = PruneGate()
  }

  func makeSample(
    remainingPercent: Int,
    credentialID: String,
    at date: Date
  ) -> XSubscriptionUsageSample {
    XSubscriptionUsageSample(
      credentialID: credentialID,
      bucketStart: TimeBucket.bucketStart(for: date),
      observedAt: date,
      remainingPercent: remainingPercent
    )
  }

  func save(sample: XSubscriptionUsageSample) async throws {
    try await store.upsert(samples: [sample], credentialID: sample.credentialID)
  }

  func recentSamples(
    credentialID: String,
    hours: Int = UsageHistoryWindow.hours
  ) async throws -> [XSubscriptionUsageSample] {
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

enum XSubscriptionHistoryMigrator {
  static let markerKey = "xSubscription.historyMigrated"
  static let grokBotDirectoryName = "GrokBotHistory.leveldb"
  static let cursorDirectoryName = "CursorHistory.leveldb"

  static func shouldMigrate(defaults: UserDefaults) -> Bool {
    defaults.object(forKey: markerKey) as? Bool != true
  }

  static func importedSamples(
    from legacy: [XSubscriptionUsageSample],
    credentialID: String
  ) -> [XSubscriptionUsageSample] {
    legacy.compactMap { sample in
      guard (0...100).contains(sample.remainingPercent) else { return nil }
      return XSubscriptionUsageSample(
        credentialID: credentialID,
        bucketStart: sample.bucketStart,
        observedAt: sample.observedAt,
        remainingPercent: sample.remainingPercent
      )
    }
  }

  static func markMigrated(defaults: UserDefaults) {
    defaults.set(true, forKey: markerKey)
  }

  static func removeLegacyDirectories(
    grokBot: URL,
    cursor: URL,
    fileManager: FileManager = .default
  ) {
    try? fileManager.removeItem(at: grokBot)
    try? fileManager.removeItem(at: cursor)
  }

  static func migrateIfNeeded(
    grokBotDirectory: URL,
    cursorDirectory: URL,
    destination: any XSubscriptionHistoryStoring,
    credentialID: String,
    defaults: UserDefaults,
    fileManager: FileManager = .default
  ) async {
    guard shouldMigrate(defaults: defaults) else { return }
    if fileManager.fileExists(atPath: grokBotDirectory.path) {
      let legacy = (try? LevelDBXSubscriptionHistoryStore.loadLegacyWeeklySamples(
        directory: grokBotDirectory,
        prefix: XSubscriptionHistoryKeyCodec.legacyWeeklyPrefix,
        credentialID: credentialID
      )) ?? []
      let imported = importedSamples(from: legacy, credentialID: credentialID)
      if !imported.isEmpty {
        try? await destination.upsert(samples: imported, credentialID: credentialID)
      }
    }
    removeLegacyDirectories(grokBot: grokBotDirectory, cursor: cursorDirectory, fileManager: fileManager)
    markMigrated(defaults: defaults)
  }
}
