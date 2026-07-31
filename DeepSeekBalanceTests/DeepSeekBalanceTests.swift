import XCTest

@testable import DeepSeekBalance

final class APIKeyProviderTests: XCTestCase {
  func testKeychainTakesPriorityOverEnvironment() {
    let keychain = FakeKeychainStore()
    keychain.storedValue = "keychain-key"
    let provider = APIKeyProvider(
      keychainStore: keychain,
      environment: ["DEEPSEEK_API_KEY": "env-key"]
    )
    XCTAssertEqual(provider.apiKey, "keychain-key")
    XCTAssertEqual(provider.source, .keychain)
  }

  func testFallsBackToEnvironmentWhenKeychainMissing() {
    let keychain = FakeKeychainStore()
    let provider = APIKeyProvider(
      keychainStore: keychain,
      environment: ["DEEPSEEK_API_KEY": "env-key"]
    )
    XCTAssertEqual(provider.apiKey, "env-key")
    XCTAssertEqual(provider.source, .environment)
  }

  func testNotConfiguredWhenBothMissing() {
    let keychain = FakeKeychainStore()
    let provider = APIKeyProvider(keychainStore: keychain, environment: [:])
    XCTAssertNil(provider.apiKey)
    XCTAssertEqual(provider.source, .notConfigured)
  }

  func testWhitespaceOnlyEnvironmentValueIsIgnored() {
    let keychain = FakeKeychainStore()
    let provider = APIKeyProvider(
      keychainStore: keychain,
      environment: ["DEEPSEEK_API_KEY": "  \n "]
    )
    XCTAssertNil(provider.apiKey)
    XCTAssertEqual(provider.source, .notConfigured)
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
    XCTAssertEqual(BalanceFormatter.numberString(from: "1234567.89", locale: enUS), "1,234,567.89")
  }

  func testKeepsRawStringWhenNotDecimal() {
    XCTAssertEqual(BalanceFormatter.format(total: "abc", currency: "CNY"), "¥abc")
  }

  func testSummaryForMultipleCurrencies() {
    let decoder = JSONDecoder()
    let response = try? decoder.decode(
      BalanceResponse.self, from: Data(TestFixtures.multiCurrencyJSON.utf8))
    let summary = response.flatMap { BalanceFormatter.summary(for: $0.balanceInfos) }
    XCTAssertEqual(summary, "¥110.00 · $2.50")
  }
}
