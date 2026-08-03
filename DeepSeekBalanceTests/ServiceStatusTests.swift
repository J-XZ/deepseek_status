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
    XCTAssertEqual(mapped.apiComponents.count, 2)
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
  static let pageJSON = """
    "page": {
      "page_id": 6410630422455,
      "name": "DeepSeek",
      "url_name": "deepseek",
      "custom_domain": "status.deepseek.com",
      "components": [
        {"component_id": "c1", "name": "DeepSeek V4 Pro API服务(API Service)", "available_since_seconds": 1706745600, "order_id": 3},
        {"component_id": "c2", "name": "DeepSeek V4 Flash API服务(API Service)", "available_since_seconds": 1706745600, "order_id": 4},
        {"component_id": "c3", "name": "快速模式(Instant Mode)", "section_id": "s1", "available_since_seconds": 1706745600, "order_id": 1},
        {"component_id": "c4", "name": "New Unknown Component", "available_since_seconds": 1706745600, "order_id": 9}
      ],
      "sections": [
        {"section_id": "s1", "name": "对话服务(Chat Service)", "order_id": 5}
      ]
    }
    """

  static let allOperational = """
    {
      "request_id": "r1",
      "data": { \(pageJSON), "active_changes": [] }
    }
    """

  static func activeChange(
    type: String = "incident",
    status: String = "monitoring",
    affectedStatus: String = "degraded",
    title: String = "API errors",
    changeID: Int = 1
  ) -> String {
    """
    {
      "change_id": \(changeID),
      "type": "\(type)",
      "title": "\(title)",
      "status": "\(status)",
      "start_at_seconds": 1785490000,
      "affected_components": [
        {"component_id": "c1", "name": "DeepSeek V4 Pro API服务(API Service)", "status": "\(affectedStatus)"}
      ],
      "updates": [
        {"at_seconds": 1785490060, "status": "\(status)", "description": "We are investigating."}
      ]
    }
    """
  }

  static func withActiveChange(
    type: String = "incident",
    status: String = "monitoring",
    affectedStatus: String = "degraded",
    changeID: Int = 1
  ) -> String {
    """
    {
      "request_id": "r1",
      "data": { \(pageJSON), "active_changes": [\(activeChange(type: type, status: status, affectedStatus: affectedStatus, changeID: changeID))] }
    }
    """
  }
}

final class ServiceStatusMapperTests: XCTestCase {
  private func map(_ json: String) throws -> DeepSeekServiceStatus {
    let response = try JSONDecoder().decode(FlashcatStatusResponse.self, from: Data(json.utf8))
    return DeepSeekStatusMapper.map(response)
  }

  func testAllOperational() throws {
    let status = try map(ServiceStatusFixtures.allOperational)
    XCTAssertEqual(status.overall, .none)
    XCTAssertEqual(status.apiComponents.map(\.name), [
      "DeepSeek V4 Pro API服务(API Service)",
      "DeepSeek V4 Flash API服务(API Service)",
    ])
    XCTAssertEqual(status.webChatComponents.map(\.name), ["快速模式(Instant Mode)"])
    XCTAssertEqual(status.otherComponents.map(\.name), ["New Unknown Component"])
    XCTAssertTrue(status.incidents.isEmpty)
    XCTAssertTrue(status.scheduledMaintenances.isEmpty)
  }

  func testDegradedPerformance() throws {
    let status = try map(ServiceStatusFixtures.withActiveChange(affectedStatus: "degraded"))
    XCTAssertEqual(status.overall, .minor)
    XCTAssertEqual(status.apiComponents.first?.status, .degradedPerformance)
    XCTAssertEqual(status.incidents.count, 1)
    XCTAssertEqual(status.incidents[0].status, .monitoring)
    XCTAssertEqual(status.incidents[0].latestUpdateBody, "We are investigating.")
  }

  func testPartialOutage() throws {
    let status = try map(ServiceStatusFixtures.withActiveChange(affectedStatus: "partial_outage"))
    XCTAssertEqual(status.overall, .minor)
    XCTAssertEqual(status.apiComponents.first?.status, .partialOutage)
  }

  func testMajorOutage() throws {
    let status = try map(ServiceStatusFixtures.withActiveChange(affectedStatus: "major_outage"))
    XCTAssertEqual(status.overall, .major)
    XCTAssertEqual(status.apiComponents.first?.status, .majorOutage)
  }

  func testCritical() throws {
    let status = try map(ServiceStatusFixtures.withActiveChange(affectedStatus: "critical"))
    XCTAssertEqual(status.overall, .critical)
    XCTAssertEqual(status.apiComponents.first?.status, .majorOutage)
    XCTAssertEqual(status.incidents.first?.impact, .critical)
  }

  func testUnderMaintenance() throws {
    let status = try map(
      ServiceStatusFixtures.withActiveChange(
        type: "maintenance",
        status: "scheduled",
        affectedStatus: "under_maintenance"
      )
    )
    XCTAssertEqual(status.overall, .maintenance)
    XCTAssertEqual(status.apiComponents.first?.status, .underMaintenance)
    XCTAssertEqual(status.scheduledMaintenances.count, 1)
    XCTAssertTrue(status.incidents.isEmpty)
  }

  func testCriticalOutageOutranksMaintenance() throws {
    let json = """
    {
      "data": {
        "page": {
          "components": [
            {"component_id": "api", "name": "API Service"},
            {"component_id": "web", "name": "Web Chat Service"}
          ],
          "sections": []
        },
        "active_changes": [
          {
            "change_id": 1,
            "type": "maintenance",
            "status": "scheduled",
            "title": "Planned",
            "affected_components": [
              {"component_id": "web", "status": "under_maintenance"}
            ]
          },
          {
            "change_id": 2,
            "type": "incident",
            "status": "investigating",
            "title": "Outage",
            "affected_components": [
              {"component_id": "api", "status": "critical"}
            ]
          }
        ]
      }
    }
    """
    let status = try map(json)
    XCTAssertEqual(status.overall, .critical)
    XCTAssertEqual(status.incidents.count, 1)
    XCTAssertEqual(status.incidents.first?.impact, .critical)
    XCTAssertEqual(status.scheduledMaintenances.count, 1)
  }

  func testIncidentImpactIsPerChange() throws {
    let json = """
    {
      "data": {
        "page": {
          "components": [
            {"component_id": "api", "name": "API Service"},
            {"component_id": "web", "name": "Web Chat Service"}
          ],
          "sections": []
        },
        "active_changes": [
          {
            "change_id": 1,
            "type": "incident",
            "status": "investigating",
            "title": "Minor blip",
            "affected_components": [
              {"component_id": "web", "status": "degraded"}
            ]
          },
          {
            "change_id": 2,
            "type": "incident",
            "status": "investigating",
            "title": "Major outage",
            "affected_components": [
              {"component_id": "api", "status": "critical"}
            ]
          }
        ]
      }
    }
    """
    let status = try map(json)
    XCTAssertEqual(status.overall, .critical)
    let byTitle = Dictionary(uniqueKeysWithValues: status.incidents.map { ($0.title, $0.impact) })
    XCTAssertEqual(byTitle["Minor blip"], .minor)
    XCTAssertEqual(byTitle["Major outage"], .critical)
  }

  func testResolvedChangeIsFilteredOut() throws {
    let json = ServiceStatusFixtures.withActiveChange(
      status: "resolved",
      affectedStatus: "operational",
      changeID: 9
    )
    let status = try map(json)
    XCTAssertEqual(status.overall, .none)
    XCTAssertTrue(status.incidents.isEmpty)
    XCTAssertEqual(status.apiComponents.first?.status, .operational)
  }

  func testUnknownComponentStatusAndOverall() throws {
    let json = ServiceStatusFixtures.withActiveChange(affectedStatus: "weird_status")
    let status = try map(json)
    XCTAssertEqual(status.apiComponents.first?.status, .unknown)
    XCTAssertEqual(status.overall, .unknown)
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
    XCTAssertTrue(DeepSeekStatusMapper.isAPIComponent("DeepSeek V4 Pro API服务(API Service)"))
    XCTAssertFalse(DeepSeekStatusMapper.isAPIComponent("Capabilities"))
    XCTAssertTrue(DeepSeekStatusMapper.isWebChatComponent("Web Chat Service"))
    XCTAssertTrue(DeepSeekStatusMapper.isWebChatComponent("网页对话服务"))
    XCTAssertFalse(DeepSeekStatusMapper.isWebChatComponent("API Service"))
  }

  func testSectionBasedWebChatClassification() {
    let components = [
      FlashcatComponent(
        componentID: "c3",
        name: "快速模式(Instant Mode)",
        description: nil,
        sectionID: "s1",
        availableSinceSeconds: 1_706_745_600,
        orderID: 1
      )
    ]
    let sections = [
      FlashcatSection(
        sectionID: "s1",
        name: "对话服务(Chat Service)",
        description: nil,
        orderID: 5
      )
    ]
    XCTAssertTrue(
      DeepSeekStatusMapper.isWebChatComponent(
        "快速模式(Instant Mode)",
        sections: Dictionary(uniqueKeysWithValues: sections.compactMap { ($0.sectionID!, $0.name!) }),
        components: components
      )
    )
  }
}

/// 脚本化状态客户端，用于 Store 语义测试。
actor ScriptedStatusClient: DeepSeekStatusFetching {
  private var results: [Result<FlashcatStatusResponse, Error>]
  private(set) var fetchCount = 0

  init(results: [Result<FlashcatStatusResponse, Error>]) {
    self.results = results
  }

  func fetchSummary() async throws -> FlashcatStatusResponse {
    fetchCount += 1
    guard !results.isEmpty else {
      return try JSONDecoder().decode(
        FlashcatStatusResponse.self,
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

  private func summary() throws -> FlashcatStatusResponse {
    try JSONDecoder().decode(
      FlashcatStatusResponse.self,
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

  func testAutoRefreshRunsAtConfiguredInterval() async throws {
    let client = ScriptedStatusClient(
      results: [.success(try summary()), .success(try summary())]
    )
    let store = DeepSeekStatusStore(
      client: client,
      clock: clock,
      refreshInterval: 0.1,
      startupRefresh: false
    )
    await store.refresh()
    clock.advance(by: 0.2)

    let deadline = Date().addingTimeInterval(2)
    var didRefresh = false
    while Date() < deadline {
      if await client.fetchCount >= 2 {
        didRefresh = true
        break
      }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertTrue(didRefresh, "自动刷新未在配置间隔内触发")
    XCTAssertEqual(store.loadState, .loaded)
  }
}

// MARK: - Atlassian Statuspage（Codex / Cursor 服务状态）

final class StatusPageClientTests: XCTestCase {
  override func setUp() {
    super.setUp()
    MockStatusURLProtocol.reset()
  }

  override func tearDown() {
    MockStatusURLProtocol.reset()
    super.tearDown()
  }

  private func makeClient() -> StatusPageClient {
    StatusPageClient(
      baseURL: URL(string: "https://status.cursor.com")!,
      session: MockStatusURLProtocol.makeSession(),
      timeoutInterval: 12
    )
  }

  private func response(statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(
      url: URL(string: "https://status.cursor.com/api/v2/status.json")!,
      statusCode: statusCode,
      httpVersion: nil,
      headerFields: nil
    )!
  }

  func testFetchesThreeEndpointsWithoutAuthorization() async throws {
    MockStatusURLProtocol.handler = { request in
      let url = request.url!.absoluteString
      let data: String
      if url.hasSuffix("api/v2/status.json") {
        data = "{\"page\":{\"name\":\"Cursor\"},\"status\":{\"indicator\":\"none\",\"description\":\"All Systems Operational\"}}"
      } else if url.hasSuffix("api/v2/components.json") {
        data = "{\"components\":[{\"id\":\"c1\",\"name\":\"API\",\"status\":\"operational\"}]}"
      } else {
        data = "{\"incidents\":[]}"
      }
      return (
        HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!,
        Data(data.utf8)
      )
    }
    let summary = try await makeClient().fetchSummary()
    XCTAssertEqual(summary.status.status?.indicator, "none")
    XCTAssertEqual(summary.components.components?.count, 1)
    XCTAssertEqual(summary.incidents.incidents?.count, 0)
    XCTAssertEqual(MockStatusURLProtocol.capturedAuthorizationHeaders().count, 3)
    XCTAssertTrue(MockStatusURLProtocol.capturedAuthorizationHeaders().allSatisfy { $0 == nil })
  }

  func testIncidentsEndpointFailureDoesNotFailWholeSummary() async throws {
    MockStatusURLProtocol.handler = { request in
      let url = request.url!.absoluteString
      let data: String
      if url.hasSuffix("api/v2/status.json") {
        data = "{\"page\":{\"name\":\"Cursor\"},\"status\":{\"indicator\":\"none\",\"description\":\"All Systems Operational\"}}"
      } else if url.hasSuffix("api/v2/components.json") {
        data = "{\"components\":[{\"id\":\"c1\",\"name\":\"API\",\"status\":\"operational\"}]}"
      } else {
        // 事故端点在部分托管上不可用（返回 HTML/500），不影响整体状态。
        data = "<html>error</html>"
      }
      let statusCode = url.hasSuffix("api/v2/incidents/unresolved.json") ? 500 : 200
      return (
        HTTPURLResponse(
          url: request.url!,
          statusCode: statusCode,
          httpVersion: nil,
          headerFields: nil
        )!,
        Data(data.utf8)
      )
    }
    let summary = try await makeClient().fetchSummary()
    XCTAssertEqual(summary.status.status?.indicator, "none")
    XCTAssertEqual(summary.components.components?.count, 1)
    XCTAssertEqual(summary.incidents.incidents?.count, 0)
  }

  func testHTTPErrorPropagates() async {
    MockStatusURLProtocol.handler = { _ in
      (self.response(statusCode: 500), Data())
    }
    do {
      _ = try await makeClient().fetchSummary()
      XCTFail("应抛出 http 错误")
    } catch let error as StatusPageClient.StatusError {
      XCTAssertEqual(error, .http(500))
    } catch {
      XCTFail("意外的错误：\(error)")
    }
  }

  func testCancellationPropagates() async {
    MockStatusURLProtocol.handler = { _ in
      throw URLError(.cancelled)
    }
    do {
      _ = try await makeClient().fetchSummary()
      XCTFail("应抛出 cancelled")
    } catch let error as StatusPageClient.StatusError {
      XCTAssertEqual(error, .cancelled)
    } catch {
      XCTFail("意外的错误：\(error)")
    }
  }
}

final class StatusPageMapperTests: XCTestCase {
  private func makeSummary(
    indicator: String? = "none",
    description: String = "All Systems Operational",
    components: [[String: String]] = [["id": "c1", "name": "API", "status": "operational"]],
    incidents: [[String: Any?]] = []
  ) -> StatusPageSummaryResponse {
    let status = StatusPageStatusResponse(
      page: StatusPageStatusResponse.Page(name: "Cursor", url: nil),
      status: StatusPageStatusResponse.Status(
        indicator: indicator,
        description: description
      )
    )
    let comps = StatusPageComponentsResponse(
      components: components.map { comp in
        StatusPageComponent(
          id: comp["id"],
          name: comp["name"],
          status: comp["status"],
          description: nil,
          group: nil
        )
      }
    )
    let incs = StatusPageIncidentsResponse(
      incidents: incidents.map { dict in
        StatusPageIncident(
          id: dict["id"] as? String,
          name: dict["name"] as? String,
          status: dict["status"] as? String,
          impact: dict["impact"] as? String,
          updatedAt: dict["updated_at"] as? String,
          incidentUpdates: dict["updates"] as? [StatusPageIncidentUpdate]
        )
      }
    )
    return StatusPageSummaryResponse(status: status, components: comps, incidents: incs)
  }

  func testMapsOperational() {
    let mapped = StatusPageMapper.map(makeSummary())
    XCTAssertEqual(mapped.overall, .none)
    XCTAssertEqual(mapped.overallDescription, "All Systems Operational")
    XCTAssertEqual(mapped.apiComponents.count, 1)
    XCTAssertTrue(mapped.incidents.isEmpty)
  }

  func testMapsMajorIndicator() {
    let mapped = StatusPageMapper.map(
      makeSummary(
        indicator: "major",
        description: "Partial service disruption",
        components: [["id": "c1", "name": "API", "status": "major_outage"]]
      )
    )
    XCTAssertEqual(mapped.overall, .major)
    XCTAssertEqual(mapped.apiComponents.first?.status, .majorOutage)
  }

  func testMapsIncidentFilteredToUnresolved() {
    let updates = StatusPageIncidentUpdate(body: "Investigating", status: "investigating", updatedAt: "2026-08-01T10:00:00.000Z")
    let mapped = StatusPageMapper.map(
      makeSummary(
        incidents: [
          [
            "id": "i1",
            "name": "Elevated API errors",
            "status": "investigating",
            "impact": "minor",
            "updated_at": "2026-08-01T10:00:00.000Z",
            "updates": [updates],
          ],
        ]
      )
    )
    XCTAssertEqual(mapped.incidents.count, 1)
    XCTAssertEqual(mapped.incidents.first?.title, "Elevated API errors")
    XCTAssertEqual(mapped.incidents.first?.status, .investigating)
    XCTAssertEqual(mapped.incidents.first?.impact, .minor)
    XCTAssertEqual(mapped.incidents.first?.updatedAt, StatusPageMapper.parseDate("2026-08-01T10:00:00.000Z"))
    XCTAssertEqual(mapped.incidents.first?.latestUpdateBody, "Investigating")
  }

  func testMapsResolvedIncidentAsNone() {
    let mapped = StatusPageMapper.map(
      makeSummary(
        incidents: [
          [
            "id": "i1",
            "name": "Resolved",
            "status": "resolved",
            "impact": "minor",
            "updated_at": "2026-08-01T10:00:00.000Z",
            "updates": [StatusPageIncidentUpdate(body: "All good", status: "resolved", updatedAt: "2026-08-01T11:00:00.000Z")],
          ],
        ]
      )
    )
    XCTAssertTrue(mapped.incidents.isEmpty)
    XCTAssertEqual(mapped.overall, .none)
  }

  func testMapsUnknownIndicatorFallsBackToComponents() {
    let mapped = StatusPageMapper.map(
      makeSummary(
        indicator: "weird",
        components: [["id": "c1", "name": "API", "status": "partial_outage"]]
      )
    )
    XCTAssertEqual(mapped.overall, .minor)
  }

  func testDegradedComponentEscalatesGreenOverall() {
    let mapped = StatusPageMapper.map(
      makeSummary(
        indicator: "none",
        components: [["id": "c1", "name": "API", "status": "degraded_performance"]]
      )
    )
    XCTAssertEqual(mapped.overall, .minor)
    XCTAssertEqual(mapped.apiComponents.first?.status, .degradedPerformance)
  }

  func testCriticalOverallIsPreserved() {
    let mapped = StatusPageMapper.map(
      makeSummary(
        indicator: "critical",
        description: "Major outage",
        components: [["id": "c1", "name": "API", "status": "operational"]]
      )
    )
    XCTAssertEqual(mapped.overall, .critical)
  }
}

@MainActor
final class StatusPageStatusStoreTests: XCTestCase {
  private var clock = MutableClock(date: Date(timeIntervalSince1970: 1_752_000_000))

  override func setUp() {
    super.setUp()
    clock = MutableClock(date: Date(timeIntervalSince1970: 1_752_000_000))
  }

  private func makeSummary() -> StatusPageSummaryResponse {
    StatusPageSummaryResponse(
      status: StatusPageStatusResponse(
        page: StatusPageStatusResponse.Page(name: "Cursor", url: nil),
        status: StatusPageStatusResponse.Status(
          indicator: "none",
          description: "All Systems Operational"
        )
      ),
      components: StatusPageComponentsResponse(
        components: [StatusPageComponent(id: "c1", name: "API", status: "operational", description: nil, group: nil)]
      ),
      incidents: StatusPageIncidentsResponse(incidents: [])
    )
  }

  private func makeStore(results: [Result<StatusPageSummaryResponse, Error>]) -> StatusPageStatusStore {
    StatusPageStatusStore(
      client: ScriptedStatusPageClient(results: results),
      officialStatusPageURL: URL(string: "https://status.cursor.com")!,
      clock: clock,
      startupRefresh: false
    )
  }

  func testLoadsStatus() async throws {
    let store = makeStore(results: [.success(makeSummary())])
    await store.refresh()
    XCTAssertEqual(store.loadState, .loaded)
    XCTAssertEqual(store.status?.overall, OverallIndicator.none)
    XCTAssertNil(store.error)
  }

  func testFirstFailureShowsUnavailable() async {
    let store = makeStore(results: [.failure(StatusPageClient.StatusError.noNetwork)])
    await store.refresh()
    XCTAssertNil(store.status)
    XCTAssertEqual(store.loadState, .unavailable)
    XCTAssertEqual(store.error, .serviceStatusUnavailable)
  }

  func testFailureKeepsOldValueAndMarksStale() async throws {
    let store = makeStore(
      results: [
        .success(makeSummary()),
        .failure(StatusPageClient.StatusError.timedOut),
      ]
    )
    await store.refresh()
    XCTAssertEqual(store.loadState, .loaded)
    clock.advance(by: 600)
    await store.refresh()
    XCTAssertNotNil(store.status)
    XCTAssertTrue(store.isStale)
    XCTAssertEqual(store.error, .serviceStatusUnavailable)
  }

  func testOfficialStatusPageURL() {
    let store = makeStore(results: [])
    XCTAssertEqual(
      store.officialStatusPageURL.absoluteString,
      "https://status.cursor.com"
    )
  }
}

/// 脚本化 Statuspage 客户端（与 ScriptedStatusClient 同理）。
final class ScriptedStatusPageClient: StatusPageFetching {
  struct ScriptedError: Error {}

  private let results: [Result<StatusPageSummaryResponse, Error>]
  private var nextIndex = 0
  private(set) var fetchCount = 0

  init(results: [Result<StatusPageSummaryResponse, Error>] = []) {
    self.results = results
  }

  func fetchSummary() async throws -> StatusPageSummaryResponse {
    fetchCount += 1
    guard nextIndex < results.count else {
      throw StatusPageClient.StatusError.noNetwork
    }
    let result = results[nextIndex]
    nextIndex += 1
    return try result.get()
  }
}
