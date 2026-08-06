import Foundation

/// Command Code 用量状态机：
/// - 有成功数据时保留旧值，失败只标记错误；
/// - API Key 来自 `~/.commandcode/auth.json`（`cmd login` 写入），失效时提示重新登录。
@MainActor
final class CommandCodeUsageStore: ObservableObject {
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
  @Published private(set) var usage: CommandCodeUsageResponse?
  @Published private(set) var lastUpdated: Date?
  @Published private(set) var isRefreshing = false
  @Published private(set) var lastDisplayError: AppDisplayError?
  @Published private(set) var historySamples: [CommandCodeUsageSample] = []

  let client: any CommandCodeUsageFetching
  let authProvider: any CommandCodeAuthProviding
  let clock: any DateProviding
  let refreshInterval: TimeInterval
  let historyService: CommandCodeHistoryService

  /// Command Code 单账号全局记录：与登录账号对应，固定凭据标识。
  static let credentialID = "commandcode"

  private var isFetching = false
  private var refreshTask: Task<Void, Never>?
  private var autoRefreshTask: Task<Void, Never>?
  private var startupPruneTask: Task<Void, Never>?
  private var autoRefreshInterval: TimeInterval?

  init(
    client: any CommandCodeUsageFetching = CommandCodeUsageClient(),
    authProvider: any CommandCodeAuthProviding = CommandCodeAuthProvider(),
    clock: any DateProviding = SystemClock(),
    refreshInterval: TimeInterval = DataRefreshPolicy.autoRefreshInterval,
    startupRefresh: Bool = true,
    startupPrune: Bool = true,
    autoRefreshInterval: TimeInterval? = DataRefreshPolicy.autoRefreshInterval,
    historyService: CommandCodeHistoryService? = nil
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
        try? await history.pruneAll(before: clock.now().addingTimeInterval(-UsageHistoryWindow.seconds))
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
        await self?.refreshIfNeeded(maximumAge: interval)
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

    let authInfo: CommandCodeAuthInfo
    do {
      authInfo = try authProvider.loadAuthInfo()
    } catch {
      applyAuthFailure(previousStatus: previousStatus)
      return
    }

    do {
      let response = try await client.fetchUsage(apiKey: authInfo.apiKey)
      usage = response
      lastUpdated = clock.now()
      lastDisplayError = nil
      status = .loaded
      await persistHistory(response: response)
    } catch CommandCodeUsageClient.APIError.cancelled {
      status = previousStatus
      return
    } catch let error as CommandCodeUsageClient.APIError {
      applyClientError(error)
    } catch {
      status = .networkError
      lastDisplayError = .noNetwork
    }
  }

  /// 记录本次剩余百分比到历史，并重新加载 14 天样本供折线图使用。
  /// 历史存储失败不影响用量展示（静默丢弃）。
  private func persistHistory(response: CommandCodeUsageResponse) async {
    guard let remainingPercent = response.remainingPercent else { return }
    let history = historyService
    let sample = history.makeSample(
      remainingPercent: remainingPercent,
      daysRemaining: response.daysRemaining,
      windowLimits: response.windowLimits,
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

  private static func makeDefaultHistoryService(clock: any DateProviding) -> CommandCodeHistoryService {
    let base = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first
    guard let base else {
      return CommandCodeHistoryService(
        store: UnavailableCommandCodeHistoryStore(),
        clock: clock
      )
    }
    let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.jxz.deepseekbalance"
    let directory = base.appendingPathComponent(bundleIdentifier, isDirectory: true)
    let fileURL = directory.appendingPathComponent("CommandCodeHistory.json")
    return CommandCodeHistoryService(
      store: CommandCodeHistoryFileStore(fileURL: fileURL),
      clock: clock
    )
  }

  private func applyAuthFailure(previousStatus: Status) {
    if usage != nil {
      // 保留旧数据，标记认证不可用。
      status = .authInvalid
    } else {
      usage = nil
      status = .notConfigured
    }
    lastDisplayError = previousStatus == .loaded ? .commandCodeAuthInvalid : .commandCodeNotConfigured
  }

  private func applyClientError(_ error: CommandCodeUsageClient.APIError) {
    switch error {
    case .cancelled:
      return
    case .unauthorized:
      if usage != nil {
        status = .authInvalid
      } else {
        status = .notConfigured
      }
      lastDisplayError = .commandCodeAuthInvalid
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

  /// 菜单栏 Command Code 部分：剩余百分比 + 与理想用量的差距，例如
  /// `71% (-4%)`。周期信息缺失或时间不在周期内时不显示差距。
  var menuBarText: String {
    if let usage, let remaining = usage.remainingPercent {
      var text = "\(remaining)%"
      if let gap = usage.usageGapPercent {
        text += " (\(gap >= 0 ? "+" : "")\(gap)%)"
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
