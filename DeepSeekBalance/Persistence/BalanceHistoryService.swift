import Foundation

/// 历史样本生成、读写与过期清理。LevelDB 细节不暴露给调用方。
struct BalanceHistoryService: Sendable {
  let store: any BalanceHistoryStoring
  let clock: any DateProviding
  private let pruneGate: PruneGate

  init(store: any BalanceHistoryStoring, clock: any DateProviding) {
    self.store = store
    self.clock = clock
    self.pruneGate = PruneGate()
  }

  /// 把一次成功响应转成当前 10 分钟桶的样本（每币种一条）。
  func makeSamples(
    from response: BalanceResponse,
    credentialID: String,
    at date: Date
  ) -> [BalanceSample] {
    let bucketStart = TimeBucket.bucketStart(for: date)
    return response.balanceInfos.map { info in
      BalanceSample(
        credentialID: credentialID,
        bucketStart: bucketStart,
        observedAt: date,
        currency: info.currency,
        totalBalance: info.totalBalance,
        grantedBalance: info.grantedBalance,
        toppedUpBalance: info.toppedUpBalance,
        isAvailable: response.isAvailable
      )
    }
  }

  func save(samples: [BalanceSample]) async throws {
    guard let credentialID = samples.first?.credentialID else { return }
    try await store.upsert(samples: samples, credentialID: credentialID)
  }

  func recentSamples(credentialID: String, hours: Int = 72) async throws -> [BalanceSample] {
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
      // 失败不记录成功时间，下一次刷新可以立即重试。
      await pruneGate.finish(success: false, at: now)
      throw error
    }
  }

  func clear(credentialID: String) async throws {
    try await store.deleteHistory(credentialID: credentialID)
  }
}

/// 节流状态：只有 prune 真正成功后才记录 lastPrune；
/// isPruning 防止两个并发调用同时执行 prune。
actor PruneGate {
  private var lastPrune: Date?
  private var isPruning = false

  func shouldBegin(now: Date, interval: TimeInterval) -> Bool {
    guard !isPruning else { return false }
    if let lastPrune, now.timeIntervalSince(lastPrune) < interval {
      return false
    }
    isPruning = true
    return true
  }

  func finish(success: Bool, at now: Date) {
    isPruning = false
    if success {
      lastPrune = now
    }
  }
}
