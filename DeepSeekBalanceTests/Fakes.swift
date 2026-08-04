import Foundation

@testable import DeepSeekBalance

/// 内存版 Keychain，用于单元测试。
final class FakeKeychainStore: APIKeyStoring, @unchecked Sendable {
  private let readCounter = AtomicCounter()
  var storedValue: String?
  var saveError: Error?
  var readError: Error?
  var deleteError: Error?

  var readCount: Int { readCounter.value }

  func save(apiKey: String) throws {
    if let saveError { throw saveError }
    storedValue = apiKey
  }

  func readAPIKey() throws -> String? {
    readCounter.increment()
    if let readError { throw readError }
    return storedValue
  }

  func deleteAPIKey() throws {
    if let deleteError { throw deleteError }
    storedValue = nil
  }
}

final class AtomicCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = 0

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  @discardableResult
  func increment() -> Int {
    lock.lock()
    storage += 1
    let result = storage
    lock.unlock()
    return result
  }
}

/// 固定时间源。
struct FixedClock: DateProviding {
  let date: Date

  func now() -> Date { date }
}

/// 固定登录信息的 Codex 认证提供者。
struct MockCodexAuthProvider: CodexAuthProviding {
  let info: CodexAuthInfo
  let refreshError: Error?

  init(
    info: CodexAuthInfo = CodexAuthInfo(
      accessToken: "token-123",
      refreshToken: "refresh-456",
      accountID: nil
    ),
    refreshError: Error? = nil
  ) {
    self.info = info
    self.refreshError = refreshError
  }

  func loadAuthInfo() throws -> CodexAuthInfo {
    info
  }

  func refreshAccessToken(refreshToken: String) async throws -> String {
    if let refreshError { throw refreshError }
    return "refreshed-token"
  }
}

/// 线程安全布尔标志，避免测试闭包捕获的可变变量出现数据竞争。
final class AtomicFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Bool

  init(_ initialValue: Bool = false) {
    value = initialValue
  }

  func set(_ newValue: Bool) {
    lock.lock()
    value = newValue
    lock.unlock()
  }

  func get() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

/// 可控 API 客户端：测试可精确决定每个请求何时完成或失败。
actor ControlledAPIClient: BalanceFetching {
  private final class Box: @unchecked Sendable {
    var continuation: CheckedContinuation<BalanceResponse, Error>?
  }

  private var pending: [Box] = []
  private(set) var keys: [String] = []

  func fetchBalance(apiKey: String) async throws -> BalanceResponse {
    keys.append(apiKey)
    let box = Box()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        box.continuation = continuation
        pending.append(box)
      }
    } onCancel: {
      Task { await self.cancel(box) }
    }
  }

  private func cancel(_ box: Box) {
    if let index = pending.firstIndex(where: { $0 === box }) {
      pending.remove(at: index)
      box.continuation?.resume(throwing: CancellationError())
      box.continuation = nil
    }
  }

  func respondNext(total: String, currency: String = "CNY", isAvailable: Bool = true) async {
    guard !pending.isEmpty else { return }
    let box = pending.removeFirst()
    box.continuation?.resume(
      returning: BalanceResponse(
        isAvailable: isAvailable,
        balanceInfos: [
          BalanceInfo(
            currency: currency,
            totalBalance: total,
            grantedBalance: "1.00",
            toppedUpBalance: "2.00"
          )
        ]
      )
    )
    box.continuation = nil
  }

  func failNext(_ error: Error) async {
    guard !pending.isEmpty else { return }
    let box = pending.removeFirst()
    box.continuation?.resume(throwing: error)
    box.continuation = nil
  }
}

/// 测试用响应与 JSON 样本。
enum TestFixtures {
  static let cnyJSON = """
    {"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"110.00","granted_balance":"10.00","topped_up_balance":"100.00"}]}
    """

  static let multiCurrencyJSON = """
    {"is_available":true,"balance_infos":[
      {"currency":"CNY","total_balance":"110.00","granted_balance":"10.00","topped_up_balance":"100.00"},
      {"currency":"USD","total_balance":"2.50","granted_balance":"0.00","topped_up_balance":"2.50"}
    ]}
    """

  static func httpResponse(statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(
      url: URL(string: "https://api.deepseek.com/user/balance")!,
      statusCode: statusCode,
      httpVersion: nil,
      headerFields: nil
    )!
  }
}
