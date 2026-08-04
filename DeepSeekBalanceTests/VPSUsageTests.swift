import Foundation
import XCTest

@testable import DeepSeekBalance

final class VPSUsageTests: XCTestCase {
  override func setUp() {
    super.setUp()
    MockURLProtocol.reset()
  }

  override func tearDown() {
    MockURLProtocol.reset()
    super.tearDown()
  }

  func testClientFetchesAccountBandwidthAndInstanceData() async throws {
    let session = MockURLProtocol.makeSession()
    MockURLProtocol.requestHandler = { request in
      let url = try XCTUnwrap(request.url)
      let body: String
      switch url.path {
      case "/v2/account":
        body = #"{"account":{"balance":5.48}}"#
      case "/v2/account/bandwidth":
        body = #"{"bandwidth":{"current_month_to_date":{"instance_bandwidth_credits":100,"gb_out":36.6}}}"#
      case "/v2/instances/i-test":
        body = #"{"instance":{"date_created":"2026-07-15T12:00:00Z","label":"demo"}}"#
      default:
        XCTFail("Unexpected Vultr endpoint: \(url.path)")
        body = "{}"
      }
      return (
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data(body.utf8)
      )
    }

    let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-04T12:00:00Z"))
    let snapshot = try await VultrUsageClient(session: session).fetchUsage(
      config: VPSUsageConfig(apiToken: "test-token", instanceID: "i-test"),
      now: now
    )

    XCTAssertEqual(snapshot.instanceID, "i-test")
    XCTAssertEqual(snapshot.instanceLabel, "demo")
    XCTAssertEqual(snapshot.totalBandwidthGB, 100, accuracy: 0.0001)
    XCTAssertEqual(snapshot.usedBandwidthGB, 36.6, accuracy: 0.0001)
    XCTAssertEqual(snapshot.remainingBandwidthGB, 63.4, accuracy: 0.0001)
    XCTAssertEqual(snapshot.remainingCreditUSD, 5.48, accuracy: 0.0001)
    XCTAssertEqual(
      Set(MockURLProtocol.capturedAuthorizationHeaders()),
      ["Bearer test-token"]
    )
    XCTAssertEqual(MockURLProtocol.recordedRequestCount, 3)
  }

  func testParserRejectsIncompleteBandwidthPayload() {
    XCTAssertThrowsError(
      try VultrUsageClient.parseMonthToDateUsage(
        from: ["bandwidth": ["current_month_to_date": ["gb_out": 1]]]
      )
    ) { error in
      XCTAssertEqual(error as? VultrUsageClient.APIError, .decodingFailed)
    }
  }

  func testBillingCycleIsDerivedFromInstanceCreationDate() throws {
    let formatter = ISO8601DateFormatter()
    let anchor = try XCTUnwrap(formatter.date(from: "2026-07-15T12:00:00Z"))
    let now = try XCTUnwrap(formatter.date(from: "2026-08-04T12:00:00Z"))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!

    let cycle = try VultrUsageClient.billingCycleFromInstanceCreated(
      anchor: anchor,
      now: now,
      calendar: calendar
    )
    XCTAssertEqual(cycle.start, anchor)
    XCTAssertEqual(
      cycle.end,
      try XCTUnwrap(formatter.date(from: "2026-08-15T12:00:00Z"))
    )
  }

  func testTrendUsesRemainingValuesAndFormatsDeltas() throws {
    let firstDate = Date(timeIntervalSince1970: 1_800_000_000)
    let secondDate = firstDate.addingTimeInterval(3600)
    let samples = [
      VPSUsageSample(
        credentialID: "cred",
        bucketStart: firstDate,
        observedAt: firstDate,
        remainingBandwidthGB: 63.4,
        remainingCreditUSD: 5.48
      ),
      VPSUsageSample(
        credentialID: "cred",
        bucketStart: firstDate,
        observedAt: firstDate.addingTimeInterval(20),
        remainingBandwidthGB: 63.2,
        remainingCreditUSD: 5.47
      ),
      VPSUsageSample(
        credentialID: "cred",
        bucketStart: secondDate,
        observedAt: secondDate,
        remainingBandwidthGB: 60.0,
        remainingCreditUSD: 5.00
      ),
    ]

    let model = VPSUsageTrendProcessor.chartModel(
      samples: samples,
      now: secondDate.addingTimeInterval(60)
    )
    let summary = try XCTUnwrap(VPSUsageTrendProcessor.summary(samples: samples))

    XCTAssertEqual(model.samples.count, 2)
    XCTAssertEqual(model.samples[0].remainingBandwidthGB, 63.2, accuracy: 0.0001)
    XCTAssertTrue(model.canDraw)
    XCTAssertEqual(summary.traffic, -3.2, accuracy: 0.0001)
    XCTAssertEqual(summary.credit, -0.47, accuracy: 0.0001)
    XCTAssertEqual(VPSUsageTrendProcessor.signedGB(summary.traffic), "-3 GB")
    XCTAssertEqual(VPSUsageTrendProcessor.signedUSD(summary.credit), "-$0.47")
  }

  func testTrafficExhaustionEstimateUsesRemainingBandwidth() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let samples = [
      VPSUsageSample(
        credentialID: "cred",
        bucketStart: now.addingTimeInterval(-3600),
        observedAt: now.addingTimeInterval(-3600),
        remainingBandwidthGB: 100,
        remainingCreditUSD: 5
      ),
      VPSUsageSample(
        credentialID: "cred",
        bucketStart: now,
        observedAt: now,
        remainingBandwidthGB: 80,
        remainingCreditUSD: 5
      ),
    ]

    let seconds = UsageExhaustionEstimator.estimate(
      points: samples.map {
        UsageExhaustionPoint(date: $0.bucketStart, remaining: $0.remainingBandwidthGB)
      },
      now: now
    )

    XCTAssertEqual(try XCTUnwrap(seconds), 4 * 3600, accuracy: 0.0001)
  }

  func testRemainingBandwidthNeverGoesBelowZero() {
    let snapshot = VPSUsageSnapshot(
      instanceID: "i-test",
      instanceLabel: nil,
      cycleStart: .distantPast,
      cycleEnd: .distantFuture,
      totalBandwidthGB: 10,
      usedBandwidthGB: 12,
      remainingCreditUSD: -1,
      refreshedAt: Date()
    )
    XCTAssertEqual(snapshot.remainingBandwidthGB, 0)
    XCTAssertEqual(snapshot.availableCreditUSD, 1)
  }

  func testRemainingCycleDaysRoundsUpAndClampsAtZero() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let twoDaysAndOneSecond = now.addingTimeInterval(2 * 86_400 + 1)

    XCTAssertEqual(
      VPSUsageStore.remainingCycleDays(until: twoDaysAndOneSecond, now: now),
      3
    )
    XCTAssertEqual(
      VPSUsageStore.remainingCycleDays(until: now, now: now),
      0
    )
    XCTAssertEqual(
      VPSUsageStore.remainingCycleDays(until: now.addingTimeInterval(-1), now: now),
      0
    )
  }

  func testCycleRemainingTextUsesBothLocalizations() {
    XCTAssertEqual(
      L10n.string(.vpsCycleRemaining, language: .simplifiedChinese, 3),
      "3天"
    )
    XCTAssertEqual(
      L10n.string(.vpsCycleRemaining, language: .english, 3),
      "3d"
    )
  }
}
