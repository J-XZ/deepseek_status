import AppKit
import XCTest

@testable import DeepSeekBalance

/// 只记录写入、读取抛错的存储，用于验证读取失败只影响趋势。
actor FailingReadHistoryStore: BalanceHistoryStoring {
  func upsert(samples: [BalanceSample], credentialID: String) async throws {}

  func fetch(credentialID: String, from: Date, to: Date) async throws -> [BalanceSample] {
    throw LevelDBError.readFailed("测试读取失败")
  }

  func prune(before: Date) async throws {}

  func deleteHistory(credentialID: String?) async throws {}
}

@MainActor
final class StoreStateCoordinationTests: XCTestCase {
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

  private func makeStore(
    keychain: FakeKeychainStore = FakeKeychainStore(),
    historyService: BalanceHistoryService? = nil
  ) -> BalanceStore {
    let keychain = keychain
    if keychain.storedValue == nil {
      keychain.storedValue = "sk-test"
    }
    return BalanceStore(
      apiClient: DeepSeekAPIClient(session: MockURLProtocol.makeSession(), timeoutInterval: 2),
      keychainStore: keychain,
      environment: [:],
      clock: clock,
      historyService: historyService ?? BalanceHistoryService(store: history, clock: clock),
      autoRefreshInterval: nil
    )
  }

  private func stub(statusCode: Int, body: Data = Data()) {
    MockURLProtocol.requestHandler = { _ in
      (TestFixtures.httpResponse(statusCode: statusCode), body)
    }
  }

  func testSuccessfulRefreshWritesHistory() async throws {
    stub(statusCode: 200, body: Data(TestFixtures.cnyJSON.utf8))
    let store = makeStore()
    await store.refresh()

    let samples = try await history.fetch(
      credentialID: CredentialFingerprint.credentialID(for: "sk-test"),
      from: .distantPast,
      to: .distantFuture
    )
    XCTAssertEqual(samples.count, 1)
    XCTAssertEqual(samples[0].currency, "CNY")
    XCTAssertEqual(samples[0].totalBalance, "110.00")
    XCTAssertEqual(samples[0].bucketStart, TimeBucket.bucketStart(for: clock.now()))
  }

  func testFailureStatusesDoNotWriteHistory() async throws {
    let cases: [(Int, Data)] = [
      (401, Data()),
      (429, Data()),
      (500, Data()),
      (200, Data("not json".utf8)),
    ]
    for (status, body) in cases {
      MockURLProtocol.reset()
      stub(statusCode: status, body: body)
      let store = makeStore()
      await store.refresh()
      let samples = try await history.fetch(
        credentialID: CredentialFingerprint.credentialID(for: "sk-test"),
        from: .distantPast,
        to: .distantFuture
      )
      XCTAssertTrue(samples.isEmpty, "status \(status) 不应写入历史")
    }
  }

  func testNetworkFailureDoesNotWriteHistory() async throws {
    MockURLProtocol.requestHandler = { _ in
      throw URLError(.notConnectedToInternet)
    }
    let store = makeStore()
    await store.refresh()
    let samples = try await history.fetch(
      credentialID: CredentialFingerprint.credentialID(for: "sk-test"),
      from: .distantPast,
      to: .distantFuture
    )
    XCTAssertTrue(samples.isEmpty)
  }

  func testUnavailableAccountStillWritesHistory() async throws {
    let json =
      #"{"is_available":false,"balance_infos":[{"currency":"CNY","total_balance":"1.00","granted_balance":"0.00","topped_up_balance":"1.00"}]}"#
    stub(statusCode: 200, body: Data(json.utf8))
    let store = makeStore()
    await store.refresh()
    XCTAssertEqual(store.status, .insufficientBalance)
    let samples = try await history.fetch(
      credentialID: CredentialFingerprint.credentialID(for: "sk-test"),
      from: .distantPast,
      to: .distantFuture
    )
    XCTAssertEqual(samples.count, 1)
    XCTAssertFalse(samples[0].isAvailable)
  }

  func testHistoryWriteFailureDoesNotAffectBalance() async throws {
    stub(statusCode: 200, body: Data(TestFixtures.cnyJSON.utf8))
    let unavailable = UnavailableBalanceHistoryStore()
    let store = makeStore(
      historyService: BalanceHistoryService(store: unavailable, clock: clock)
    )
    await store.refresh()
    XCTAssertEqual(store.status, .loaded)
    XCTAssertEqual(store.menuBarText, "¥110.00")
    XCTAssertNotNil(store.historyError)
  }

  func testHistoryReadFailureOnlyAffectsTrend() async throws {
    stub(statusCode: 200, body: Data(TestFixtures.cnyJSON.utf8))
    let store = makeStore(
      historyService: BalanceHistoryService(
        store: FailingReadHistoryStore(),
        clock: clock
      )
    )
    await store.refresh()
    XCTAssertEqual(store.status, .loaded)
    XCTAssertEqual(store.menuBarText, "¥110.00")
    XCTAssertNotNil(store.historyError)
    XCTAssertTrue(store.historySamples.isEmpty)
  }

  func testCurrencySelectionDefaultsToCNY() async {
    stub(statusCode: 200, body: Data(TestFixtures.multiCurrencyJSON.utf8))
    let store = makeStore()
    await store.refresh()
    XCTAssertEqual(store.availableCurrencies.first, "CNY")
    XCTAssertEqual(store.selectedCurrency, "CNY")
  }

  func testCurrencySelectionPolicy() async {
    stub(statusCode: 200, body: Data(TestFixtures.multiCurrencyJSON.utf8))
    let store = makeStore()
    await store.refresh()
    store.selectCurrency("USD")
    XCTAssertEqual(store.selectedCurrency, "USD")
    store.selectCurrency("EUR")
    XCTAssertEqual(store.selectedCurrency, "USD")
  }

  func testWakeEventsOnlyTriggerSingleCoordinatedRefresh() async throws {
    stub(statusCode: 200, body: Data(TestFixtures.cnyJSON.utf8))
    let store = makeStore()

    let center = NSWorkspace.shared.notificationCenter
    center.post(name: NSWorkspace.didWakeNotification, object: nil)
    center.post(name: NSWorkspace.didWakeNotification, object: nil)

    await waitForRecordedRequests(1)
    // 给第二个事件留出处理时间，确认不会产生第二个请求。
    try? await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertEqual(MockURLProtocol.recordedRequestCount, 1)
    XCTAssertEqual(store.status, .loaded)
  }

  func testClearLocalHistoryDoesNotAffectAPIKey() async throws {
    stub(statusCode: 200, body: Data(TestFixtures.cnyJSON.utf8))
    let keychain = FakeKeychainStore()
    keychain.storedValue = "sk-test"
    let store = makeStore(keychain: keychain)
    await store.refresh()
    XCTAssertEqual(store.historySamples.count, 1)

    await store.clearLocalHistory()
    XCTAssertTrue(store.historySamples.isEmpty)
    XCTAssertEqual(keychain.storedValue, "sk-test")
    XCTAssertEqual(store.status, .loaded)
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
}
