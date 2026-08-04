import Foundation
import XCTest

@testable import DeepSeekBalance

final class OpenCodeUsageTests: XCTestCase {
  func testParsesNetscapeCookieContentWithoutKeepingOtherCookies() throws {
    let content = """
    # Netscape HTTP Cookie File
    .opencode.ai\tTRUE\t/\tTRUE\t1817197991\tauth\tfake-session-token
    .opencode.ai\tTRUE\t/\tTRUE\t1817197991\tother\tignored
    """

    XCTAssertEqual(
      try OpenCodeCookieParser.parse(content),
      "auth=fake-session-token"
    )
  }

  func testParsesCookieFilePath() throws {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("opencode-cookie-\(UUID().uuidString).txt")
    let content = ".opencode.ai\tTRUE\t/\tTRUE\t0\t__Host-auth\tfake-host-token\n"
    try content.write(to: path, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: path) }

    XCTAssertEqual(
      try OpenCodeCookieParser.parse(path.path),
      "__Host-auth=fake-host-token"
    )
  }

  func testParsesNoSubscriptionPage() throws {
    let page = """
    <script>
    subscription: null,
    subscriptionID: null,
    subscriptionPlan: null,
    lite: null,
    liteSubscriptionID: null
    </script>
    """

    XCTAssertNil(
      try OpenCodeUsageClient.parseGoSubscription(
        text: page,
        now: Date(timeIntervalSince1970: 1_750_000_000)
      )
    )
  }

  func testIgnoresNumericMonthlyMetadataWhenSubscriptionFieldsAreNull() throws {
    let page = """
    subscription: null,
    subscriptionID: null,
    subscriptionPlan: null,
    lite: null,
    liteSubscriptionID: null,
    monthlyUsage: 4,
    timeMonthlyUsageUpdated: 1750000000
    """

    XCTAssertNil(
      try OpenCodeUsageClient.parseGoSubscription(
        text: page,
        now: Date(timeIntervalSince1970: 1_750_000_000)
      )
    )
  }

  func testParsesGoWindowsAndNormalizesFractionalPercent() throws {
    let page = """
    subscription: { id: "sub_1" },
    rollingUsage: { usagePercent: 0.25, resetInSec: 3600 },
    weeklyUsage: { usagePercent: 35, resetInSec: 7200 },
    monthlyUsage: { usagePercent: 42.5, resetInSec: 10800 }
    """

    let subscription = try XCTUnwrap(
      try OpenCodeUsageClient.parseGoSubscription(
        text: page,
        now: Date(timeIntervalSince1970: 1_750_000_000)
      )
    )
    XCTAssertEqual(subscription.rolling?.usedPercent, 25)
    XCTAssertEqual(subscription.weekly?.usedPercent, 35)
    XCTAssertEqual(subscription.monthly?.usedPercent, 43)
  }

  func testParsesCurrentSolidStartGoWindowShape() throws {
    let page = """
    subscription: null,
    subscriptionID: null,
    subscriptionPlan: null,
    SubscriptionID: "sub_active",
    rollingUsage:$R[36]={status:"ok",resetInSec:17808,usagePercent:1},
    weeklyUsage:$R[37]={status:"ok",resetInSec:499713,usagePercent:12},
    monthlyUsage:$R[38]={status:"ok",resetInSec:2676166,usagePercent:34}
    """

    let subscription = try XCTUnwrap(
      try OpenCodeUsageClient.parseGoSubscription(
        text: page,
        now: Date(timeIntervalSince1970: 1_750_000_000)
      )
    )
    XCTAssertEqual(subscription.rolling?.usedPercent, 1)
    XCTAssertEqual(subscription.rolling?.resetInSec, 17808)
    XCTAssertEqual(subscription.weekly?.usedPercent, 12)
    XCTAssertEqual(subscription.weekly?.resetInSec, 499713)
    XCTAssertEqual(subscription.monthly?.usedPercent, 34)
    XCTAssertEqual(subscription.monthly?.resetInSec, 2676166)
  }

  func testKeepsIntegerOnePercentInJSONWindow() throws {
    let page = """
      {
        "subscription": {"id": "sub_1"},
        "rollingUsage": {"usagePercent": 1, "resetInSec": 3600},
        "weeklyUsage": {"usagePercent": 2, "resetInSec": 7200},
        "monthlyUsage": {"usagePercent": 3, "resetInSec": 10800}
      }
    """

    let subscription = try XCTUnwrap(
      try OpenCodeUsageClient.parseGoSubscription(
        text: page,
        now: Date(timeIntervalSince1970: 1_750_000_000)
      )
    )
    XCTAssertEqual(subscription.rolling?.usedPercent, 1)
    XCTAssertEqual(subscription.weekly?.usedPercent, 2)
    XCTAssertEqual(subscription.monthly?.usedPercent, 3)
  }

  func testHistorySampleStoresAllGoWindowsAndZenBalance() throws {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let snapshot = OpenCodeUsageSnapshot(
      workspaceID: "wrk_test123",
      goSubscription: OpenCodeGoSubscription(
        rolling: OpenCodeUsageWindow(kind: .rolling, usedPercent: 12, resetInSec: 100),
        weekly: OpenCodeUsageWindow(kind: .weekly, usedPercent: 34, resetInSec: 200),
        monthly: OpenCodeUsageWindow(kind: .monthly, usedPercent: 56, resetInSec: 300),
        renewsAt: nil
      ),
      zenBalanceUSD: 5.5,
      updatedAt: now
    )
    let historyURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("opencode-history-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: historyURL) }

    let service = OpenCodeHistoryService(
      store: OpenCodeHistoryFileStore(fileURL: historyURL),
      clock: FixedClock(date: now)
    )
    let sample = try XCTUnwrap(
      service.makeSample(from: snapshot, credentialID: "cred", at: now)
    )

    XCTAssertEqual(sample.goRollingUsedPercent, 12)
    XCTAssertEqual(sample.goWeeklyUsedPercent, 34)
    XCTAssertEqual(sample.goMonthlyUsedPercent, 56)
    XCTAssertEqual(sample.zenBalanceUSD, 5.5)
  }

  func testHistorySampleDecodesLegacyMonthlyOnlyRecord() throws {
    let payload = """
    {
      "credentialID": "cred",
      "bucketStart": 1750000000,
      "observedAt": 1750000000,
      "goMonthlyUsedPercent": 56,
      "zenBalanceUSD": 5.5
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let sample = try decoder.decode(OpenCodeUsageSample.self, from: Data(payload.utf8))

    XCTAssertNil(sample.goRollingUsedPercent)
    XCTAssertNil(sample.goWeeklyUsedPercent)
    XCTAssertEqual(sample.goMonthlyUsedPercent, 56)
    XCTAssertEqual(sample.zenBalanceUSD, 5.5)
  }

  func testParsesZenBalanceInBillingUnits() throws {
    XCTAssertEqual(
      try XCTUnwrap(OpenCodeUsageClient.parseZenBalance(text: "balance: 548407681")),
      5.48407681,
      accuracy: 0.00000001
    )
    XCTAssertEqual(
      try XCTUnwrap(OpenCodeUsageClient.parseZenBalance(text: "{\"balance\": 5.5}")),
      5.5,
      accuracy: 0.00000001
    )
  }

  func testClientReturnsZenWhenGoIsNotSubscribed() async throws {
    let session = MockURLProtocol.makeSession()
    MockURLProtocol.requestHandler = { request in
      let url = try XCTUnwrap(request.url)
      if url.path == "/_server" {
        let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
          .first(where: { $0.name == "id" })?.value
        if id == "def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f" {
          return (
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
            Data(#"id: "wrk_test123""#.utf8)
          )
        }
        return (
          HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          Data("balance: 548407681".utf8)
        )
      }
      return (
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data("subscription: null, subscriptionID: null, lite: null, liteSubscriptionID: null".utf8)
      )
    }
    defer { MockURLProtocol.reset() }

    let client = OpenCodeUsageClient(session: session)
    let snapshot = try await client.fetchUsage(
      cookieHeader: "auth=fake-session-token",
      now: Date(timeIntervalSince1970: 1_750_000_000)
    )

    XCTAssertEqual(snapshot.workspaceID, "wrk_test123")
    XCTAssertNil(snapshot.goSubscription)
    XCTAssertEqual(snapshot.zenBalanceUSD ?? 0, 5.48407681, accuracy: 0.00000001)
    XCTAssertEqual(MockURLProtocol.recordedRequestCount, 3)
  }

  private func historySample(at offset: TimeInterval, balance: Double) -> OpenCodeUsageSample {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let date = now.addingTimeInterval(offset)
    return OpenCodeUsageSample(
      credentialID: "cred",
      bucketStart: date,
      observedAt: date,
      goRollingUsedPercent: nil,
      goWeeklyUsedPercent: nil,
      goMonthlyUsedPercent: nil,
      zenBalanceUSD: balance
    )
  }

  func testUnsubscribedZenEstimateFallsBackToTwentyFourHours() {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let samples = [
      historySample(at: -20 * 3600, balance: 6),
      historySample(at: -10 * 3600, balance: 5),
      historySample(at: 0, balance: 5),
    ]

    XCTAssertEqual(
      OpenCodeTrendProcessor.zenExhaustionEstimate(samples: samples, now: now) ?? -1,
      100 * 3600,
      accuracy: 0.001
    )
  }

  func testUnsubscribedZenEstimateFallsBackToAllHistory() {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let samples = [
      historySample(at: -5 * 24 * 3600, balance: 6),
      historySample(at: -4 * 24 * 3600, balance: 5),
      historySample(at: 0, balance: 5),
    ]

    XCTAssertEqual(
      OpenCodeTrendProcessor.zenExhaustionEstimate(samples: samples, now: now) ?? -1,
      25 * 24 * 3600,
      accuracy: 0.001
    )
  }

  func testUnsubscribedZenEstimateIsNilWhenAllHistoryHasNoConsumption() {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let samples = [
      historySample(at: -24 * 3600, balance: 5),
      historySample(at: 0, balance: 5),
    ]

    XCTAssertNil(OpenCodeTrendProcessor.zenExhaustionEstimate(samples: samples, now: now))
  }

  func testSubscribedOpenCodeEstimatesWeeklyGoAndZenSeparately() {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let samples = [
      OpenCodeUsageSample(
        credentialID: "cred",
        bucketStart: now.addingTimeInterval(-10 * 3600),
        observedAt: now.addingTimeInterval(-10 * 3600),
        goRollingUsedPercent: 5,
        goWeeklyUsedPercent: 10,
        goMonthlyUsedPercent: 20,
        zenBalanceUSD: 6
      ),
      OpenCodeUsageSample(
        credentialID: "cred",
        bucketStart: now,
        observedAt: now,
        goRollingUsedPercent: 6,
        goWeeklyUsedPercent: 20,
        goMonthlyUsedPercent: 30,
        zenBalanceUSD: 5
      ),
    ]

    let estimates = OpenCodeTrendProcessor.exhaustionEstimates(
      samples: samples,
      showGoTrend: true,
      now: now
    )
    XCTAssertEqual(estimates.goWeeklySeconds ?? -1, 80 * 3600, accuracy: 0.001)
    XCTAssertEqual(estimates.zenSeconds ?? -1, 50 * 3600, accuracy: 0.001)
  }

  func testUnsubscribedOpenCodeEstimateContainsOnlyZen() {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let samples = [
      OpenCodeUsageSample(
        credentialID: "cred",
        bucketStart: now.addingTimeInterval(-10 * 3600),
        observedAt: now.addingTimeInterval(-10 * 3600),
        goRollingUsedPercent: 5,
        goWeeklyUsedPercent: 10,
        goMonthlyUsedPercent: 20,
        zenBalanceUSD: 6
      ),
      OpenCodeUsageSample(
        credentialID: "cred",
        bucketStart: now,
        observedAt: now,
        goRollingUsedPercent: 6,
        goWeeklyUsedPercent: 20,
        goMonthlyUsedPercent: 30,
        zenBalanceUSD: 5
      ),
    ]

    let estimates = OpenCodeTrendProcessor.exhaustionEstimates(
      samples: samples,
      showGoTrend: false,
      now: now
    )
    XCTAssertNil(estimates.goWeeklySeconds)
    XCTAssertEqual(estimates.zenSeconds ?? -1, 50 * 3600, accuracy: 0.001)
  }

  func testOpenCodeWindowIdealUsageGapUsesEachWindowLength() {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let rolling = OpenCodeUsageWindow(
      kind: .rolling,
      usedPercent: 70,
      resetInSec: 2 * 3600
    )
    let weekly = OpenCodeUsageWindow(
      kind: .weekly,
      usedPercent: 80,
      resetInSec: 3 * 24 * 3600
    )
    let monthly = OpenCodeUsageWindow(
      kind: .monthly,
      usedPercent: 45,
      resetInSec: 15 * 24 * 3600
    )

    XCTAssertEqual(rolling.expectedUsedPercent(now: now) ?? -1, 60, accuracy: 0.001)
    XCTAssertEqual(rolling.usageGapPercent(now: now), 10)
    XCTAssertEqual(weekly.expectedUsedPercent(now: now) ?? -1, 400 / 7, accuracy: 0.001)
    XCTAssertEqual(weekly.usageGapPercent(now: now), 23)
    XCTAssertEqual(monthly.expectedUsedPercent(now: now) ?? -1, 50, accuracy: 0.001)
    XCTAssertEqual(monthly.usageGapPercent(now: now), -5)
  }

  func testOpenCodeMonthlyMenuTextShowsUsedPercentAndIdealGap() {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let subscription = OpenCodeGoSubscription(
      rolling: nil,
      weekly: nil,
      monthly: OpenCodeUsageWindow(
        kind: .monthly,
        usedPercent: 30,
        resetInSec: 15 * 24 * 3600
      ),
      renewsAt: nil
    )

    XCTAssertEqual(
      OpenCodeUsageStore.monthlyMenuText(subscription: subscription, now: now),
      "30% (-20%)"
    )
    XCTAssertEqual(
      OpenCodeUsageStore.monthlyMenuText(subscription: nil, now: now),
      "--"
    )
  }

}
