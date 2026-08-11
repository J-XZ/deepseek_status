import XCTest

@testable import DeepSeekBalance

final class TrendPeriodTests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 1_752_000_000)

  func testCycleOrder() {
    XCTAssertEqual(
      TrendPeriod.cycle,
      [.fourteenDays, .sevenDays, .oneDay, .threeHours, .oneHour]
    )
    XCTAssertEqual(TrendPeriod.fourteenDays.next(), .sevenDays)
    XCTAssertEqual(TrendPeriod.sevenDays.next(), .oneDay)
    XCTAssertEqual(TrendPeriod.oneDay.next(), .threeHours)
    XCTAssertEqual(TrendPeriod.threeHours.next(), .oneHour)
    XCTAssertEqual(TrendPeriod.oneHour.next(), .fourteenDays)
  }

  func testDurations() {
    XCTAssertEqual(TrendPeriod.fourteenDays.duration, 14 * 24 * 3600)
    XCTAssertEqual(TrendPeriod.sevenDays.duration, 7 * 24 * 3600)
    XCTAssertEqual(TrendPeriod.oneDay.duration, 24 * 3600)
    XCTAssertEqual(TrendPeriod.threeHours.duration, 3 * 3600)
    XCTAssertEqual(TrendPeriod.oneHour.duration, 3600)
  }

  func testDisplayNames() {
    XCTAssertEqual(
      TrendPeriod.fourteenDays.displayName(language: .simplifiedChinese),
      "14天"
    )
    XCTAssertEqual(
      TrendPeriod.sevenDays.displayName(language: .simplifiedChinese),
      "7天"
    )
    XCTAssertEqual(
      TrendPeriod.oneDay.displayName(language: .simplifiedChinese),
      "1天"
    )
    XCTAssertEqual(
      TrendPeriod.threeHours.displayName(language: .simplifiedChinese),
      "3小时"
    )
    XCTAssertEqual(
      TrendPeriod.oneHour.displayName(language: .simplifiedChinese),
      "1小时"
    )
    XCTAssertEqual(
      TrendPeriod.oneHour.displayName(language: .english),
      "1 hour"
    )
  }

  func testFilterBoundaries() {
    let now = t0.addingTimeInterval(10 * 3600)
    let period = TrendPeriod.oneDay
    let boundary = now.addingTimeInterval(-period.duration)
    let samples = [
      boundary.addingTimeInterval(-1),
      boundary,
      now,
      now.addingTimeInterval(1),
    ]
    let filtered = TrendPeriod.filtered(samples, period: period, now: now) { $0 }
    XCTAssertEqual(filtered, [boundary, now])
  }

  /// 历史按 10 分钟桶采样；1 小时 / 3 小时窗口直接用真实原始点展示，
  /// 不做按天聚合，也不伪造缺失数据。
  func testShortWindowsKeepTenMinuteGranularity() {
    let now = t0
    let hourlySamples = (0..<6).map {
      t0.addingTimeInterval(-TimeInterval(5 - $0) * 600)
    }
    let oneHour = TrendPeriod.filtered(hourlySamples, period: .oneHour, now: now) { $0 }
    XCTAssertEqual(oneHour.count, 6)
    XCTAssertTrue(TrendPeriod.oneHour.isSubDaily)
    XCTAssertEqual(
      TrendPeriod.oneHour.aggregation,
      .rawTenMinutePoints
    )

    let threeHourSamples = (0..<18).map {
      t0.addingTimeInterval(-TimeInterval(17 - $0) * 600)
    }
    let threeHours = TrendPeriod.filtered(threeHourSamples, period: .threeHours, now: now) { $0 }
    XCTAssertEqual(threeHours.count, 18)
    XCTAssertTrue(TrendPeriod.threeHours.isSubDaily)
    XCTAssertEqual(
      TrendPeriod.threeHours.aggregation,
      .rawTenMinutePoints
    )
  }

  func testBalanceChartModelFiltersByPeriodAndDomain() {
    let now = t0.addingTimeInterval(TrendPeriod.oneDay.duration)
    let old = Date(timeIntervalSince1970: t0.timeIntervalSince1970 - 10 * 3600)
    let samples = [
      sample(at: old),
      sample(at: now.addingTimeInterval(-600)),
      sample(at: now),
    ]
    let model = BalanceTrendProcessor.chartModel(
      samples: samples,
      currency: "CNY",
      now: now,
      period: .oneHour
    )
    XCTAssertEqual(
      model.xDomain,
      now.addingTimeInterval(-3600)...now
    )
    let visibleDates = Set(model.segments.flatMap(\.points).map(\.date))
    XCTAssertFalse(visibleDates.contains(old))
    XCTAssertTrue(visibleDates.contains(now.addingTimeInterval(-600)))
    XCTAssertTrue(visibleDates.contains(now))
  }

  private func sample(
    at bucket: Date,
    total: String = "100.00",
    granted: String = "10.00",
    toppedUp: String = "90.00"
  ) -> BalanceSample {
    BalanceSample(
      credentialID: "cred",
      bucketStart: bucket,
      observedAt: bucket,
      currency: "CNY",
      totalBalance: total,
      grantedBalance: granted,
      toppedUpBalance: toppedUp,
      isAvailable: true
    )
  }
}
