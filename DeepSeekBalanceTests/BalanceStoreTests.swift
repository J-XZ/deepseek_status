import XCTest

@testable import DeepSeekBalance

@MainActor
final class BalanceStoreTests: XCTestCase {
  private var clock = FixedClock(date: Date(timeIntervalSince1970: 1_750_000_000))
  private var history = InMemoryBalanceHistoryStore()

  override func setUp() {
    super.setUp()
    MockURLProtocol.reset()
    history = InMemoryBalanceHistoryStore()
    clock = FixedClock(date: Date(timeIntervalSince1970: 1_750_000_000))
  }

  override func tearDown() {
    MockURLProtocol.reset()
    super.tearDown()
  }

  private func makeStore(
    keychain: FakeKeychainStore,
    environment: [String: String] = [:],
    apiClient: (any BalanceFetching)? = nil,
    historyService: BalanceHistoryService? = nil,
    language: AppLanguage = .simplifiedChinese
  ) -> BalanceStore {
    BalanceStore(
      apiClient: apiClient
        ?? DeepSeekAPIClient(session: MockURLProtocol.makeSession(), timeoutInterval: 2),
      keychainStore: keychain,
      environment: environment,
      clock: clock,
      historyService: historyService ?? BalanceHistoryService(store: history, clock: clock),
      autoRefreshInterval: nil,
      language: language
    )
  }

  private func balanceJSON(total: String) -> String {
    """
    {"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"\(total)","granted_balance":"1.00","topped_up_balance":"2.00"}]}
    """
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
    let shouldFail = AtomicFlag(false)
    MockURLProtocol.requestHandler = { _ in
      if shouldFail.get() {
        return (TestFixtures.httpResponse(statusCode: 500), Data())
      }
      return (TestFixtures.httpResponse(statusCode: 200), Data(TestFixtures.cnyJSON.utf8))
    }
    let store = makeStore(keychain: keychain)

    await store.refresh()
    XCTAssertEqual(store.status, .loaded)
    XCTAssertEqual(store.menuBarText, "¥110.00")

    shouldFail.set(true)
    await store.refresh()
    XCTAssertEqual(store.status, .serverError)
    XCTAssertNotNil(store.balance)
    XCTAssertEqual(store.menuBarText, "¥110.00")
    XCTAssertNotNil(store.lastErrorMessage)
  }

  func testAuthenticationFailureClearsDisplayedBalance() async {
    let keychain = FakeKeychainStore()
    keychain.storedValue = "sk-test"
    let shouldFail = AtomicFlag(false)
    MockURLProtocol.requestHandler = { _ in
      if shouldFail.get() {
        return (TestFixtures.httpResponse(statusCode: 401), Data())
      }
      return (TestFixtures.httpResponse(statusCode: 200), Data(TestFixtures.cnyJSON.utf8))
    }
    let store = makeStore(keychain: keychain)
    await store.refresh()
    XCTAssertEqual(store.menuBarText, "¥110.00")

    shouldFail.set(true)
    await store.refresh()
    XCTAssertEqual(store.status, .authenticationFailed)
    XCTAssertNil(store.balance)
    XCTAssertEqual(store.menuBarText, "错误")
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
      (TestFixtures.httpResponse(statusCode: 200), Data(TestFixtures.cnyJSON.utf8))
    }
    let store = makeStore(keychain: keychain)
    MockURLProtocol.startHolding()

    let first: Task<Void, Never> = Task { await store.refresh() }
    await waitForRecordedRequests(1)
    let readsBeforeSecond = keychain.readCount
    let second: Task<Void, Never> = Task { await store.refresh() }
    await waitForKeychainReads(keychain, readsBeforeSecond + 1)
    await Task.yield()

    MockURLProtocol.releaseAllHeld()
    await first.value
    await second.value
    XCTAssertEqual(MockURLProtocol.recordedRequestCount, 1)
  }

  func testMenuOpenRefreshJoinsInFlightRequest() async {
    let keychain = FakeKeychainStore()
    keychain.storedValue = "sk-test"
    MockURLProtocol.requestHandler = { _ in
      (TestFixtures.httpResponse(statusCode: 200), Data(TestFixtures.cnyJSON.utf8))
    }
    let store = makeStore(keychain: keychain)
    MockURLProtocol.startHolding()

    let first: Task<Void, Never> = Task { await store.refresh() }
    await waitForRecordedRequests(1)
    let readsBeforeMenuOpen = keychain.readCount
    let menuOpen: Task<Void, Never> = Task { await store.refreshIfNeeded(maximumAge: 60) }
    await waitForKeychainReads(keychain, readsBeforeMenuOpen + 1)
    await Task.yield()

    MockURLProtocol.releaseAllHeld()
    await first.value
    await menuOpen.value
    XCTAssertEqual(MockURLProtocol.recordedRequestCount, 1)
  }

  func testSwitchingAPIKeyDoesNotShowOldBalanceMidFlight() async {
    let client = ControlledAPIClient()
    let keychain = FakeKeychainStore()
    keychain.storedValue = "sk-a"
    let store = makeStore(keychain: keychain, apiClient: client)

    let first: Task<Void, Never> = Task { await store.refresh() }
    await waitForClientRequests(client, 1)
    XCTAssertEqual(store.status, .loading)

    keychain.storedValue = "sk-b"
    let second: Task<Void, Never> = Task { await store.refresh() }
    await waitForClientRequests(client, 2)
    // 切换后旧余额必须清空，菜单栏显示加载状态。
    XCTAssertNil(store.balance)
    XCTAssertEqual(store.menuBarText, "…")

    await first.value
    await client.respondNext(total: "110.00")
    await second.value
    XCTAssertEqual(store.status, .loaded)
    XCTAssertEqual(store.menuBarText, "¥110.00")
    let keys = await client.keys
    XCTAssertEqual(keys, ["sk-a", "sk-b"])
  }

  func testOldCredentialRequestCannotOverrideNewCredential() async {
    let client = ControlledAPIClient()
    let keychain = FakeKeychainStore()
    keychain.storedValue = "sk-a"
    let store = makeStore(keychain: keychain, apiClient: client)

    let first: Task<Void, Never> = Task { await store.refresh() }
    await waitForClientRequests(client, 1)

    keychain.storedValue = "sk-b"
    let second: Task<Void, Never> = Task { await store.refresh() }
    await waitForClientRequests(client, 2)

    // 旧凭据请求被取消后，新凭据再完成。
    await first.value
    await client.respondNext(total: "220.00")
    await second.value

    // 最终必须是新凭据的余额。
    XCTAssertEqual(store.menuBarText, "¥220.00")
    XCTAssertEqual(store.lastErrorMessage, nil)
    let keys = await client.keys
    XCTAssertEqual(keys, ["sk-a", "sk-b"])
  }

  func testCancelledRequestDoesNotShowUserError() async {
    let client = ControlledAPIClient()
    let keychain = FakeKeychainStore()
    keychain.storedValue = "sk-a"
    let store = makeStore(keychain: keychain, apiClient: client)

    let first: Task<Void, Never> = Task { await store.refresh() }
    await waitForClientRequests(client, 1)

    keychain.storedValue = "sk-b"
    let second: Task<Void, Never> = Task { await store.refresh() }
    await waitForClientRequests(client, 2)

    await first.value
    await client.respondNext(total: "99.00")
    await second.value

    // 旧请求被取消：不显示错误，状态是新凭据的结果。
    XCTAssertNil(store.lastErrorMessage)
    XCTAssertEqual(store.menuBarText, "¥99.00")
  }

  func testClearingLastKeyClearsOldBalance() async {
    let keychain = FakeKeychainStore()
    keychain.storedValue = "sk-test"
    MockURLProtocol.requestHandler = { _ in
      (TestFixtures.httpResponse(statusCode: 200), Data(TestFixtures.cnyJSON.utf8))
    }
    let store = makeStore(keychain: keychain)
    await store.refresh()
    XCTAssertEqual(store.menuBarText, "¥110.00")

    await store.clearSavedKey()
    XCTAssertEqual(store.status, .notConfigured)
    XCTAssertNil(store.balance)
    XCTAssertNil(store.lastUpdated)
    XCTAssertEqual(store.menuBarText, "未配置")
    XCTAssertTrue(store.historySamples.isEmpty)
  }

  func testSaveEmptyKeyReturnsEmptyInput() {
    let keychain = FakeKeychainStore()
    let store = makeStore(keychain: keychain)
    XCTAssertEqual(store.saveAPIKey("   \n "), .emptyInput)
    XCTAssertNil(keychain.storedValue)
  }

  func testSaveTrimsAndStoresKey() async {
    let keychain = FakeKeychainStore()
    MockURLProtocol.requestHandler = { _ in
      (TestFixtures.httpResponse(statusCode: 200), Data(TestFixtures.cnyJSON.utf8))
    }
    let store = makeStore(keychain: keychain)
    XCTAssertEqual(store.saveAPIKey("  sk-123  \n"), .success)
    XCTAssertEqual(keychain.storedValue, "sk-123")
    XCTAssertEqual(store.keySource, .keychain)
  }

  func testKeychainReadErrorShowsKeychainErrorState() async {
    let keychain = FakeKeychainStore()
    keychain.readError = KeychainError.unexpectedData
    let store = makeStore(
      keychain: keychain,
      environment: ["DEEPSEEK_API_KEY": "env-key"]
    )
    await store.refresh()
    XCTAssertEqual(store.status, .keychainError)
    XCTAssertNotNil(store.lastErrorMessage)
    XCTAssertTrue(MockURLProtocol.capturedAuthorizationHeaders().isEmpty)
  }

  // MARK: - 启用/停用

  func testDisabledStoreSkipsRefreshAndHistoryWrite() async {
    let keychain = FakeKeychainStore()
    keychain.storedValue = "sk-test"
    MockURLProtocol.requestHandler = { _ in
      (TestFixtures.httpResponse(statusCode: 200), Data(TestFixtures.cnyJSON.utf8))
    }
    let store = makeStore(keychain: keychain)
    await store.refresh()
    XCTAssertEqual(store.status, .loaded)
    XCTAssertEqual(MockURLProtocol.recordedRequestCount, 1)
    let firstCount = await history.count
    XCTAssertEqual(firstCount, 1)

    // 停用后刷新被跳过：状态不变、不发请求、不写历史。
    store.setEnabled(false)
    XCTAssertEqual(store.isEnabled, false)
    await store.refresh()
    await store.refreshIfNeeded(maximumAge: 0)
    await store.refreshAll()
    XCTAssertEqual(MockURLProtocol.recordedRequestCount, 1)
    let disabledCount = await history.count
    XCTAssertEqual(disabledCount, 1)

    // 重新启用后立即刷新一次。
    store.setEnabled(true)
    XCTAssertEqual(store.isEnabled, true)
    await waitForRecordedRequests(2)
  }

  private func waitForRecordedRequests(_ count: Int, timeout: TimeInterval = 2) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if MockURLProtocol.recordedRequestCount >= count {
        return
      }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("等待 \(count) 个请求超时，当前 \(MockURLProtocol.recordedRequestCount)")
  }

  private func waitForClientRequests(
    _ client: ControlledAPIClient,
    _ count: Int,
    timeout: TimeInterval = 2
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if await client.keys.count >= count {
        return
      }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    let current = await client.keys.count
    XCTFail("等待 \(count) 个请求超时，当前 \(current)")
  }

  private func waitForKeychainReads(
    _ keychain: FakeKeychainStore,
    _ count: Int,
    timeout: TimeInterval = 2
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if keychain.readCount >= count {
        return
      }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("等待 Keychain 读取次数达到 \(count) 超时，当前 \(keychain.readCount)")
  }
}
