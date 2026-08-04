import Foundation

protocol VPSConfigStoring {
  func load() throws -> VPSUsageConfig
  func save(_ config: VPSUsageConfig) throws
  func clear() throws
}

/// Vultr Token 使用独立 Keychain account，Instance ID 只保存为普通配置。
struct KeychainVPSConfigStore: VPSConfigStoring {
  private let keychain: any APIKeyStoring
  private let defaults: UserDefaults

  init(
    keychain: any APIKeyStoring = KeychainStore(
      service: Bundle.main.bundleIdentifier ?? "com.jxz.deepseekbalance",
      account: "vultr-api-token",
      legacyService: nil
    ),
    defaults: UserDefaults = .standard
  ) {
    self.keychain = keychain
    self.defaults = defaults
  }

  func load() throws -> VPSUsageConfig {
    VPSUsageConfig(
      apiToken: try keychain.readAPIKey() ?? "",
      instanceID: defaults.string(forKey: Self.instanceIDKey) ?? ""
    )
  }

  func save(_ config: VPSUsageConfig) throws {
    defaults.set(config.instanceID, forKey: Self.instanceIDKey)
    try keychain.save(apiKey: config.apiToken)
  }

  func clear() throws {
    defaults.removeObject(forKey: Self.instanceIDKey)
    try keychain.deleteAPIKey()
  }

  private static let instanceIDKey = "vultr.instanceID"
}
