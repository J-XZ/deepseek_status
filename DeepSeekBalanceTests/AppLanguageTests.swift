import XCTest

@testable import DeepSeekBalance

final class AppLanguageTests: XCTestCase {
  private var suiteName: String!

  override func setUp() {
    super.setUp()
    suiteName = "AppLanguageTests-\(UUID().uuidString)"
  }

  override func tearDown() {
    UserDefaults.standard.removePersistentDomain(forName: suiteName)
    suiteName = nil
    super.tearDown()
  }

  private func makeDefaults(_ name: String = "AppLanguageTests") -> UserDefaults {
    let suite = UserDefaults(suiteName: "\(name)-\(UUID().uuidString)")!
    suite.removePersistentDomain(forName: "\(name)-\(UUID().uuidString)")
    return suite
  }

  func testInitialChineseSystemChoosesChinese() {
    let suite = makeDefaults()
    XCTAssertEqual(
      AppLanguage.initial(defaults: suite, systemLanguages: ["zh-Hans-CN", "en-US"]),
      .simplifiedChinese
    )
  }

  func testInitialEnglishSystemChoosesEnglish() {
    let suite = makeDefaults()
    XCTAssertEqual(
      AppLanguage.initial(defaults: suite, systemLanguages: ["en-US", "zh-Hans"]),
      .english
    )
  }

  func testOtherSystemLanguagesDefaultToEnglish() {
    let suite = makeDefaults()
    XCTAssertEqual(
      AppLanguage.initial(defaults: suite, systemLanguages: ["fr-FR", "ja-JP"]),
      .english
    )
  }

  func testSavedChoiceWinsOverSystemLanguage() {
    let suite = makeDefaults()
    suite.set(AppLanguage.simplifiedChinese.rawValue, forKey: AppLanguage.userDefaultsKey)
    XCTAssertEqual(
      AppLanguage.initial(defaults: suite, systemLanguages: ["en-US"]),
      .simplifiedChinese
    )
  }

  func testUserChoicePersists() {
    let suite = makeDefaults()
    AppLanguage.english.save(defaults: suite)
    XCTAssertEqual(
      suite.string(forKey: AppLanguage.userDefaultsKey),
      AppLanguage.english.rawValue
    )
  }
}

@MainActor
final class BalanceStoreLanguageTests: XCTestCase {
  private var clock = FixedClock(date: Date(timeIntervalSince1970: 1_752_000_000))
  private var history = InMemoryBalanceHistoryStore()

  override func setUp() {
    super.setUp()
    MockURLProtocol.reset()
    history = InMemoryBalanceHistoryStore()
    clock = FixedClock(date: Date(timeIntervalSince1970: 1_752_000_000))
  }

  override func tearDown() {
    MockURLProtocol.reset()
    super.tearDown()
  }

  private func makeStore(language: AppLanguage = .simplifiedChinese) -> BalanceStore {
    let keychain = FakeKeychainStore()
    return BalanceStore(
      apiClient: DeepSeekAPIClient(
        session: MockURLProtocol.makeSession(),
        timeoutInterval: 2
      ),
      keychainStore: keychain,
      environment: [:],
      clock: clock,
      historyService: BalanceHistoryService(store: history, clock: clock),
      autoRefreshInterval: nil,
      startupRefresh: false,
      startupPrune: false,
      language: language
    )
  }

  func testMenuBarFallbackSwitchesImmediately() async {
    let store = makeStore(language: .simplifiedChinese)
    await store.refresh()
    XCTAssertEqual(store.menuBarText, "未配置")
    store.setLanguage(.english)
    XCTAssertEqual(store.menuBarText, "Not configured")
    store.setLanguage(.simplifiedChinese)
    XCTAssertEqual(store.menuBarText, "未配置")
  }

  func testStatusBadgeSwitchesImmediately() async {
    let keychain = FakeKeychainStore()
    keychain.readError = KeychainError.unexpectedData
    let store = BalanceStore(
      apiClient: DeepSeekAPIClient(session: MockURLProtocol.makeSession(), timeoutInterval: 2),
      keychainStore: keychain,
      environment: ["DEEPSEEK_API_KEY": "sk-env"],
      clock: clock,
      historyService: BalanceHistoryService(store: history, clock: clock),
      autoRefreshInterval: nil,
      startupRefresh: false,
      startupPrune: false,
      language: .simplifiedChinese
    )
    await store.refresh()
    XCTAssertEqual(store.statusTitle, "Keychain 错误")
    store.setLanguage(.english)
    XCTAssertEqual(store.statusTitle, "Keychain error")
  }

  func testExistingErrorSwitchesLanguageWithoutNewRequest() async {
    let keychain = FakeKeychainStore()
    keychain.readError = KeychainError.unexpectedData
    let store = BalanceStore(
      apiClient: DeepSeekAPIClient(session: MockURLProtocol.makeSession(), timeoutInterval: 2),
      keychainStore: keychain,
      environment: ["DEEPSEEK_API_KEY": "sk-env"],
      clock: clock,
      historyService: BalanceHistoryService(store: history, clock: clock),
      autoRefreshInterval: nil,
      startupRefresh: false,
      startupPrune: false,
      language: .simplifiedChinese
    )
    await store.refresh()
    XCTAssertEqual(store.lastDisplayError, .keychain("无法读取已保存的 API Key"))
    let zh = store.lastErrorMessage
    XCTAssertTrue(zh?.contains("Keychain 错误") == true)
    store.setLanguage(.english)
    let en = store.lastErrorMessage
    XCTAssertTrue(en?.contains("Keychain error") == true)
    XCTAssertEqual(MockURLProtocol.recordedRequestCount, 0)
  }

  func testServiceStatusErrorTextSwitchesLanguage() {
    let error: AppDisplayError = .serviceStatusUnavailable
    XCTAssertEqual(
      error.text(language: .simplifiedChinese),
      "暂时无法获取官方状态信息"
    )
    XCTAssertEqual(
      error.text(language: .english),
      "Official status temporarily unavailable"
    )
  }

  func testLoginItemStatusTextSwitchesLanguage() {
    XCTAssertEqual(L10n.string(.loginRequiresApproval, language: .simplifiedChinese), "需要在系统设置中批准")
    XCTAssertEqual(L10n.string(.loginRequiresApproval, language: .english), "Requires approval in System Settings")
  }

  func testDateFormatterUsesSelectedLanguage() {
    let date = Date(timeIntervalSince1970: 1_752_000_000)
    let zh = date.formatted(
      Date.FormatStyle(date: .abbreviated, time: .shortened).locale(.init(identifier: "zh-Hans"))
    )
    let en = date.formatted(
      Date.FormatStyle(date: .abbreviated, time: .shortened).locale(.init(identifier: "en"))
    )
    XCTAssertTrue(zh.contains("年"))
    XCTAssertFalse(en.contains("年"))
  }

  func testNumberFormatterUsesSelectedLanguage() {
    let zh = BalanceTrendProcessor.formattedAmount(
      Decimal(string: "1234567.89")!,
      currency: "USD",
      locale: .init(identifier: "zh-Hans")
    )
    let en = BalanceTrendProcessor.formattedAmount(
      Decimal(string: "1234567.89")!,
      currency: "USD",
      locale: .init(identifier: "en")
    )
    XCTAssertEqual(zh, "$1,234,567.89")
    XCTAssertEqual(en, "$1,234,567.89")
  }

  func testCurrencySymbolDoesNotChangeWithLanguage() {
    XCTAssertEqual(
      BalanceFormatter.format(total: "110.00", currency: "CNY", locale: .init(identifier: "zh-Hans")),
      "¥110.00"
    )
    XCTAssertEqual(
      BalanceFormatter.format(total: "110.00", currency: "CNY", locale: .init(identifier: "en")),
      "¥110.00"
    )
    XCTAssertEqual(
      BalanceFormatter.format(total: "10.00", currency: "EUR", locale: .init(identifier: "en")),
      "EUR 10.00"
    )
  }
}
