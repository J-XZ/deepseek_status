import AppKit
import Foundation

/// 官方服务状态状态机：
/// - 有成功数据时保留旧值，失败只标记 stale；
/// - 首次失败显示 unavailable，绝不把“状态接口不可访问”解释为服务宕机。
@MainActor
final class DeepSeekStatusStore: ServiceStatusStoring {
  @Published private(set) var status: DeepSeekServiceStatus?
  @Published private(set) var loadState: ServiceStatusLoadState = .idle
  @Published private(set) var lastSuccessfulUpdate: Date?
  @Published private(set) var isStale = false
  @Published private(set) var error: AppDisplayError?

  let client: any DeepSeekStatusFetching
  let clock: any DateProviding
  let refreshInterval: TimeInterval

  private var refreshTask: Task<Void, Never>?
  private var autoRefreshTask: Task<Void, Never>?
  private var isFetching = false

  let officialStatusPageURL = URL(string: "https://status.deepseek.com/")!

  init(
    client: any DeepSeekStatusFetching = DeepSeekStatusClient(),
    clock: any DateProviding = SystemClock(),
    refreshInterval: TimeInterval = DataRefreshPolicy.autoRefreshInterval,
    startupRefresh: Bool = true
  ) {
    self.client = client
    self.clock = clock
    self.refreshInterval = refreshInterval
    startAutoRefreshIfNeeded()

    if startupRefresh, isEnabled {
      refreshTask = Task { [weak self] in
        await self?.refresh()
      }
    }
  }

  deinit {
    refreshTask?.cancel()
    autoRefreshTask?.cancel()
  }

  // MARK: - 启用/停用

  /// 菜单栏隐藏 DeepSeek 时置为 false：停止后台状态收集；重新显示时恢复并刷新一次。
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
    guard isEnabled, refreshInterval > 0 else { return }
    let interval = refreshInterval
    autoRefreshTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(interval))
        guard !Task.isCancelled else { break }
        await self?.refreshIfNeeded(maximumAge: interval)
      }
    }
  }

  /// 弹出菜单打开时：缓存超过 60 秒（或从未成功）则刷新。
  func refreshIfNeeded(maximumAge: TimeInterval = 60) async {
    guard isEnabled else { return }
    let age: TimeInterval
    if let lastSuccessfulUpdate {
      age = clock.now().timeIntervalSince(lastSuccessfulUpdate)
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
    defer { isFetching = false }

    let previousLoadState = loadState
    if status == nil {
      loadState = .loading
    }

    do {
      let summary = try await client.fetchSummary()
      status = DeepSeekStatusMapper.map(summary)
      lastSuccessfulUpdate = clock.now()
      isStale = false
      error = nil
      loadState = .loaded
    } catch DeepSeekStatusClient.StatusError.cancelled {
      // 取消不改变已有展示。
      loadState = previousLoadState
      return
    } catch {
      if status != nil {
        // 保留上一次成功数据，标记为可能已过期。
        isStale = true
        loadState = .loaded
      } else {
        status = nil
        loadState = .unavailable
      }
      self.error = .serviceStatusUnavailable
    }
  }

  func openOfficialStatusPage() {
    NSWorkspace.shared.open(officialStatusPageURL)
  }
}
