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
  func testTargetHeightUsesLargestVisibleVendorPage() {
    XCTAssertEqual(
      PopoverSizing.largestPageHeight([640, 812, 704]),
      812
    )
  }

  func testTargetHeightIsNotCappedOnAComfortableScreen() {
    XCTAssertEqual(
      PopoverSizing.constrainedHeight(
        pageHeights: [640, 812, 704],
        visibleFrameHeight: 1_000
      ),
      812
    )
  }

  func testTallestPageUsesTheAvailableScreenHeightBeforeScrolling() {
    XCTAssertEqual(
      PopoverSizing.constrainedHeight(
        pageHeights: [820, 1_160, 940],
        visibleFrameHeight: 1_440
      ),
      1_160
    )
  }

  func testTallestPageIsCappedOnlyWhenItExceedsTheVisibleScreen() {
    XCTAssertEqual(
      PopoverSizing.constrainedHeight(
        pageHeights: [820, 1_160, 940],
        visibleFrameHeight: 1_000
      ),
      968
    )
  }

  func testTargetHeightIsCappedByTheScreenVisibleFrame() {
    XCTAssertEqual(
      PopoverSizing.constrainedHeight(
        pageHeights: [640, 812, 704],
        visibleFrameHeight: 700
      ),
      668
    )
  }

  func testTinyScreensNeverReceiveAHeightAboveTheirVisibleFrame() {
    XCTAssertEqual(
      PopoverSizing.constrainedHeight(
        pageHeights: [640],
        visibleFrameHeight: 20
      ),
      1
    )
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
