import Combine
import Foundation

/// 菜单栏应用的全局状态。所有可观察状态都在主线程（MainActor）更新。
@MainActor
final class BalanceStore: ObservableObject {
  enum Status: Equatable {
    case idle
    case loading
    case loaded
    case notConfigured
    case authenticationFailed
    case insufficientBalance
    case rateLimited
    case networkError
    case serverError
    case decodingError
  }

  enum SaveResult: Equatable {
    case success
    case emptyInput
    case failure(String)
  }

  @Published private(set) var status: Status = .idle
  @Published private(set) var balance: BalanceResponse?
  @Published private(set) var lastUpdated: Date?
  @Published private(set) var isRefreshing = false
  @Published private(set) var keySource: APIKeySource = .notConfigured
  @Published private(set) var lastErrorMessage: String?

  let apiClient: DeepSeekAPIClient
  let keyProvider: any APIKeyProviding
  let keychainStore: any APIKeyStoring

  private let autoRefreshInterval: TimeInterval?
  private var autoRefreshTask: Task<Void, Never>?

  init(
    apiClient: DeepSeekAPIClient = DeepSeekAPIClient(),
    keychainStore: any APIKeyStoring = KeychainStore(),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    autoRefreshInterval: TimeInterval? = 300
  ) {
    self.apiClient = apiClient
    self.keychainStore = keychainStore
    self.keyProvider = APIKeyProvider(keychainStore: keychainStore, environment: environment)
    self.autoRefreshInterval = autoRefreshInterval
    self.keySource = self.keyProvider.source

    guard let interval = autoRefreshInterval else { return }
    autoRefreshTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(interval))
        guard !Task.isCancelled else { break }
        await self?.refresh()
      }
    }
    Task { [weak self] in
      await self?.refresh()
    }
  }

  deinit {
    autoRefreshTask?.cancel()
  }

  /// 菜单栏文字：有缓存时优先显示缓存金额，否则按状态显示 `…` / `未配置` / `错误`。
  var menuBarText: String {
    if let balance, let summary = BalanceFormatter.summary(for: balance.balanceInfos) {
      return summary
    }
    switch status {
    case .idle, .loading:
      return "…"
    case .notConfigured:
      return "未配置"
    case .loaded:
      return "—"
    case .authenticationFailed, .insufficientBalance, .rateLimited,
      .networkError, .serverError, .decodingError:
      return "错误"
    }
  }

  var statusTitle: String {
    switch status {
    case .idle, .loading:
      return "加载中"
    case .loaded:
      return "可用"
    case .notConfigured:
      return "未配置"
    case .insufficientBalance:
      return "余额不足"
    case .authenticationFailed, .rateLimited, .networkError,
      .serverError, .decodingError:
      return "请求失败"
    }
  }

  var hasError: Bool {
    switch status {
    case .authenticationFailed, .rateLimited, .networkError,
      .serverError, .decodingError:
      return true
    default:
      return false
    }
  }

  /// 发起一次余额请求；已有请求进行中时直接返回，避免重复请求。
  func refresh() async {
    guard !isRefreshing else { return }
    isRefreshing = true
    if balance == nil {
      status = .loading
    }
    defer { isRefreshing = false }

    keySource = keyProvider.source
    guard let apiKey = keyProvider.apiKey else {
      status = .notConfigured
      lastErrorMessage = nil
      return
    }

    do {
      let response = try await apiClient.fetchBalance(apiKey: apiKey)
      balance = response
      lastUpdated = Date()
      status = response.isAvailable ? .loaded : .insufficientBalance
      lastErrorMessage = nil
    } catch let error as DeepSeekAPIClient.APIError {
      lastErrorMessage = error.errorDescription
      status = status(for: error)
    } catch {
      lastErrorMessage = "发生未知错误"
      status = .networkError
    }
  }

  /// 打开菜单时调用：距上次成功请求超过 `maximumAge` 秒则刷新。
  func refreshIfNeeded(maximumAge: TimeInterval = 60) async {
    guard balance == nil || Date().timeIntervalSince(lastUpdated ?? .distantPast) >= maximumAge
    else {
      return
    }
    await refresh()
  }

  /// 保存 API Key（已去除首尾空白），成功后调用方应立即刷新。
  func saveAPIKey(_ rawValue: String) -> SaveResult {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .emptyInput }
    do {
      try keychainStore.save(apiKey: trimmed)
      keySource = keyProvider.source
      return .success
    } catch {
      return .failure(error.localizedDescription)
    }
  }

  /// 清除 Keychain 中保存的密钥；若存在环境变量则自动回退并刷新余额。
  func clearSavedKey() async {
    do {
      try keychainStore.deleteAPIKey()
    } catch {
      lastErrorMessage = "无法清除已保存的密钥：\(error.localizedDescription)"
      return
    }
    keySource = keyProvider.source
    await refresh()
  }

  private func status(for error: DeepSeekAPIClient.APIError) -> Status {
    switch error {
    case .unauthorized:
      return .authenticationFailed
    case .insufficientBalance:
      return .insufficientBalance
    case .rateLimited:
      return .rateLimited
    case .server:
      return .serverError
    case .decodingFailed:
      return .decodingError
    case .noNetwork, .timedOut, .cancelled, .otherHTTP:
      return .networkError
    }
  }
}
