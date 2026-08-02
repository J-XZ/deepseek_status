import Foundation

/// Cursor 用量状态机：
/// - 有成功数据时保留旧值，失败只标记错误；
/// - 访问令牌来自 Keychain（`cursor agent login` 写入），失效时提示重新登录。
@MainActor
final class CursorUsageStore: ObservableObject {
  enum Status: Equatable {
    case idle
    case loading
    case loaded
    case notConfigured
    case authInvalid
    case networkError
    case serverError
    case decodingError
  }

  @Published private(set) var status: Status = .idle
  @Published private(set) var usage: CursorUsageResponse?
  @Published private(set) var profile: CursorProfileInfo?
  @Published private(set) var lastUpdated: Date?
  @Published private(set) var isRefreshing = false
  @Published private(set) var lastDisplayError: AppDisplayError?
  @Published private(set) var historySamples: [CursorUsageSample] = []

  let client: any CursorUsageFetching
  let authProvider: any CursorAuthProviding
  let clock: any DateProviding
  let refreshInterval: TimeInterval
  let historyService: CursorHistoryService

  /// Cursor 单账号全局记录：与登录账号对应，固定凭据标识。
  static let credentialID = "cursor"

  private var isFetching = false
  private var refreshTask: Task<Void, Never>?
  private var autoRefreshTask: Task<Void, Never>?
  private var startupPruneTask: Task<Void, Never>?
  private var autoRefreshInterval: TimeInterval?

  init(
    client: any CursorUsageFetching = CursorUsageClient(),
    authProvider: any CursorAuthProviding = CursorAuthProvider(),
    clock: any DateProviding = SystemClock(),
    refreshInterval: TimeInterval = 300,
    startupRefresh: Bool = true,
    startupPrune: Bool = true,
    autoRefreshInterval: TimeInterval? = 300,
    historyService: CursorHistoryService? = nil
  ) {
    self.client = client
    self.authProvider = authProvider
    self.clock = clock
    self.refreshInterval = refreshInterval
    self.historyService = historyService ?? Self.makeDefaultHistoryService(clock: clock)

    // 周期刷新：与余额刷新一致，保证用量与历史记录持续更新。
    self.autoRefreshInterval = autoRefreshInterval
    startAutoRefreshIfNeeded()

    if startupRefresh {
      refreshTask = Task { [weak self] in
        await self?.refresh()
      }
    }

    if startupPrune {
      let history = self.historyService
      let clock = self.clock
      startupPruneTask = Task(priority: .utility) { [weak self] in
        try? await history.pruneAll(before: clock.now().addingTimeInterval(-72 * 3600))
        try? await self?.historyService.pruneThrottled()
      }
    }
  }

  deinit {
    refreshTask?.cancel()
    autoRefreshTask?.cancel()
    startupPruneTask?.cancel()
  }

  // MARK: - 启用/停用

  /// 当前是否允许后台收集用量。菜单栏隐藏该供应商时置为 false：
  /// 停止周期刷新、启动刷新与历史写入；重新显示时恢复并立即刷新一次。
  private(set) var isEnabled = true

  func setEnabled(_ enabled: Bool) {
    guard isEnabled != enabled else { return }
    isEnabled = enabled
    if enabled {
      refreshTask = Task { [weak self] in
        await self?.refresh()
      }
      startAutoRefreshIfNeeded()
    } else {
      refreshTask?.cancel()
      refreshTask = nil
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
        await self?.refreshIfNeeded(maximumAge: 60)
      }
    }
  }

  /// 弹出菜单打开时：缓存超过 maximumAge 秒（或从未成功）则刷新。
  func refreshIfNeeded(maximumAge: TimeInterval = 60) async {
    guard isEnabled else { return }
    let age: TimeInterval
    if let lastUpdated {
      age = clock.now().timeIntervalSince(lastUpdated)
    } else {
      age = .infinity
    }
    guard age >= maximumAge else { return }
    await refresh()
  }

  func refresh() async {
    guard isEnabled else { return }
    guard !isFetching else { return }
    isFetching = true
    isRefreshing = true
    defer {
      isFetching = false
      isRefreshing = false
    }

    let previousStatus = status
    if usage == nil {
      status = .loading
    }

    let authInfo: CursorAuthInfo
    do {
      authInfo = try authProvider.loadAuthInfo()
    } catch {
      applyAuthFailure(previousStatus: previousStatus)
      return
    }

    // 账号资料（订阅方案/邮箱）解析较慢，放到后台执行。
    let profile = await Task.detached { [authProvider] in
      authProvider.loadProfile()
    }.value
    if let profile {
      self.profile = profile
    }

    do {
      let response = try await client.fetchUsage(accessToken: authInfo.accessToken)
      usage = response
      lastUpdated = clock.now()
      lastDisplayError = nil
      status = .loaded
      await persistHistory(
        remainingPercent: response.remainingPercent,
        apiRemainingPercent: response.apiRemainingPercent
      )
    } catch CursorUsageClient.APIError.cancelled {
      status = previousStatus
      return
    } catch let error as CursorUsageClient.APIError {
      applyClientError(error)
    } catch {
      status = .networkError
      lastDisplayError = .noNetwork
    }
  }

  /// 记录本次剩余百分比到历史，并重新加载 72 小时样本供折线图使用。
  /// 历史存储失败不影响用量展示（静默丢弃）。
  private func persistHistory(
    remainingPercent: Int?,
    apiRemainingPercent: Int?
  ) async {
    guard let remainingPercent else { return }
    let history = historyService
    let sample = history.makeSample(
      remainingPercent: remainingPercent,
      apiRemainingPercent: apiRemainingPercent,
      credentialID: Self.credentialID,
      at: clock.now()
    )
    do {
      try await history.save(sample: sample)
      historySamples = try await history.recentSamples(credentialID: Self.credentialID)
    } catch {
      return
    }
    try? await history.pruneThrottled()
  }

  private static func makeDefaultHistoryService(clock: any DateProviding) -> CursorHistoryService {
    let base = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first
    guard let base else {
      return CursorHistoryService(store: UnavailableCursorHistoryStore(), clock: clock)
    }
    let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.jxz.deepseekbalance"
    let directory = base
      .appendingPathComponent(bundleIdentifier, isDirectory: true)
      .appendingPathComponent("CursorHistory.leveldb", isDirectory: true)
    if let store = try? LevelDBCursorHistoryStore.open(directory: directory) {
      return CursorHistoryService(store: store, clock: clock)
    }
    return CursorHistoryService(store: UnavailableCursorHistoryStore(), clock: clock)
  }

  private func applyAuthFailure(previousStatus: Status) {
    if usage != nil {
      // 保留旧数据，标记认证不可用。
      status = .authInvalid
    } else {
      usage = nil
      status = .notConfigured
    }
    lastDisplayError = previousStatus == .loaded ? .cursorAuthInvalid : .cursorNotConfigured
  }

  private func applyClientError(_ error: CursorUsageClient.APIError) {
    switch error {
    case .cancelled:
      return
    case .unauthorized:
      if usage != nil {
        status = .authInvalid
      } else {
        status = .notConfigured
      }
      lastDisplayError = .cursorAuthInvalid
    case .server(let code):
      status = .serverError
      lastDisplayError = .server(code)
    case .httpError(let code):
      status = .serverError
      lastDisplayError = .http(code)
    case .noNetwork:
      status = .networkError
      lastDisplayError = .noNetwork
    case .timedOut:
      status = .networkError
      lastDisplayError = .timeout
    case .decodingFailed:
      status = .decodingError
      lastDisplayError = .decoding
    }
  }

  // MARK: - 菜单栏文字

  /// 菜单栏 Cursor 部分：第一方模型用量 / API 用量，各含与理想用量的差距，例如
  /// `29% (+20%)/61% (-2%)`。`/` 前是第一方模型用量，`/` 后是 API 用量。
  /// 周期信息缺失或时间不在周期内时不显示差距；API 用量不可用时只显示第一方。
  var menuBarText: String {
    if let usage, let remaining = usage.remainingPercent {
      var text = "\(remaining)%"
      if let gap = usage.usageGapPercent {
        text += " (\(gap >= 0 ? "+" : "")\(gap)%)"
      }
      if let apiRemaining = usage.apiRemainingPercent {
        text += "/"
        text += "\(apiRemaining)%"
        if let apiGap = usage.apiUsageGapPercent {
          text += " (\(apiGap >= 0 ? "+" : "")\(apiGap)%)"
        }
      }
      return text
    }
    switch status {
    case .idle, .loading:
      return "…"
    case .loaded:
      return "—"
    case .notConfigured, .authInvalid, .networkError, .serverError, .decodingError:
      return "—"
    }
  }
}
