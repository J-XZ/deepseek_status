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
    XCTAssertEqual(status.overall, .none)
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
}
