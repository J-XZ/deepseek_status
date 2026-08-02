import Foundation

/// OpenCode 趋势历史样本。
/// Go 保存 5 小时、每周、月度窗口的已用百分比，Zen 保存美元余额。
struct OpenCodeUsageSample: Codable, Equatable, Identifiable, Sendable {
  let credentialID: String
  let bucketStart: Date
  let observedAt: Date
  let goRollingUsedPercent: Int?
  let goWeeklyUsedPercent: Int?
  let goMonthlyUsedPercent: Int?
  let zenBalanceUSD: Double?

  var id: String {
    "\(credentialID)/\(Int64(bucketStart.timeIntervalSince1970))"
  }
}

protocol OpenCodeHistoryStoring: Sendable {
  func upsert(sample: OpenCodeUsageSample) async throws
  func fetch(credentialID: String, from: Date, to: Date) async throws -> [OpenCodeUsageSample]
  func prune(before: Date) async throws
  func deleteHistory(credentialID: String?) async throws
}

/// OpenCode 历史采用独立 JSON 文件，避免与现有 LevelDB 句柄共享目录。
/// 文件中只有趋势数值和不可逆 credentialID，不含 Cookie。
actor OpenCodeHistoryFileStore: OpenCodeHistoryStoring {
  private let fileURL: URL
  private var samples: [OpenCodeUsageSample]

  init(fileURL: URL) {
    self.fileURL = fileURL
    self.samples = (try? Self.load(fileURL: fileURL)) ?? []
  }

  func upsert(sample: OpenCodeUsageSample) async throws {
    samples.removeAll {
      $0.credentialID == sample.credentialID && $0.bucketStart == sample.bucketStart
    }
    samples.append(sample)
    try persist()
  }

  func fetch(credentialID: String, from: Date, to: Date) async throws -> [OpenCodeUsageSample] {
    samples
      .filter {
        $0.credentialID == credentialID && $0.bucketStart >= from && $0.bucketStart <= to
      }
      .sorted { $0.bucketStart < $1.bucketStart }
  }

  func prune(before: Date) async throws {
    samples.removeAll { $0.bucketStart < before }
    try persist()
  }

  func deleteHistory(credentialID: String?) async throws {
    if let credentialID {
      samples.removeAll { $0.credentialID == credentialID }
    } else {
      samples.removeAll()
    }
    try persist()
  }

  private func persist() throws {
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: nil
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    let data = try encoder.encode(samples)
    try data.write(to: fileURL, options: [.atomic])
  }

  private static func load(fileURL: URL) throws -> [OpenCodeUsageSample] {
    let data = try Data(contentsOf: fileURL)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return try decoder.decode([OpenCodeUsageSample].self, from: data)
  }
}

struct OpenCodeHistoryService: Sendable {
  let store: any OpenCodeHistoryStoring
  let clock: any DateProviding
  private let pruneGate: PruneGate

  init(store: any OpenCodeHistoryStoring, clock: any DateProviding) {
    self.store = store
    self.clock = clock
    self.pruneGate = PruneGate()
  }

  func makeSample(
    from snapshot: OpenCodeUsageSnapshot,
    credentialID: String,
    at date: Date
  ) -> OpenCodeUsageSample? {
    let goRolling = snapshot.goRollingUsedPercent
    let goWeekly = snapshot.goWeeklyUsedPercent
    let goMonthly = snapshot.goMonthlyUsedPercent
    let zen = snapshot.zenBalanceUSD
    guard goRolling != nil || goWeekly != nil || goMonthly != nil || zen != nil else {
      return nil
    }
    return OpenCodeUsageSample(
      credentialID: credentialID,
      bucketStart: TimeBucket.bucketStart(for: date),
      observedAt: date,
      goRollingUsedPercent: goRolling.map(Self.normalizedPercent),
      goWeeklyUsedPercent: goWeekly.map(Self.normalizedPercent),
      goMonthlyUsedPercent: goMonthly.map { max(0, min(100, $0)) },
      zenBalanceUSD: zen
    )
  }

  private static func normalizedPercent(_ value: Int) -> Int {
    max(0, min(100, value))
  }

  func save(sample: OpenCodeUsageSample) async throws {
    try await store.upsert(sample: sample)
  }

  func recentSamples(credentialID: String, hours: Int = 72) async throws -> [OpenCodeUsageSample] {
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
      try await store.prune(before: now.addingTimeInterval(-72 * 3600))
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
