import Foundation

/// Codex 历史样本生成、读写与过期清理。LevelDB 细节不暴露给调用方。
struct CodexHistoryService: Sendable {
  let store: any CodexHistoryStoring
  let clock: any DateProviding
  private let pruneGate: PruneGate

  init(store: any CodexHistoryStoring, clock: any DateProviding) {
    self.store = store
    self.clock = clock
    self.pruneGate = PruneGate()
  }

  /// 把一次成功响应转成当前 10 分钟桶的样本。
  func makeSample(
    remainingPercent: Int,
    credentialID: String,
    at date: Date
  ) -> CodexUsageSample {
    CodexUsageSample(
      credentialID: credentialID,
      bucketStart: TimeBucket.bucketStart(for: date),
      observedAt: date,
      remainingPercent: remainingPercent
    )
  }

  func save(sample: CodexUsageSample) async throws {
    try await store.upsert(samples: [sample], credentialID: sample.credentialID)
  }

  func recentSamples(credentialID: String, hours: Int = 72) async throws -> [CodexUsageSample] {
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
