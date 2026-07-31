import XCTest

@testable import DeepSeekBalance

final class InMemoryHistoryStoreTests: XCTestCase {
  private var store = InMemoryBalanceHistoryStore()
  private let t0 = Date(timeIntervalSince1970: 1_752_000_000)

  override func setUp() {
    super.setUp()
    store = InMemoryBalanceHistoryStore()
  }

  private func sample(
    at bucket: Date,
    currency: String = "CNY",
    total: String = "100.00",
    credentialID: String = "cred"
  ) -> BalanceSample {
    BalanceSample(
      credentialID: credentialID,
      bucketStart: bucket,
      observedAt: bucket,
      currency: currency,
      totalBalance: total,
      grantedBalance: "1.00",
      toppedUpBalance: "2.00",
      isAvailable: true
    )
  }

  func testUpsertAndFetch() async throws {
    try await store.upsert(
      samples: [sample(at: t0), sample(at: t0.addingTimeInterval(600))],
      credentialID: "cred"
    )
    let fetched = try await store.fetch(
      credentialID: "cred", from: .distantPast, to: .distantFuture)
    XCTAssertEqual(fetched.count, 2)
  }

  func testFetchRespectsTimeRange() async throws {
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
    XCTAssertTrue(fetched[0].bucketStart <= fetched[1].bucketStart)
  }

  func testResultsAreSortedAscending() async throws {
    try await store.upsert(
      samples: [
        sample(at: t0.addingTimeInterval(600)),
        sample(at: t0),
        sample(at: t0.addingTimeInterval(-600)),
      ],
      credentialID: "cred"
    )
    let fetched = try await store.fetch(
      credentialID: "cred", from: .distantPast, to: .distantFuture)
    XCTAssertEqual(
      fetched.map(\.bucketStart),
      [t0.addingTimeInterval(-600), t0, t0.addingTimeInterval(600)]
    )
  }

  func testCredentialIsolation() async throws {
    try await store.upsert(samples: [sample(at: t0, credentialID: "a")], credentialID: "a")
    try await store.upsert(samples: [sample(at: t0, credentialID: "b")], credentialID: "b")
    let a = try await store.fetch(credentialID: "a", from: .distantPast, to: .distantFuture)
    let b = try await store.fetch(credentialID: "b", from: .distantPast, to: .distantFuture)
    XCTAssertEqual(a.count, 1)
    XCTAssertEqual(b.count, 1)
  }

  func testPrune() async throws {
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

  func testDeleteCurrentCredential() async throws {
    try await store.upsert(samples: [sample(at: t0, credentialID: "a")], credentialID: "a")
    try await store.upsert(samples: [sample(at: t0, credentialID: "b")], credentialID: "b")
    try await store.deleteHistory(credentialID: "a")
    let a = try await store.fetch(credentialID: "a", from: .distantPast, to: .distantFuture)
    let b = try await store.fetch(credentialID: "b", from: .distantPast, to: .distantFuture)
    XCTAssertTrue(a.isEmpty)
    XCTAssertEqual(b.count, 1)
  }

  func testDeleteAllHistory() async throws {
    try await store.upsert(samples: [sample(at: t0, credentialID: "a")], credentialID: "a")
    try await store.upsert(samples: [sample(at: t0, credentialID: "b")], credentialID: "b")
    try await store.deleteHistory(credentialID: nil)
    let a = try await store.fetch(credentialID: "a", from: .distantPast, to: .distantFuture)
    let b = try await store.fetch(credentialID: "b", from: .distantPast, to: .distantFuture)
    XCTAssertTrue(a.isEmpty)
    XCTAssertTrue(b.isEmpty)
  }

  func testConcurrentUpsertsRemainConsistent() async throws {
    let samples = (0..<40).map { index in
      sample(at: t0.addingTimeInterval(TimeInterval(index) * 600))
    }
    await withTaskGroup(of: Void.self) { group in
      for sample in samples {
        group.addTask {
          try? await self.store.upsert(samples: [sample], credentialID: "cred")
        }
      }
    }
    let fetched = try await store.fetch(
      credentialID: "cred", from: .distantPast, to: .distantFuture)
    XCTAssertEqual(fetched.count, 40)
  }
}
