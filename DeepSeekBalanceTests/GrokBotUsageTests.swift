import XCTest

@testable import DeepSeekBalance

@MainActor
final class GrokBotUsageTests: XCTestCase {
  override func setUp() {
    super.setUp()
    MockURLProtocol.reset()
  }

  override func tearDown() {
    MockURLProtocol.reset()
    super.tearDown()
  }

  func testParserMeteredRemainingDerived() throws {
    let data = Data("""
      {
        "usagePercent": 27.4,
        "hasNonZeroIncludedLimit": true,
        "nextResetTimestampUtc": {"seconds":"1700086400","nanos":0}
      }
      """.utf8)
    let snapshot = try GrokBotUsageParser.parse(data)
    guard case .metered(let quota) = snapshot.weekly else {
      return XCTFail("expected metered")
    }
    XCTAssertEqual(quota.usedPercent, 27)
    XCTAssertEqual(quota.remainingPercent, 73)
  }

  func testParserPooledDropsPercent() throws {
    let data = Data("""
      {
        "usagePercent": 63.0,
        "usesPooledEnterpriseAllowance": true
      }
      """.utf8)
    let snapshot = try GrokBotUsageParser.parse(data)
    XCTAssertEqual(snapshot.weekly, .enterprisePooled)
    XCTAssertNil(snapshot.meteredQuota)
  }

  func testParserTrialExclusive() throws {
    let data = Data("""
      {
        "usagePercent": 40.0,
        "hasNonZeroIncludedLimit": true,
        "sandTrialExpiresAt": "2026-01-15T12:00:00Z"
      }
      """.utf8)
    let snapshot = try GrokBotUsageParser.parse(data)
    guard case .trial = snapshot.weekly else {
      return XCTFail("expected trial")
    }
  }

  func testConnectTimestampProtobufObject() throws {
    let data = Data("""
      {
        "usagePercent": 10.0,
        "hasNonZeroIncludedLimit": true,
        "nextResetTimestampUtc": {"seconds":"1700000000","nanos":0}
      }
      """.utf8)
    let snapshot = try GrokBotUsageParser.parse(data)
    guard case .metered(let quota) = snapshot.weekly else {
      return XCTFail("expected metered")
    }
    XCTAssertEqual(quota.resetsAt?.timeIntervalSince1970, 1_700_000_000)
  }

  func testConnectTimestampRFC3339() throws {
    let data = Data("""
      {
        "usagePercent": 10.0,
        "hasNonZeroIncludedLimit": true,
        "nextResetTimestampUtc": "2023-11-14T22:13:20Z"
      }
      """.utf8)
    let snapshot = try GrokBotUsageParser.parse(data)
    guard case .metered(let quota) = snapshot.weekly else {
      return XCTFail("expected metered")
    }
    XCTAssertNotNil(quota.resetsAt)
  }

  func testStoreWithoutTokenReportsNotConfigured() async {
    MockURLProtocol.requestHandler = { _ in
      (TestFixtures.grokBotHTTPResponse(statusCode: 200), Data(TestFixtures.grokBotMeteredJSON.utf8))
    }
    let store = GrokBotUsageStore(
      client: makeClient(),
      authProvider: MockCursorAuthProvider(authError: CursorAuthError.securityCommandFailed),
      clock: FixedClock(date: Date(timeIntervalSince1970: 1_700_000_000)),
      startupRefresh: false
    )
    await store.refresh()
    XCTAssertEqual(store.status, .notConfigured)
    XCTAssertNil(store.usage)
    XCTAssertEqual(store.menuBarText, "—")
  }

  func testStoreMeteredPersistsHistorySample() async throws {
    MockURLProtocol.requestHandler = { _ in
      (TestFixtures.grokBotHTTPResponse(statusCode: 200), Data(TestFixtures.grokBotMeteredJSON.utf8))
    }
    let history = InMemoryGrokBotHistoryStore()
    let store = GrokBotUsageStore(
      client: makeClient(),
      authProvider: MockCursorAuthProvider(),
      clock: FixedClock(date: Date(timeIntervalSince1970: 1_700_000_000)),
      startupRefresh: false,
      autoRefreshInterval: nil,
      historyService: GrokBotHistoryService(store: history, clock: SystemClock())
    )
    await store.refresh()
    XCTAssertEqual(store.status, .loaded)
    guard case .metered(let quota) = store.usage?.weekly else {
      return XCTFail("expected metered")
    }
    XCTAssertEqual(quota.remainingPercent, 73)
    let samples = try await history.fetch(
      credentialID: "grokbot",
      from: Date(timeIntervalSince1970: 0),
      to: Date(timeIntervalSince1970: 1_800_000_000)
    )
    XCTAssertEqual(samples.count, 1)
    XCTAssertEqual(samples.first?.remainingPercent, 73)
  }

  func testStoreEnterpriseDoesNotWriteHistory() async throws {
    MockURLProtocol.requestHandler = { _ in
      (
        TestFixtures.grokBotHTTPResponse(statusCode: 200),
        Data("""
          {"usagePercent":50.0,"usesPooledEnterpriseAllowance":true}
          """.utf8)
      )
    }
    let history = InMemoryGrokBotHistoryStore()
    let store = GrokBotUsageStore(
      client: makeClient(),
      authProvider: MockCursorAuthProvider(),
      clock: FixedClock(date: Date(timeIntervalSince1970: 1_700_000_000)),
      startupRefresh: false,
      autoRefreshInterval: nil,
      historyService: GrokBotHistoryService(store: history, clock: SystemClock())
    )
    await store.refresh()
    XCTAssertEqual(store.status, .loaded)
    XCTAssertEqual(store.usage?.weekly, .enterprisePooled)
    let count = await history.count
    XCTAssertEqual(count, 0)
  }

  private func makeClient() -> GrokBotUsageClient {
    GrokBotUsageClient(session: MockURLProtocol.makeSession())
  }
}

extension TestFixtures {
  static let grokBotMeteredJSON = """
    {
      "usagePercent": 27.0,
      "hasNonZeroIncludedLimit": true,
      "nextResetTimestampUtc": {"seconds":"1700086400","nanos":0}
    }
    """

  static func grokBotHTTPResponse(statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(
      url: URL(
        string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus"
      )!,
      statusCode: statusCode,
      httpVersion: nil,
      headerFields: nil
    )!
  }
}
