import AppKit
import XCTest

@testable import DeepSeekBalance

final class APIKeyProviderTests: XCTestCase {
  func testKeychainTakesPriorityOverEnvironment() throws {
    let keychain = FakeKeychainStore()
    keychain.storedValue = "keychain-key"
    let provider = APIKeyProvider(
      keychainStore: keychain,
      environment: ["DEEPSEEK_API_KEY": "env-key"]
    )
    let credential = try XCTUnwrap(provider.resolveCredential())
    XCTAssertEqual(credential.apiKey, "keychain-key")
    XCTAssertEqual(credential.source, .keychain)
  }

  func testFallsBackToEnvironmentWhenKeychainMissing() throws {
    let keychain = FakeKeychainStore()
    let provider = APIKeyProvider(
      keychainStore: keychain,
      environment: ["DEEPSEEK_API_KEY": "env-key"]
    )
    let credential = try XCTUnwrap(provider.resolveCredential())
    XCTAssertEqual(credential.apiKey, "env-key")
    XCTAssertEqual(credential.source, .environment)
  }

  func testKeychainReadErrorDoesNotFallBackToEnvironment() {
    let keychain = FakeKeychainStore()
    keychain.readError = KeychainError.unexpectedData
    let provider = APIKeyProvider(
      keychainStore: keychain,
      environment: ["DEEPSEEK_API_KEY": "env-key"]
    )
    XCTAssertThrowsError(try provider.resolveCredential())
  }

  func testKeychainValueIsTrimmed() throws {
    let keychain = FakeKeychainStore()
    keychain.storedValue = "  sk-trimmed  \n"
    let provider = APIKeyProvider(keychainStore: keychain, environment: [:])
    let credential = try XCTUnwrap(provider.resolveCredential())
    XCTAssertEqual(credential.apiKey, "sk-trimmed")
    XCTAssertEqual(credential.source, .keychain)
  }

  func testEnvironmentValueIsTrimmed() throws {
    let keychain = FakeKeychainStore()
    let provider = APIKeyProvider(
      keychainStore: keychain,
      environment: ["DEEPSEEK_API_KEY": "  env-trimmed\n"]
    )
    let credential = try XCTUnwrap(provider.resolveCredential())
    XCTAssertEqual(credential.apiKey, "env-trimmed")
  }

  func testWhitespaceOnlyKeychainValueFallsBackToEnvironment() throws {
    // 明确规则：Keychain 值为空白时视为未保存密钥，回退环境变量。
    let keychain = FakeKeychainStore()
    keychain.storedValue = "   \n "
    let provider = APIKeyProvider(
      keychainStore: keychain,
      environment: ["DEEPSEEK_API_KEY": "env-key"]
    )
    let credential = try XCTUnwrap(provider.resolveCredential())
    XCTAssertEqual(credential.apiKey, "env-key")
    XCTAssertEqual(credential.source, .environment)
  }

  func testNotConfiguredWhenBothMissing() throws {
    let keychain = FakeKeychainStore()
    let provider = APIKeyProvider(keychainStore: keychain, environment: [:])
    XCTAssertNil(try provider.resolveCredential())
  }

  func testSameAPIKeyProducesSameCredentialID() {
    XCTAssertEqual(
      CredentialFingerprint.credentialID(for: "sk-abc"),
      CredentialFingerprint.credentialID(for: "sk-abc")
    )
    XCTAssertEqual(
      CredentialFingerprint.credentialID(for: "  sk-abc  "),
      CredentialFingerprint.credentialID(for: "sk-abc")
    )
  }

  func testDifferentAPIKeysProduceDifferentCredentialIDs() {
    XCTAssertNotEqual(
      CredentialFingerprint.credentialID(for: "sk-abc"),
      CredentialFingerprint.credentialID(for: "sk-xyz")
    )
  }

  func testKeychainAndEnvironmentShareCredentialIDForSameKey() throws {
    let keychain = FakeKeychainStore()
    keychain.storedValue = "shared-key"
    let provider = APIKeyProvider(
      keychainStore: keychain,
      environment: ["DEEPSEEK_API_KEY": "shared-key"]
    )
    let keychainCredential = try XCTUnwrap(provider.resolveCredential())
    let envOnly = APIKeyProvider(
      keychainStore: FakeKeychainStore(),
      environment: ["DEEPSEEK_API_KEY": "shared-key"]
    )
    let envCredential = try XCTUnwrap(envOnly.resolveCredential())
    XCTAssertEqual(keychainCredential.credentialID, envCredential.credentialID)
  }

  func testCredentialIDIsSHA256Hex() {
    // SHA-256("sk-abc") = 已知值，验证使用完整十六进制。
    let expected =
      "f7a6e4c1f97a47a2f8b3e2d4c6a8b0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7"
    XCTAssertNotEqual(CredentialFingerprint.credentialID(for: "sk-abc"), expected)
    XCTAssertEqual(CredentialFingerprint.credentialID(for: "sk-abc").count, 64)
  }
}

final class BalanceFormattingTests: XCTestCase {
  func testFormatsCNY() {
    XCTAssertEqual(BalanceFormatter.format(total: "110.00", currency: "CNY"), "¥110.00")
  }

  func testFormatsUSD() {
    XCTAssertEqual(BalanceFormatter.format(total: "10.25", currency: "USD"), "$10.25")
  }

  func testFormatsUnknownCurrency() {
    XCTAssertEqual(BalanceFormatter.format(total: "10.00", currency: "EUR"), "EUR 10.00")
  }

  func testUsesLocaleGrouping() {
    let enUS = Locale(identifier: "en_US")
    XCTAssertEqual(
      BalanceFormatter.numberString(from: "1234567.89", locale: enUS),
      "1,234,567.89"
    )
  }

  func testKeepsRawStringWhenNotDecimal() {
    XCTAssertEqual(BalanceFormatter.format(total: "abc", currency: "CNY"), "¥abc")
  }

  func testSummaryForMultipleCurrencies() {
    let decoder = JSONDecoder()
    let response = try? decoder.decode(
      BalanceResponse.self,
      from: Data(TestFixtures.multiCurrencyJSON.utf8)
    )
    let summary = response.flatMap { BalanceFormatter.summary(for: $0.balanceInfos) }
    XCTAssertEqual(summary, "¥110.00 · $2.50")
  }
}

final class PopoverSizingTests: XCTestCase {
  func testPageHeightUsesTheSelectedTabHeight() {
    XCTAssertEqual(
      PopoverSizing.pageHeight(
        [.deepseek: 640, .codex: 812, .vps: 704],
        for: .codex
      ),
      812
    )
  }

  func testPageHeightFallsBackWhenTabWasNotMeasuredYet() {
    XCTAssertEqual(
      PopoverSizing.pageHeight(
        [.deepseek: 640],
        for: .vps
      ),
      PopoverSizing.fallbackHeight
    )
  }

  func testTargetHeightIsNotCappedOnAComfortableScreen() {
    XCTAssertEqual(
      PopoverSizing.constrainedHeight(
        pageHeight: 812,
        visibleFrameHeight: 1_000
      ),
      812
    )
  }

  func testTallPageUsesTheAvailableScreenHeightBeforeScrolling() {
    XCTAssertEqual(
      PopoverSizing.constrainedHeight(
        pageHeight: 1_160,
        visibleFrameHeight: 1_440
      ),
      1_160
    )
  }

  func testTallPageIsCappedOnlyWhenItExceedsTheVisibleScreen() {
    XCTAssertEqual(
      PopoverSizing.constrainedHeight(
        pageHeight: 1_160,
        visibleFrameHeight: 1_000
      ),
      968
    )
  }

  func testTargetHeightIsCappedByTheScreenVisibleFrame() {
    XCTAssertEqual(
      PopoverSizing.constrainedHeight(
        pageHeight: 812,
        visibleFrameHeight: 700
      ),
      668
    )
  }

  func testTinyScreensNeverReceiveAHeightAboveTheirVisibleFrame() {
    XCTAssertEqual(
      PopoverSizing.constrainedHeight(
        pageHeight: 640,
        visibleFrameHeight: 20
      ),
      1
    )
  }

  func testShownPopoverNeverShrinksDuringAsyncMeasurement() {
    XCTAssertEqual(
      PopoverSizing.stableHeight(
        targetHeight: 760,
        currentHeight: 820,
        isPopoverShown: true
      ),
      820
    )
    XCTAssertEqual(
      PopoverSizing.stableHeight(
        targetHeight: 900,
        currentHeight: 820,
        isPopoverShown: true
      ),
      900
    )
  }

  func testShownPopoverShrinksToTheNewPageWhenTabSwitches() {
    XCTAssertEqual(
      PopoverSizing.stableHeight(
        targetHeight: 760,
        currentHeight: 820,
        isPopoverShown: true,
        allowsShrink: true
      ),
      760
    )
  }

  func testClosedPopoverUsesLatestMeasuredHeight() {
    XCTAssertEqual(
      PopoverSizing.stableHeight(
        targetHeight: 760,
        currentHeight: 820,
        isPopoverShown: false
      ),
      760
    )
  }

  func testShownPopoverStillRespectsScreenLimit() {
    XCTAssertEqual(
      PopoverSizing.stableHeight(
        targetHeight: 668,
        currentHeight: 820,
        isPopoverShown: true,
        maximumHeight: 668
      ),
      668
    )
  }

  func testWindowHeightAddsArrowAndBorderChromeToTheContent() {
    XCTAssertEqual(
      PopoverSizing.windowHeight(contentHeight: 846, chromeHeight: 13),
      859
    )
    XCTAssertEqual(
      PopoverSizing.windowHeight(contentHeight: 1, chromeHeight: 0),
      1
    )
  }

  func testContentHeightLimitAccountsForChrome() {
    XCTAssertEqual(
      PopoverSizing.contentHeightLimit(visibleFrameHeight: 1_000, chromeHeight: 13),
      955
    )
    XCTAssertEqual(
      PopoverSizing.contentHeightLimit(visibleFrameHeight: 20, chromeHeight: 13),
      1
    )
    XCTAssertNil(
      PopoverSizing.contentHeightLimit(visibleFrameHeight: nil, chromeHeight: 13)
    )
  }
}

final class BalanceTrendYAxisTests: XCTestCase {
  func testCeilingRoundsUpToNiceScale() {
    XCTAssertEqual(BalanceTrendProcessor.yCeiling(for: 1_234.56), 2_000)
    XCTAssertEqual(BalanceTrendProcessor.yCeiling(for: 846), 1_000)
    XCTAssertEqual(BalanceTrendProcessor.yCeiling(for: 45.6), 50)
    XCTAssertEqual(BalanceTrendProcessor.yCeiling(for: 0.42), 0.5, accuracy: 0.0001)
  }

  func testCeilingNeverShrinksTheDomain() {
    XCTAssertEqual(BalanceTrendProcessor.yCeiling(for: 2_000), 2_000)
    XCTAssertEqual(BalanceTrendProcessor.yCeiling(for: 5), 5)
    XCTAssertEqual(BalanceTrendProcessor.yCeiling(for: 1), 2)
  }

  func testCeilingHandlesNonPositiveAndNonFiniteValues() {
    XCTAssertEqual(BalanceTrendProcessor.yCeiling(for: 0), 1)
    XCTAssertEqual(BalanceTrendProcessor.yCeiling(for: -3), 1)
    XCTAssertEqual(BalanceTrendProcessor.yCeiling(for: .infinity), 1)
    XCTAssertEqual(BalanceTrendProcessor.yCeiling(for: .nan), 1)
  }
}

final class MenuBarUsageColorTests: XCTestCase {
  func testMissingOrZeroGapKeepsSystemColor() {
    XCTAssertNil(MenuBarUsageColor.color(for: nil, isDark: true))
    XCTAssertNil(MenuBarUsageColor.color(for: 0, isDark: true))
    XCTAssertNotNil(MenuBarUsageColor.color(for: -1, isDark: true))
    XCTAssertNotNil(MenuBarUsageColor.color(for: 1, isDark: true))
  }

  func testUnderUsageUsesContinuousGreenInterval() throws {
    let near = try rgba(XCTUnwrap(MenuBarUsageColor.color(for: -11, isDark: true)))
    let mid = try rgba(XCTUnwrap(MenuBarUsageColor.color(for: -5, isDark: true)))
    let full = try rgba(XCTUnwrap(MenuBarUsageColor.color(for: -30, isDark: true)))
    let clamped = try rgba(XCTUnwrap(MenuBarUsageColor.color(for: -31, isDark: true)))

    XCTAssertGreaterThanOrEqual(near.alpha, 0.95)
    XCTAssertGreaterThan(near.green, near.red)
    XCTAssertGreaterThan(near.green, near.blue)
    XCTAssertEqual(near.red, full.red, accuracy: 0.0001)
    XCTAssertEqual(near.blue, full.blue, accuracy: 0.0001)
    XCTAssertGreaterThan(mid.red, full.red)
    XCTAssertLessThan(mid.red, 0.9)
    XCTAssertGreaterThan(mid.blue, full.blue)
    XCTAssertLessThan(mid.blue, 0.9)
    XCTAssertGreaterThan(full.green, 0.9)
    XCTAssertLessThan(full.red, 0.65)
    XCTAssertLessThan(full.blue, 0.65)
    XCTAssertEqual(full.green, clamped.green, accuracy: 0.0001)
    XCTAssertEqual(full.red, clamped.red, accuracy: 0.0001)
    XCTAssertEqual(full.blue, clamped.blue, accuracy: 0.0001)
  }

  func testGradientIsContinuousAcrossWholeRange() throws {
    let gaps = Array(-10...30)
    var previous: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)?
    for gap in gaps where gap != 0 {
      let current = try rgba(XCTUnwrap(MenuBarUsageColor.color(for: gap, isDark: true)))
      if let previous {
        XCTAssertFalse(
          abs(previous.red - current.red) < 0.0001
            && abs(previous.green - current.green) < 0.0001
            && abs(previous.blue - current.blue) < 0.0001
        )
      }
      previous = current
    }
  }

  func testOverageUsesAContinuousBrightWhiteYellowRedGradient() throws {
    let low = try rgba(XCTUnwrap(MenuBarUsageColor.color(for: 1, isDark: true)))
    let yellow = try rgba(XCTUnwrap(MenuBarUsageColor.color(for: 10, isDark: true)))
    let high = try rgba(XCTUnwrap(MenuBarUsageColor.color(for: 30, isDark: true)))

    XCTAssertGreaterThanOrEqual(low.alpha, 0.95)
    XCTAssertGreaterThan(low.blue, yellow.blue)
    XCTAssertGreaterThan(yellow.green, 0.85)
    XCTAssertGreaterThan(yellow.blue, 0.45)
    XCTAssertGreaterThan(yellow.green, high.green)
    XCTAssertGreaterThan(high.green, 0.55)
    XCTAssertGreaterThan(high.blue, 0.55)
    XCTAssertGreaterThanOrEqual(high.red, yellow.red)
  }

  func testTrafficRiskUsesGreenYellowRedGradient() throws {
    XCTAssertNil(MenuBarUsageColor.color(forTrafficRisk: nil, isDark: true))

    let safe = try rgba(XCTUnwrap(MenuBarUsageColor.color(forTrafficRisk: 0, isDark: true)))
    let yellow = try rgba(XCTUnwrap(MenuBarUsageColor.color(forTrafficRisk: 0.5, isDark: true)))
    let severe = try rgba(XCTUnwrap(MenuBarUsageColor.color(forTrafficRisk: 1, isDark: true)))
    let quarter = try rgba(XCTUnwrap(MenuBarUsageColor.color(forTrafficRisk: 0.25, isDark: true)))
    let threeQuarter = try rgba(XCTUnwrap(MenuBarUsageColor.color(forTrafficRisk: 0.75, isDark: true)))

    XCTAssertGreaterThanOrEqual(safe.alpha, 0.95)
    XCTAssertGreaterThan(safe.green, 0.9)
    XCTAssertLessThan(safe.red, 0.65)
    XCTAssertLessThan(safe.blue, 0.65)
    XCTAssertGreaterThan(yellow.green, 0.85)
    XCTAssertGreaterThan(yellow.blue, 0.45)
    XCTAssertGreaterThan(yellow.green, severe.green)
    XCTAssertGreaterThanOrEqual(severe.red, yellow.red)
    XCTAssertGreaterThan(safe.green, yellow.green)
    XCTAssertGreaterThan(quarter.green, threeQuarter.green)
    XCTAssertGreaterThan(threeQuarter.red, quarter.red)
  }

  func testProgressColorUsesBlueAsMiddleInsteadOfWhite() throws {
    XCTAssertNil(MenuBarUsageColor.progressColor(forGap: nil))

    let green = try rgba(XCTUnwrap(MenuBarUsageColor.progressColor(forGap: -10)))
    let blue = try rgba(XCTUnwrap(MenuBarUsageColor.progressColor(forGap: 0)))
    let yellow = try rgba(XCTUnwrap(MenuBarUsageColor.progressColor(forGap: 10)))
    let red = try rgba(XCTUnwrap(MenuBarUsageColor.progressColor(forGap: 30)))
    let clamped = try rgba(XCTUnwrap(MenuBarUsageColor.progressColor(forGap: 99)))

    XCTAssertGreaterThanOrEqual(green.alpha, 0.95)
    XCTAssertGreaterThan(green.green, green.red)
    XCTAssertGreaterThan(green.green, green.blue)
    XCTAssertLessThan(green.red, 0.65)
    XCTAssertLessThan(green.blue, 0.65)
    // 低饱和度暗绿：绿分量明显偏暗，且与红/蓝分量的差距较小（不刺眼）。
    XCTAssertLessThan(green.green, 0.75)
    XCTAssertLessThan(green.green - green.red, 0.35)
    // 0 点为蓝色（区别于菜单栏的白色中间色）。
    XCTAssertGreaterThan(blue.blue, blue.red)
    XCTAssertGreaterThan(blue.blue, blue.green)
    XCTAssertGreaterThan(blue.blue, green.blue)
    // 浅天蓝而非高饱和系统蓝：绿分量应明显高于纯蓝的 0.0。
    XCTAssertGreaterThan(blue.green, 0.6)
    XCTAssertGreaterThan(blue.alpha, 0.95)
    XCTAssertGreaterThan(yellow.green, 0.85)
    XCTAssertGreaterThan(yellow.blue, 0.45)
    XCTAssertGreaterThanOrEqual(red.red, yellow.red)
    XCTAssertGreaterThan(red.red, blue.red)
    XCTAssertGreaterThan(red.red, green.red)
    // 超界钳制到端点颜色。
    XCTAssertEqual(red.red, clamped.red, accuracy: 0.0001)
    XCTAssertEqual(red.green, clamped.green, accuracy: 0.0001)
    XCTAssertEqual(red.blue, clamped.blue, accuracy: 0.0001)
  }

  func testProgressGradientIsContinuousAcrossWholeRange() throws {
    var previous: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)?
    for gap in -10...30 {
      let current = try rgba(XCTUnwrap(MenuBarUsageColor.progressColor(forGap: Double(gap))))
      if let previous {
        XCTAssertFalse(
          abs(previous.red - current.red) < 0.0001
            && abs(previous.green - current.green) < 0.0001
            && abs(previous.blue - current.blue) < 0.0001
        )
      }
      previous = current
    }
  }

  private func rgba(_ color: NSColor) throws -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
    let rgb = try XCTUnwrap(color.usingColorSpace(.deviceRGB))
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    rgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return (red, green, blue, alpha)
  }
}

final class UsageProgressEvaluatorTests: XCTestCase {
  func testMissingIdealProgressUsesBlueClassification() {
    XCTAssertEqual(
      UsageProgressEvaluator.status(usedPercent: 80, idealPercent: nil),
      .noIdeal
    )
  }

  func testProgressWithinTenPercentagePointsStaysOnTrack() {
    XCTAssertEqual(
      UsageProgressEvaluator.status(usedPercent: 59, idealPercent: 50),
      .onTrack
    )
    XCTAssertEqual(
      UsageProgressEvaluator.status(usedPercent: 41, idealPercent: 50),
      .onTrack
    )
  }

  func testProgressExactlyTenPercentagePointsStaysOnTrack() {
    XCTAssertEqual(
      UsageProgressEvaluator.status(usedPercent: 60, idealPercent: 50),
      .onTrack
    )
    XCTAssertEqual(
      UsageProgressEvaluator.status(usedPercent: 40, idealPercent: 50),
      .onTrack
    )
  }

  func testProgressMoreThanTenPointsBehindIsGreenClassification() {
    XCTAssertEqual(
      UsageProgressEvaluator.status(usedPercent: 39, idealPercent: 50),
      .behindIdeal
    )
  }

  func testProgressMoreThanTenPointsAheadIsOrangeClassification() {
    XCTAssertEqual(
      UsageProgressEvaluator.status(usedPercent: 61, idealPercent: 50),
      .aheadOfIdeal
    )
  }
}

final class TrendChartModelCacheTests: XCTestCase {
  func testBalanceCacheRoundTripAndSameHourKey() {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    let samples = [
      BalanceSample(
        credentialID: "c", bucketStart: t0, observedAt: t0,
        currency: "CNY", totalBalance: "100", grantedBalance: "0",
        toppedUpBalance: "10", isAvailable: true
      ),
      BalanceSample(
        credentialID: "c", bucketStart: t0 + 600, observedAt: t0 + 600,
        currency: "CNY", totalBalance: "90", grantedBalance: "0",
        toppedUpBalance: "10", isAvailable: true
      ),
    ]
    let now = Date(timeIntervalSince1970: 1_700_000_100)
    let key = BalanceTrendProcessor.chartModelCacheKey(
      samples: samples, currency: "CNY", now: now
    )
    XCTAssertNil(BalanceTrendProcessor.cachedChartModel(for: key))
    let model = BalanceTrendProcessor.chartModel(samples: samples, currency: "CNY", now: now)
    XCTAssertEqual(model.segments.count, 3)
    BalanceTrendProcessor.storeChartModel(model, for: key)
    XCTAssertEqual(BalanceTrendProcessor.cachedChartModel(for: key), model)
    // 同一小时内重访问命中同一缓存项。
    let laterSameHour = Date(timeIntervalSince1970: 1_700_000_300)
    XCTAssertEqual(
      BalanceTrendProcessor.chartModelCacheKey(
        samples: samples, currency: "CNY", now: laterSameHour
      ),
      key
    )
  }

  func testBalanceCacheKeyChangesWithSamplesAndCurrency() {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    let samples = [
      BalanceSample(
        credentialID: "c", bucketStart: t0, observedAt: t0,
        currency: "CNY", totalBalance: "100", grantedBalance: "0",
        toppedUpBalance: "10", isAvailable: true
      )
    ]
    let now = Date(timeIntervalSince1970: 1_700_000_100)
    let key = BalanceTrendProcessor.chartModelCacheKey(
      samples: samples, currency: "CNY", now: now
    )
    XCTAssertNotEqual(
      BalanceTrendProcessor.chartModelCacheKey(
        samples: samples, currency: "USD", now: now
      ),
      key
    )
    XCTAssertNotEqual(
      BalanceTrendProcessor.chartModelCacheKey(
        samples: samples + [
          BalanceSample(
            credentialID: "c", bucketStart: t0 + 600, observedAt: t0 + 600,
            currency: "CNY", totalBalance: "95", grantedBalance: "0",
            toppedUpBalance: "10", isAvailable: true
          )
        ],
        currency: "CNY", now: now
      ),
      key
    )
  }

  func testVPSCacheRoundTripAndKeyChangesWithSamples() {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    let s1 = VPSUsageSample(
      credentialID: "c", bucketStart: t0, observedAt: t0,
      remainingBandwidthGB: 100, remainingCreditUSD: 5
    )
    let s2 = VPSUsageSample(
      credentialID: "c", bucketStart: t0 + 600, observedAt: t0 + 600,
      remainingBandwidthGB: 90, remainingCreditUSD: 4
    )
    let now = Date(timeIntervalSince1970: 1_700_000_100)
    let key = VPSUsageTrendProcessor.chartModelCacheKey(samples: [s1, s2], now: now)
    XCTAssertNil(VPSUsageTrendProcessor.cachedChartModel(for: key))
    let model = VPSUsageTrendProcessor.chartModel(samples: [s1, s2], now: now)
    XCTAssertTrue(model.canDraw)
    VPSUsageTrendProcessor.storeChartModel(model, for: key)
    XCTAssertEqual(VPSUsageTrendProcessor.cachedChartModel(for: key), model)
    XCTAssertNotEqual(
      VPSUsageTrendProcessor.chartModelCacheKey(samples: [s1], now: now),
      key
    )
  }
}
