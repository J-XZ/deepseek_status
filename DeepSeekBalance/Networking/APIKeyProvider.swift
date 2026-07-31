import Foundation

/// 当前 API Key 的来源。
enum APIKeySource: Equatable, Sendable {
  case keychain
  case environment
  case notConfigured

  var displayName: String {
    switch self {
    case .keychain:
      return "Keychain"
    case .environment:
      return "环境变量 DEEPSEEK_API_KEY"
    case .notConfigured:
      return "未配置"
    }
  }
}

protocol APIKeyProviding: Sendable {
  var source: APIKeySource { get }
  var apiKey: String? { get }
}

/// 统一密钥来源：Keychain 优先，其次环境变量 `DEEPSEEK_API_KEY`。
struct APIKeyProvider: APIKeyProviding {
  static let environmentVariableName = "DEEPSEEK_API_KEY"

  let keychainStore: any APIKeyStoring
  let environment: [String: String]

  init(
    keychainStore: any APIKeyStoring = KeychainStore(),
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.keychainStore = keychainStore
    self.environment = environment
  }

  var apiKey: String? {
    if let key = try? keychainStore.readAPIKey(),
      !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return key
    }
    return trimmedEnvironmentKey
  }

  var source: APIKeySource {
    if let key = try? keychainStore.readAPIKey(),
      !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return .keychain
    }
    if trimmedEnvironmentKey != nil {
      return .environment
    }
    return .notConfigured
  }

  private var trimmedEnvironmentKey: String? {
    guard let raw = environment[Self.environmentVariableName] else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
