import XCTest

@testable import DeepSeekBalance

final class BalanceClientTests: XCTestCase {
  override func setUp() {
    super.setUp()
    MockURLProtocol.reset()
  }

  override func tearDown() {
    MockURLProtocol.reset()
    super.tearDown()
  }

  private func makeClient(timeout: TimeInterval = 15) -> DeepSeekAPIClient {
    DeepSeekAPIClient(session: MockURLProtocol.makeSession(), timeoutInterval: timeout)
  }

  func testParsesStandardCNYResponse() async throws {
    MockURLProtocol.requestHandler = { _ in
      (TestFixtures.httpResponse(statusCode: 200), Data(TestFixtures.cnyJSON.utf8))
    }
    let response = try await makeClient().fetchBalance(apiKey: "sk-test")
    XCTAssertTrue(response.isAvailable)
    XCTAssertEqual(response.balanceInfos.count, 1)
    let info = try XCTUnwrap(response.balanceInfos.first)
    XCTAssertEqual(info.currency, "CNY")
    XCTAssertEqual(info.totalBalance, "110.00")
    XCTAssertEqual(info.grantedBalance, "10.00")
    XCTAssertEqual(info.toppedUpBalance, "100.00")
  }

  func testParsesMultiCurrencyResponse() async throws {
    MockURLProtocol.requestHandler = { _ in
      (TestFixtures.httpResponse(statusCode: 200), Data(TestFixtures.multiCurrencyJSON.utf8))
    }
    let response = try await makeClient().fetchBalance(apiKey: "sk-test")
    XCTAssertEqual(response.balanceInfos.map(\.currency), ["CNY", "USD"])
    XCTAssertEqual(response.balanceInfos[1].totalBalance, "2.50")
  }

  func testSendsAuthorizationHeader() async throws {
    MockURLProtocol.requestHandler = { _ in
      (TestFixtures.httpResponse(statusCode: 200), Data(TestFixtures.cnyJSON.utf8))
    }
    _ = try await makeClient().fetchBalance(apiKey: "sk-test-123")
    XCTAssertEqual(MockURLProtocol.capturedAuthorizationHeaders(), ["Bearer sk-test-123"])
  }

  func testUnauthorizedStatus() async {
    MockURLProtocol.requestHandler = { _ in
      (TestFixtures.httpResponse(statusCode: 401), Data())
    }
    do {
      _ = try await makeClient().fetchBalance(apiKey: "sk-bad")
      XCTFail("应抛出 unauthorized")
    } catch let error as DeepSeekAPIClient.APIError {
      XCTAssertEqual(error, .unauthorized)
    } catch {
      XCTFail("意外的错误类型：\(error)")
    }
  }

  func testInsufficientBalanceStatus() async {
    MockURLProtocol.requestHandler = { _ in
      (TestFixtures.httpResponse(statusCode: 402), Data())
    }
    do {
      _ = try await makeClient().fetchBalance(apiKey: "sk-test")
      XCTFail("应抛出 insufficientBalance")
    } catch let error as DeepSeekAPIClient.APIError {
      XCTAssertEqual(error, .insufficientBalance)
    } catch {
      XCTFail("意外的错误类型：\(error)")
    }
  }

  func testRateLimitedStatus() async {
    MockURLProtocol.requestHandler = { _ in
      (TestFixtures.httpResponse(statusCode: 429), Data())
    }
    do {
      _ = try await makeClient().fetchBalance(apiKey: "sk-test")
      XCTFail("应抛出 rateLimited")
    } catch let error as DeepSeekAPIClient.APIError {
      XCTAssertEqual(error, .rateLimited)
    } catch {
      XCTFail("意外的错误类型：\(error)")
    }
  }

  func testServerErrorStatus() async {
    MockURLProtocol.requestHandler = { _ in
      (TestFixtures.httpResponse(statusCode: 500), Data())
    }
    do {
      _ = try await makeClient().fetchBalance(apiKey: "sk-test")
      XCTFail("应抛出 server 错误")
    } catch let error as DeepSeekAPIClient.APIError {
      XCTAssertEqual(error, .server(statusCode: 500))
    } catch {
      XCTFail("意外的错误类型：\(error)")
    }
  }

  func testGenericHTTPErrorStatus() async {
    MockURLProtocol.requestHandler = { _ in
      (TestFixtures.httpResponse(statusCode: 404), Data())
    }
    do {
      _ = try await makeClient().fetchBalance(apiKey: "sk-test")
      XCTFail("应抛出 httpError")
    } catch let error as DeepSeekAPIClient.APIError {
      XCTAssertEqual(error, .httpError(statusCode: 404))
    } catch {
      XCTFail("意外的错误类型：\(error)")
    }
  }

  func testInvalidJSONProducesDecodingError() async {
    MockURLProtocol.requestHandler = { _ in
      (TestFixtures.httpResponse(statusCode: 200), Data("not json".utf8))
    }
    do {
      _ = try await makeClient().fetchBalance(apiKey: "sk-test")
      XCTFail("应抛出 decodingFailed")
    } catch let error as DeepSeekAPIClient.APIError {
      XCTAssertEqual(error, .decodingFailed)
    } catch {
      XCTFail("意外的错误类型：\(error)")
    }
  }

  func testNetworkErrorIsMapped() async {
    MockURLProtocol.requestHandler = { _ in
      throw URLError(.notConnectedToInternet)
    }
    do {
      _ = try await makeClient().fetchBalance(apiKey: "sk-test")
      XCTFail("应抛出 noNetwork")
    } catch let error as DeepSeekAPIClient.APIError {
      XCTAssertEqual(error, .noNetwork)
    } catch {
      XCTFail("意外的错误类型：\(error)")
    }
  }

  func testTimeoutIsMapped() async {
    // 直接返回 URLError(.timedOut)，避免依赖真实等待。
    MockURLProtocol.requestHandler = { _ in
      throw URLError(.timedOut)
    }
    do {
      _ = try await makeClient().fetchBalance(apiKey: "sk-test")
      XCTFail("应抛出 timedOut")
    } catch let error as DeepSeekAPIClient.APIError {
      XCTAssertEqual(error, .timedOut)
    } catch {
      XCTFail("意外的错误类型：\(error)")
    }
  }
}
