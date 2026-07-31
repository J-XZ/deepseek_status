import Foundation

/// 拦截 URLSession 请求的 URLProtocol，用于不依赖真实网络地测试。
/// 支持受控请求持有（hold），测试可精确控制响应时序，不使用 `Thread.sleep`。
final class MockURLProtocol: URLProtocol {
  private static let lock = NSLock()
  static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
  private static var recordedRequests: [URLRequest] = []
  private static var holdRequests = false
  private static var parkedSemaphores: [ObjectIdentifier: DispatchSemaphore] = [:]

  static func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  static func reset() {
    lock.lock()
    requestHandler = nil
    recordedRequests = []
    holdRequests = false
    let parked = parkedSemaphores
    parkedSemaphores = [:]
    lock.unlock()
    for semaphore in parked.values {
      semaphore.signal()
    }
  }

  static func capturedAuthorizationHeaders() -> [String?] {
    lock.lock()
    defer { lock.unlock() }
    return recordedRequests.map { $0.value(forHTTPHeaderField: "Authorization") }
  }

  static var recordedRequestCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return recordedRequests.count
  }

  /// 开启请求持有：后续请求挂起，直到 `releaseAllHeld()`。
  static func startHolding() {
    lock.lock()
    holdRequests = true
    lock.unlock()
  }

  static func releaseAllHeld() {
    lock.lock()
    let parked = parkedSemaphores.values
    parkedSemaphores = [:]
    lock.unlock()
    for semaphore in parked {
      semaphore.signal()
    }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.lock.lock()
    let handler = Self.requestHandler
    let shouldHold = Self.holdRequests
    Self.recordedRequests.append(request)
    Self.lock.unlock()

    if shouldHold {
      let semaphore = DispatchSemaphore(value: 0)
      Self.lock.lock()
      Self.parkedSemaphores[ObjectIdentifier(self)] = semaphore
      Self.lock.unlock()
      semaphore.wait()
    }

    guard let handler else {
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

  override func stopLoading() {
    // 任务被取消时唤醒挂起的协议线程，避免死锁。
    Self.lock.lock()
    let semaphore = Self.parkedSemaphores.removeValue(forKey: ObjectIdentifier(self))
    Self.lock.unlock()
    semaphore?.signal()
  }
}
