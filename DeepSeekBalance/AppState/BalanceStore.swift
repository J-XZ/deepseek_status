import AppKit
import Combine
import Foundation

/// 菜单栏应用全局状态。所有可观察状态都在主线程（MainActor）更新。
@MainActor
final class BalanceStore: ObservableObject {
  enum Status: Equatable {
    case idle
    case loading
    case loaded
    case notConfigured
    case keychainError
    case authenticationFailed
    case insufficientBalance
    case rateLimited
    case httpError
    case networkError
    case serverError
    case decodingError
    case historyStorageError
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
  @Published private(set) var currentCredentialID: String?

  @Published private(set) var historySamples: [BalanceSample] = []
  @Published private(set) var availableCurrencies: [String] = []
  @Published private(set) var selectedCurrency: String?
  @Published private(set) var historyError: String?

  let apiClient: any BalanceFetching
  let keyProvider: any APIKeyProviding
  let keychainStore: any APIKeyStoring
  let historyService: BalanceHistoryService
  let clock: any DateProviding

  private let coordinator = RefreshCoordinator()
  private var autoRefreshTask: Task<Void, Never>?
  private var observers: [NSObjectProtocol] = []
  private var lastLifecycleEvent = Date.distantPast

  init(
    apiClient: any BalanceFetching = DeepSeekAPIClient(),
    keychainStore: any APIKeyStoring = KeychainStore(),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    clock: any DateProviding = SystemClock(),
    historyService: BalanceHistoryService? = nil,
    autoRefreshInterval: TimeInterval? = 300
  ) {
    self.apiClient = apiClient
    self.keychainStore = keychainStore
    self.keyProvider = APIKeyProvider(keychainStore: keychainStore, environment: environment)
    self.clock = clock
    self.historyService = historyService ?? Self.makeDefaultHistoryService(clock: clock)

    coordinator.onIsRefreshingChange = { [weak self] value in
      self?.isRefreshing = value
    }
    setupLifecycleObservers()

    guard let interval = autoRefreshInterval else { return }
    autoRefreshTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(interval))
        guard !Task.isCancelled else { break }
        await self?.refreshIfNeeded(maximumAge: 60)
      }
    }
    Task { [weak self] in
      await self?.refresh()
    }

    // 启动时执行一次 72 小时清理（失败只影响历史，不影响余额）。
    let history = historyService ?? Self.makeDefaultHistoryService(clock: clock)
    Task.detached(priority: .utility) {
      try? await history.pruneAll(before: Date().addingTimeInterval(-72 * 3600))
    }
  }

  deinit {
    autoRefreshTask?.cancel()
    for observer in observers {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - 菜单栏文字

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
    case .keychainError, .authenticationFailed, .insufficientBalance,
      .rateLimited, .httpError, .networkError, .serverError,
      .decodingError, .historyStorageError:
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
    case .keychainError:
      return "Keychain 错误"
    case .authenticationFailed, .rateLimited, .httpError, .networkError,
      .serverError, .decodingError, .historyStorageError:
      return "请求失败"
    case .insufficientBalance:
      return "余额不足"
    }
  }

  // MARK: - 刷新入口

  func refresh(force: Bool = false) async {
    let credential: ResolvedCredential?
    do {
      credential = try keyProvider.resolveCredential()
    } catch {
      coordinator.cancelAll()
      presentKeychainError(error)
      return
    }

    guard let credential else {
      coordinator.cancelAll()
      applyNotConfiguredState()
      return
    }

    if currentCredentialID != credential.credentialID {
      switchCredential(to: credential)
    }

    guard coordinator.begin(credentialID: credential.credentialID, force: force) else {
      await coordinator.awaitCurrent()
      return
    }

    let task = Task<Void, Never> { [weak self] in
      _ = await self?.performRefresh(credential: credential)
    }
    coordinator.adopt(task, credentialID: credential.credentialID)
    await task.value
  }

  /// 打开菜单时调用：距上次成功超过 maximumAge 秒才刷新。
  func refreshIfNeeded(maximumAge: TimeInterval = 60) async {
    guard balance == nil || clock.now().timeIntervalSince(lastUpdated ?? .distantPast) >= maximumAge
    else {
      return
    }
    await refresh()
  }

  // MARK: - API Key 管理

  func saveAPIKey(_ rawValue: String) -> SaveResult {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .emptyInput }
    do {
      try keychainStore.save(apiKey: trimmed)
      keySource = resolvedSource()
      return .success
    } catch {
      return .failure(error.localizedDescription)
    }
  }

  func clearSavedKey() async {
    do {
      try keychainStore.deleteAPIKey()
    } catch {
      lastErrorMessage = "无法清除已保存的密钥：\(error.localizedDescription)"
      return
    }
    await refresh()
  }

  func selectCurrency(_ currency: String) {
    guard availableCurrencies.contains(currency) else { return }
    selectedCurrency = currency
  }

  /// 清除当前凭据的本地历史（不影响 Keychain、环境变量与当前余额）。
  func clearLocalHistory() async {
    guard let credentialID = currentCredentialID else {
      historySamples = []
      selectedCurrency = nil
      return
    }
    do {
      try await historyService.clear(credentialID: credentialID)
      historySamples = []
      availableCurrencies = []
      selectedCurrency = nil
      historyError = nil
    } catch {
      historyError = "清除本地历史失败：\(error.localizedDescription)"
    }
  }

  // MARK: - 内部实现

  private func performRefresh(credential: ResolvedCredential) async {
    guard currentCredentialID == credential.credentialID else { return }
    if balance == nil {
      status = .loading
    }

    do {
      let response = try await apiClient.fetchBalance(apiKey: credential.apiKey)
      guard currentCredentialID == credential.credentialID else { return }
      applySuccess(response, credential: credential)
      let samples = historyService.makeSamples(
        from: response,
        credentialID: credential.credentialID,
        at: clock.now()
      )
      await persistHistory(
        response: response,
        credentialID: credential.credentialID,
        samples: samples
      )
    } catch let error as DeepSeekAPIClient.APIError {
      guard currentCredentialID == credential.credentialID else { return }
      applyFailure(error)
    } catch {
      guard currentCredentialID == credential.credentialID else { return }
      lastErrorMessage = "发生未知错误"
      status = .networkError
    }
  }

  private func applySuccess(_ response: BalanceResponse, credential: ResolvedCredential) {
    currentCredentialID = credential.credentialID
    keySource = credential.source
    balance = response
    lastUpdated = clock.now()
    lastErrorMessage = nil
    status = response.isAvailable ? .loaded : .insufficientBalance
  }

  private func applyFailure(_ error: DeepSeekAPIClient.APIError) {
    switch error {
    case .cancelled:
      // 取消不是面向用户的真实故障，不覆盖当前状态。
      return
    case .unauthorized:
      // 认证失败：不再把旧缓存当作有效余额显示。
      balance = nil
      status = .authenticationFailed
      lastErrorMessage = error.errorDescription
    case .insufficientBalance:
      status = .insufficientBalance
      lastErrorMessage = error.errorDescription
    case .rateLimited:
      status = .rateLimited
      lastErrorMessage = error.errorDescription
    case .server:
      status = .serverError
      lastErrorMessage = error.errorDescription
    case .httpError:
      status = .httpError
      lastErrorMessage = error.errorDescription
    case .noNetwork:
      status = .networkError
      lastErrorMessage = error.errorDescription
    case .timedOut:
      status = .networkError
      lastErrorMessage = error.errorDescription
    case .decodingFailed:
      status = .decodingError
      lastErrorMessage = error.errorDescription
    }
  }

  /// 凭据切换：清空旧账号余额与趋势数据，进入加载状态。
  private func switchCredential(to credential: ResolvedCredential) {
    currentCredentialID = credential.credentialID
    keySource = credential.source
    balance = nil
    lastUpdated = nil
    lastErrorMessage = nil
    historySamples = []
    availableCurrencies = []
    selectedCurrency = nil
    historyError = nil
    status = .loading
  }

  private func applyNotConfiguredState() {
    currentCredentialID = nil
    keySource = .notConfigured
    balance = nil
    lastUpdated = nil
    lastErrorMessage = nil
    historySamples = []
    availableCurrencies = []
    selectedCurrency = nil
    historyError = nil
    status = .notConfigured
  }

  private func presentKeychainError(_ error: Error) {
    // 保守处理：无法确认凭据时清空当前余额显示，避免旧账号金额误显示。
    balance = nil
    lastUpdated = nil
    status = .keychainError
    lastErrorMessage = error.localizedDescription
  }

  private func resolvedSource() -> APIKeySource {
    (try? keyProvider.resolveCredential())?.source ?? .notConfigured
  }

  // MARK: - 历史持久化

  /// 成功刷新后按顺序执行：写入当前桶 → 重新读取 72 小时历史 → 更新图表 → 节流清理。
  private func persistHistory(
    response: BalanceResponse,
    credentialID: String,
    samples: [BalanceSample]
  ) async {
    do {
      try await historyService.save(samples: samples)
      let recent = try await historyService.recentSamples(credentialID: credentialID)
      guard currentCredentialID == credentialID else { return }
      historySamples = recent
      updateAvailableCurrencies(response: response, history: recent)
      historyError = nil
      try await historyService.pruneThrottled()
    } catch {
      guard currentCredentialID == credentialID else { return }
      historyError = error.localizedDescription
    }
  }

  private func updateAvailableCurrencies(response: BalanceResponse, history: [BalanceSample]) {
    var ordered: [String] = []
    func append(_ currency: String) {
      if !ordered.contains(currency) {
        ordered.append(currency)
      }
    }
    ["CNY", "USD"].forEach(append)
    response.balanceInfos.map(\.currency).forEach(append)
    Set(history.map(\.currency)).sorted().forEach(append)
    availableCurrencies = ordered
    if let selected = selectedCurrency, ordered.contains(selected) {
      return
    }
    selectedCurrency = ordered.first
  }

  // MARK: - 生命周期

  private func setupLifecycleObservers() {
    let workspaceCenter = NSWorkspace.shared.notificationCenter
    observers.append(
      workspaceCenter.addObserver(
        forName: NSWorkspace.didWakeNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in await self?.handleLifecycleEvent() }
      }
    )
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in await self?.handleLifecycleEvent() }
      }
    )
  }

  private func handleLifecycleEvent() async {
    // 合并 wake / active 事件，5 秒内只协调一次刷新。
    let now = clock.now()
    guard now.timeIntervalSince(lastLifecycleEvent) >= 5 else { return }
    lastLifecycleEvent = now
    await refreshIfNeeded(maximumAge: 60)
  }

  private static func makeDefaultHistoryService(clock: any DateProviding) -> BalanceHistoryService {
    let base = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first
    guard let base else {
      return BalanceHistoryService(store: UnavailableBalanceHistoryStore(), clock: clock)
    }
    let directory =
      base
      .appendingPathComponent(
        Bundle.main.bundleIdentifier ?? "com.example.DeepSeekBalance",
        isDirectory: true
      )
      .appendingPathComponent("BalanceHistory.leveldb", isDirectory: true)
    if let store = try? LevelDBBalanceHistoryStore(directory: directory) {
      return BalanceHistoryService(store: store, clock: clock)
    }
    return BalanceHistoryService(store: UnavailableBalanceHistoryStore(), clock: clock)
  }
}
