import XCTest

@testable import DeepSeekBalance

@MainActor
final class CommandCodeUsageTests: XCTestCase {
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
    let data = Data(TestFixtures.commandCodeUsageJSON.utf8)
    let usage = try JSONDecoder().decode(CommandCodeUsageResponse.self, from: data)
    XCTAssertEqual(usage.credits?.monthlyCredits, 9.83)
    XCTAssertEqual(usage.credits?.purchasedCredits, 0)
    XCTAssertEqual(usage.subscription?.planId, "individual-go")
    XCTAssertEqual(usage.subscription?.status, "active")
    XCTAssertEqual(usage.summary?.totalCount, 171)
    XCTAssertEqual(usage.summary?.totalCost, 0.167)
    XCTAssertEqual(usage.user?.userName, "J-XZ")
    XCTAssertEqual(usage.planDisplayName, "Go")
  }

  func testParsesWindowLimits() throws {
    let data = Data(TestFixtures.commandCodeUsageJSON.utf8)
    let usage = try JSONDecoder().decode(CommandCodeUsageResponse.self, from: data)
    let fiveHour = try XCTUnwrap(usage.fiveHourLimit)
    XCTAssertEqual(fiveHour.used, 0.17)
    XCTAssertEqual(fiveHour.cap, 3)
    XCTAssertFalse(fiveHour.isExceeded)
    XCTAssertEqual(fiveHour.usedPercent, 6)
    XCTAssertNotNil(fiveHour.resetAtDate)
  }

  func testParsesNullFields() throws {
    let data = Data("{}".utf8)
    let usage = try JSONDecoder().decode(CommandCodeUsageResponse.self, from: data)
    XCTAssertNil(usage.credits)
    XCTAssertNil(usage.subscription)
    XCTAssertNil(usage.usageGapPercent)
    XCTAssertNil(usage.remainingPercent)
    XCTAssertFalse(usage.hasAnyCredits)
  }

  func testRemainingPercentComputation() throws {
    let start = "2026-08-06T02:10:47.000Z"
    let end = "2026-09-06T02:10:47.000Z"
    let usage = CommandCodeUsageResponse(
      credits: CommandCodeCredits(
        monthlyCredits: 9.83,
        purchasedCredits: 0,
        freeCredits: 0,
        belowThreshold: false
      ),
      windowLimits: nil,
      subscription: CommandCodeSubscription(
        id: "sub_1",
        status: "active",
        planId: "individual-go",
        currentPeriodStart: start,
        currentPeriodEnd: end,
        cancelAtPeriodEnd: false
      ),
      summary: CommandCodeUsageSummary(
        totalCount: 171,
        totalCost: 0.167,
        averageCost: nil,
        successRate: 100,
        totalTokens: 12_500_000,
        periodBasis: nil
      ),
      user: nil
    )
    XCTAssertEqual(usage.totalPool, 10)
    XCTAssertEqual(usage.usedPercent, 2)
    XCTAssertEqual(usage.remainingPercent, 98)
    XCTAssertNotNil(usage.daysRemaining)
  }

  func testPlanDisplayName() {
    XCTAssertEqual(CommandCodeUsageFormatter.planDisplayName("individual-pro"), "Pro")
    XCTAssertEqual(CommandCodeUsageFormatter.planDisplayName("individual-max"), "Max")
    XCTAssertEqual(CommandCodeUsageFormatter.planDisplayName("individual-ultra"), "Ultra")
    XCTAssertEqual(CommandCodeUsageFormatter.planDisplayName("teams-pro"), "Teams Pro")
    XCTAssertNil(CommandCodeUsageFormatter.planDisplayName(nil))
    XCTAssertEqual(CommandCodeUsageFormatter.planDisplayName("unknown-plan"), "UNKNOWN-PLAN")
  }

  func testPlanMonthlyCredits() {
    XCTAssertEqual(CommandCodeUsageFormatter.monthlyCredits(for: "individual-go"), 10)
    XCTAssertEqual(CommandCodeUsageFormatter.monthlyCredits(for: "individual-pro"), 30)
    XCTAssertEqual(CommandCodeUsageFormatter.monthlyCredits(for: "individual-max"), 150)
    XCTAssertNil(CommandCodeUsageFormatter.monthlyCredits(for: "unknown"))
  }

  // MARK: - 认证

  func testAuthProviderReadsAPIKey() throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let authFile = tempDir.appendingPathComponent("auth.json")
    try Data("""
      {"apiKey":"test-key-123","userName":"tester"}
      """.utf8).write(to: authFile)

    let provider = CommandCodeAuthProvider(authFileURL: authFile)
    let info = try provider.loadAuthInfo()
    XCTAssertEqual(info.apiKey, "test-key-123")
  }

  func testAuthProviderMissingFile() {
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent("missing-auth-\(UUID().uuidString).json")
    let provider = CommandCodeAuthProvider(authFileURL: missing)
    XCTAssertThrowsError(try provider.loadAuthInfo()) { error in
      XCTAssertEqual(error as? CommandCodeAuthError, .authFileUnreadable)
    }
  }

  // MARK: - 网络

  func testClientSendsBearerHeader() async throws {
    let session = MockURLProtocol.makeSession()
    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.httpMethod, "GET")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )!
      return (response, Data("{}".utf8))
    }
    let client = CommandCodeUsageClient(session: session)
    let usage = try await client.fetchUsage(apiKey: "secret")
    XCTAssertNil(usage.credits)
    XCTAssertNil(usage.subscription)
  }

  func testClientDecodesFullResponse() async throws {
    let session = MockURLProtocol.makeSession()
    MockURLProtocol.requestHandler = { request in
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )!
      let body: Data
      if request.url!.path.contains("/whoami") {
        body = Data(#"{"user":{"userName":"J-XZ","email":"a@b.com"}}"#.utf8)
      } else if request.url!.path.contains("/credits") {
        body = Data(#"{"credits":{"monthlyCredits":9.83}}"#.utf8)
      } else if request.url!.path.contains("/subscriptions") {
        body = Data(#"{"data":{"planId":"individual-pro","status":"active"}}"#.utf8)
      } else {
        body = Data(#"{"totalCount":171,"totalCost":0.167}"#.utf8)
      }
      return (response, body)
    }
    let client = CommandCodeUsageClient(session: session)
    let usage = try await client.fetchUsage(apiKey: "secret")
    XCTAssertEqual(usage.user?.userName, "J-XZ")
    XCTAssertEqual(usage.credits?.monthlyCredits, 9.83)
    XCTAssertEqual(usage.subscription?.planId, "individual-pro")
    XCTAssertEqual(usage.summary?.totalCount, 171)
  }

  func testClientUnauthorized() async {
    let session = MockURLProtocol.makeSession()
    MockURLProtocol.requestHandler = { request in
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 401,
        httpVersion: nil,
        headerFields: nil
      )!
      return (response, Data())
    }
    let client = CommandCodeUsageClient(session: session)
    do {
      _ = try await client.fetchUsage(apiKey: "bad")
      XCTFail("Expected unauthorized error")
    } catch let error as CommandCodeUsageClient.APIError {
      XCTAssertEqual(error, .unauthorized)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  // MARK: - Store

  func testStoreRefreshSuccess() async {
    let store = makeStore()
    MockURLProtocol.requestHandler = { request in
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )!
      let body: Data
      if request.url!.path.contains("/whoami") {
        body = Data(#"{"user":{"userName":"J-XZ"}}"#.utf8)
      } else if request.url!.path.contains("/credits") {
        body = Data(#"{"credits":{"monthlyCredits":9.83}}"#.utf8)
      } else if request.url!.path.contains("/subscriptions") {
        body = Data(#"{"data":{"planId":"individual-go","status":"active"}}"#.utf8)
      } else {
        body = Data(#"{"totalCount":10,"totalCost":0.1}"#.utf8)
      }
      return (response, body)
    }
    await store.refresh()
    XCTAssertEqual(store.status, .loaded)
    XCTAssertEqual(store.usage?.credits?.monthlyCredits, 9.83)
    XCTAssertEqual(store.usage?.planDisplayName, "Go")
    XCTAssertNotNil(store.lastUpdated)
  }

  func testStoreAuthFailure() async {
    let store = makeStore(authFileMissing: true)
    await store.refresh()
    XCTAssertEqual(store.status, .notConfigured)
    XCTAssertEqual(store.lastDisplayError, .commandCodeNotConfigured)
  }

  func testDisabledStoreSkipsRefresh() async {
    let store = makeStore()
    MockURLProtocol.requestHandler = { request in
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )!
      return (response, Data("{}".utf8))
    }
    store.setEnabled(false)
    let before = MockURLProtocol.recordedRequestCount
    await store.refresh()
    XCTAssertEqual(MockURLProtocol.recordedRequestCount, before)
  }

  private func makeStore(authFileMissing: Bool = false) -> CommandCodeUsageStore {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let authFile = tempDir.appendingPathComponent("auth.json")
    if !authFileMissing {
      try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
      try? Data(#"{"apiKey":"test-key"}"#.utf8).write(to: authFile)
    }
    let historyDir = tempDir.appendingPathComponent("history.json")
    let history = CommandCodeHistoryService(
      store: CommandCodeHistoryFileStore(fileURL: historyDir),
      clock: FixedClock(date: Date(timeIntervalSince1970: 1_784_813_765))
    )
    return CommandCodeUsageStore(
      client: CommandCodeUsageClient(session: MockURLProtocol.makeSession()),
      authProvider: CommandCodeAuthProvider(authFileURL: authFile),
      clock: FixedClock(date: Date(timeIntervalSince1970: 1_784_813_765)),
      startupRefresh: false,
      startupPrune: false,
      autoRefreshInterval: nil,
      historyService: history
    )
  }
}
