import Foundation
import XCTest

@testable import DeepSeekBalance

/// 拦截状态请求的 URLProtocol（与余额测试的 MockURLProtocol 分离，避免交叉污染）。
final class MockStatusURLProtocol: URLProtocol {
  private static let lock = NSLock()
  static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
  private static var recorded: [URLRequest] = []

  static func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockStatusURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  static func reset() {
    lock.lock()
    handler = nil
    recorded = []
    lock.unlock()
  }

  static var requestCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return recorded.count
  }

  static func capturedAuthorizationHeaders() -> [String?] {
    lock.lock()
    defer { lock.unlock() }
    return recorded.map { $0.value(forHTTPHeaderField: "Authorization") }
  }

  static func capturedAcceptHeaders() -> [String?] {
    lock.lock()
    defer { lock.unlock() }
    return recorded.map { $0.value(forHTTPHeaderField: "Accept") }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.lock.lock()
    Self.recorded.append(request)
    let handler = Self.handler
    Self.lock.unlock()

    guard let handler else {
      client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
      return
    }
    do {
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

final class ServiceStatusClientTests: XCTestCase {
  override func setUp() {
    super.setUp()
    MockStatusURLProtocol.reset()
  }

  override func tearDown() {
    MockStatusURLProtocol.reset()
    super.tearDown()
  }

  private func makeClient() -> DeepSeekStatusClient {
    DeepSeekStatusClient(
      session: MockStatusURLProtocol.makeSession(),
      timeoutInterval: 12
    )
  }

  private func response(statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(
      url: DeepSeekStatusClient.defaultURL,
      statusCode: statusCode,
      httpVersion: nil,
      headerFields: nil
    )!
  }

  func testSendsNoAuthorizationAndAcceptsJSON() async throws {
    MockStatusURLProtocol.handler = { _ in
      (self.response(statusCode: 200), Data("{}".utf8))
    }
    _ = try await makeClient().fetchSummary()
    XCTAssertEqual(MockStatusURLProtocol.capturedAuthorizationHeaders(), [nil])
    XCTAssertEqual(MockStatusURLProtocol.capturedAcceptHeaders(), ["application/json"])
  }

  func testParsesSummaryWithoutAPIKey() async throws {
    MockStatusURLProtocol.handler = { _ in
      (self.response(statusCode: 200), Data(ServiceStatusFixtures.allOperational.utf8))
    }
    let summary = try await makeClient().fetchSummary()
    let mapped = DeepSeekStatusMapper.map(summary)
    XCTAssertEqual(mapped.overall, .none)
    XCTAssertEqual(mapped.apiComponents.count, 1)
    XCTAssertEqual(mapped.webChatComponents.count, 1)
  }

  func testHTTP500MapsToHTTPError() async {
    MockStatusURLProtocol.handler = { _ in
      (self.response(statusCode: 500), Data())
    }
    do {
      _ = try await makeClient().fetchSummary()
      XCTFail("应抛出 http 错误")
    } catch let error as DeepSeekStatusClient.StatusError {
      XCTAssertEqual(error, .http(500))
    } catch {
      XCTFail("意外的错误：\(error)")
    }
  }

  func testTimeoutMapsToTimedOut() async {
    MockStatusURLProtocol.handler = { _ in
      throw URLError(.timedOut)
    }
    do {
      _ = try await makeClient().fetchSummary()
      XCTFail("应抛出 timedOut")
    } catch let error as DeepSeekStatusClient.StatusError {
      XCTAssertEqual(error, .timedOut)
    } catch {
      XCTFail("意外的错误：\(error)")
    }
  }

  func testNoNetworkMapsToNoNetwork() async {
    MockStatusURLProtocol.handler = { _ in
      throw URLError(.notConnectedToInternet)
    }
    do {
      _ = try await makeClient().fetchSummary()
      XCTFail("应抛出 noNetwork")
    } catch let error as DeepSeekStatusClient.StatusError {
      XCTAssertEqual(error, .noNetwork)
    } catch {
      XCTFail("意外的错误：\(error)")
    }
  }

  func testInvalidJSONMapsToDecoding() async {
    MockStatusURLProtocol.handler = { _ in
      (self.response(statusCode: 200), Data("not json".utf8))
    }
    do {
      _ = try await makeClient().fetchSummary()
      XCTFail("应抛出 decoding")
    } catch let error as DeepSeekStatusClient.StatusError {
      XCTAssertEqual(error, .decoding)
    } catch {
      XCTFail("意外的错误：\(error)")
    }
  }

  func testCancellationMapsToCancelled() async {
    MockStatusURLProtocol.handler = { _ in
      throw URLError(.cancelled)
    }
    do {
      _ = try await makeClient().fetchSummary()
      XCTFail("应抛出 cancelled")
    } catch let error as DeepSeekStatusClient.StatusError {
      XCTAssertEqual(error, .cancelled)
    } catch {
      XCTFail("意外的错误：\(error)")
    }
  }
}

enum ServiceStatusFixtures {
  static let allOperational = """
    {
      "page": {"id": "p1", "name": "DeepSeek", "url": "https://status.deepseek.com", "updated_at": "2026-07-31T01:00:00.000Z"},
      "status": {"indicator": "none", "description": "All Systems Operational"},
      "components": [
        {"id": "c1", "name": "API Service", "status": "operational", "group": false},
        {"id": "c2", "name": "Web Chat Service", "status": "operational", "group": false}
      ],
      "incidents": [],
      "scheduled_maintenances": []
    }
    """

  static let degraded = allOperational.replacingOccurrences(
    of: #""status": "operational""#,
    with: #""status": "degraded_performance""#
  )

  static let partialOutage = allOperational.replacingOccurrences(
    of: #""status": "operational""#,
    with: #""status": "partial_outage""#
  )

  static let majorOutage = allOperational.replacingOccurrences(
    of: #""status": "operational""#,
    with: #""status": "major_outage""#
  )

  static let critical = allOperational.replacingOccurrences(
    of: #""indicator": "none""#,
    with: #""indicator": "critical""#
  ).replacingOccurrences(
    of: #""status": "operational""#,
    with: #""status": "major_outage""#
  )

  static let underMaintenance = allOperational.replacingOccurrences(
    of: #""status": "operational""#,
    with: #""status": "under_maintenance""#
  )

  static let incident = """
    {
      "page": {"id": "p1", "name": "DeepSeek", "url": "https://status.deepseek.com", "updated_at": "2026-07-31T01:00:00.000Z"},
      "status": {"indicator": "major", "description": "Partial Service Disruption"},
      "components": [
        {"id": "c1", "name": "API Service", "status": "major_outage", "group": false},
        {"id": "c2", "name": "Web Chat Service", "status": "operational", "group": false},
        {"id": "c3", "name": "New Unknown Component", "status": "weird_status", "group": false},
        {"id": "g1", "name": "Component Group", "status": "operational", "group": true}
      ],
      "incidents": [
        {
          "id": "i1",
          "name": "API errors",
          "status": "investigating",
          "impact": "major",
          "created_at": "2026-07-31T00:00:00.000Z",
          "updated_at": "2026-07-31T00:30:00.000Z",
          "incident_updates": [
            {"status": "investigating", "body": "We are investigating elevated API error rates.", "created_at": "2026-07-31T00:00:00.000Z", "updated_at": "2026-07-31T00:00:00.000Z"}
          ]
        },
        {
          "id": "i2",
          "name": "Old resolved issue",
          "status": "resolved",
          "impact": "minor",
          "created_at": "2026-07-30T00:00:00.000Z",
          "updated_at": "2026-07-30T01:00:00.000Z",
          "incident_updates": []
        }
      ],
      "scheduled_maintenances": [
        {
          "id": "m1",
          "name": "Scheduled database maintenance",
          "status": "scheduled",
          "impact": "maintenance",
          "created_at": "2026-07-30T00:00:00.000Z",
          "updated_at": "2026-07-30T00:00:00.000Z",
          "incident_updates": []
        }
      ]
    }
    """
}

final class ServiceStatusMapperTests: XCTestCase {
  private let fixedDate = Date(timeIntervalSince1970: 1_752_000_000)

  private func map(_ json: String) throws -> DeepSeekServiceStatus {
    let summary = try JSONDecoder().decode(StatusPageSummary.self, from: Data(json.utf8))
    return DeepSeekStatusMapper.map(summary) { _ in self.fixedDate }
  }

  func testAllOperational() throws {
    let status = try map(ServiceStatusFixtures.allOperational)
    XCTAssertEqual(status.overall, .none)
    XCTAssertEqual(status.apiComponents.map(\.name), ["API Service"])
    XCTAssertEqual(status.webChatComponents.map(\.name), ["Web Chat Service"])
    XCTAssertTrue(status.otherComponents.isEmpty)
    XCTAssertTrue(status.incidents.isEmpty)
    XCTAssertEqual(status.updatedAt, fixedDate)
  }

  func testDegradedPerformance() throws {
    let status = try map(ServiceStatusFixtures.degraded)
    XCTAssertEqual(status.apiComponents.first?.status, .degradedPerformance)
    XCTAssertEqual(status.webChatComponents.first?.status, .degradedPerformance)
  }

  func testPartialOutage() throws {
    let status = try map(ServiceStatusFixtures.partialOutage)
    XCTAssertEqual(status.apiComponents.first?.status, .partialOutage)
  }

  func testMajorOutage() throws {
    let status = try map(ServiceStatusFixtures.majorOutage)
    XCTAssertEqual(status.apiComponents.first?.status, .majorOutage)
  }

  func testCritical() throws {
    let status = try map(ServiceStatusFixtures.critical)
    XCTAssertEqual(status.overall, .critical)
  }

  func testUnderMaintenance() throws {
    let status = try map(ServiceStatusFixtures.underMaintenance)
    XCTAssertEqual(status.apiComponents.first?.status, .underMaintenance)
  }

  func testUnknownComponentAndGroupHandling() throws {
    let status = try map(ServiceStatusFixtures.incident)
    XCTAssertEqual(status.otherComponents.map(\.name), ["New Unknown Component"])
    XCTAssertEqual(status.otherComponents.first?.status, .unknown)
    XCTAssertFalse(status.otherComponents.contains { $0.name == "Component Group" })
  }

  func testUnknownIndicatorFallsBack() throws {
    let json = ServiceStatusFixtures.allOperational.replacingOccurrences(
      of: #""indicator": "none""#,
      with: #""indicator": "something_new""#
    )
    let status = try map(json)
    XCTAssertEqual(status.overall, .unknown)
  }

  func testIncidentParsing() throws {
    let status = try map(ServiceStatusFixtures.incident)
    XCTAssertEqual(status.incidents.count, 1)
    let incident = status.incidents[0]
    XCTAssertEqual(incident.title, "API errors")
    XCTAssertEqual(incident.status, .investigating)
    XCTAssertEqual(incident.impact, .major)
    XCTAssertEqual(incident.updatedAt, fixedDate)
    XCTAssertEqual(incident.latestUpdateBody, "We are investigating elevated API error rates.")
    XCTAssertEqual(status.scheduledMaintenances.count, 1)
    XCTAssertEqual(status.scheduledMaintenances[0].title, "Scheduled database maintenance")
  }

  func testMissingOptionalFields() throws {
    let status = try map("{}")
    XCTAssertEqual(status.overall, .unknown)
    XCTAssertTrue(status.apiComponents.isEmpty)
    XCTAssertTrue(status.webChatComponents.isEmpty)
    XCTAssertTrue(status.otherComponents.isEmpty)
    XCTAssertTrue(status.incidents.isEmpty)
    XCTAssertTrue(status.scheduledMaintenances.isEmpty)
    XCTAssertNil(status.updatedAt)
  }

  func testAPIComponentRecognition() {
    XCTAssertTrue(DeepSeekStatusMapper.isAPIComponent("API Service"))
    XCTAssertTrue(DeepSeekStatusMapper.isAPIComponent("API 服务"))
    XCTAssertTrue(DeepSeekStatusMapper.isAPIComponent("DeepSeek API"))
    XCTAssertFalse(DeepSeekStatusMapper.isAPIComponent("Capabilities"))
    XCTAssertTrue(DeepSeekStatusMapper.isWebChatComponent("Web Chat Service"))
    XCTAssertTrue(DeepSeekStatusMapper.isWebChatComponent("网页对话服务"))
    XCTAssertFalse(DeepSeekStatusMapper.isWebChatComponent("API Service"))
  }
}

/// 脚本化状态客户端，用于 Store 语义测试。
actor ScriptedStatusClient: DeepSeekStatusFetching {
  private var results: [Result<StatusPageSummary, Error>]
  private(set) var fetchCount = 0

  init(results: [Result<StatusPageSummary, Error>]) {
    self.results = results
  }

  func fetchSummary() async throws -> StatusPageSummary {
    fetchCount += 1
    guard !results.isEmpty else {
      return try JSONDecoder().decode(
        StatusPageSummary.self,
        from: Data(ServiceStatusFixtures.allOperational.utf8)
      )
    }
    return try results.removeFirst().get()
  }
}

@MainActor
final class DeepSeekStatusStoreTests: XCTestCase {
  private var clock = MutableClock(date: Date(timeIntervalSince1970: 1_752_000_000))

  override func setUp() {
    super.setUp()
    clock = MutableClock(date: Date(timeIntervalSince1970: 1_752_000_000))
  }

  private func summary() throws -> StatusPageSummary {
    try JSONDecoder().decode(
      StatusPageSummary.self,
      from: Data(ServiceStatusFixtures.allOperational.utf8)
    )
  }

  func testFirstFailureShowsUnknownNotOutage() async throws {
    let client = ScriptedStatusClient(results: [.failure(DeepSeekStatusClient.StatusError.noNetwork)])
    let store = DeepSeekStatusStore(client: client, clock: clock, startupRefresh: false)
    await store.refresh()
    XCTAssertNil(store.status)
    XCTAssertEqual(store.loadState, .unavailable)
    XCTAssertEqual(store.error, .serviceStatusUnavailable)
    XCTAssertFalse(store.isStale)
  }

  func testFailureKeepsOldValueAndMarksStale() async throws {
    let client = ScriptedStatusClient(
      results: [
        .success(try summary()),
        .failure(DeepSeekStatusClient.StatusError.timedOut),
      ]
    )
    let store = DeepSeekStatusStore(client: client, clock: clock, startupRefresh: false)
    await store.refresh()
    XCTAssertEqual(store.loadState, .loaded)
    XCTAssertNil(store.error)

    clock.advance(by: 600)
    await store.refresh()
    XCTAssertNotNil(store.status)
    XCTAssertTrue(store.isStale)
    XCTAssertEqual(store.lastSuccessfulUpdate, clock.now().addingTimeInterval(-600))
    XCTAssertEqual(store.error, .serviceStatusUnavailable)
  }

  func testConcurrentRefreshSendsSingleRequest() async throws {
    let client = ScriptedStatusClient(results: [.success(try summary())])
    let store = DeepSeekStatusStore(client: client, clock: clock, startupRefresh: false)
    async let first: Void = store.refresh()
    async let second: Void = store.refresh()
    _ = await (first, second)
    let count = await client.fetchCount
    XCTAssertEqual(count, 1)
  }

  func testCancellationDoesNotChangeState() async throws {
    let client = ScriptedStatusClient(results: [.failure(DeepSeekStatusClient.StatusError.cancelled)])
    let store = DeepSeekStatusStore(client: client, clock: clock, startupRefresh: false)
    await store.refresh()
    XCTAssertEqual(store.loadState, .idle)
    XCTAssertNil(store.error)
  }

  func testRefreshIfNeededSkipsWhenFresh() async throws {
    let client = ScriptedStatusClient(results: [.success(try summary())])
    let store = DeepSeekStatusStore(client: client, clock: clock, startupRefresh: false)
    await store.refresh()
    await store.refreshIfNeeded(maximumAge: 60)
    let count = await client.fetchCount
    XCTAssertEqual(count, 1)
  }

  func testRefreshIfNeededFetchesWhenStale() async throws {
    let client = ScriptedStatusClient(results: [.success(try summary())])
    let store = DeepSeekStatusStore(client: client, clock: clock, startupRefresh: false)
    await store.refresh()
    clock.advance(by: 120)
    await store.refreshIfNeeded(maximumAge: 60)
    let count = await client.fetchCount
    XCTAssertEqual(count, 2)
  }
}
