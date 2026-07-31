import Foundation

@testable import DeepSeekBalance

/// 内存版 Keychain，用于单元测试。
final class FakeKeychainStore: APIKeyStoring, @unchecked Sendable {
  var storedValue: String?
  var saveError: Error?
  var readError: Error?
  var deleteError: Error?

  func save(apiKey: String) throws {
    if let saveError { throw saveError }
    storedValue = apiKey
  }

  func readAPIKey() throws -> String? {
    if let readError { throw readError }
    return storedValue
  }

  func deleteAPIKey() throws {
    if let deleteError { throw deleteError }
    storedValue = nil
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
