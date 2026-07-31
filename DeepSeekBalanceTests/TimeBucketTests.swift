import XCTest

@testable import DeepSeekBalance

final class TimeBucketTests: XCTestCase {
  // 1_752_000_000 是 600 的整数倍，便于构造边界。
  private let t0 = Date(timeIntervalSince1970: 1_752_000_000)

  func testExactBoundaryBelongsToSameBucket() {
    XCTAssertEqual(TimeBucket.bucketStart(for: t0), t0)
  }

  func testEndOfBucketBelongsToSameBucket() {
    XCTAssertEqual(TimeBucket.bucketStart(for: t0.addingTimeInterval(599)), t0)
  }

  func testNextBucketStartsOnBoundary() {
    XCTAssertEqual(
      TimeBucket.bucketStart(for: t0.addingTimeInterval(600)),
      t0.addingTimeInterval(600)
    )
  }

  func testBucketAlwaysFloorsDown() {
    XCTAssertEqual(TimeBucket.bucketStart(for: t0.addingTimeInterval(1)), t0)
    XCTAssertEqual(
      TimeBucket.bucketStart(for: t0.addingTimeInterval(601)),
      t0.addingTimeInterval(600)
    )
  }

  func testBucketIsIndependentOfTimeZone() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
    let shanghaiNoon = try XCTUnwrap(
      calendar.date(
        from: DateComponents(year: 2026, month: 7, day: 31, hour: 12, minute: 0, second: 0)
      )
    )
    let bucket = TimeBucket.bucketStart(for: shanghaiNoon)
    var utcCalendar = Calendar(identifier: .gregorian)
    utcCalendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
    let components = utcCalendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second],
      from: bucket
    )
    XCTAssertEqual(components.hour, 4)
    XCTAssertEqual(components.minute, 0)
  }

  func testSameBucketUpsertKeepsLatest() async throws {
    let store = InMemoryBalanceHistoryStore()
    let older = sample(bucket: t0, observedAt: t0.addingTimeInterval(1), total: "100.00")
    let newer = sample(bucket: t0, observedAt: t0.addingTimeInterval(120), total: "95.00")
    try await store.upsert(samples: [older], credentialID: "cred")
    try await store.upsert(samples: [newer], credentialID: "cred")
    let fetched = try await store.fetch(
      credentialID: "cred", from: .distantPast, to: .distantFuture)
    XCTAssertEqual(fetched.count, 1)
    XCTAssertEqual(fetched[0].totalBalance, "95.00")
  }

  func testDifferentCurrenciesDoNotOverwrite() async throws {
    let store = InMemoryBalanceHistoryStore()
    let cny = sample(bucket: t0, observedAt: t0, total: "100.00", currency: "CNY")
    let usd = sample(bucket: t0, observedAt: t0, total: "10.00", currency: "USD")
    try await store.upsert(samples: [cny, usd], credentialID: "cred")
    let fetched = try await store.fetch(
      credentialID: "cred", from: .distantPast, to: .distantFuture)
    XCTAssertEqual(fetched.count, 2)
  }

  func testDifferentCredentialsDoNotOverwrite() async throws {
    let store = InMemoryBalanceHistoryStore()
    try await store.upsert(
      samples: [sample(bucket: t0, observedAt: t0, total: "100.00", credentialID: "a")],
      credentialID: "a"
    )
    try await store.upsert(
      samples: [sample(bucket: t0, observedAt: t0, total: "200.00", credentialID: "b")],
      credentialID: "b"
    )
    let a = try await store.fetch(credentialID: "a", from: .distantPast, to: .distantFuture)
    let b = try await store.fetch(credentialID: "b", from: .distantPast, to: .distantFuture)
    XCTAssertEqual(a.count, 1)
    XCTAssertEqual(b.count, 1)
    XCTAssertEqual(a[0].totalBalance, "100.00")
    XCTAssertEqual(b[0].totalBalance, "200.00")
  }

  private func sample(
    bucket: Date,
    observedAt: Date,
    total: String,
    currency: String = "CNY",
    credentialID: String = "cred"
  ) -> BalanceSample {
    BalanceSample(
      credentialID: credentialID,
      bucketStart: bucket,
      observedAt: observedAt,
      currency: currency,
      totalBalance: total,
      grantedBalance: "1.00",
      toppedUpBalance: "2.00",
      isAvailable: true
    )
  }
}
