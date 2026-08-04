import Foundation

/// Vultr 最近 14 天趋势样本。只保存剩余值，不保存 API Token。
struct VPSUsageSample: Codable, Equatable, Identifiable, Sendable {
  let credentialID: String
  let bucketStart: Date
  let observedAt: Date
  let remainingBandwidthGB: Double
  let remainingCreditUSD: Double

  var id: String {
    "\(credentialID)/\(Int64(bucketStart.timeIntervalSince1970))"
  }

  /// 兼容旧历史中可能保存的负账户余额，图表按额度绝对值展示。
  var availableCreditUSD: Double {
    abs(remainingCreditUSD)
  }
}

protocol VPSHistoryStoring: Sendable {
  func upsert(sample: VPSUsageSample) async throws
  func fetch(credentialID: String, from: Date, to: Date) async throws -> [VPSUsageSample]
  func prune(before: Date) async throws
  func deleteHistory(credentialID: String?) async throws
}

/// VPS 趋势独立保存，避免和其它供应商的 LevelDB 句柄互相影响。
actor VPSHistoryFileStore: VPSHistoryStoring {
  private let fileURL: URL
  private var samples: [VPSUsageSample]

  init(fileURL: URL) {
    self.fileURL = fileURL
    self.samples = (try? Self.load(fileURL: fileURL)) ?? []
  }

  func upsert(sample: VPSUsageSample) async throws {
    samples.removeAll {
      $0.credentialID == sample.credentialID && $0.bucketStart == sample.bucketStart
    }
    samples.append(sample)
    try persist()
  }

  func fetch(
    credentialID: String,
    from: Date,
    to: Date
  ) async throws -> [VPSUsageSample] {
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
    try encoder.encode(samples).write(to: fileURL, options: [.atomic])
  }

  private static func load(fileURL: URL) throws -> [VPSUsageSample] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return try decoder.decode([VPSUsageSample].self, from: Data(contentsOf: fileURL))
  }
}

struct VPSHistoryService: Sendable {
  let store: any VPSHistoryStoring
  let clock: any DateProviding
  private let pruneGate: PruneGate

  init(store: any VPSHistoryStoring, clock: any DateProviding) {
    self.store = store
    self.clock = clock
    self.pruneGate = PruneGate()
  }

  func makeSample(
    from snapshot: VPSUsageSnapshot,
    credentialID: String,
    at date: Date
  ) -> VPSUsageSample {
    VPSUsageSample(
      credentialID: credentialID,
      bucketStart: TimeBucket.bucketStart(for: date),
      observedAt: date,
      remainingBandwidthGB: snapshot.remainingBandwidthGB,
      remainingCreditUSD: snapshot.availableCreditUSD
    )
  }

  func save(sample: VPSUsageSample) async throws {
    try await store.upsert(sample: sample)
  }

  func recentSamples(
    credentialID: String,
    hours: Int = UsageHistoryWindow.hours
  ) async throws -> [VPSUsageSample] {
    let now = clock.now()
    return try await store.fetch(
      credentialID: credentialID,
      from: now.addingTimeInterval(-Double(hours) * 3600),
      to: now
    )
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

  func clear(credentialID: String?) async throws {
    try await store.deleteHistory(credentialID: credentialID)
  }
}
