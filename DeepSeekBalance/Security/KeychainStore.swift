import Foundation
import Security

/// Keychain 存取抽象，便于测试时注入内存 Fake。
protocol APIKeyStoring: Sendable {
  func save(apiKey: String) throws
  func readAPIKey() throws -> String?
  func deleteAPIKey() throws
}

enum KeychainError: LocalizedError {
  case unexpectedStatus(OSStatus)
  case unexpectedData

  var errorDescription: String? {
    switch self {
    case .unexpectedStatus(let status):
      let message = SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"
      return "Keychain 错误：\(message)"
    case .unexpectedData:
      return "无法读取已保存的 API Key"
    }
  }
}

/// 将 API Key 保存到 macOS Keychain 的独立封装。
struct KeychainStore: APIKeyStoring {
  let service: String
  let account: String

  init(
    service: String = Bundle.main.bundleIdentifier ?? "com.example.DeepSeekBalance",
    account: String = "deepseek-api-key"
  ) {
    self.service = service
    self.account = account
  }

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  func save(apiKey: String) throws {
    let data = Data(apiKey.utf8)
    let updateAttributes: [String: Any] = [kSecValueData as String: data]
    let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttributes as CFDictionary)
    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw KeychainError.unexpectedStatus(updateStatus)
    }

    var query = baseQuery
    query[kSecValueData as String] = data
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    let addStatus = SecItemAdd(query as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw KeychainError.unexpectedStatus(addStatus)
    }
  }

  func readAPIKey() throws -> String? {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess else {
      throw KeychainError.unexpectedStatus(status)
    }
    guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
      throw KeychainError.unexpectedData
    }
    return value
  }

  func deleteAPIKey() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    if status == errSecSuccess || status == errSecItemNotFound {
      return
    }
    throw KeychainError.unexpectedStatus(status)
  }
}
