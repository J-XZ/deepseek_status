import CoreGraphics
import XCTest

@testable import DeepSeekBalance

final class TrendChartModelTests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 1_752_000_000)
  private let now = Date(timeIntervalSince1970: 1_752_000_000 + 72 * 3600)

  private func sample(
    at bucket: Date,
    currency: String = "CNY",
    total: String = "100.00",
    granted: String = "10.00",
    toppedUp: String = "90.00",
    credentialID: String = "cred"
  ) -> BalanceSample {
    BalanceSample(
      credentialID: credentialID,
      bucketStart: bucket,
      observedAt: bucket,
      currency: currency,
      totalBalance: total,
      grantedBalance: granted,
      toppedUpBalance: toppedUp,
      isAvailable: true
    )
  }

  func testSingleSampleProducesNoLine() {
    let model = BalanceTrendProcessor.chartModel(
      samples: [sample(at: t0)],
      currency: "CNY",
      now: now
    )
    XCTAssertTrue(model.segments.isEmpty)
  }

  func testMultipleSamplesProduceLines() {
    let samples = [
      sample(at: t0),
      sample(at: t0.addingTimeInterval(600)),
      sample(at: t0.addingTimeInterval(1200)),
    ]
    let model = BalanceTrendProcessor.chartModel(
      samples: samples,
      currency: "CNY",
      now: now
    )
    XCTAssertEqual(model.segments.count, 3)
  }

  func testExactTwentyMinuteGapDoesNotSplit() {
    let samples = [
      sample(at: t0),
      sample(at: t0.addingTimeInterval(20 * 60)),
    ]
    let model = BalanceTrendProcessor.chartModel(
      samples: samples,
      currency: "CNY",
      now: now
    )
    XCTAssertEqual(model.segments.count, 3)
  }

  func testOverTwentyMinuteGapSplits() {
    let samples = [
      sample(at: t0),
      sample(at: t0.addingTimeInterval(20 * 60 + 1)),
    ]
    let model = BalanceTrendProcessor.chartModel(
      samples: samples,
      currency: "CNY",
      now: now
    )
    XCTAssertEqual(model.segments.count, 0)
  }

  func testMetricsSegmentIndependently() {
    // chartModel 按 metric 独立分段：这里直接验证各 metric 的点流分段互不影响。
    func point(_ date: Date, _ metric: TrendPoint.Metric, _ value: Double = 100) -> TrendPoint {
      TrendPoint(
        id: "\(metric.rawValue)-\(date.timeIntervalSince1970)",
        date: date,
        metric: metric,
        value: value
      )
    }

    let totalPoints = [
      point(t0, .total),
      point(t0.addingTimeInterval(600), .total),
      point(t0.addingTimeInterval(2100), .total),
      point(t0.addingTimeInterval(2700), .total),
    ]
    let toppedUpPoints = [
      point(t0, .toppedUp),
      point(t0.addingTimeInterval(600), .toppedUp),
      point(t0.addingTimeInterval(1200), .toppedUp),
      point(t0.addingTimeInterval(2100), .toppedUp),
      point(t0.addingTimeInterval(2700), .toppedUp),
    ]

    let totalSegments = BalanceTrendProcessor.segments(from: totalPoints)
    let toppedUpSegments = BalanceTrendProcessor.segments(from: toppedUpPoints)
    XCTAssertEqual(totalSegments.count, 2)
    XCTAssertEqual(toppedUpSegments.count, 1)
  }

  func testXDomainIsRecentSeventyTwoHours() {
    let model = BalanceTrendProcessor.chartModel(
      samples: [sample(at: t0)],
      currency: "CNY",
      now: now
    )
    XCTAssertEqual(model.xDomain.lowerBound, now.addingTimeInterval(-72 * 3600))
    XCTAssertEqual(model.xDomain.upperBound, now)
  }

  func testManySamplesProduceOnlyLines() {
    let samples = (0..<432).map { index in
      sample(at: t0.addingTimeInterval(TimeInterval(index) * 600))
    }
    let model = BalanceTrendProcessor.chartModel(
      samples: samples,
      currency: "CNY",
      now: now
    )
    XCTAssertEqual(model.segments.count, 3)
    XCTAssertTrue(model.segments.allSatisfy { $0.points.count == 432 })
  }

  func testNearestSampleSelection() {
    let samples = [
      sample(at: t0, total: "100.00"),
      sample(at: t0.addingTimeInterval(600), total: "90.00"),
      sample(at: t0.addingTimeInterval(1200), total: "80.00"),
    ]
    let nearest = BalanceTrendProcessor.nearestSample(
      to: t0.addingTimeInterval(650),
      samples: samples,
      currency: "CNY"
    )
    XCTAssertEqual(nearest?.bucketStart, t0.addingTimeInterval(600))
    XCTAssertEqual(nearest?.totalBalance, "90.00")
  }

  func testNearestSampleFiltersCurrency() {
    let samples = [
      sample(at: t0, total: "100.00"),
      sample(at: t0, currency: "USD", total: "10.00"),
    ]
    let nearest = BalanceTrendProcessor.nearestSample(
      to: t0,
      samples: samples,
      currency: "CNY"
    )
    XCTAssertEqual(nearest?.currency, "CNY")
  }

  func testPlotCoordinateBounds() {
    let frame = CGRect(x: 20, y: 10, width: 400, height: 180)
    XCTAssertTrue(
      BalanceTrendProcessor.containsPlotCoordinate(CGPoint(x: 20, y: 10), in: frame)
    )
    XCTAssertTrue(
      BalanceTrendProcessor.containsPlotCoordinate(CGPoint(x: 420, y: 190), in: frame)
    )
    XCTAssertFalse(
      BalanceTrendProcessor.containsPlotCoordinate(CGPoint(x: 19, y: 50), in: frame)
    )
    XCTAssertFalse(
      BalanceTrendProcessor.containsPlotCoordinate(CGPoint(x: 100, y: 200), in: frame)
    )
  }

  func testUnknownCurrencyAxisFormat() {
    XCTAssertEqual(BalanceAxisFormat(currency: "EUR").format(10), "EUR 10.00")
    XCTAssertEqual(BalanceAxisFormat(currency: "CNY").format(10), "¥10.00")
    XCTAssertEqual(BalanceAxisFormat(currency: "USD").format(10), "$10.00")
  }
}
