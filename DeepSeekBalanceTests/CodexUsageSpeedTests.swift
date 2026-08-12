import XCTest

@testable import DeepSeekBalance

final class CodexUsageSpeedTests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 1_752_000_000)

  private func sample(
    at bucket: Date,
    remaining: Int,
    observedAt: Date? = nil
  ) -> CodexUsageSample {
    CodexUsageSample(
      credentialID: "cred",
      bucketStart: bucket,
      observedAt: observedAt ?? bucket,
      remainingPercent: remaining
    )
  }

  private func weeklyWindow(resetAt: Date) -> CodexUsageWindow {
    CodexUsageWindow(
      usedPercent: 10,
      limitWindowSeconds: 604800,
      resetAt: Int(resetAt.timeIntervalSince1970)
    )
  }

  func testActualSpeedUsesFirstAndLastSamplesInThreeHourWindow() {
    let now = t0.addingTimeInterval(3 * 3600)
    let samples = [
      sample(at: t0.addingTimeInterval(600), remaining: 90),
      sample(at: t0.addingTimeInterval(1800), remaining: 80),
    ]
    let speed = CodexUsageSpeedEvaluator.actualSpeed(samples: samples, now: now)
    // used 10 -> 20，间隔 1200s = 1/3h，速度 = 10 / (1/3) = 30 pp/h。
    XCTAssertEqual(speed ?? -1, 30, accuracy: 0.0001)
  }

  func testActualSpeedRequiresAtLeastTwoDistinctBuckets() {
    let now = t0.addingTimeInterval(3 * 3600)
    XCTAssertNil(
      CodexUsageSpeedEvaluator.actualSpeed(
        samples: [sample(at: t0, remaining: 90)],
        now: now
      )
    )
    XCTAssertNil(
      CodexUsageSpeedEvaluator.actualSpeed(
        samples: [
          sample(at: t0, remaining: 90),
          sample(at: t0, remaining: 80),
        ],
        now: now
      )
    )
  }

  func testActualSpeedIgnoresSamplesOutsideWindow() {
    let now = t0.addingTimeInterval(3 * 3600)
    let samples = [
      sample(at: t0.addingTimeInterval(-600), remaining: 99),
      sample(at: t0.addingTimeInterval(600), remaining: 95),
      sample(at: t0.addingTimeInterval(1800), remaining: 90),
    ]
    let speed = CodexUsageSpeedEvaluator.actualSpeed(samples: samples, now: now)
    XCTAssertEqual(speed ?? -1, 15, accuracy: 0.0001)
  }

  func testIdealSpeedForValidWeeklyWindow() {
    let now = t0.addingTimeInterval(3 * 3600)
    let window = weeklyWindow(resetAt: t0.addingTimeInterval(7 * 24 * 3600))
    XCTAssertEqual(
      CodexUsageSpeedEvaluator.idealSpeed(window: window, now: now) ?? -1,
      100.0 / (7.0 * 24.0),
      accuracy: 0.0001
    )
  }

  func testIdealSpeedNilWhenWindowInvalid() {
    let now = t0.addingTimeInterval(3 * 3600)
    XCTAssertNil(CodexUsageSpeedEvaluator.idealSpeed(window: nil, now: now))
    XCTAssertNil(
      CodexUsageSpeedEvaluator.idealSpeed(
        window: CodexUsageWindow(usedPercent: 10, limitWindowSeconds: 18000, resetAt: 1_752_000_000),
        now: now
      )
    )
    XCTAssertNil(
      CodexUsageSpeedEvaluator.idealSpeed(
        window: weeklyWindow(resetAt: t0.addingTimeInterval(-7 * 24 * 3600)),
        now: now
      )
    )
  }

  func testComparisonUsesTolerance() {
    let ideal = CodexUsageSpeedEvaluator.idealSpeedPPH
    XCTAssertEqual(
      CodexUsageSpeedEvaluator.comparison(actual: ideal + 0.4, ideal: ideal),
      .onPar
    )
    XCTAssertEqual(
      CodexUsageSpeedEvaluator.comparison(actual: ideal + 1.0, ideal: ideal),
      .faster
    )
    XCTAssertEqual(
      CodexUsageSpeedEvaluator.comparison(actual: ideal - 1.0, ideal: ideal),
      .slower
    )
  }

  func testIdealLineAlignsWithFirstAndLastSamples() {
    let now = t0.addingTimeInterval(3 * 3600)
    let window = weeklyWindow(resetAt: t0.addingTimeInterval(7 * 24 * 3600))
    let firstSample = t0.addingTimeInterval(600)
    let lastSample = t0.addingTimeInterval(1800)
    let line = CodexUsageSpeedEvaluator.idealLine(
      window: window,
      now: now,
      firstSample: firstSample,
      lastSample: lastSample,
      firstSampleRemaining: 90
    )
    XCTAssertEqual(line?.start, firstSample)
    XCTAssertEqual(line?.end, lastSample)
    // 起点与蓝线首样本完全重合，包括剩余值。
    XCTAssertEqual(line?.startRemaining ?? -1, 90, accuracy: 0.0001)
    XCTAssertEqual(
      line?.endRemaining ?? -1,
      90 - CodexUsageSpeedEvaluator.idealSpeedPPH * (1200 / 3600),
      accuracy: 0.0001
    )
  }

  func testIdealLineKeepsSampleStartEvenWhenEarlierThanWeeklyStart() {
    let weeklyStart = t0.addingTimeInterval(2 * 3600)
    let resetAt = weeklyStart.addingTimeInterval(7 * 24 * 3600)
    let now = t0.addingTimeInterval(5 * 3600)
    let firstSample = t0.addingTimeInterval(30 * 60)
    let lastSample = t0.addingTimeInterval(2 * 3600 + 600)
    let line = CodexUsageSpeedEvaluator.idealLine(
      window: weeklyWindow(resetAt: resetAt),
      now: now,
      firstSample: firstSample,
      lastSample: lastSample,
      firstSampleRemaining: 85
    )
    // 绿线起点必须与蓝线首样本严格对齐（时间与剩余都一致）。
    XCTAssertEqual(line?.start, firstSample)
    XCTAssertEqual(line?.startRemaining ?? -1, 85, accuracy: 0.0001)
    XCTAssertEqual(line?.end, lastSample)
  }

  func testIdealLineNilOutsideWeeklyWindow() {
    let now = t0.addingTimeInterval(8 * 24 * 3600)
    XCTAssertNil(
      CodexUsageSpeedEvaluator.idealLine(
        window: weeklyWindow(resetAt: t0.addingTimeInterval(7 * 24 * 3600)),
        now: now,
        firstSample: now.addingTimeInterval(-3600),
        lastSample: now,
        firstSampleRemaining: 90
      )
    )
  }

  func testEvaluateHidesWhenSamplesInsufficient() {
    let now = t0.addingTimeInterval(3 * 3600)
    let result = CodexUsageSpeedEvaluator.evaluate(
      samples: [sample(at: t0, remaining: 90)],
      window: weeklyWindow(resetAt: t0.addingTimeInterval(7 * 24 * 3600)),
      now: now
    )
    XCTAssertNil(result)
  }

  func testEvaluateProducesFullComparison() {
    let now = t0.addingTimeInterval(3 * 3600)
    let samples = [
      sample(at: t0.addingTimeInterval(600), remaining: 90),
      sample(at: t0.addingTimeInterval(1800), remaining: 80),
    ]
    let result = CodexUsageSpeedEvaluator.evaluate(
      samples: samples,
      window: weeklyWindow(resetAt: t0.addingTimeInterval(7 * 24 * 3600)),
      now: now
    )
    XCTAssertNotNil(result)
    XCTAssertEqual(result?.actualSpeedPPH ?? -1, 30, accuracy: 0.0001)
    XCTAssertEqual(
      result?.idealSpeedPPH ?? -1,
      100.0 / (7.0 * 24.0),
      accuracy: 0.0001
    )
    XCTAssertEqual(result?.comparison, .faster)
    XCTAssertEqual(result?.idealLineStart, t0.addingTimeInterval(600))
    XCTAssertEqual(result?.idealLineEnd, t0.addingTimeInterval(1800))
  }

  func testEvaluateSupportsOneHourWindow() {
    let now = t0.addingTimeInterval(3600)
    let samples = [
      sample(at: t0.addingTimeInterval(600), remaining: 95),
      sample(at: t0.addingTimeInterval(1800), remaining: 90),
    ]
    let result = CodexUsageSpeedEvaluator.evaluate(
      samples: samples,
      window: weeklyWindow(resetAt: t0.addingTimeInterval(7 * 24 * 3600)),
      now: now,
      windowSeconds: 3600
    )
    // used 5 -> 10，间隔 1200s = 1/3h，实际速度 = 15 pp/h。
    XCTAssertEqual(result?.actualSpeedPPH ?? -1, 15, accuracy: 0.0001)
    XCTAssertEqual(result?.idealLineStart, t0.addingTimeInterval(600))
    XCTAssertEqual(result?.idealLineEnd, t0.addingTimeInterval(1800))
  }

  func testEvaluateUsesExplicitFirstLastForGreenLineAlignment() {
    let now = t0.addingTimeInterval(3 * 3600)
    let samples = [
      sample(at: t0.addingTimeInterval(600), remaining: 90),
      sample(at: t0.addingTimeInterval(1800), remaining: 80),
      // 孤立末样本：蓝线 segments 会丢弃，绿线不应以它为终点。
      sample(at: t0.addingTimeInterval(2 * 3600 + 1800), remaining: 70),
    ]
    let result = CodexUsageSpeedEvaluator.evaluate(
      samples: samples,
      window: weeklyWindow(resetAt: t0.addingTimeInterval(7 * 24 * 3600)),
      now: now,
      firstSample: t0.addingTimeInterval(600),
      lastSample: t0.addingTimeInterval(1800)
    )
    XCTAssertEqual(result?.idealLineStart, t0.addingTimeInterval(600))
    XCTAssertEqual(result?.idealLineEnd, t0.addingTimeInterval(1800))
  }

  func testLocalizedConclusions() {
    XCTAssertEqual(
      L10n.string(.codexSpeedFaster, language: .simplifiedChinese),
      "快于理想"
    )
    XCTAssertEqual(
      L10n.string(.codexSpeedSlower, language: .simplifiedChinese),
      "慢于理想"
    )
    XCTAssertEqual(
      L10n.string(.codexSpeedOnPar, language: .simplifiedChinese),
      "与理想相当"
    )
    XCTAssertEqual(
      L10n.string(.codexSpeedFaster, language: .english),
      "Faster than ideal"
    )
    XCTAssertEqual(
      L10n.string(.codexSpeedSlower, language: .english),
      "Slower than ideal"
    )
    XCTAssertEqual(
      L10n.string(.codexSpeedOnPar, language: .english),
      "On par with ideal"
    )
  }
}
