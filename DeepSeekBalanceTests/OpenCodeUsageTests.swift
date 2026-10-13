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

  func testParsesNetscapeCookieKeepsConsoleSession() throws {
    let content = """
    # Netscape HTTP Cookie File
    opencode.ai\tFALSE\t/\tTRUE\t1793979736\t__Host-console_session\tst_session
    opencode.ai\tFALSE\t/\tFALSE\t1817197991\tauth\tfake-session-token
    opencode.ai\tFALSE\t/\tFALSE\t1817197991\tother\tignored
    """

    XCTAssertEqual(
      try OpenCodeCookieParser.parse(content),
      "__Host-console_session=st_session; auth=fake-session-token"
    )
  }

  func testParsesOfficialGoUsage() throws {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let reset = try XCTUnwrap(formatter.date(from: "2025-06-15T12:00:00.000Z"))
    let now = reset.addingTimeInterval(-3200)
    let payload = """
    {"usage":{"rolling":{"status":"ok","percent":4,"resetsAt":"2025-06-15T12:00:00.000Z"},
    "weekly":{"status":"ok","percent":9.4,"resetsAt":"2025-06-16T00:00:00.000Z"},
    "monthly":{"status":"ok","percent":0.6,"resetsAt":"2025-07-15T12:00:00.000Z"}}}
    """
    let subscription = try XCTUnwrap(
      OpenCodeUsageClient.parseGoUsage(data: Data(payload.utf8), now: now)
    )
    XCTAssertEqual(subscription.rolling?.usedPercent, 4)
    XCTAssertEqual(subscription.weekly?.usedPercent, 9)
    XCTAssertEqual(subscription.monthly?.usedPercent, 1)
    XCTAssertEqual(subscription.rolling?.resetInSec, 3200)
  }

  func testParsesZenBalanceFromMicroCents() throws {
    let payload = #"{"balanceMicroCents":"161741486","availableMicroCents":"161741486"}"#
    XCTAssertEqual(
      try XCTUnwrap(OpenCodeUsageClient.parseZenBalanceUSD(data: Data(payload.utf8))),
      1.61741486,
      accuracy: 0.00000001
    )
  }

  func testHistorySampleStoresAllGoWindowsAndZenBalance() throws {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let snapshot = OpenCodeUsageSnapshot(
      workspaceID: "wrk_test123",
      accountEmail: nil,
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

  func testClientUsesOfficialGoAndConsoleEndpoints() async throws {
    let session = MockURLProtocol.makeSession()
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    MockURLProtocol.requestHandler = { request in
      let url = try XCTUnwrap(request.url)
      let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
      switch url.path {
      case "/zen/go/v1/usage":
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let body = """
        {"usage":{"rolling":{"status":"ok","percent":4,"resetsAt":"2025-06-15T12:00:00.000Z"},
        "weekly":{"status":"ok","percent":9,"resetsAt":"2025-06-16T00:00:00.000Z"},
        "monthly":{"status":"ok","percent":12,"resetsAt":"2025-07-15T12:00:00.000Z"}}}
        """
        return (response, Data(body.utf8))
      case "/console/api/orgs":
        return (response, Data(#"[{"id":"wrk_test123","name":"test"}]"#.utf8))
      case "/console/api/user":
        return (response, Data(#"{"id":"acc_1","email":"user@example.com"}"#.utf8))
      case "/console/api/billing/status":
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-org-id"), "wrk_test123")
        return (response, Data(#"{"balanceMicroCents":"548407681"}"#.utf8))
      default:
        return (
          HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!,
          Data()
        )
      }
    }
    defer { MockURLProtocol.reset() }

    let client = OpenCodeUsageClient(session: session)
    let snapshot = try await client.fetchUsage(
      cookieHeader: "__Host-console_session=st_session",
      apiKey: "test-key",
      now: now
    )

    XCTAssertEqual(snapshot.workspaceID, "wrk_test123")
    XCTAssertEqual(snapshot.accountEmail, "user@example.com")
    XCTAssertEqual(snapshot.goSubscription?.monthly?.usedPercent, 12)
    XCTAssertEqual(snapshot.zenBalanceUSD ?? 0, 5.48407681, accuracy: 0.00000001)
  }

  func testClientKeepsZenWhenGoSubscriptionIsMissing() async throws {
    let session = MockURLProtocol.makeSession()
    MockURLProtocol.requestHandler = { request in
      let url = try XCTUnwrap(request.url)
      if url.path == "/zen/go/v1/usage" {
        return (
          HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!,
          Data(#"{"type":"error","error":{"type":"EntitlementError"}}"#.utf8)
        )
      }
      if url.path == "/console/api/orgs" {
        return (
          HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          Data(#"[{"id":"wrk_test123"}]"#.utf8)
        )
      }
      if url.path == "/console/api/billing/status" {
        return (
          HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          Data(#"{"balanceMicroCents":100000000}"#.utf8)
        )
      }
      return (
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data(#"{"email":"user@example.com"}"#.utf8)
      )
    }
    defer { MockURLProtocol.reset() }

    let client = OpenCodeUsageClient(session: session)
    let snapshot = try await client.fetchUsage(
      cookieHeader: "__Host-console_session=st_session",
      apiKey: "test-key",
      now: Date(timeIntervalSince1970: 1_750_000_000)
    )
    XCTAssertNil(snapshot.goSubscription)
    XCTAssertEqual(snapshot.zenBalanceUSD ?? 0, 1, accuracy: 0.00000001)
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

  func testOpenCodeTrendUsesRemainingPercentForGoChartAndChange() throws {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let samples = [
      OpenCodeUsageSample(
        credentialID: "cred",
        bucketStart: now.addingTimeInterval(-10 * 3600),
        observedAt: now.addingTimeInterval(-10 * 3600),
        goRollingUsedPercent: 5,
        goWeeklyUsedPercent: 10,
        goMonthlyUsedPercent: 20,
        zenBalanceUSD: nil
      ),
      OpenCodeUsageSample(
        credentialID: "cred",
        bucketStart: now,
        observedAt: now,
        goRollingUsedPercent: 6,
        goWeeklyUsedPercent: 20,
        goMonthlyUsedPercent: 30,
        zenBalanceUSD: nil
      ),
    ]

    let model = OpenCodeTrendProcessor.chartModel(
      samples: samples,
      showGoTrend: true,
      now: now
    )
    let weekly = try XCTUnwrap(model.goSeries.first { $0.kind == .weekly })
    let monthly = try XCTUnwrap(model.goSeries.first { $0.kind == .monthly })
    XCTAssertEqual(weekly.points.map(\.value), [0.9, 0.8])
    XCTAssertEqual(monthly.points.map(\.value), [0.8, 0.7])
    XCTAssertEqual(
      OpenCodeTrendProcessor.monthlyRemainingChangePercent(samples: samples),
      -10
    )
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

  func testOpenCodeMonthlyIdealUsageUsesLongerServerResetPeriod() {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let monthly = OpenCodeUsageWindow(
      kind: .monthly,
      usedPercent: 0,
      resetInSec: 30 * 24 * 3600 + 75_013
    )

    XCTAssertEqual(monthly.expectedUsedPercent(now: now) ?? -1, 0, accuracy: 0.001)
    XCTAssertEqual(monthly.usageGapPercent(now: now), 0)
  }

  func testOpenCodeMonthlyMenuTextShowsRemainingPercentAndIdealGap() {
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
      "70% (-20%)"
    )
    XCTAssertEqual(
      OpenCodeUsageStore.monthlyMenuText(subscription: nil, now: now),
      "--"
    )
  }

  func testOpenCodeMonthlyMenuTextShowsZeroGapForLongerServerResetPeriod() {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let subscription = OpenCodeGoSubscription(
      rolling: nil,
      weekly: nil,
      monthly: OpenCodeUsageWindow(
        kind: .monthly,
        usedPercent: 0,
        resetInSec: 30 * 24 * 3600 + 75_013
      ),
      renewsAt: nil
    )

    XCTAssertEqual(
      OpenCodeUsageStore.monthlyMenuText(subscription: subscription, now: now),
      "100% (+0%)"
    )
  }

  func testOpenCodeMonthlyMenuTextUsesRenewalDateWhenWindowResetIsMissing() {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let subscription = OpenCodeGoSubscription(
      rolling: nil,
      weekly: nil,
      monthly: OpenCodeUsageWindow(
        kind: .monthly,
        usedPercent: 30,
        resetInSec: nil
      ),
      renewsAt: now.addingTimeInterval(15 * 24 * 3600)
    )

    XCTAssertEqual(
      OpenCodeUsageStore.monthlyMenuText(subscription: subscription, now: now),
      "70% (-20%)"
    )
  }

  func testOpenCodeMonthlyMenuTextKeepsComparisonParenthesesWhenIdealIsUnavailable() {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let subscription = OpenCodeGoSubscription(
      rolling: nil,
      weekly: nil,
      monthly: OpenCodeUsageWindow(
        kind: .monthly,
        usedPercent: 30,
        resetInSec: nil
      ),
      renewsAt: nil
    )

    XCTAssertEqual(
      OpenCodeUsageStore.monthlyMenuText(subscription: subscription, now: now),
      "70% (--)"
    )
  }

}
