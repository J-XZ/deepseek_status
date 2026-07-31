import XCTest

@testable import DeepSeekBalance

final class MutableClock: DateProviding, @unchecked Sendable {
  private let lock = NSLock()
  private var currentDate: Date

  init(date: Date) {
    currentDate = date
  }

  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return currentDate
  }

  func advance(by seconds: TimeInterval) {
    lock.lock()
    currentDate = currentDate.addingTimeInterval(seconds)
    lock.unlock()
  }
}

/// 记录 prune 调用次数的存储，用于验证节流。
actor PruneRecordingStore: BalanceHistoryStoring {
  private(set) var pruneCount = 0
  private var samples: [BalanceSample] = []

  func upsert(samples incoming: [BalanceSample], credentialID: String) async throws {
    samples.append(contentsOf: incoming)
  }

  func fetch(credentialID: String, from: Date, to: Date) async throws -> [BalanceSample] {
    samples.filter { $0.credentialID == credentialID }
  }

  func prune(before: Date) async throws {
    pruneCount += 1
    samples.removeAll { $0.bucketStart < before }
  }

  func deleteHistory(credentialID: String?) async throws {
    if let credentialID {
      samples.removeAll { $0.credentialID == credentialID }
    } else {
      samples.removeAll()
    }
  }
}

final class BalanceHistoryServiceTests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 1_752_000_000)

  private func response() throws -> BalanceResponse {
    let data = Data(TestFixtures.multiCurrencyJSON.utf8)
    return try JSONDecoder().decode(BalanceResponse.self, from: data)
  }

  func testMakeSamplesUsesTenMinuteBucket() throws {
    let clock = FixedClock(date: t0.addingTimeInterval(599))
    let service = BalanceHistoryService(
      store: InMemoryBalanceHistoryStore(),
      clock: clock
    )
    let samples = service.makeSamples(
      from: try response(),
      credentialID: "cred",
      at: clock.now()
    )
    XCTAssertEqual(samples.count, 2)
    XCTAssertEqual(samples[0].bucketStart, t0)
    XCTAssertEqual(Set(samples.map(\.currency)), Set(["CNY", "USD"]))
  }

  func testSaveAndFetchRecent() async throws {
    let store = InMemoryBalanceHistoryStore()
    let clock = FixedClock(date: t0)
    let service = BalanceHistoryService(store: store, clock: clock)
    let samples = service.makeSamples(from: try response(), credentialID: "cred", at: t0)
    try await service.save(samples: samples)
    let recent = try await service.recentSamples(credentialID: "cred", hours: 72)
    XCTAssertEqual(recent.count, 2)
    XCTAssertEqual(Set(recent.map(\.currency)), Set(["CNY", "USD"]))
  }

  func testPruneIsThrottled() async throws {
    let store = PruneRecordingStore()
    let clock = MutableClock(date: t0)
    let service = BalanceHistoryService(store: store, clock: clock)

    try await service.pruneThrottled()
    let countAfterFirst = await store.pruneCount
    XCTAssertEqual(countAfterFirst, 1)

    // 同一时刻再次触发：被节流。
    try await service.pruneThrottled()
    let countAfterSecond = await store.pruneCount
    XCTAssertEqual(countAfterSecond, 1)

    // 超过 6 小时后触发：执行。
    clock.advance(by: 6 * 3600 + 1)
    try await service.pruneThrottled()
    let countAfterThird = await store.pruneCount
    XCTAssertEqual(countAfterThird, 2)
  }

  func testClearCredentialHistory() async throws {
    let store = InMemoryBalanceHistoryStore()
    let service = BalanceHistoryService(store: store, clock: FixedClock(date: t0))
    let samples = service.makeSamples(from: try response(), credentialID: "cred", at: t0)
    try await service.save(samples: samples)
    try await service.clear(credentialID: "cred")
    let recent = try await service.recentSamples(credentialID: "cred", hours: 72)
    XCTAssertTrue(recent.isEmpty)
  }
}
