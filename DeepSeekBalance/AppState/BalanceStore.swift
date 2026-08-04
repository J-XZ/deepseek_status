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
    case failure(AppDisplayError)
  }

  @Published private(set) var status: Status = .idle
  @Published private(set) var balance: BalanceResponse?
  @Published private(set) var lastUpdated: Date?
  @Published private(set) var isRefreshing = false
  @Published private(set) var keySource: APIKeySource = .notConfigured
  @Published private(set) var lastDisplayError: AppDisplayError?
  @Published private(set) var currentCredentialID: String?

  @Published private(set) var historySamples: [BalanceSample] = []
  @Published private(set) var availableCurrencies: [String] = []
  @Published private(set) var selectedCurrency: String?
  @Published private(set) var historyDisplayError: AppDisplayError?
  @Published private(set) var language: AppLanguage
  @Published private(set) var appearance: AppAppearance

  /// 兼容旧测试/旧调用的文本视图：按当前语言即时渲染。
  var lastErrorMessage: String? {
    lastDisplayError?.text(language: language)
  }

  var historyError: String? {
    historyDisplayError?.text(language: language)
  }

  let apiClient: any BalanceFetching
  let keyProvider: any APIKeyProviding
  let keychainStore: any APIKeyStoring
  let historyService: BalanceHistoryService
  let clock: any DateProviding
  let languageDefaults: UserDefaults
  let statusStore: DeepSeekStatusStore?
  let loginItemStore: LoginItemStore?

  private let coordinator = RefreshCoordinator()
  /// 在凭据解析和网络请求之间也保持单飞，避免第二个菜单刷新在首个请求
  /// 已经结束、但还未完成整个刷新流程时又发起重复请求。
  private var refreshGateTask: Task<Void, Never>?
  private var refreshGateGeneration = 0
  private var autoRefreshTask: Task<Void, Never>?
  private var startupRefreshTask: Task<Void, Never>?
  private var startupPruneTask: Task<Void, Never>?
  private var observations: [NotificationObservation] = []
  private var lastLifecycleEvent = Date.distantPast
  private var autoRefreshInterval: TimeInterval?

  init(
    apiClient: any BalanceFetching = DeepSeekAPIClient(),
    keychainStore: any APIKeyStoring = KeychainStore(),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    clock: any DateProviding = SystemClock(),
    historyService: BalanceHistoryService? = nil,
    autoRefreshInterval: TimeInterval? = DataRefreshPolicy.autoRefreshInterval,
    startupRefresh: Bool = true,
    startupPrune: Bool = true,
    language: AppLanguage = AppLanguage.initial(),
    languageDefaults: UserDefaults = .standard,
    appearance: AppAppearance = AppAppearance.initial(),
    statusStore: DeepSeekStatusStore? = nil,
    loginItemStore: LoginItemStore? = nil
  ) {
    self.apiClient = apiClient
    self.keychainStore = keychainStore
    self.keyProvider = APIKeyProvider(keychainStore: keychainStore, environment: environment)
    self.clock = clock
    self.historyService = historyService ?? Self.makeDefaultHistoryService(clock: clock)
    self.language = language
    self.languageDefaults = languageDefaults
    self.appearance = appearance
    self.statusStore = statusStore
    self.loginItemStore = loginItemStore

    coordinator.onIsRefreshingChange = { [weak self] value in
      self?.isRefreshing = value
    }
    setupLifecycleObservers()

    // 周期刷新：保证额度与历史记录持续更新。
    self.autoRefreshInterval = autoRefreshInterval
    startAutoRefreshIfNeeded()

    // 启动刷新与启动清理相互独立、分别可注入。
    if startupRefresh {
      startupRefreshTask = Task { [weak self] in
        await self?.refresh()
      }
    }

    if startupPrune {
      let history = self.historyService
      let clock = self.clock
      startupPruneTask = Task(priority: .utility) { [weak self] in
        try? await history.pruneAll(before: clock.now().addingTimeInterval(-UsageHistoryWindow.seconds))
        try? await self?.historyService.pruneThrottled()
      }
    }
  }

  deinit {
    refreshGateTask?.cancel()
    autoRefreshTask?.cancel()
    startupRefreshTask?.cancel()
    startupPruneTask?.cancel()
    for observation in observations {
      observation.remove()
    }
  }

  // MARK: - 启用/停用

  /// 当前是否允许后台收集额度。菜单栏隐藏该供应商时置为 false：
  /// 停止周期刷新、启动刷新与历史写入；重新显示时恢复并立即刷新一次。
  private(set) var isEnabled = true

  func setEnabled(_ enabled: Bool) {
    guard isEnabled != enabled else { return }
    isEnabled = enabled
    if enabled {
      startupRefreshTask = Task { [weak self] in
        await self?.refresh()
      }
      startAutoRefreshIfNeeded()
    } else {
      startupRefreshTask?.cancel()
      startupRefreshTask = nil
      autoRefreshTask?.cancel()
      autoRefreshTask = nil
    }
  }

  private func startAutoRefreshIfNeeded() {
    autoRefreshTask?.cancel()
    guard isEnabled, let interval = autoRefreshInterval else { return }
    autoRefreshTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(interval))
        guard !Task.isCancelled else { break }
        await self?.refreshIfNeeded(maximumAge: interval)
      }
    }
  }

  // MARK: - 语言切换

  func setLanguage(_ newLanguage: AppLanguage) {
    guard language != newLanguage else { return }
    language = newLanguage
    newLanguage.save(defaults: languageDefaults)
  }

  // MARK: - 外观切换

  func setAppearance(_ newAppearance: AppAppearance) {
    guard appearance != newAppearance else { return }
    appearance = newAppearance
    newAppearance.save()
  }

  // MARK: - 菜单栏文字

  var menuBarText: String {
    if let balance, let summary = BalanceFormatter.summary(
      for: balance.balanceInfos,
      locale: language.locale
    ) {
      return summary
    }
    switch status {
    case .idle, .loading:
      return L10n.string(.menuBarLoading, language: language)
    case .notConfigured:
      return L10n.string(.menuBarNotConfigured, language: language)
    case .loaded:
      return "—"
    case .keychainError, .authenticationFailed, .insufficientBalance,
      .rateLimited, .httpError, .networkError, .serverError,
      .decodingError, .historyStorageError:
      return L10n.string(.menuBarError, language: language)
    }
  }

  var statusTitle: String {
    switch status {
    case .idle, .loading:
      return L10n.string(.statusLoading, language: language)
    case .loaded:
      return L10n.string(.statusLoaded, language: language)
    case .notConfigured:
      return L10n.string(.statusNotConfigured, language: language)
    case .keychainError:
      return L10n.string(.statusKeychainError, language: language)
    case .authenticationFailed, .rateLimited, .httpError, .networkError,
      .serverError, .decodingError, .historyStorageError:
      return L10n.string(.statusRequestFailed, language: language)
    case .insufficientBalance:
      return L10n.string(.statusInsufficientBalance, language: language)
    }
  }

  // MARK: - 刷新入口

  func refresh(force: Bool = false) async {
    await refreshRequest(force: force, maximumAge: nil)
  }

  private func refreshRequest(force: Bool, maximumAge: TimeInterval?) async {
    guard isEnabled else { return }
    var credentialOverride: ResolvedCredential?

    // 先观察当前凭据是否发生变化，再决定加入现有请求还是替换它。
    // 如果当前凭据尚未解析，直接加入即可；这覆盖启动刷新与生命周期通知
    // 同时到达的情况，避免它们在两个 Keychain 读取完成后各自发起请求。
    if !force, let refreshGateTask {
      if let currentCredentialID {
        do {
          let credential = try await resolveCredential()
          guard let credential else {
            cancelRefreshGate()
            applyNotConfiguredState()
            return
          }

          // refreshIfNeeded 可能在凭据解析期间跨过了新鲜度边界，重新检查一次，
          // 避免首个请求刚完成后又重复发送第二个请求。
          if let maximumAge {
            guard balance == nil
              || clock.now().timeIntervalSince(lastUpdated ?? .distantPast) >= maximumAge
            else {
              return
            }
          }

          if credential.credentialID == currentCredentialID {
            await refreshGateTask.value
            return
          }
          // Keychain 已切换到新凭据：取消旧请求，并复用这次已解析的凭据。
          credentialOverride = credential
        } catch {
          cancelRefreshGate()
          presentKeychainError(error)
          return
        }
      } else {
        await refreshGateTask.value
        return
      }
    }

    if force || refreshGateTask != nil {
      cancelRefreshGate()
    }

    refreshGateGeneration += 1
    let generation = refreshGateGeneration
    let task: Task<Void, Never> = Task { [weak self] in
      guard let self else { return }
      await self.performResolvedRefresh(
        credential: credentialOverride,
        force: force,
        maximumAge: maximumAge
      )
    }
    refreshGateTask = task
    await task.value
    if refreshGateGeneration == generation {
      refreshGateTask = nil
    }
  }

  private func resolveCredential() async throws -> ResolvedCredential? {
    let keyProvider = self.keyProvider
    return try await Task.detached(priority: .utility) {
      try keyProvider.resolveCredential()
    }.value
  }

  private func performResolvedRefresh(
    credential: ResolvedCredential?,
    force: Bool,
    maximumAge: TimeInterval?
  ) async {
    let resolvedCredential: ResolvedCredential?
    do {
      if let credential {
        resolvedCredential = credential
      } else {
        resolvedCredential = try await resolveCredential()
      }
    } catch {
      cancelRefreshGate()
      presentKeychainError(error)
      return
    }

    guard let resolvedCredential else {
      cancelRefreshGate()
      applyNotConfiguredState()
      return
    }

    // refreshIfNeeded 可能在凭据解析期间跨过了新鲜度边界，重新检查一次。
    if let maximumAge {
      guard balance == nil
        || clock.now().timeIntervalSince(lastUpdated ?? .distantPast) >= maximumAge
      else {
        return
      }
    }

    if currentCredentialID != resolvedCredential.credentialID {
      switchCredential(to: resolvedCredential)
    }
    await performRefreshFlow(credential: resolvedCredential, force: force)
  }

  private func performRefreshFlow(
    credential: ResolvedCredential,
    force: Bool
  ) async {
    guard currentCredentialID == credential.credentialID else { return }

    guard coordinator.begin(credentialID: credential.credentialID, force: force) else {
      await coordinator.awaitCurrent()
      return
    }

    let task = Task<Void, Never> { [weak self] in
      _ = await self?.performRefresh(credential: credential)
    }
    let token = coordinator.adopt(task, credentialID: credential.credentialID)
    await task.value
    coordinator.finish(token: token)
  }

  private func cancelRefreshGate() {
    refreshGateGeneration += 1
    refreshGateTask?.cancel()
    refreshGateTask = nil
    coordinator.cancelAll()
  }

  /// 打开菜单时调用：距上次成功超过 maximumAge 秒才刷新。
  func refreshIfNeeded(maximumAge: TimeInterval = 60) async {
    guard balance == nil || clock.now().timeIntervalSince(lastUpdated ?? .distantPast) >= maximumAge
    else {
      return
    }
    await refreshRequest(force: false, maximumAge: maximumAge)
  }

  /// 底部总刷新：并发刷新余额与官方状态，两者错误互不覆盖。
  func refreshAll() async {
    async let balanceRefresh: Void = refresh()
    async let statusRefresh: Void = statusStore?.refreshIfNeeded(maximumAge: 0) ?? ()
    _ = await (balanceRefresh, statusRefresh)
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
      return .failure(.keychain(error.localizedDescription))
    }
  }

  func clearSavedKey() async {
    do {
      try keychainStore.deleteAPIKey()
    } catch {
      lastDisplayError = .keychain(error.localizedDescription)
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
      availableCurrencies = []
      return
    }
    do {
      try await historyService.clear(credentialID: credentialID)
      historySamples = []
      historyDisplayError = nil
      // 清除历史后，当前余额中真实存在的币种仍然保留在 Picker 中。
      updateAvailableCurrencies(response: balance, history: [])
    } catch {
      historyDisplayError = .history(error.localizedDescription)
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
      lastDisplayError = .unknown
      status = .networkError
    }
  }

  private func applySuccess(_ response: BalanceResponse, credential: ResolvedCredential) {
    currentCredentialID = credential.credentialID
    keySource = credential.source
    balance = response
    lastUpdated = clock.now()
    lastDisplayError = nil
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
      lastDisplayError = error.asDisplayError()
    case .insufficientBalance:
      status = .insufficientBalance
      lastDisplayError = error.asDisplayError()
    case .rateLimited:
      status = .rateLimited
      lastDisplayError = error.asDisplayError()
    case .server:
      status = .serverError
      lastDisplayError = error.asDisplayError()
    case .httpError:
      status = .httpError
      lastDisplayError = error.asDisplayError()
    case .noNetwork:
      status = .networkError
      lastDisplayError = error.asDisplayError()
    case .timedOut:
      status = .networkError
      lastDisplayError = error.asDisplayError()
    case .decodingFailed:
      status = .decodingError
      lastDisplayError = error.asDisplayError()
    }
  }

  /// 凭据切换：清空旧账号余额与趋势数据，进入加载状态。
  private func switchCredential(to credential: ResolvedCredential) {
    currentCredentialID = credential.credentialID
    keySource = credential.source
    balance = nil
    lastUpdated = nil
    lastDisplayError = nil
    historySamples = []
    availableCurrencies = []
    selectedCurrency = nil
    historyDisplayError = nil
    status = .loading
  }

  private func applyNotConfiguredState() {
    currentCredentialID = nil
    keySource = .notConfigured
    balance = nil
    lastUpdated = nil
    lastDisplayError = nil
    historySamples = []
    availableCurrencies = []
    selectedCurrency = nil
    historyDisplayError = nil
    status = .notConfigured
  }

  private func presentKeychainError(_ error: Error) {
    // 无法确认凭据：取消请求并清空所有旧账号可见状态，避免残留显示。
    coordinator.cancelAll()
    currentCredentialID = nil
    balance = nil
    lastUpdated = nil
    historySamples = []
    availableCurrencies = []
    selectedCurrency = nil
    historyDisplayError = nil
    keySource = .notConfigured
    status = .keychainError
    lastDisplayError = .keychain(error.localizedDescription)
  }

  private func resolvedSource() -> APIKeySource {
    (try? keyProvider.resolveCredential())?.source ?? .notConfigured
  }

  // MARK: - 历史持久化

  /// 成功刷新后按顺序执行：写入当前桶 → 重新读取 14 天历史 → 更新图表 → 节流清理。
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
      historyDisplayError = nil
    } catch {
      guard currentCredentialID == credentialID else { return }
      historyDisplayError = .history(error.localizedDescription)
    }
    // 清理失败只影响过期数据回收，不影响当前余额与趋势显示。
    try? await historyService.pruneThrottled()
  }

  /// 币种选择只来自真实数据：当前余额响应 + 当前凭据历史，不做无条件 CNY/USD 兜底。
  private func updateAvailableCurrencies(response: BalanceResponse?, history: [BalanceSample]) {
    var ordered: [String] = []
    func append(_ currency: String) {
      if !ordered.contains(currency) {
        ordered.append(currency)
      }
    }
    response?.balanceInfos.map(\.currency).forEach(append)
    Set(history.map(\.currency)).sorted().forEach(append)
    // 排序优先：CNY（若真实存在）、USD（若真实存在），其余按稳定顺序。
    var sorted: [String] = []
    if let cny = ordered.first(where: { $0 == "CNY" }) {
      sorted.append(cny)
    }
    if let usd = ordered.first(where: { $0 == "USD" }) {
      sorted.append(usd)
    }
    sorted.append(contentsOf: ordered.filter { $0 != "CNY" && $0 != "USD" })
    availableCurrencies = sorted
    if let selected = selectedCurrency, sorted.contains(selected) {
      return
    }
    selectedCurrency = sorted.first
  }

  // MARK: - 生命周期

  private func setupLifecycleObservers() {
    let workspaceCenter = NSWorkspace.shared.notificationCenter
    observations.append(
      NotificationObservation(
        center: workspaceCenter,
        token: workspaceCenter.addObserver(
          forName: NSWorkspace.didWakeNotification,
          object: nil,
          queue: .main
        ) { [weak self] _ in
          Task { @MainActor [weak self] in await self?.handleLifecycleEvent() }
        }
      )
    )
    let defaultCenter = NotificationCenter.default
    observations.append(
      NotificationObservation(
        center: defaultCenter,
        token: defaultCenter.addObserver(
          forName: NSApplication.didBecomeActiveNotification,
          object: nil,
          queue: .main
        ) { [weak self] _ in
          Task { @MainActor [weak self] in await self?.handleLifecycleEvent() }
        }
      )
    )
  }

  private func handleLifecycleEvent() async {
    // 合并 wake / active 事件，5 秒内只协调一次刷新。
    let now = clock.now()
    guard now.timeIntervalSince(lastLifecycleEvent) >= 5 else { return }
    lastLifecycleEvent = now
    async let balanceRefresh: Void = refreshIfNeeded(maximumAge: 60)
    async let statusRefresh: Void = statusStore?.refreshIfNeeded(maximumAge: 60) ?? ()
    async let loginSync: Void = loginItemStore?.syncFromSystem() ?? ()
    _ = await (balanceRefresh, statusRefresh, loginSync)
  }

  private static func makeDefaultHistoryService(clock: any DateProviding) -> BalanceHistoryService {
    let base = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first
    guard let base else {
      return BalanceHistoryService(store: UnavailableBalanceHistoryStore(), clock: clock)
    }
    let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.jxz.deepseekbalance"
    let directory = base
      .appendingPathComponent(bundleIdentifier, isDirectory: true)
      .appendingPathComponent("BalanceHistory.leveldb", isDirectory: true)
    let legacyDirectory = base
      .appendingPathComponent("com.example.DeepSeekBalance", isDirectory: true)
      .appendingPathComponent("BalanceHistory.leveldb", isDirectory: true)
    let directoryToOpen =
      FileManager.default.fileExists(atPath: directory.path) ||
      !FileManager.default.fileExists(atPath: legacyDirectory.path)
      ? directory
      : legacyDirectory
    if let store = try? LevelDBBalanceHistoryStore.open(directory: directoryToOpen) {
      return BalanceHistoryService(store: store, clock: clock)
    }
    return BalanceHistoryService(store: UnavailableBalanceHistoryStore(), clock: clock)
  }
}
