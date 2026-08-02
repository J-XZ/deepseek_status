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

}
