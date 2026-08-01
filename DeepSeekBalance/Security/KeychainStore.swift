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
  private let legacyService: String?

  init(
    service: String = Bundle.main.bundleIdentifier ?? "com.jxz.deepseekbalance",
    account: String = "deepseek-api-key",
    legacyService: String? = "com.example.DeepSeekBalance"
  ) {
    self.service = service
    self.account = account
    self.legacyService = legacyService == service ? nil : legacyService
  }

  private func baseQuery(service: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  func save(apiKey: String) throws {
    let data = Data(apiKey.utf8)
    let updateAttributes: [String: Any] = [kSecValueData as String: data]
    let updateStatus = SecItemUpdate(
      baseQuery(service: service) as CFDictionary,
      updateAttributes as CFDictionary
    )
    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw KeychainError.unexpectedStatus(updateStatus)
    }

    var query = baseQuery(service: service)
    query[kSecValueData as String] = data
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    let addStatus = SecItemAdd(query as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw KeychainError.unexpectedStatus(addStatus)
    }
  }

  func readAPIKey() throws -> String? {
    if let value = try readAPIKey(service: service) {
      return value
    }
    if let legacyService {
      return try readAPIKey(service: legacyService)
    }
    return nil
  }

  private func readAPIKey(service: String) throws -> String? {
    var query = baseQuery(service: service)
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
    let services = [service] + (legacyService.map { [$0] } ?? [])
    for service in services {
      let status = SecItemDelete(baseQuery(service: service) as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw KeychainError.unexpectedStatus(status)
      }
    }
  }
}
