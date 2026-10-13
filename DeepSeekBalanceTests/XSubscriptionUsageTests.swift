import XCTest

@testable import DeepSeekBalance

@MainActor
final class XSubscriptionUsageTests: XCTestCase {
  override func setUp() {
    super.setUp()
    MockURLProtocol.reset()
  }

  override func tearDown() {
    MockURLProtocol.reset()
    super.tearDown()
  }

  func testParserMergedSampleUsesPercentScale() throws {
    let sand = try XSubscriptionSandParser.parse(Data(TestFixtures.xSubscriptionSandJSON.utf8))
    guard case .metered(let quota) = sand.weekly else {
      return XCTFail("expected metered")
    }
    XCTAssertEqual(quota.usedPercent, 0)
    XCTAssertEqual(quota.remainingPercent, 100)
    XCTAssertEqual(sand.isUnified, true)
    XCTAssertEqual(sand.cursorPlanName, "Ultra")
    XCTAssertEqual(sand.onDemand?.visible, true)
    XCTAssertEqual(sand.onDemand?.eligible, true)
    XCTAssertNotNil(sand.unifiedBillingUrl)
    XCTAssertNotNil(sand.currentPeriodStart)
    XCTAssertNotNil(sand.nextResetTimestampUtc)

    let plan = try XSubscriptionPlanParser.parse(Data(TestFixtures.xSubscriptionPlanJSON.utf8))
    XCTAssertEqual(plan.planName, "Ultra")
    XCTAssertEqual(plan.isMerged, true)
    XCTAssertEqual(plan.includedUsagePeriod, "INCLUDED_USAGE_PERIOD_WEEKLY")
  }

  func testParserLegacyPercentScaleAndUnmergedFlag() throws {
    let sand = try XSubscriptionSandParser.parse(
      Data("""
        {
          "usagePercent": 27.4,
          "hasNonZeroIncludedLimit": true,
          "nextResetTimestampUtc": {"seconds":"1700086400","nanos":0}
        }
        """.utf8)
    )
    guard case .metered(let quota) = sand.weekly else {
      return XCTFail("expected metered")
    }
    XCTAssertEqual(quota.usedPercent, 27)
    XCTAssertEqual(quota.remainingPercent, 73)
    XCTAssertNil(sand.isUnified)

    let plan = try XSubscriptionPlanParser.parse(
      Data("""
        {"planInfo":{"planName":"Pro"},"isMerged":false}
        """.utf8)
    )
    XCTAssertEqual(plan.isMerged, false)
    XCTAssertEqual(plan.planName, "Pro")
  }

  func testParserEnterpriseTrialAndNoLimit() throws {
    let pooled = try XSubscriptionSandParser.parse(
      Data("""
        {"usagePercent":63.0,"usesPooledEnterpriseAllowance":true}
        """.utf8)
    )
    XCTAssertEqual(pooled.weekly, .enterprisePooled)

    let trial = try XSubscriptionSandParser.parse(
      Data("""
        {
          "usagePercent":40.0,
          "hasNonZeroIncludedLimit":true,
          "sandTrialExpiresAt":"2026-01-15T12:00:00Z"
        }
        """.utf8)
    )
    guard case .trial = trial.weekly else {
      return XCTFail("expected trial")
    }

    let noLimit = try XSubscriptionSandParser.parse(
      Data("""
        {"hasNonZeroIncludedLimit":false,"usagePercent":12.0}
        """.utf8)
    )
    XCTAssertEqual(noLimit.weekly, .noIncludedLimit)
  }

  func testParserGetMeReadsUserIdFromNumberStringAndNestedUser() throws {
    XCTAssertEqual(try XSubscriptionMeParser.parse(Data(#"{"userId":42}"#.utf8)), 42)
    XCTAssertEqual(try XSubscriptionMeParser.parse(Data(#"{"userId":"99"}"#.utf8)), 99)
    XCTAssertEqual(try XSubscriptionMeParser.parse(Data(#"{"user":{"id":"7"}}"#.utf8)), 7)
    XCTAssertEqual(try XSubscriptionMeParser.parse(Data(#"{"user":{"userId":12345}}"#.utf8)), 12_345)
    XCTAssertThrowsError(try XSubscriptionMeParser.parse(Data("{}".utf8)))
  }

  func testParserDailySpendEmptyObjectIsEmptyBreakdown() throws {
    let empty = try XSubscriptionDailySpendParser.parse(Data("{}".utf8))
    XCTAssertTrue(empty.isEmpty)
    XCTAssertEqual(empty.cursor.tokens, 0)
    XCTAssertEqual(empty.grokBot.tokens, 0)
    XCTAssertNil(empty.cursor.sharePercent)
    XCTAssertNil(empty.grokBot.spendCents)

    let emptyArrays = try XSubscriptionDailySpendParser.parse(
      Data(#"{"categories":["sand","cursor"],"dailySpend":[]}"#.utf8)
    )
    XCTAssertTrue(emptyArrays.isEmpty)
  }

  func testParserDailySpendSumsMultiDayTwoCategoriesAndPrefersCents() throws {
    let breakdown = try XSubscriptionDailySpendParser.parse(
      Data(
        """
        {
          "categories": ["sand", "cursor"],
          "dailySpend": [
            {"day": "1760313600000", "category": "sand", "totalTokens": "1000", "spendCents": "10"},
            {"day": "1760399999000", "category": "sand", "totalTokens": 500},
            {"day": "1760313600000", "category": "cursor", "totalTokens": "8500", "totalCents": "90"}
          ]
        }
        """.utf8
      )
    )
    XCTAssertFalse(breakdown.isEmpty)
    XCTAssertEqual(breakdown.grokBot.tokens, 1_500)
    XCTAssertEqual(breakdown.cursor.tokens, 8_500)
    XCTAssertEqual(breakdown.grokBot.sharePercent, 15)
    XCTAssertEqual(breakdown.cursor.sharePercent, 85)
    XCTAssertEqual(breakdown.grokBot.spendCents, 10)
    XCTAssertEqual(breakdown.cursor.spendCents, 90)
  }

  func testParserDailySpendIgnoresMissingFields() throws {
    let breakdown = try XSubscriptionDailySpendParser.parse(
      Data(
        """
        {
          "dailySpend": [
            {"day": "1", "totalTokens": "100"},
            {"category": "cursor"},
            {"category": "sand", "totalTokens": "2000"},
            {"category": "cursor", "spendCents": "25"}
          ]
        }
        """.utf8
      )
    )
    XCTAssertEqual(breakdown.grokBot.tokens, 2_000)
    XCTAssertEqual(breakdown.cursor.tokens, 0)
    XCTAssertEqual(breakdown.cursor.spendCents, 25)
    XCTAssertNil(breakdown.grokBot.spendCents)
    XCTAssertEqual(breakdown.grokBot.sharePercent, 100)
    XCTAssertEqual(breakdown.cursor.sharePercent, 0)
  }

  func testParserPrepaidOmitsAvailableCentsAsZeroAndReadsStringAmounts() throws {
    let omitted = try XSubscriptionPrepaidParser.parse(
      Data(#"{"billingMode":"PREPAID_BILLING_MODE_PREPAID","eligible":true,"hasPaymentMethod":true,"spentThisMonthCents":"0"}"#.utf8)
    )
    XCTAssertEqual(omitted.availableCents, 0)
    XCTAssertEqual(omitted.spentThisMonthCents, 0)
    XCTAssertEqual(omitted.eligible, true)
    XCTAssertEqual(omitted.hasPaymentMethod, true)
    XCTAssertEqual(omitted.billingMode, "PREPAID_BILLING_MODE_PREPAID")

    let strings = try XSubscriptionPrepaidParser.parse(
      Data(#"{"availableCents":"1234","fundedCents":"5000","spentCents":"3766","spentThisMonthCents":"250"}"#.utf8)
    )
    XCTAssertEqual(strings.availableCents, 1_234)
    XCTAssertEqual(strings.fundedCents, 5_000)
    XCTAssertEqual(strings.spentCents, 3_766)
    XCTAssertEqual(strings.spentThisMonthCents, 250)
  }

  func testParserHardLimitUnlimitedAndCapped() throws {
    let unlimited = try XSubscriptionHardLimitParser.parse(
      Data(#"{"hardLimit":2147483647}"#.utf8)
    )
    XCTAssertEqual(unlimited.dollars, XSubscriptionHardLimit.unlimitedSentinel)
    XCTAssertTrue(unlimited.isUnlimited)

    let capped = try XSubscriptionHardLimitParser.parse(
      Data(#"{"hardLimit":"200"}"#.utf8)
    )
    XCTAssertEqual(capped.dollars, 200)
    XCTAssertFalse(capped.isUnlimited)
  }

  func testDailySpendRequestUsesUTCMidnightAndRelativeReset() throws {
    let start = ISO8601DateFormatter.xSubscriptionFractional.date(from: "2026-10-13T06:55:46.293Z")!
    let end = ISO8601DateFormatter.xSubscriptionFractional.date(from: "2026-10-20T06:55:46.293Z")!
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let midnight = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13))!
    XCTAssertEqual(XSubscriptionDailySpendRequest.utcStartOfDay(start), midnight)

    let body = try JSONSerialization.jsonObject(
      with: XSubscriptionDailySpendRequest.body(userId: 42, periodStart: start, periodEnd: end)
    ) as? [String: Any]
    XCTAssertEqual((body?["userId"] as? NSNumber)?.int64Value, 42)
    XCTAssertEqual(body?["periodStartMs"] as? String, XSubscriptionDailySpendRequest.epochMsString(midnight))
    XCTAssertEqual(body?["periodEndMs"] as? String, XSubscriptionDailySpendRequest.epochMsString(end))
    XCTAssertEqual(body?["groupBy"] as? Int, 5)
    XCTAssertEqual(body?["spendType"] as? Int, 3)
    XCTAssertEqual(body?["includeCreditUsage"] as? Bool, true)
  }

  func testAmountFormattingUsesUSDCentsDollarsAndCompactTokens() {
    let locale = Locale(identifier: "en_US")
    XCTAssertEqual(XSubscriptionUsageFormatter.formatCents(0, locale: locale), "$0.00")
    XCTAssertEqual(XSubscriptionUsageFormatter.formatCents(1_234, locale: locale), "$12.34")
    XCTAssertEqual(XSubscriptionUsageFormatter.formatCents(10_000, locale: locale), "$100.00")
    XCTAssertEqual(XSubscriptionUsageFormatter.formatDollars(200, locale: locale), "$200.00")
    XCTAssertNil(XSubscriptionUsageFormatter.formatCents(nil, locale: locale))
    XCTAssertEqual(XSubscriptionUsageFormatter.formatTokens(0, locale: locale), "0")
    XCTAssertEqual(XSubscriptionUsageFormatter.formatTokens(999, locale: locale), "999")
    XCTAssertEqual(XSubscriptionUsageFormatter.formatTokens(1_234, locale: locale), "1.2K")
    XCTAssertEqual(XSubscriptionUsageFormatter.formatTokens(12_900_000, locale: locale), "12.9M")
  }

  func testClientMergesConcurrentResponsesAndDegradesOptionalFailures() async throws {
    installDefaultHandler(planStatus: 500, spendJSON: TestFixtures.xSubscriptionDailySpendJSON)
    let snapshot = try await makeClient().fetchUsage(accessToken: "token")
    XCTAssertEqual(snapshot.isMerged, true)
    XCTAssertEqual(snapshot.planDisplayName, "Ultra")
    XCTAssertEqual(snapshot.meteredQuota?.remainingPercent, 100)
    XCTAssertEqual(snapshot.prepaid?.availableCents, 0)
    XCTAssertEqual(snapshot.prepaid?.spentThisMonthCents, 0)
    XCTAssertEqual(snapshot.hardLimit?.isUnlimited, true)
    XCTAssertEqual(snapshot.productBreakdown?.cursor.tokens, 8_500)
    XCTAssertEqual(snapshot.productBreakdown?.grokBot.tokens, 1_500)
  }

  func testClientSendsDailySpendBodyFromGetMeAndUTCMidnight() async throws {
    installDefaultHandler()
    _ = try await makeClient().fetchUsage(accessToken: "token")
    let spend = try XCTUnwrap(
      MockURLProtocol.recordedRequestsSnapshot().first {
        $0.url?.path.hasSuffix("GetDailySpendByCategory") == true
      }
    )
    let prepaid = try XCTUnwrap(
      MockURLProtocol.recordedRequestsSnapshot().first {
        $0.url?.path.hasSuffix("GetUserPrepaidBilling") == true
      }
    )
    let spendJSON = try XCTUnwrap(MockURLProtocol.httpBody(from: spend)).jsonObject()
    let start = ISO8601DateFormatter.xSubscriptionFractional.date(
      from: "2026-10-13T06:55:46.293Z"
    )!
    let end = ISO8601DateFormatter.xSubscriptionFractional.date(
      from: "2026-10-20T06:55:46.293Z"
    )!
    XCTAssertEqual((spendJSON["userId"] as? NSNumber)?.int64Value, 42)
    XCTAssertEqual(
      spendJSON["periodStartMs"] as? String,
      XSubscriptionDailySpendRequest.epochMsString(XSubscriptionDailySpendRequest.utcStartOfDay(start))
    )
    XCTAssertEqual(
      spendJSON["periodEndMs"] as? String,
      XSubscriptionDailySpendRequest.epochMsString(end)
    )
    XCTAssertEqual(
      try XCTUnwrap(MockURLProtocol.httpBody(from: prepaid)).jsonObject()["limit"] as? Int,
      1
    )
    XCTAssertNil(
      snapshotHasCreditGrantsRequest()
    )
  }

  func testClientSkipsDailySpendWhenGetMeFails() async throws {
    installDefaultHandler(meStatus: 404)
    let snapshot = try await makeClient().fetchUsage(accessToken: "token")
    XCTAssertNil(snapshot.productBreakdown)
    XCTAssertFalse(
      MockURLProtocol.recordedRequestsSnapshot().contains {
        $0.url?.path.hasSuffix("GetDailySpendByCategory") == true
      }
    )
  }

  func testClientMainEndpointFailureThrows() async {
    MockURLProtocol.requestHandler = { request in
      let path = request.url?.path ?? ""
      if path.hasSuffix("GetSandUsageStatus") {
        return (
          TestFixtures.xSubscriptionHTTPResponse(path: "GetSandUsageStatus", statusCode: 401),
          Data()
        )
      }
      return (
        TestFixtures.xSubscriptionHTTPResponse(path: "GetPlanInfo"),
        Data(TestFixtures.xSubscriptionPlanJSON.utf8)
      )
    }
    do {
      _ = try await makeClient().fetchUsage(accessToken: "token")
      XCTFail("expected throw")
    } catch XSubscriptionUsageClient.APIError.unauthorized {
      return
    } catch {
      XCTFail("unexpected \(error)")
    }
  }

  func testClientOptionalPrepaidHardLimitAndSpendFailuresDegradeOnlyThoseSections() async throws {
    installDefaultHandler(prepaidStatus: 404, spendStatus: 500, hardLimitStatus: 404)
    let snapshot = try await makeClient().fetchUsage(accessToken: "token")
    XCTAssertEqual(snapshot.meteredQuota?.remainingPercent, 100)
    XCTAssertEqual(snapshot.planDisplayName, "Ultra")
    XCTAssertNil(snapshot.prepaid)
    XCTAssertNil(snapshot.hardLimit)
    XCTAssertNil(snapshot.productBreakdown)
  }

  func testStoreWithoutTokenReportsNotConfigured() async {
    let store = XSubscriptionUsageStore(
      client: makeClient(),
      authProvider: MockXSubscriptionAuthProvider(
        authError: XSubscriptionAuthError.securityCommandFailed
      ),
      clock: FixedClock(date: Date(timeIntervalSince1970: 1_700_000_000)),
      startupRefresh: false
    )
    await store.refresh()
    XCTAssertEqual(store.status, .notConfigured)
    XCTAssertNil(store.usage)
    XCTAssertEqual(store.menuBarText, "—")
  }

  func testStoreMergedPersistsHistorySample() async throws {
    installDefaultHandler()
    let history = InMemoryXSubscriptionHistoryStore()
    let clock = FixedClock(date: Date(timeIntervalSince1970: 1_700_000_000))
    let store = XSubscriptionUsageStore(
      client: makeClient(),
      authProvider: MockXSubscriptionAuthProvider(),
      clock: clock,
      startupRefresh: false,
      startupPrune: false,
      autoRefreshInterval: nil,
      historyService: XSubscriptionHistoryService(store: history, clock: clock)
    )
    await store.refresh()
    XCTAssertEqual(store.status, .loaded)
    XCTAssertEqual(store.usage?.isMerged, true)
    XCTAssertEqual(store.usage?.planDisplayName, "Ultra")
    XCTAssertEqual(store.usage?.meteredQuota?.remainingPercent, 100)
    XCTAssertEqual(store.usage?.prepaid?.availableCents, 0)
    let samples = try await history.fetch(
      credentialID: "xsubscription",
      from: Date(timeIntervalSince1970: 0),
      to: Date(timeIntervalSince1970: 1_800_000_000)
    )
    XCTAssertEqual(samples.count, 1)
    XCTAssertEqual(samples.first?.remainingPercent, 100)
  }

  func testStoreLegacyUnmergedStillLoadsPartialData() async throws {
    MockURLProtocol.requestHandler = { request in
      let path = request.url?.path ?? ""
      if path.hasSuffix("GetSandUsageStatus") {
        return (
          TestFixtures.xSubscriptionHTTPResponse(path: "GetSandUsageStatus"),
          Data("""
            {
              "usagePercent": 27.0,
              "hasNonZeroIncludedLimit": true,
              "nextResetTimestampUtc": {"seconds":"1700086400","nanos":0}
            }
            """.utf8)
        )
      }
      if path.hasSuffix("GetPlanInfo") {
        return (
          TestFixtures.xSubscriptionHTTPResponse(path: "GetPlanInfo"),
          Data("""
            {"planInfo":{"planName":"Pro"},"isMerged":false}
            """.utf8)
        )
      }
      return (
        TestFixtures.xSubscriptionHTTPResponse(path: path, statusCode: 500),
        Data()
      )
    }
    let store = XSubscriptionUsageStore(
      client: makeClient(),
      authProvider: MockXSubscriptionAuthProvider(),
      clock: FixedClock(date: Date(timeIntervalSince1970: 1_700_000_000)),
      startupRefresh: false,
      startupPrune: false,
      autoRefreshInterval: nil,
      historyService: XSubscriptionHistoryService(
        store: InMemoryXSubscriptionHistoryStore(),
        clock: FixedClock(date: Date(timeIntervalSince1970: 1_700_000_000))
      )
    )
    await store.refresh()
    XCTAssertEqual(store.status, .loaded)
    XCTAssertEqual(store.usage?.isMerged, false)
    XCTAssertEqual(store.usage?.planDisplayName, "Pro")
    XCTAssertEqual(store.usage?.meteredQuota?.remainingPercent, 73)
    XCTAssertNil(store.usage?.prepaid)
    XCTAssertNil(store.usage?.productBreakdown)
  }

  private func makeClient() -> XSubscriptionUsageClient {
    XSubscriptionUsageClient(session: MockURLProtocol.makeSession())
  }

  private func snapshotHasCreditGrantsRequest() -> URLRequest? {
    MockURLProtocol.recordedRequestsSnapshot().first {
      $0.url?.path.contains("GetCreditGrantsBalance") == true
    }
  }

  private func installDefaultHandler(
    planStatus: Int = 200,
    meStatus: Int = 200,
    prepaidStatus: Int = 200,
    spendStatus: Int = 200,
    hardLimitStatus: Int = 200,
    spendJSON: String = "{}",
    prepaidJSON: String = TestFixtures.xSubscriptionPrepaidJSON
  ) {
    MockURLProtocol.requestHandler = { request in
      let path = request.url?.path ?? ""
      if path.hasSuffix("GetSandUsageStatus") {
        return (
          TestFixtures.xSubscriptionHTTPResponse(path: "GetSandUsageStatus"),
          Data(TestFixtures.xSubscriptionSandJSON.utf8)
        )
      }
      if path.hasSuffix("GetPlanInfo") {
        return (
          TestFixtures.xSubscriptionHTTPResponse(path: "GetPlanInfo", statusCode: planStatus),
          Data(TestFixtures.xSubscriptionPlanJSON.utf8)
        )
      }
      if path.hasSuffix("GetMe") {
        return (
          TestFixtures.xSubscriptionHTTPResponse(path: "GetMe", statusCode: meStatus),
          Data(#"{"userId":42}"#.utf8)
        )
      }
      if path.hasSuffix("GetUserPrepaidBilling") {
        return (
          TestFixtures.xSubscriptionHTTPResponse(path: "GetUserPrepaidBilling", statusCode: prepaidStatus),
          Data(prepaidJSON.utf8)
        )
      }
      if path.hasSuffix("GetDailySpendByCategory") {
        return (
          TestFixtures.xSubscriptionHTTPResponse(path: "GetDailySpendByCategory", statusCode: spendStatus),
          Data(spendJSON.utf8)
        )
      }
      if path.hasSuffix("GetHardLimit") {
        return (
          TestFixtures.xSubscriptionHTTPResponse(path: "GetHardLimit", statusCode: hardLimitStatus),
          Data(#"{"hardLimit":2147483647}"#.utf8)
        )
      }
      return (
        TestFixtures.xSubscriptionHTTPResponse(path: "unknown", statusCode: 404),
        Data()
      )
    }
  }
}

struct MockXSubscriptionAuthProvider: XSubscriptionAuthProviding {
  var accessToken = "test-token"
  var authError: XSubscriptionAuthError?

  func loadAuthInfo() throws -> XSubscriptionAuthInfo {
    if let authError { throw authError }
    return XSubscriptionAuthInfo(accessToken: accessToken)
  }
}

extension TestFixtures {
  static let xSubscriptionSandJSON = """
    {
      "currentPeriodStart": "2026-10-13T06:55:46.293Z",
      "nextResetTimestampUtc": "2026-10-20T06:55:46.293Z",
      "usagePercent": 0.030036,
      "hasAvailableUsage": true,
      "hasNonZeroIncludedLimit": true,
      "onDemandSettings": {
        "visible": true,
        "eligible": true,
        "dashboardUrl": "https://cursor.com/dashboard/spending?for=<redacted>"
      },
      "grokPlanLabel": "Grok Bot Plan",
      "cursorPlanName": "Ultra",
      "isUnified": true,
      "unifiedBillingUrl": "https://cursor.com/v2/billing?host=desktop&entrypoint=grok_bot_billing"
    }
    """

  static let xSubscriptionPlanJSON = """
    {
      "planInfo": {
        "planName": "Ultra",
        "price": "",
        "billingCycleEnd": "1794552887843",
        "includedUsagePeriod": "INCLUDED_USAGE_PERIOD_WEEKLY",
        "includedUsageResetsAt": "1792479346293"
      },
      "isMerged": true
    }
    """

  static let xSubscriptionPrepaidJSON = """
    {
      "billingMode": "PREPAID_BILLING_MODE_PREPAID",
      "eligible": true,
      "hasPaymentMethod": true,
      "spentThisMonthCents": "0"
    }
    """

  static let xSubscriptionDailySpendJSON = """
    {
      "categories": ["sand", "cursor"],
      "dailySpend": [
        {"day": "1760313600000", "category": "sand", "totalTokens": "1500", "spendCents": "10"},
        {"day": "1760313600000", "category": "cursor", "totalTokens": "8500", "totalCents": "90"}
      ]
    }
    """

  static func xSubscriptionHTTPResponse(
    path: String,
    statusCode: Int = 200
  ) -> HTTPURLResponse {
    HTTPURLResponse(
      url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/\(path)")!,
      statusCode: statusCode,
      httpVersion: nil,
      headerFields: nil
    )!
  }
}

private extension Data {
  func jsonObject() throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: self)
    return try XCTUnwrap(object as? [String: Any])
  }
}

private extension ISO8601DateFormatter {
  static let xSubscriptionFractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
}

final class XSubscriptionPercentRegressionTests: XCTestCase {
  // 回归：真实接口返回 0...100 百分比（2026-10-13 实测 usagePercent=0.843227，官方显示已用 1%）。
  func testPercentFieldsAreAlreadyPercentNotFractions() {
    XCTAssertEqual(XSubscriptionPercent.usedPercent(from: 0.843227), 1)
    XCTAssertEqual(XSubscriptionPercent.usedPercent(from: 0.8285946385052803), 1)
    XCTAssertEqual(XSubscriptionPercent.usedPercent(from: 0.030036), 0)
    XCTAssertEqual(XSubscriptionPercent.usedPercent(from: 0), 0)
    XCTAssertEqual(XSubscriptionPercent.usedPercent(from: 1.0), 1)
    XCTAssertEqual(XSubscriptionPercent.usedPercent(from: 42.4), 42)
    XCTAssertEqual(XSubscriptionPercent.usedPercent(from: 150), 100)
  }
}

final class XSubscriptionProductPieTests: XCTestCase {
  private func spend(_ tokens: Int64, cents: Int64? = nil) -> XSubscriptionProductSpend {
    XSubscriptionProductSpend(tokens: tokens, spendCents: cents, sharePercent: nil)
  }

  func testTwoProductsUseTokensWhenNoCents() {
    let b = XSubscriptionProductBreakdown(cursor: spend(300), grokBot: spend(100))
    XCTAssertEqual(b.pieSlices.map(\.product), [.cursor, .grokBot])
    XCTAssertEqual(b.pieSlices.map(\.value), [300, 100])
  }

  func testCentsPreferredWhenBothPresent() {
    let b = XSubscriptionProductBreakdown(cursor: spend(300, cents: 5), grokBot: spend(100, cents: 15))
    XCTAssertEqual(b.pieSlices.map(\.value), [5, 15])
  }

  func testSingleProductYieldsOneSlice() {
    let b = XSubscriptionProductBreakdown(cursor: spend(0), grokBot: spend(42))
    XCTAssertEqual(b.pieSlices.map(\.product), [.grokBot])
  }

  func testEmptyYieldsNoSlices() {
    let b = XSubscriptionProductBreakdown(cursor: .zero, grokBot: .zero)
    XCTAssertTrue(b.isEmpty)
    XCTAssertTrue(b.pieSlices.isEmpty)
  }
}
