import Foundation

/// Command Code 用量历史存储抽象。实现必须保证并发安全且不阻塞调用方线程。
protocol CommandCodeHistoryStoring: Sendable {
  func upsert(sample: CommandCodeUsageSample) async throws
  func fetch(credentialID: String, from: Date, to: Date) async throws -> [CommandCodeUsageSample]
  func prune(before: Date) async throws
  func deleteHistory(credentialID: String?) async throws
}

/// 历史文件不可用时使用的空实现：用量展示不受影响，历史记录静默丢弃。
struct UnavailableCommandCodeHistoryStore: CommandCodeHistoryStoring {
  func upsert(sample: CommandCodeUsageSample) async throws {
    throw LevelDBError.unavailable
  }

  func fetch(credentialID: String, from: Date, to: Date) async throws -> [CommandCodeUsageSample] {
    throw LevelDBError.unavailable
  }

  func prune(before: Date) async throws {
    throw LevelDBError.unavailable
  }

  func deleteHistory(credentialID: String?) async throws {
    throw LevelDBError.unavailable
  }
}

/// Command Code 历史采用独立 JSON 文件，避免与现有 LevelDB 句柄共享目录。
/// 文件中只有趋势数值和不可逆 credentialID，不含 API Key。
actor CommandCodeHistoryFileStore: CommandCodeHistoryStoring {
  private let fileURL: URL
  private var samples: [CommandCodeUsageSample]

  init(fileURL: URL) {
    self.fileURL = fileURL
    self.samples = (try? Self.load(fileURL: fileURL)) ?? []
  }

  func upsert(sample: CommandCodeUsageSample) async throws {
    samples.removeAll {
      $0.credentialID == sample.credentialID && $0.bucketStart == sample.bucketStart
    }
    samples.append(sample)
    try persist()
  }

  func fetch(credentialID: String, from: Date, to: Date) async throws -> [CommandCodeUsageSample] {
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

  private static func load(fileURL: URL) throws -> [CommandCodeUsageSample] {
    let data = try Data(contentsOf: fileURL)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return try decoder.decode([CommandCodeUsageSample].self, from: data)
  }
}

/// Command Code 历史样本生成、读写与过期清理。JSON 文件细节不暴露给调用方。
struct CommandCodeHistoryService: Sendable {
  let store: any CommandCodeHistoryStoring
  let clock: any DateProviding
  private let pruneGate: PruneGate

  init(store: any CommandCodeHistoryStoring, clock: any DateProviding) {
    self.store = store
    self.clock = clock
    self.pruneGate = PruneGate()
  }

  /// 把一次成功响应转成当前 10 分钟桶的样本。
  func makeSample(
    remainingPercent: Int,
    daysRemaining: Int?,
    windowLimits: CommandCodeWindowLimits?,
    credentialID: String,
    at date: Date
  ) -> CommandCodeUsageSample {
    CommandCodeUsageSample(
      credentialID: credentialID,
      bucketStart: TimeBucket.bucketStart(for: date),
      observedAt: date,
      remainingPercent: remainingPercent,
      daysRemaining: daysRemaining,
      fiveHourUsedPercent: windowLimits?.fiveHour.flatMap(Self.normalizedPercent),
      weeklyUsedPercent: windowLimits?.weekly.flatMap(Self.normalizedPercent)
    )
  }

  /// 已用百分比夹在 0...100；金额缺失（cap 为 nil）时返回 nil。
  private static func normalizedPercent(_ limit: CommandCodeWindowLimit) -> Int? {
    limit.usedPercent
  }

  func save(sample: CommandCodeUsageSample) async throws {
    try await store.upsert(sample: sample)
  }

  func recentSamples(
    credentialID: String,
    hours: Int = UsageHistoryWindow.hours
  ) async throws -> [CommandCodeUsageSample] {
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

  /// 节流清理：默认每 6 小时最多执行一次。
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
