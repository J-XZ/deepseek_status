import Foundation

/// 当前 API Key 的来源。
enum APIKeySource: Equatable, Sendable {
  case keychain
  case environment
  case notConfigured
}

/// 一次性解析得到的凭据：apiKey、来源与不可逆 credentialID。
struct ResolvedCredential: Sendable, Equatable {
  let apiKey: String
  let source: APIKeySource
  let credentialID: String
}

protocol APIKeyProviding: Sendable {
  /// 单次解析最多读取一次 Keychain。
  /// 仅当 Keychain 项不存在（返回 nil）时回退环境变量；
  /// Keychain 读取错误会抛出，绝不静默回退或伪装成“未配置”。
  func resolveCredential() throws -> ResolvedCredential?
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

  func resolveCredential() throws -> ResolvedCredential? {
    let storedValue = try keychainStore.readAPIKey()
    if let key = storedValue?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
      return ResolvedCredential(
        apiKey: key,
        source: .keychain,
        credentialID: CredentialFingerprint.credentialID(for: key)
      )
    }
    // 明确规则：Keychain 项不存在或值为空白时，视为未从 Keychain 提供密钥，
    // 允许回退环境变量；Keychain 读取错误已在上面抛出。
    return environmentCredential()
  }

  private func environmentCredential() -> ResolvedCredential? {
    guard let raw = environment[Self.environmentVariableName] else { return nil }
    let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return nil }
    return ResolvedCredential(
      apiKey: key,
      source: .environment,
      credentialID: CredentialFingerprint.credentialID(for: key)
    )
  }
}
