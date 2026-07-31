import Foundation

/// 拦截 URLSession 请求的 URLProtocol，用于不依赖真实网络地测试。
final class MockURLProtocol: URLProtocol {
  private static let lock = NSLock()
  static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
  private static var recordedRequests: [URLRequest] = []

  static func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  static func reset() {
    lock.lock()
    requestHandler = nil
    recordedRequests = []
    lock.unlock()
  }

  static func capturedAuthorizationHeaders() -> [String?] {
    lock.lock()
    defer { lock.unlock() }
    return recordedRequests.map { $0.value(forHTTPHeaderField: "Authorization") }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.lock.lock()
    let handler = Self.requestHandler
    Self.recordedRequests.append(request)
    Self.lock.unlock()

    guard let handler = handler else {
      // 未安装 handler：不回调，让 URLSession 触发超时。
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
