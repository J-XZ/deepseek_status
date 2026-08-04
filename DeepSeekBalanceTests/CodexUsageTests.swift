import XCTest

@testable import DeepSeekBalance

@MainActor
final class CodexUsageTests: XCTestCase {
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
    let data = Data(TestFixtures.codexUsageJSON.utf8)
    let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
    XCTAssertEqual(usage.planType, "prolite")
    XCTAssertEqual(usage.email, "user@example.com")
    XCTAssertEqual(usage.rateLimit?.allowed, true)
    XCTAssertEqual(usage.rateLimit?.limitReached, false)
    XCTAssertEqual(usage.rateLimit?.primaryWindow?.usedPercent, 7)
    XCTAssertEqual(usage.rateLimit?.primaryWindow?.limitWindowSeconds, 604800)
    XCTAssertEqual(usage.remainingPercent, 93)
    XCTAssertEqual(usage.credits?.hasCredits, false)
    XCTAssertEqual(usage.credits?.balance, "0")
  }

  func testParsesResponseWithNullFields() throws {
    let data = Data("""
      {"user_id":null,"plan_type":null,"rate_limit":null,"credits":null,
       "additional_rate_limits":null,"rate_limit_reset_credits":null}
      """.utf8)
    let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
    XCTAssertNil(usage.planType)
    XCTAssertNil(usage.rateLimit)
    XCTAssertNil(usage.remainingPercent)
  }

  func testFiveHourWindowDefaultsToFullAvailability() throws {
    let data = Data(TestFixtures.codexUsageJSON.utf8)
    let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
    // 官方未下发 secondary_window：5 小时可用量视为始终 100%。
    XCTAssertNil(usage.rateLimit?.secondaryWindow)
    XCTAssertEqual(usage.fiveHourRemainingPercent, 100)
    XCTAssertEqual(usage.overallRemainingPercent, 93)
  }

  func testFiveHourWindowUsesRealDataWhenProvided() throws {
    let data = Data("""
      {"plan_type":"pro","rate_limit":{
        "allowed":true,"limit_reached":false,
        "primary_window":{"used_percent":50,"limit_window_seconds":604800,
                          "reset_after_seconds":100,"reset_at":1786165992},
        "secondary_window":{"used_percent":20,"limit_window_seconds":18000,
                            "reset_after_seconds":200,"reset_at":1786165992}
      }}
      """.utf8)
    let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
    XCTAssertEqual(usage.fiveHourRemainingPercent, 80)
    // 5 小时剩余 80% 比每周剩余 50% 宽松，整体取更严格值 50%。
    XCTAssertEqual(usage.overallRemainingPercent, 50)
  }

  func testFiveHourWindowCanBeStricterThanWeekly() throws {
    let data = Data("""
      {"plan_type":"pro","rate_limit":{
        "allowed":true,"limit_reached":false,
        "primary_window":{"used_percent":10,"limit_window_seconds":604800,
                          "reset_after_seconds":100,"reset_at":1786165992},
        "secondary_window":{"used_percent":90,"limit_window_seconds":18000,
                            "reset_after_seconds":200,"reset_at":1786165992}
      }}
      """.utf8)
    let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
    XCTAssertEqual(usage.fiveHourRemainingPercent, 10)
    // 5 小时剩余 10% 比每周剩余 90% 更严格，整体取 10%。
    XCTAssertEqual(usage.overallRemainingPercent, 10)
  }

  func testRemainingPercentClamped() {
    XCTAssertEqual(CodexUsageWindow(
      usedPercent: 150,
      limitWindowSeconds: 604800,
      resetAfterSeconds: 0,
      resetAt: nil
    ).remainingPercent, 0)
    XCTAssertEqual(CodexUsageWindow(
      usedPercent: -5,
      limitWindowSeconds: 604800,
      resetAfterSeconds: 0,
      resetAt: nil
    ).remainingPercent, 100)
  }

  func testPlanDisplayName() {
    XCTAssertEqual(CodexUsageFormatter.planDisplayName("prolite"), "Pro Lite")
    XCTAssertEqual(CodexUsageFormatter.planDisplayName("PLUS"), "Plus")
    XCTAssertEqual(CodexUsageFormatter.planDisplayName("enterprise"), "Enterprise")
    XCTAssertEqual(CodexUsageFormatter.planDisplayName("custom_plan"), "CUSTOM_PLAN")
    XCTAssertNil(CodexUsageFormatter.planDisplayName(nil))
    XCTAssertNil(CodexUsageFormatter.planDisplayName(""))
  }

  func testWindowTitleRecognition() {
    XCTAssertEqual(
      CodexUsageFormatter.windowTitle(limitWindowSeconds: 604800, language: .english),
      "Weekly window"
    )
    XCTAssertEqual(
      CodexUsageFormatter.windowTitle(limitWindowSeconds: 18000, language: .english),
      "5-hour window"
    )
    XCTAssertEqual(
      CodexUsageFormatter.windowTitle(limitWindowSeconds: 12345, language: .english),
      "Usage window"
    )
  }

  func testExpectedUsedPercentAtMidpoint() throws {
    let resetAt = 1_800_000
    let now = Date(timeIntervalSince1970: 900_000)
    let percent = try XCTUnwrap(
      CodexUsageFormatter.expectedUsedPercent(
        resetAt: resetAt,
        limitWindowSeconds: 1_800_000,
        now: now
      )
    )
    XCTAssertEqual(percent, 50, accuracy: 0.001)
  }

  func testExpectedUsedPercentAtWindowStartAndEnd() throws {
    let resetAt = 1_800_000
    let start = try XCTUnwrap(
      CodexUsageFormatter.expectedUsedPercent(
        resetAt: resetAt,
        limitWindowSeconds: 1_800_000,
        now: Date(timeIntervalSince1970: 0)
      )
    )
    XCTAssertEqual(start, 0, accuracy: 0.001)

    let end = try XCTUnwrap(
      CodexUsageFormatter.expectedUsedPercent(
        resetAt: resetAt,
        limitWindowSeconds: 1_800_000,
        now: Date(timeIntervalSince1970: 1_800_000)
      )
    )
    XCTAssertEqual(end, 100, accuracy: 0.001)
  }

  func testExpectedUsedPercentClampsOutOfRange() throws {
    let resetAt = 1_800_000
    let afterReset = CodexUsageFormatter.expectedUsedPercent(
      resetAt: resetAt,
      limitWindowSeconds: 1_800_000,
      now: Date(timeIntervalSince1970: 1_900_000)
    )
    XCTAssertNil(afterReset)

    let beforeStart = CodexUsageFormatter.expectedUsedPercent(
      resetAt: resetAt,
      limitWindowSeconds: 1_800_000,
      now: Date(timeIntervalSince1970: -100)
    )
    XCTAssertNil(beforeStart)
  }

  func testExpectedUsedPercentNilWithoutWindowInfo() {
    XCTAssertNil(CodexUsageFormatter.expectedUsedPercent(resetAt: nil, limitWindowSeconds: 1800))
    XCTAssertNil(CodexUsageFormatter.expectedUsedPercent(resetAt: 1_800_000, limitWindowSeconds: 0))
    XCTAssertNil(CodexUsageFormatter.expectedUsedPercent(resetAt: 1_800_000, limitWindowSeconds: -100))
  }

  func testUsageGapPercentFasterThanIdeal() throws {
    // 周期中点理想已用 50%，实际已用 70% → 消耗快于理想 +20。
    let resetAt = Int(Date().timeIntervalSince1970) + 302_400
    let data = Data("""
      {"plan_type":"pro","rate_limit":{
        "allowed":true,"limit_reached":false,
        "primary_window":{"used_percent":70,"limit_window_seconds":604800,
                          "reset_after_seconds":100,"reset_at":\(resetAt)}
      }}
      """.utf8)
    let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
    let gap = try XCTUnwrap(usage.usageGapPercent)
    XCTAssertEqual(gap, 20)
  }

  func testUsageGapPercentSlowerThanIdeal() throws {
    // 周期中点理想已用 50%，实际已用 30% → 消耗慢于理想 -20。
    let resetAt = Int(Date().timeIntervalSince1970) + 302_400
    let data = Data("""
      {"plan_type":"pro","rate_limit":{
        "allowed":true,"limit_reached":false,
        "primary_window":{"used_percent":30,"limit_window_seconds":604800,
                          "reset_after_seconds":100,"reset_at":\(resetAt)}
      }}
      """.utf8)
    let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
    let gap = try XCTUnwrap(usage.usageGapPercent)
    XCTAssertEqual(gap, -20)
  }

  func testUsageGapPercentNilWithoutWindowInfo() throws {
    let data = Data("""
      {"plan_type":"pro","rate_limit":{
        "allowed":true,"limit_reached":false,
        "primary_window":{"used_percent":30,"limit_window_seconds":604800,
                          "reset_after_seconds":100,"reset_at":null}
      }}
      """.utf8)
    let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
    XCTAssertNil(usage.usageGapPercent)
  }

  func testMenuBarTextIncludesGap() async throws {
    let resetAt = Int(Date().timeIntervalSince1970) + 302_400
    MockURLProtocol.requestHandler = { _ in
      (
        TestFixtures.codexHTTPResponse(statusCode: 200),
        Data("""
          {"plan_type":"pro","rate_limit":{
            "allowed":true,"limit_reached":false,
            "primary_window":{"used_percent":70,"limit_window_seconds":604800,
                              "reset_after_seconds":100,"reset_at":\(resetAt)}
          }}
          """.utf8)
      )
    }
    let store = CodexUsageStore(
      client: makeClient(),
      authProvider: MockCodexAuthProvider(),
      clock: FixedClock(date: Date(timeIntervalSince1970: 1_512_000)),
      startupRefresh: false,
      startupPrune: false,
      autoRefreshInterval: nil,
      historyService: CodexHistoryService(store: InMemoryCodexHistoryStore(), clock: SystemClock())
    )
    await store.refresh()
    // 周期中点理想已用 50%，实际 70% → 菜单栏 "30% (+20%)"。
    XCTAssertEqual(store.menuBarText, "30% (+20%)")
  }

  // MARK: - 启用/停用

  func testDisabledStoreSkipsRefreshAndHistoryWrite() async {
    let counter = RequestCounter()
    MockURLProtocol.requestHandler = { _ in
      counter.increment()
      return (
        TestFixtures.codexHTTPResponse(statusCode: 200),
        Data(TestFixtures.codexUsageJSON.utf8)
      )
    }
    let history = InMemoryCodexHistoryStore()
    let clock = FixedClock(date: Date(timeIntervalSince1970: 1_700_000_000))
    let store = CodexUsageStore(
      client: makeClient(),
      authProvider: MockCodexAuthProvider(),
      clock: clock,
      startupRefresh: false,
      startupPrune: false,
      autoRefreshInterval: nil,
      historyService: CodexHistoryService(store: history, clock: clock)
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
    await waitForRequests(counter, expected: 2)
  }

  private func waitForRequests(
    _ counter: RequestCounter,
    expected: Int,
    timeout: TimeInterval = 2
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if counter.count >= expected { return }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("等待 \(expected) 个请求超时，当前 \(counter.count)")
  }

  func testDisabledStoreSkipsStartupRefresh() async {
    let counter = RequestCounter()
    MockURLProtocol.requestHandler = { _ in
      counter.increment()
      return (
        TestFixtures.codexHTTPResponse(statusCode: 200),
        Data(TestFixtures.codexUsageJSON.utf8)
      )
    }
    let store = CodexUsageStore(
      client: makeClient(),
      authProvider: MockCodexAuthProvider(),
      clock: FixedClock(date: Date(timeIntervalSince1970: 1_700_000_000)),
      startupRefresh: false,
      autoRefreshInterval: nil
    )
    await store.refresh()
    XCTAssertEqual(counter.count, 1)
    await store.setEnabled(false)
    await store.refresh()
    XCTAssertEqual(counter.count, 1)
  }

  // MARK: - 网络客户端

  private func makeClient(timeout: TimeInterval = 15) -> CodexUsageClient {
    CodexUsageClient(session: MockURLProtocol.makeSession(), timeoutInterval: timeout)
  }

  func testFetchUsageSendsAuthorizationHeader() async throws {
    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(
        request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Mozilla/5.0"), true
      )
      return (
        TestFixtures.codexHTTPResponse(statusCode: 200),
        Data(TestFixtures.codexUsageJSON.utf8)
      )
    }
    _ = try await makeClient().fetchUsage(accessToken: "token-123")
    XCTAssertEqual(MockURLProtocol.capturedAuthorizationHeaders(), ["Bearer token-123"])
  }

  func testFetchUsageUnauthorized() async {
    MockURLProtocol.requestHandler = { _ in
      (TestFixtures.codexHTTPResponse(statusCode: 401), Data())
    }
    do {
      _ = try await makeClient().fetchUsage(accessToken: "bad")
      XCTFail("应抛出 unauthorized")
    } catch let error as CodexUsageClient.APIError {
      XCTAssertEqual(error, .unauthorized)
    } catch {
      XCTFail("意外的错误类型：\(error)")
    }
  }

  func testFetchUsageDecodingError() async {
    MockURLProtocol.requestHandler = { _ in
      (TestFixtures.codexHTTPResponse(statusCode: 200), Data("not json".utf8))
    }
    do {
      _ = try await makeClient().fetchUsage(accessToken: "token")
      XCTFail("应抛出 decodingFailed")
    } catch let error as CodexUsageClient.APIError {
      XCTAssertEqual(error, .decodingFailed)
    } catch {
      XCTFail("意外的错误类型：\(error)")
    }
  }

  func testFetchUsageServerError() async {
    MockURLProtocol.requestHandler = { _ in
      (TestFixtures.codexHTTPResponse(statusCode: 500), Data())
    }
    do {
      _ = try await makeClient().fetchUsage(accessToken: "token")
      XCTFail("应抛出 server 错误")
    } catch let error as CodexUsageClient.APIError {
      XCTAssertEqual(error, .server(statusCode: 500))
    } catch {
      XCTFail("意外的错误类型：\(error)")
    }
  }

  // MARK: - 认证读取

  func testAuthProviderReadsDefaultPath() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let authFile = directory.appendingPathComponent("auth.json")
    try Data(TestFixtures.codexAuthJSON.utf8).write(to: authFile)

    let provider = CodexAuthProvider(authFileURL: authFile)
    let info = try provider.loadAuthInfo()
    XCTAssertEqual(info.accessToken, "eyJ.access")
    XCTAssertEqual(info.refreshToken, "rt_abc")
    XCTAssertEqual(info.accountID, "user-123")
  }

  func testAuthProviderMissingFileThrows() {
    let provider = CodexAuthProvider(
      authFileURL: URL(fileURLWithPath: "/nonexistent/auth.json")
    )
    XCTAssertThrowsError(try provider.loadAuthInfo()) { error in
      XCTAssertEqual(error as? CodexAuthError, .noAuthFile)
    }
  }

  func testAuthProviderMissingAccessTokenThrows() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let authFile = directory.appendingPathComponent("auth.json")
    try Data("{\"tokens\":{\"refresh_token\":\"rt_abc\"}}".utf8).write(to: authFile)

    let provider = CodexAuthProvider(authFileURL: authFile)
    XCTAssertThrowsError(try provider.loadAuthInfo()) { error in
      XCTAssertEqual(error as? CodexAuthError, .missingAccessToken)
    }
  }

  // MARK: - 状态机

  func testStoreWithoutAuthFileReportsNotConfigured() async {
    MockURLProtocol.requestHandler = { _ in
      (TestFixtures.codexHTTPResponse(statusCode: 200), Data(TestFixtures.codexUsageJSON.utf8))
    }
    let store = CodexUsageStore(
      client: makeClient(),
      authProvider: CodexAuthProvider(
        authFileURL: URL(fileURLWithPath: "/nonexistent/codex/auth.json")
      ),
      clock: FixedClock(date: Date(timeIntervalSince1970: 1_700_000_000)),
      startupRefresh: false
    )
    await store.refresh()
    XCTAssertEqual(store.status, .notConfigured)
    XCTAssertNil(store.usage)
    XCTAssertEqual(store.menuBarText, "—")
  }

  func testStoreUsesInjectedAuthInfo() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let authFile = directory.appendingPathComponent("auth.json")
    try Data(TestFixtures.codexAuthJSON.utf8).write(to: authFile)

    MockURLProtocol.requestHandler = { _ in
      (TestFixtures.codexHTTPResponse(statusCode: 200), Data(TestFixtures.codexUsageJSON.utf8))
    }
    let store = CodexUsageStore(
      client: makeClient(),
      authProvider: CodexAuthProvider(authFileURL: authFile, session: MockURLProtocol.makeSession()),
      clock: FixedClock(date: Date(timeIntervalSince1970: 1_700_000_000)),
      startupRefresh: false
    )
    await store.refresh()
    XCTAssertEqual(store.status, .loaded)
    XCTAssertEqual(store.usage?.remainingPercent, 93)
    // 差距值依赖真实时间，只断言剩余百分比主体。
    XCTAssertTrue(store.menuBarText.hasPrefix("93%"))
  }

  func testStoreAutoRefreshesExpiredToken() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let authFile = directory.appendingPathComponent("auth.json")
    try Data(TestFixtures.codexAuthJSON.utf8).write(to: authFile)

    var requestCount = 0
    MockURLProtocol.requestHandler = { request in
      requestCount += 1
      let token = request.value(forHTTPHeaderField: "Authorization") ?? ""
      if request.url?.path.contains("oauth/token") == true {
        return (
          TestFixtures.codexHTTPResponse(statusCode: 200),
          Data(#"{"access_token":"new-token","refresh_token":"rt_new"}"#.utf8)
        )
      }
      if token == "Bearer eyJ.access" {
        return (TestFixtures.codexHTTPResponse(statusCode: 401), Data())
      }
      return (
        TestFixtures.codexHTTPResponse(statusCode: 200),
        Data(TestFixtures.codexUsageJSON.utf8)
      )
    }
    let store = CodexUsageStore(
      client: makeClient(),
      authProvider: CodexAuthProvider(authFileURL: authFile, session: MockURLProtocol.makeSession()),
      clock: FixedClock(date: Date(timeIntervalSince1970: 1_700_000_000)),
      startupRefresh: false
    )
    await store.refresh()
    XCTAssertEqual(store.status, .loaded)
    let usageRequests = MockURLProtocol.capturedAuthorizationHeaders().compactMap { $0 }
    XCTAssertEqual(usageRequests, ["Bearer eyJ.access", "Bearer new-token"])
    // 差距值依赖真实时间，只断言剩余百分比主体。
    XCTAssertTrue(store.menuBarText.hasPrefix("93%"))
  }

  func testAuthProviderPersistsAccessTokenWhenRefreshTokenOmitted() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let authFile = directory.appendingPathComponent("auth.json")
    try Data(TestFixtures.codexAuthJSON.utf8).write(to: authFile)

    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url?.path.contains("oauth/token"), true)
      return (
        TestFixtures.codexHTTPResponse(statusCode: 200),
        Data(#"{"access_token":"rotated-access"}"#.utf8)
      )
    }
    let provider = CodexAuthProvider(authFileURL: authFile, session: MockURLProtocol.makeSession())
    let newToken = try await provider.refreshAccessToken(refreshToken: "rt_abc")
    XCTAssertEqual(newToken, "rotated-access")

    let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: authFile)) as? [String: Any]
    let tokens = saved?["tokens"] as? [String: Any]
    XCTAssertEqual(tokens?["access_token"] as? String, "rotated-access")
    XCTAssertEqual(tokens?["refresh_token"] as? String, "rt_abc")
  }
}

/// 线程安全请求计数器，供异步测试闭包与断言共享。
final class RequestCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
  func increment() {
    lock.lock()
    value += 1
    lock.unlock()
  }
}

extension TestFixtures {
  static let codexUsageJSON = """
    {
      "user_id": "user-1",
      "account_id": "user-1",
      "email": "user@example.com",
      "plan_type": "prolite",
      "rate_limit": {
        "allowed": true,
        "limit_reached": false,
        "primary_window": {
          "used_percent": 7,
          "limit_window_seconds": 604800,
          "reset_after_seconds": 573820,
          "reset_at": 1786165992
        },
        "secondary_window": null
      },
      "credits": {
        "has_credits": false,
        "unlimited": false,
        "overage_limit_reached": false,
        "balance": "0"
      }
    }
    """

  static let codexAuthJSON = """
    {
      "auth_mode": "chatgpt",
      "OPENAI_API_KEY": null,
      "tokens": {
        "id_token": "id-token",
        "access_token": "eyJ.access",
        "refresh_token": "rt_abc",
        "account_id": "user-123"
      },
      "last_refresh": "2026-08-01T05:12:24.594889Z"
    }
    """

  static func codexHTTPResponse(statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(
      url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
      statusCode: statusCode,
      httpVersion: nil,
      headerFields: nil
    )!
  }
}
