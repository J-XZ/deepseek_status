import XCTest

@testable import DeepSeekBalance

@MainActor
final class BalanceStoreTests: XCTestCase {
  override func setUp() {
    super.setUp()
    MockURLProtocol.reset()
  }

  override func tearDown() {
    MockURLProtocol.reset()
    super.tearDown()
  }

  private func makeStore(
    keychain: FakeKeychainStore,
    environment: [String: String] = [:]
  ) -> BalanceStore {
    BalanceStore(
      apiClient: DeepSeekAPIClient(session: MockURLProtocol.makeSession(), timeoutInterval: 2),
      keychainStore: keychain,
      environment: environment,
      autoRefreshInterval: nil
    )
  }

  func testKeychainKeyIsUsedOverEnvironment() async {
    let keychain = FakeKeychainStore()
    keychain.storedValue = "keychain-key"
    MockURLProtocol.requestHandler = { _ in
      (TestFixtures.httpResponse(statusCode: 200), Data(TestFixtures.cnyJSON.utf8))
    }
    let store = makeStore(
      keychain: keychain,
      environment: ["DEEPSEEK_API_KEY": "env-key"]
    )
    await store.refresh()
    XCTAssertEqual(store.keySource, .keychain)
    XCTAssertEqual(store.status, .loaded)
    XCTAssertEqual(MockURLProtocol.capturedAuthorizationHeaders(), ["Bearer keychain-key"])
  }

  func testFallsBackToEnvironmentAfterClearingKeychain() async {
    let keychain = FakeKeychainStore()
    keychain.storedValue = "keychain-key"
    MockURLProtocol.requestHandler = { _ in
      (TestFixtures.httpResponse(statusCode: 200), Data(TestFixtures.cnyJSON.utf8))
    }
    let store = makeStore(
      keychain: keychain,
      environment: ["DEEPSEEK_API_KEY": "env-key"]
    )
    await store.refresh()
    await store.clearSavedKey()
    XCTAssertEqual(store.keySource, .environment)
    XCTAssertEqual(
      MockURLProtocol.capturedAuthorizationHeaders(),
      ["Bearer keychain-key", "Bearer env-key"]
    )
  }

  func testUnconfiguredKeyDoesNotSendRequest() async {
    let keychain = FakeKeychainStore()
    let store = makeStore(keychain: keychain)
    await store.refresh()
    XCTAssertEqual(store.status, .notConfigured)
    XCTAssertEqual(store.menuBarText, "未配置")
    XCTAssertTrue(MockURLProtocol.capturedAuthorizationHeaders().isEmpty)
  }

  func testFailedRequestKeepsLastSuccessfulBalance() async {
    let keychain = FakeKeychainStore()
    keychain.storedValue = "sk-test"
    var shouldFail = false
    MockURLProtocol.requestHandler = { _ in
      if shouldFail {
        return (TestFixtures.httpResponse(statusCode: 500), Data())
      }
      return (TestFixtures.httpResponse(statusCode: 200), Data(TestFixtures.cnyJSON.utf8))
    }
    let store = makeStore(keychain: keychain)

    await store.refresh()
    XCTAssertEqual(store.status, .loaded)
    XCTAssertEqual(store.menuBarText, "¥110.00")

    shouldFail = true
    await store.refresh()
    XCTAssertEqual(store.status, .serverError)
    XCTAssertNotNil(store.balance)
    XCTAssertEqual(store.menuBarText, "¥110.00")
    XCTAssertNotNil(store.lastErrorMessage)
  }

  func testUnavailableAccountShowsInsufficientBalance() async {
    let keychain = FakeKeychainStore()
    keychain.storedValue = "sk-test"
    let json =
      #"{"is_available":false,"balance_infos":[{"currency":"CNY","total_balance":"1.00","granted_balance":"0.00","topped_up_balance":"1.00"}]}"#
    MockURLProtocol.requestHandler = { _ in
      (TestFixtures.httpResponse(statusCode: 200), Data(json.utf8))
    }
    let store = makeStore(keychain: keychain)
    await store.refresh()
    XCTAssertEqual(store.status, .insufficientBalance)
  }

  func testConcurrentRefreshSendsSingleRequest() async {
    let keychain = FakeKeychainStore()
    keychain.storedValue = "sk-test"
    MockURLProtocol.requestHandler = { _ in
      Thread.sleep(forTimeInterval: 0.1)
      return (TestFixtures.httpResponse(statusCode: 200), Data(TestFixtures.cnyJSON.utf8))
    }
    let store = makeStore(keychain: keychain)

    async let first: Void = store.refresh()
    async let second: Void = store.refresh()
    _ = await (first, second)

    XCTAssertEqual(MockURLProtocol.capturedAuthorizationHeaders().count, 1)
  }

  func testSaveEmptyKeyReturnsEmptyInput() {
    let keychain = FakeKeychainStore()
    let store = makeStore(keychain: keychain)
    XCTAssertEqual(store.saveAPIKey("   \n "), .emptyInput)
    XCTAssertNil(keychain.storedValue)
  }

  func testSaveTrimsAndStoresKey() {
    let keychain = FakeKeychainStore()
    let store = makeStore(keychain: keychain)
    XCTAssertEqual(store.saveAPIKey("  sk-123  \n"), .success)
    XCTAssertEqual(keychain.storedValue, "sk-123")
    XCTAssertEqual(store.keySource, .keychain)
  }
}
