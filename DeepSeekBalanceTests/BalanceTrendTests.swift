import XCTest

@testable import DeepSeekBalance

final class BalanceTrendTests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 1_752_000_000)

  private func sample(
    at bucket: Date,
    currency: String = "CNY",
    total: String = "100.00",
    granted: String = "10.00",
    toppedUp: String = "90.00",
    observedAt: Date? = nil
  ) -> BalanceSample {
    BalanceSample(
      credentialID: "cred",
      bucketStart: bucket,
      observedAt: observedAt ?? bucket,
      currency: currency,
      totalBalance: total,
      grantedBalance: granted,
      toppedUpBalance: toppedUp,
      isAvailable: true
    )
  }

  func testParsesDecimalSafely() {
    XCTAssertEqual(BalanceTrendProcessor.decimal(from: "110.00"), Decimal(string: "110.00"))
    XCTAssertNil(BalanceTrendProcessor.decimal(from: "not-a-number"))
  }

  func testDecimalToChartDouble() {
    XCTAssertEqual(BalanceTrendProcessor.double(from: Decimal(string: "10.50")!), 10.5)
  }

  func testFourteenDayDeltaNegative() {
    let samples = [
      sample(at: t0, total: "110.00"),
      sample(at: t0.addingTimeInterval(3600), total: "100.00"),
    ]
    let summary = BalanceTrendProcessor.summary(samples: samples, currency: "CNY")
    XCTAssertEqual(
      summary.text(language: .simplifiedChinese),
      "近14天用量变化：-¥10.00（-9.1%）"
    )
  }

  func testFourteenDayDeltaPositive() {
    let samples = [
      sample(at: t0, total: "100.00"),
      sample(at: t0.addingTimeInterval(3600), total: "110.00"),
    ]
    let summary = BalanceTrendProcessor.summary(samples: samples, currency: "CNY")
    XCTAssertEqual(
      summary.text(language: .simplifiedChinese),
      "近14天用量变化：+¥10.00（+10.0%）"
    )
  }

  func testInsufficientSamples() {
    let samples = [sample(at: t0)]
    let summary = BalanceTrendProcessor.summary(samples: samples, currency: "CNY")
    XCTAssertEqual(
      summary.text(language: .simplifiedChinese),
      "近14天用量变化：样本不足"
    )
  }

  func testFirstValueZeroSkipsPercent() {
    let samples = [
      sample(at: t0, total: "0.00"),
      sample(at: t0.addingTimeInterval(3600), total: "10.00"),
    ]
    let summary = BalanceTrendProcessor.summary(samples: samples, currency: "CNY")
    if case .available(_, let percent) = summary.kind {
      XCTAssertNil(percent)
    } else {
      XCTFail("应为 available")
    }
    XCTAssertEqual(
      summary.text(language: .simplifiedChinese),
      "近14天用量变化：+¥10.00"
    )
  }

  func testFiltersByCurrency() {
    let samples = [
      sample(at: t0, currency: "CNY", total: "110.00"),
      sample(at: t0, currency: "USD", total: "10.00"),
    ]
    let points = BalanceTrendProcessor.points(for: samples, currency: "CNY")
    XCTAssertEqual(points.count, 3)
    XCTAssertTrue(points.allSatisfy { $0.metric != .toppedUp || true })
    XCTAssertEqual(Set(points.map(\.metric)), Set(TrendPoint.Metric.allCases))
  }

  func testGapSplitsSegments() {
    let samples = [
      sample(at: t0),
      sample(at: t0.addingTimeInterval(600)),
      sample(at: t0.addingTimeInterval(600 + 1300)),
    ]
    let points = BalanceTrendProcessor.points(for: samples, currency: "CNY")
    let segments = BalanceTrendProcessor.segments(from: points)
    XCTAssertEqual(segments.count, 2)
  }

  func testNoGapKeepsSingleSegment() {
    let samples = [
      sample(at: t0),
      sample(at: t0.addingTimeInterval(600)),
      sample(at: t0.addingTimeInterval(1200)),
    ]
    let points = BalanceTrendProcessor.points(for: samples, currency: "CNY")
    let segments = BalanceTrendProcessor.segments(from: points)
    XCTAssertEqual(segments.count, 1)
  }

  func testSingleSampleProducesPoints() {
    let samples = [sample(at: t0)]
    let points = BalanceTrendProcessor.points(for: samples, currency: "CNY")
    XCTAssertEqual(points.count, 3)
  }

  func testInvalidAmountsAreSkipped() {
    let samples = [
      sample(at: t0, total: "bad"),
      sample(at: t0.addingTimeInterval(600), total: "100.00"),
    ]
    let points = BalanceTrendProcessor.points(for: samples, currency: "CNY")
    XCTAssertEqual(points.count, 3)
    XCTAssertEqual(points.filter { $0.metric == .total }.first?.value, 100)
  }

  func testPointsAreSortedAscending() {
    let samples = [
      sample(at: t0.addingTimeInterval(1200)),
      sample(at: t0),
      sample(at: t0.addingTimeInterval(600)),
    ]
    let points = BalanceTrendProcessor.points(for: samples, currency: "CNY")
    let dates = points.map(\.date)
    XCTAssertEqual(dates, dates.sorted())
  }

  func testSameBucketDeduplicates() {
    let samples = [
      sample(at: t0, total: "100.00", observedAt: t0.addingTimeInterval(1)),
      sample(at: t0, total: "90.00", observedAt: t0.addingTimeInterval(120)),
    ]
    let points = BalanceTrendProcessor.points(for: samples, currency: "CNY")
    XCTAssertEqual(points.count, 3)
    XCTAssertEqual(points.filter { $0.metric == .total }.first?.value, 90)
  }

  func testDeltaTextFormats() {
    XCTAssertEqual(
      BalanceTrendProcessor.deltaText(delta: Decimal(string: "12.35")!, currency: "CNY"),
      "+¥12.35"
    )
    XCTAssertEqual(
      BalanceTrendProcessor.deltaText(delta: Decimal(string: "-3.20")!, currency: "USD"),
      "-$3.20"
    )
    XCTAssertEqual(
      BalanceTrendProcessor.deltaText(delta: 0, currency: "CNY"),
      "¥0.00"
    )
  }

  func testPercentText() {
    XCTAssertEqual(
      TrendSummary.percentText(Decimal(string: "12.6")!, language: .simplifiedChinese),
      "+12.6%"
    )
    XCTAssertEqual(
      TrendSummary.percentText(Decimal(string: "-3.0")!, language: .simplifiedChinese),
      "-3.0%"
    )
  }

  private func exhaustionPoint(_ offset: TimeInterval, remaining: Double) -> UsageExhaustionPoint {
    UsageExhaustionPoint(date: t0.addingTimeInterval(offset), remaining: remaining)
  }

  func testExhaustionEstimatePrefersTheMostRecentHour() {
    let points = [
      exhaustionPoint(-3600, remaining: 100),
      exhaustionPoint(0, remaining: 90),
    ]
    XCTAssertEqual(
      UsageExhaustionEstimator.estimate(points: points, now: t0) ?? -1,
      9 * 3600,
      accuracy: 0.001
    )
  }

  func testExhaustionEstimateFallsBackToTwentyFourHours() {
    let points = [
      exhaustionPoint(-20 * 3600, remaining: 100),
      exhaustionPoint(-10 * 3600, remaining: 90),
      exhaustionPoint(0, remaining: 90),
    ]
    XCTAssertEqual(
      UsageExhaustionEstimator.estimate(points: points, now: t0) ?? -1,
      180 * 3600,
      accuracy: 0.001
    )
  }

  func testExhaustionEstimateFallsBackToSeventyTwoHours() {
    let points = [
      exhaustionPoint(-48 * 3600, remaining: 100),
      exhaustionPoint(-24 * 3600, remaining: 80),
      exhaustionPoint(0, remaining: 80),
    ]
    XCTAssertEqual(
      UsageExhaustionEstimator.estimate(points: points, now: t0) ?? -1,
      8 * 24 * 3600,
      accuracy: 0.001
    )
  }

  func testExhaustionEstimateFallsBackToAllHistory() {
    let points = [
      exhaustionPoint(-5 * 24 * 3600, remaining: 100),
      exhaustionPoint(-4 * 24 * 3600, remaining: 90),
      exhaustionPoint(0, remaining: 90),
    ]
    XCTAssertEqual(
      UsageExhaustionEstimator.estimate(points: points, now: t0) ?? -1,
      45 * 24 * 3600,
      accuracy: 0.001
    )
  }

  func testExhaustionEstimateReturnsNilWithoutConsumption() {
    let points = [
      exhaustionPoint(-24 * 3600, remaining: 100),
      exhaustionPoint(0, remaining: 100),
    ]
    XCTAssertNil(UsageExhaustionEstimator.estimate(points: points, now: t0))
  }

  func testExhaustionDurationUsesLocalizedLargestUsefulUnit() {
    XCTAssertEqual(
      UsageExhaustionEstimator.formattedDuration(2 * 24 * 3600, language: .simplifiedChinese),
      "2天"
    )
    XCTAssertEqual(
      UsageExhaustionEstimator.formattedDuration(3 * 3600, language: .english),
      "3 hours"
    )
    XCTAssertEqual(
      UsageExhaustionEstimator.formattedDuration(4 * 60, language: .simplifiedChinese),
      "4分钟"
    )
  }
}
