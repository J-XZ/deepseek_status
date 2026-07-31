import XCTest

@testable import DeepSeekBalance

/// 真实 LevelDB 测试：使用临时目录，每个测试唯一子目录，结束后关闭并删除。
final class LevelDBBalanceHistoryStoreTests: XCTestCase {
  private var directory: URL!
  private var store: LevelDBBalanceHistoryStore?
  private let t0 = Date(timeIntervalSince1970: 1_752_000_000)

  override func setUp() {
    super.setUp()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("LevelDBTests-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDown() async throws {
    if let store {
      await store.close()
    }
    store = nil
    try? FileManager.default.removeItem(at: directory)
    try await super.tearDown()
  }

  private func makeStore() throws -> LevelDBBalanceHistoryStore {
    let newStore = try LevelDBBalanceHistoryStore(directory: directory)
    store = newStore
    return newStore
  }

  private func sample(
    at bucket: Date,
    currency: String = "CNY",
    total: String = "100.00",
    credentialID: String = "cred",
    observedAt: Date? = nil
  ) -> BalanceSample {
    BalanceSample(
      credentialID: credentialID,
      bucketStart: bucket,
      observedAt: observedAt ?? bucket,
      currency: currency,
      totalBalance: total,
      grantedBalance: "1.00",
      toppedUpBalance: "2.00",
      isAvailable: true
    )
  }

  func testCreatesDirectoryAutomatically() async throws {
    let deep = directory.appendingPathComponent("a/b", isDirectory: true)
    let store = try LevelDBBalanceHistoryStore(directory: deep)
    XCTAssertTrue(FileManager.default.fileExists(atPath: deep.path))
    await store.close()
  }

  func testOpensDatabaseAndWritesSingleSample() async throws {
    let store = try makeStore()
    try await store.upsert(samples: [sample(at: t0)], credentialID: "cred")
    let fetched = try await store.fetch(
      credentialID: "cred", from: .distantPast, to: .distantFuture)
    XCTAssertEqual(fetched.count, 1)
    XCTAssertEqual(fetched[0].totalBalance, "100.00")
  }

  func testWritesMultipleCurrenciesInBatch() async throws {
    let store = try makeStore()
    try await store.upsert(
      samples: [
        sample(at: t0, currency: "CNY", total: "110.00"),
        sample(at: t0, currency: "USD", total: "10.00"),
      ],
      credentialID: "cred"
    )
    let fetched = try await store.fetch(
      credentialID: "cred", from: .distantPast, to: .distantFuture)
    XCTAssertEqual(fetched.count, 2)
    XCTAssertEqual(Set(fetched.map(\.currency)), Set(["CNY", "USD"]))
  }

  func testDataSurvivesReopen() async throws {
    var first: LevelDBBalanceHistoryStore? = try makeStore()
    try await first?.upsert(samples: [sample(at: t0)], credentialID: "cred")
    await first?.close()
    first = nil

    let second = try LevelDBBalanceHistoryStore(directory: directory)
    let fetched = try await second.fetch(
      credentialID: "cred", from: .distantPast, to: .distantFuture)
    XCTAssertEqual(fetched.count, 1)
    await second.close()
  }

  func testSameBucketUpsert() async throws {
    let store = try makeStore()
    try await store.upsert(
      samples: [sample(at: t0, total: "100.00", observedAt: t0.addingTimeInterval(1))],
      credentialID: "cred"
    )
    try await store.upsert(
      samples: [sample(at: t0, total: "95.00", observedAt: t0.addingTimeInterval(120))],
      credentialID: "cred"
    )
    let fetched = try await store.fetch(
      credentialID: "cred", from: .distantPast, to: .distantFuture)
    XCTAssertEqual(fetched.count, 1)
    XCTAssertEqual(fetched[0].totalBalance, "95.00")
  }

  func testCredentialPrefixScan() async throws {
    let store = try makeStore()
    try await store.upsert(samples: [sample(at: t0, credentialID: "a")], credentialID: "a")
    try await store.upsert(samples: [sample(at: t0, credentialID: "b")], credentialID: "b")
    let a = try await store.fetch(credentialID: "a", from: .distantPast, to: .distantFuture)
    XCTAssertEqual(a.count, 1)
    XCTAssertEqual(a[0].credentialID, "a")
  }

  func testCurrencyPrefixScan() async throws {
    let store = try makeStore()
    try await store.upsert(
      samples: [sample(at: t0, currency: "CNY"), sample(at: t0, currency: "USD")],
      credentialID: "cred"
    )
    let fetched = try await store.fetch(
      credentialID: "cred", from: .distantPast, to: .distantFuture)
    XCTAssertEqual(fetched.count, 2)
  }

  func testTimeRangeScan() async throws {
    let store = try makeStore()
    try await store.upsert(
      samples: [
        sample(at: t0.addingTimeInterval(-1200)),
        sample(at: t0),
        sample(at: t0.addingTimeInterval(600)),
      ],
      credentialID: "cred"
    )
    let fetched = try await store.fetch(
      credentialID: "cred", from: t0, to: t0.addingTimeInterval(600))
    XCTAssertEqual(fetched.count, 2)
  }

  func testPrune() async throws {
    let store = try makeStore()
    try await store.upsert(
      samples: [
        sample(at: t0.addingTimeInterval(-100_000)),
        sample(at: t0),
      ],
      credentialID: "cred"
    )
    try await store.prune(before: t0.addingTimeInterval(-3600))
    let fetched = try await store.fetch(
      credentialID: "cred", from: .distantPast, to: .distantFuture)
    XCTAssertEqual(fetched.count, 1)
    XCTAssertEqual(fetched[0].bucketStart, t0)
  }

  func testDeleteCredentialHistory() async throws {
    let store = try makeStore()
    try await store.upsert(samples: [sample(at: t0, credentialID: "a")], credentialID: "a")
    try await store.upsert(samples: [sample(at: t0, credentialID: "b")], credentialID: "b")
    try await store.deleteHistory(credentialID: "a")
    let a = try await store.fetch(credentialID: "a", from: .distantPast, to: .distantFuture)
    let b = try await store.fetch(credentialID: "b", from: .distantPast, to: .distantFuture)
    XCTAssertTrue(a.isEmpty)
    XCTAssertEqual(b.count, 1)
  }

  func testDeleteAllHistory() async throws {
    let store = try makeStore()
    try await store.upsert(samples: [sample(at: t0, credentialID: "a")], credentialID: "a")
    try await store.upsert(samples: [sample(at: t0, credentialID: "b")], credentialID: "b")
    try await store.deleteHistory(credentialID: nil)
    let a = try await store.fetch(credentialID: "a", from: .distantPast, to: .distantFuture)
    let b = try await store.fetch(credentialID: "b", from: .distantPast, to: .distantFuture)
    XCTAssertTrue(a.isEmpty)
    XCTAssertTrue(b.isEmpty)
  }

  func testCorruptValueIsSkipped() async throws {
    let store = try makeStore()
    try await store.upsert(samples: [sample(at: t0, total: "100.00")], credentialID: "cred")
    let key = HistoryKeyCodec.key(credentialID: "cred", currency: "CNY", bucketStart: t0)
    try await store.writeRaw(key: key, value: Data("not-json".utf8))

    // 不崩溃、不抛错，损坏记录被跳过。
    let fetched = try await store.fetch(
      credentialID: "cred", from: .distantPast, to: .distantFuture)
    XCTAssertTrue(fetched.isEmpty)
  }

  func testCorruptValueDoesNotAffectOtherRecords() async throws {
    let store = try makeStore()
    try await store.upsert(
      samples: [
        sample(at: t0, currency: "CNY", total: "100.00"),
        sample(at: t0, currency: "USD", total: "10.00"),
      ],
      credentialID: "cred"
    )
    let corruptKey = HistoryKeyCodec.key(credentialID: "cred", currency: "CNY", bucketStart: t0)
    try await store.writeRaw(key: corruptKey, value: Data("garbage".utf8))
    let fetched = try await store.fetch(
      credentialID: "cred", from: .distantPast, to: .distantFuture)
    XCTAssertEqual(fetched.count, 1)
    XCTAssertEqual(fetched[0].currency, "USD")
  }

  func testActorSerializesAccess() async throws {
    let store = try makeStore()
    let samples = (0..<30).map { index in
      sample(at: t0.addingTimeInterval(TimeInterval(index) * 600))
    }
    await withTaskGroup(of: Void.self) { group in
      for sample in samples {
        group.addTask {
          try? await store.upsert(samples: [sample], credentialID: "cred")
        }
      }
    }
    let fetched = try await store.fetch(
      credentialID: "cred", from: .distantPast, to: .distantFuture)
    XCTAssertEqual(fetched.count, 30)
  }
}
