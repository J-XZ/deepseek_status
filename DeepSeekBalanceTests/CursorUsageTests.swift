import XCTest

@testable import DeepSeekBalance

@MainActor
final class CursorUsageTests: XCTestCase {
  override func setUp() {
    super.setUp()
    MockURLProtocol.reset()
  }

  override func tearDown() {
    MockURLProtocol.reset()
    super.tearDown()
  }

  // MARK: - 模型解码

  func testParsesUsageResponse() throws {
    let data = Data(TestFixtures.cursorUsageJSON.utf8)
    let usage = try JSONDecoder().decode(CursorUsageResponse.self, from: data)
    XCTAssertEqual(usage.billingCycleStart, 1_784_813_765_000)
    XCTAssertEqual(usage.billingCycleEnd, 1_787_492_165_000)
    XCTAssertEqual(usage.billingCycleStartDate?.timeIntervalSince1970, 1_784_813_765)
    XCTAssertEqual(usage.planUsage?.totalSpend, 64312)
    XCTAssertEqual(usage.planUsage?.includedSpend, 7000)
    XCTAssertEqual(usage.planUsage?.bonusSpend, 57312)
    XCTAssertEqual(usage.planUsage?.limit, 7000)
    XCTAssertEqual(usage.spendLimitUsage?.limitType, "user")
    XCTAssertEqual(usage.usedPercent, 71)
    XCTAssertEqual(usage.apiUsedPercent, 83)
    XCTAssertEqual(usage.remainingPercent, 29)
    XCTAssertEqual(usage.windowSeconds, 2_678_400)
  }

  func testParsesNumericEpochMillis() throws {
    let data = Data("""
      {"billingCycleStart":1784813765000,"billingCycleEnd":1787492165000,
       "planUsage":{"totalPercentUsed":50.0}}
      """.utf8)
    let usage = try JSONDecoder().decode(CursorUsageResponse.self, from: data)
    XCTAssertEqual(usage.billingCycleStart, 1_784_813_765_000)
    XCTAssertEqual(usage.usedPercent, 50)
  }

  func testParsesResponseWithNullFields() throws {
    let data = Data("{}".utf8)
    let usage = try JSONDecoder().decode(CursorUsageResponse.self, from: data)
    XCTAssertNil(usage.billingCycleStart)
    XCTAssertNil(usage.planUsage)
    XCTAssertNil(usage.usedPercent)
    XCTAssertNil(usage.remainingPercent)
    XCTAssertFalse(usage.limitReached)
  }

  func testRemainingPercentClamped() throws {
    let data = Data("""
      {"planUsage":{"totalPercentUsed":150.0}}
      """.utf8)
    let usage = try JSONDecoder().decode(CursorUsageResponse.self, from: data)
    XCTAssertEqual(usage.usedPercent, 100)
    XCTAssertEqual(usage.remainingPercent, 0)
    XCTAssertTrue(usage.limitReached)
  }

  func testPlanDisplayName() {
    XCTAssertEqual(CursorUsageFormatter.planDisplayName("Pro+"), "Pro+")
    XCTAssertEqual(CursorUsageFormatter.planDisplayName("ultra"), "Ultra")
    XCTAssertEqual(CursorUsageFormatter.planDisplayName("TEAMS"), "Teams")
    XCTAssertEqual(CursorUsageFormatter.planDisplayName("custom_plan"), "CUSTOM_PLAN")
    XCTAssertNil(CursorUsageFormatter.planDisplayName(nil))
    XCTAssertNil(CursorUsageFormatter.planDisplayName(""))
  }

  func testFormatCents() {
    XCTAssertEqual(
      CursorUsageFormatter.formatCents(64312, locale: Locale(identifier: "en_US")),
      "$643.12"
    )
    XCTAssertEqual(
      CursorUsageFormatter.formatCents(7000, locale: Locale(identifier: "en_US")),
      "$70.00"
    )
    XCTAssertNil(CursorUsageFormatter.formatCents(nil, locale: Locale(identifier: "en_US")))
  }

  func testExpectedUsedPercentAtMidpoint() throws {
    let start = Date(timeIntervalSince1970: 0)
    let end = Date(timeIntervalSince1970: 1_800_000)
    let percent = try XCTUnwrap(
      CursorUsageFormatter.expectedUsedPercent(
        start: start,
        end: end,
        now: Date(timeIntervalSince1970: 900_000)
      )
    )
    XCTAssertEqual(percent, 50, accuracy: 0.001)
  }

  func testExpectedUsedPercentNilOutOfRange() {
    let start = Date(timeIntervalSince1970: 0)
    let end = Date(timeIntervalSince1970: 1_800_000)
    XCTAssertNil(CursorUsageFormatter.expectedUsedPercent(
      start: start, end: end, now: Date(timeIntervalSince1970: -100)
    ))
    XCTAssertNil(CursorUsageFormatter.expectedUsedPercent(
      start: start, end: end, now: Date(timeIntervalSince1970: 1_900_000)
    ))
  }

  func testUsageGapPercentFasterThanIdeal() throws {
    // 周期中点理想已用 50%，实际已用 70% → 消耗快于理想 +20。
    let startMs = Int64(Date().timeIntervalSince1970 - 15 * 86400) * 1000
    let endMs = startMs + 30 * 86400 * 1000
    let data = Data("""
      {"billingCycleStart":"\(startMs)","billingCycleEnd":"\(endMs)",
       "planUsage":{"totalPercentUsed":70.0}}
      """.utf8)
    let usage = try JSONDecoder().decode(CursorUsageResponse.self, from: data)
    let gap = try XCTUnwrap(usage.usageGapPercent)
    XCTAssertEqual(gap, 20)
  }

  func testUsageGapPercentSlowerThanIdeal() throws {
    let startMs = Int64(Date().timeIntervalSince1970 - 15 * 86400) * 1000
    let endMs = startMs + 30 * 86400 * 1000
    let data = Data("""
      {"billingCycleStart":"\(startMs)","billingCycleEnd":"\(endMs)",
       "planUsage":{"totalPercentUsed":30.0}}
      """.utf8)
    let usage = try JSONDecoder().decode(CursorUsageResponse.self, from: data)
    let gap = try XCTUnwrap(usage.usageGapPercent)
    XCTAssertEqual(gap, -20)
  }

  func testUsageGapPercentNilWithoutCycle() throws {
    let data = Data("{\"planUsage\":{\"totalPercentUsed\":30.0}}".utf8)
    let usage = try JSONDecoder().decode(CursorUsageResponse.self, from: data)
    XCTAssertNil(usage.usageGapPercent)
  }

  func testApiRemainingPercentAndGap() throws {
    let startMs = Int64(Date().timeIntervalSince1970 - 15 * 86400) * 1000
    let endMs = startMs + 30 * 86400 * 1000
    let data = Data("""
      {"billingCycleStart":"\(startMs)","billingCycleEnd":"\(endMs)",
       "planUsage":{"totalPercentUsed":70.0,"apiPercentUsed":83.0}}
      """.utf8)
    let usage = try JSONDecoder().decode(CursorUsageResponse.self, from: data)
    XCTAssertEqual(usage.apiUsedPercent, 83)
    XCTAssertEqual(usage.apiRemainingPercent, 17)
    // 周期中点理想 50%，API 已用 83% → +33。
    let gap = try XCTUnwrap(usage.apiUsageGapPercent)
    XCTAssertEqual(gap, 33)
  }

  func testApiGapNilWithoutCycle() throws {
    let data = Data("{\"planUsage\":{\"apiPercentUsed\":83.0}}".utf8)
    let usage = try JSONDecoder().decode(CursorUsageResponse.self, from: data)
    XCTAssertNil(usage.apiUsageGapPercent)
    XCTAssertEqual(usage.apiRemainingPercent, 17)
  }

  func testHasNoPlanUsage() throws {
    let none = try JSONDecoder().decode(CursorUsageResponse.self, from: Data("{}".utf8))
    XCTAssertTrue(none.hasNoPlanUsage)
    let withPlan = try JSONDecoder().decode(
      CursorUsageResponse.self,
      from: Data("{\"planUsage\":{\"totalPercentUsed\":50.0}}".utf8)
    )
    XCTAssertFalse(withPlan.hasNoPlanUsage)
  }

  func testFormatCentsAlwaysUsesUSD() {
    // 即使系统 locale 为中文，金额仍固定显示美元符号。
    XCTAssertEqual(
      CursorUsageFormatter.formatCents(64312, locale: Locale(identifier: "zh_CN")),
      "$643.12"
    )
  }

  func testMenuBarTextIncludesGap() async throws {
    let startMs = Int64(Date().timeIntervalSince1970 - 15 * 86400) * 1000
    let endMs = startMs + 30 * 86400 * 1000
    MockURLProtocol.requestHandler = { _ in
      (
        TestFixtures.cursorHTTPResponse(statusCode: 200),
        Data("""
          {"billingCycleStart":"\(startMs)","billingCycleEnd":"\(endMs)",
           "planUsage":{"totalPercentUsed":70.0}}
          """.utf8)
      )
    }
    let store = CursorUsageStore(
      client: makeClient(),
      authProvider: MockCursorAuthProvider(),
      clock: FixedClock(date: Date(timeIntervalSince1970: 1_700_000_000)),
      startupRefresh: false,
      startupPrune: false,
      autoRefreshInterval: nil,
      historyService: CursorHistoryService(
        store: InMemoryCursorHistoryStore(), clock: SystemClock()
      )
    )
    await store.refresh()
    // 周期中点理想已用 50%，实际 70% → 菜单栏 "30% (+20%)"。
    XCTAssertEqual(store.menuBarText, "30% (+20%)")
  }

  func testMenuBarTextIncludesApiChannel() async throws {
    let startMs = Int64(Date().timeIntervalSince1970 - 15 * 86400) * 1000
    let endMs = startMs + 30 * 86400 * 1000
    MockURLProtocol.requestHandler = { _ in
      (
        TestFixtures.cursorHTTPResponse(statusCode: 200),
        Data("""
          {"billingCycleStart":"\(startMs)","billingCycleEnd":"\(endMs)",
           "planUsage":{"totalPercentUsed":70.0,"apiPercentUsed":83.0}}
          """.utf8)
      )
    }
    let store = CursorUsageStore(
      client: makeClient(),
      authProvider: MockCursorAuthProvider(),
      clock: FixedClock(date: Date(timeIntervalSince1970: 1_700_000_000)),
      startupRefresh: false,
      startupPrune: false,
      autoRefreshInterval: nil,
      historyService: CursorHistoryService(
        store: InMemoryCursorHistoryStore(), clock: SystemClock()
      )
    )
    await store.refresh()
    // 周期中点理想 50%：第一方 70%→剩 30%（+20），API 83%→剩 17%（+33）。
    XCTAssertEqual(store.menuBarText, "30% (+20%)/17% (+33%)")
  }

  func testMenuBarTextOmitsApiChannelWhenUnavailable() async throws {
    MockURLProtocol.requestHandler = { _ in
      (
        TestFixtures.cursorHTTPResponse(statusCode: 200),
        Data("{\"planUsage\":{\"totalPercentUsed\":70.0}}".utf8)
      )
    }
    let store = CursorUsageStore(
      client: makeClient(),
      authProvider: MockCursorAuthProvider(),
      clock: FixedClock(date: Date(timeIntervalSince1970: 1_700_000_000)),
      startupRefresh: false,
      startupPrune: false,
      autoRefreshInterval: nil,
      historyService: CursorHistoryService(
        store: InMemoryCursorHistoryStore(), clock: SystemClock()
      )
    )
    await store.refresh()
    XCTAssertEqual(store.menuBarText, "30%")
  }

  func testHistorySampleStoresApiRemainingPercent() async throws {
    let startMs = Int64(Date().timeIntervalSince1970 - 15 * 86400) * 1000
    let endMs = startMs + 30 * 86400 * 1000
    MockURLProtocol.requestHandler = { _ in
      (
        TestFixtures.cursorHTTPResponse(statusCode: 200),
        Data("""
          {"billingCycleStart":"\(startMs)","billingCycleEnd":"\(endMs)",
           "planUsage":{"totalPercentUsed":70.0,"apiPercentUsed":83.0}}
          """.utf8)
      )
    }
    let history = InMemoryCursorHistoryStore()
    let store = CursorUsageStore(
      client: makeClient(),
      authProvider: MockCursorAuthProvider(),
      clock: FixedClock(date: Date(timeIntervalSince1970: 1_700_000_000)),
      startupRefresh: false,
      autoRefreshInterval: nil,
      historyService: CursorHistoryService(store: history, clock: SystemClock())
    )
    await store.refresh()
    let samples = try await history.fetch(
      credentialID: "cursor",
      from: Date(timeIntervalSince1970: 0),
      to: Date(timeIntervalSince1970: 1_800_000_000)
    )
    XCTAssertEqual(samples.count, 1)
    XCTAssertEqual(samples.first?.remainingPercent, 30)
    XCTAssertEqual(samples.first?.apiRemainingPercent, 17)
  }

  // MARK: - 网络客户端

  private func makeClient(timeout: TimeInterval = 15) -> CursorUsageClient {
    CursorUsageClient(session: MockURLProtocol.makeSession(), timeoutInterval: timeout)
  }

  func testFetchUsageSendsAuthAndProtocolHeaders() async throws {
    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(
        request.value(forHTTPHeaderField: "Connect-Protocol-Version"),
        "1"
      )
      XCTAssertEqual(
        request.value(forHTTPHeaderField: "Content-Type"),
        "application/json"
      )
      return (
        TestFixtures.cursorHTTPResponse(statusCode: 200),
        Data(TestFixtures.cursorUsageJSON.utf8)
      )
    }
    let usage = try await makeClient().fetchUsage(accessToken: "token-123")
    XCTAssertEqual(usage.remainingPercent, 29)
    XCTAssertEqual(MockURLProtocol.capturedAuthorizationHeaders(), ["Bearer token-123"])
  }

  func testFetchUsageUnauthorized() async {
    MockURLProtocol.requestHandler = { _ in
      (TestFixtures.cursorHTTPResponse(statusCode: 401), Data())
    }
    do {
      _ = try await makeClient().fetchUsage(accessToken: "bad")
      XCTFail("应抛出 unauthorized")
    } catch let error as CursorUsageClient.APIError {
      XCTAssertEqual(error, .unauthorized)
    } catch {
      XCTFail("意外的错误类型：\(error)")
    }
  }

  func testFetchUsageDecodingError() async {
    MockURLProtocol.requestHandler = { _ in
      (TestFixtures.cursorHTTPResponse(statusCode: 200), Data("not json".utf8))
    }
    do {
      _ = try await makeClient().fetchUsage(accessToken: "token")
      XCTFail("应抛出 decodingFailed")
    } catch let error as CursorUsageClient.APIError {
      XCTAssertEqual(error, .decodingFailed)
    } catch {
      XCTFail("意外的错误类型：\(error)")
    }
  }

  func testFetchUsageServerError() async {
    MockURLProtocol.requestHandler = { _ in
      (TestFixtures.cursorHTTPResponse(statusCode: 500), Data())
    }
    do {
      _ = try await makeClient().fetchUsage(accessToken: "token")
      XCTFail("应抛出 server 错误")
    } catch let error as CursorUsageClient.APIError {
      XCTAssertEqual(error, .server(statusCode: 500))
    } catch {
      XCTFail("意外的错误类型：\(error)")
    }
  }

  // MARK: - 账号资料解析

  func testParseAboutOutput() {
    let profile = CursorAuthProvider.parseAbout(
      """
      Subscription Tier   Pro+
      User Email   user@example.com

      Model   auto
      """
    )
    XCTAssertEqual(profile?.planTier, "Pro+")
    XCTAssertEqual(profile?.email, "user@example.com")
  }

  func testParseAboutMissingFields() {
    let profile = CursorAuthProvider.parseAbout("Model   auto\nVersion 1.0")
    XCTAssertNil(profile)
  }

  func testResolveCursorAgentURL() {
    XCTAssertNil(
      CursorAuthProvider.resolveCursorAgentURL(environment: ["PATH": "/usr/bin:/bin"])
    )
    XCTAssertEqual(
      CursorAuthProvider.resolveCursorAgentURL(environment: [
        "PATH": "/usr/bin:/bin", "HOME": "/nonexistent"
      ]),
      nil
    )
  }

  // MARK: - 状态机

  func testDisabledStoreSkipsRefreshAndHistoryWrite() async {
    let counter = RequestCounter()
    MockURLProtocol.requestHandler = { _ in
      counter.increment()
      return (
        TestFixtures.cursorHTTPResponse(statusCode: 200),
        Data(TestFixtures.cursorUsageJSON.utf8)
      )
    }
    let history = InMemoryCursorHistoryStore()
    let store = CursorUsageStore(
      client: makeClient(),
      authProvider: MockCursorAuthProvider(
        profile: CursorProfileInfo(planTier: "Pro+", email: "user@example.com")
      ),
      clock: FixedClock(date: Date(timeIntervalSince1970: 1_700_000_000)),
      startupRefresh: false,
      autoRefreshInterval: nil,
      historyService: CursorHistoryService(store: history, clock: SystemClock())
    )
    await store.refresh()
    XCTAssertEqual(store.status, .loaded)
    XCTAssertEqual(counter.count, 1)
    let firstCount = await history.count
    XCTAssertEqual(firstCount, 1)

    // 停用后刷新被跳过：状态不变、不发请求、不写历史。
    store.setEnabled(false)
    XCTAssertEqual(store.isEnabled, false)
    await store.refresh()
    await store.refreshIfNeeded(maximumAge: 0)
    XCTAssertEqual(counter.count, 1)
    let disabledCount = await history.count
    XCTAssertEqual(disabledCount, 1)

    // 重新启用后立即刷新一次。
    store.setEnabled(true)
    XCTAssertEqual(store.isEnabled, true)
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
      if counter.count >= 2 { break }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(counter.count, 2)
  }

  func testStoreWithoutTokenReportsNotConfigured() async {
    MockURLProtocol.requestHandler = { _ in
      (TestFixtures.cursorHTTPResponse(statusCode: 200), Data(TestFixtures.cursorUsageJSON.utf8))
    }
    let store = CursorUsageStore(
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

  func testStoreLoadsUsageAndProfile() async {
    MockURLProtocol.requestHandler = { _ in
      (TestFixtures.cursorHTTPResponse(statusCode: 200), Data(TestFixtures.cursorUsageJSON.utf8))
    }
    let store = CursorUsageStore(
      client: makeClient(),
      authProvider: MockCursorAuthProvider(
        profile: CursorProfileInfo(planTier: "Pro+", email: "user@example.com")
      ),
      clock: FixedClock(date: Date(timeIntervalSince1970: 1_700_000_000)),
      startupRefresh: false
    )
    await store.refresh()
    XCTAssertEqual(store.status, .loaded)
    XCTAssertEqual(store.usage?.remainingPercent, 29)
    XCTAssertEqual(store.profile?.planTier, "Pro+")
    XCTAssertEqual(store.profile?.email, "user@example.com")
    XCTAssertTrue(store.menuBarText.hasPrefix("29%"))
  }

  func testStoreUnauthorizedReportsAuthInvalid() async {
    MockURLProtocol.requestHandler = { _ in
      (TestFixtures.cursorHTTPResponse(statusCode: 401), Data())
    }
    let store = CursorUsageStore(
      client: makeClient(),
      authProvider: MockCursorAuthProvider(),
      clock: FixedClock(date: Date(timeIntervalSince1970: 1_700_000_000)),
      startupRefresh: false
    )
    await store.refresh()
    XCTAssertEqual(store.status, .notConfigured)
    XCTAssertEqual(store.lastDisplayError, .cursorAuthInvalid)
  }

  func testStoreNetworkError() async {
    MockURLProtocol.requestHandler = { _ in
      (TestFixtures.cursorHTTPResponse(statusCode: 500), Data())
    }
    let store = CursorUsageStore(
      client: makeClient(),
      authProvider: MockCursorAuthProvider(),
      clock: FixedClock(date: Date(timeIntervalSince1970: 1_700_000_000)),
      startupRefresh: false
    )
    await store.refresh()
    XCTAssertEqual(store.status, .serverError)
  }
}

extension TestFixtures {
  static let cursorUsageJSON = """
    {
      "billingCycleStart": "1784813765000",
      "billingCycleEnd": "1787492165000",
      "planUsage": {
        "totalSpend": 64312,
        "includedSpend": 7000,
        "bonusSpend": 57312,
        "limit": 7000,
        "remainingBonus": false,
        "autoPercentUsed": 68.93375,
        "apiPercentUsed": 83.31818181818181,
        "totalPercentUsed": 70.67252747252746
      },
      "spendLimitUsage": {
        "limitType": "user"
      },
      "displayThreshold": 200,
      "enabled": true
    }
    """

  static func cursorHTTPResponse(statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(
      url: URL(
        string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
      )!,
      statusCode: statusCode,
      httpVersion: nil,
      headerFields: nil
    )!
  }
}

/// 固定令牌的 Cursor 认证提供者。
struct MockCursorAuthProvider: CursorAuthProviding {
  let info: CursorAuthInfo
  let profile: CursorProfileInfo?
  let authError: Error?

  init(
    info: CursorAuthInfo = CursorAuthInfo(accessToken: "token-123"),
    profile: CursorProfileInfo? = nil,
    authError: Error? = nil
  ) {
    self.info = info
    self.profile = profile
    self.authError = authError
  }

  func loadAuthInfo() throws -> CursorAuthInfo {
    if let authError { throw authError }
    return info
  }

  func loadProfile() -> CursorProfileInfo? {
    profile
  }
}
