import AppKit
import Foundation

/// Atlassian Statuspage 官方服务状态状态机（Codex / Cursor 共用）。
/// 语义与 DeepSeekStatusStore 一致：保留旧值、失败标记 stale、首次失败显示 unavailable。
@MainActor
final class StatusPageStatusStore: ServiceStatusStoring {
  @Published private(set) var status: DeepSeekServiceStatus?
  @Published private(set) var loadState: ServiceStatusLoadState = .idle
  @Published private(set) var lastSuccessfulUpdate: Date?
  @Published private(set) var isStale = false
  @Published private(set) var error: AppDisplayError?

  let client: any StatusPageFetching
  let clock: any DateProviding
  let refreshInterval: TimeInterval
  let officialStatusPageURL: URL

  private var refreshTask: Task<Void, Never>?
  private var autoRefreshTask: Task<Void, Never>?
  private var isFetching = false

  init(
    client: any StatusPageFetching,
    officialStatusPageURL: URL,
    clock: any DateProviding = SystemClock(),
    refreshInterval: TimeInterval = DataRefreshPolicy.autoRefreshInterval,
    startupRefresh: Bool = true
  ) {
    self.client = client
    self.officialStatusPageURL = officialStatusPageURL
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

  /// 菜单栏隐藏对应供应商时置为 false：停止后台状态收集；重新显示时恢复并刷新一次。
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
      status = StatusPageMapper.map(summary)
      lastSuccessfulUpdate = clock.now()
      isStale = false
      error = nil
      loadState = .loaded
    } catch StatusPageClient.StatusError.cancelled {
      loadState = previousLoadState
      return
    } catch {
      if status != nil {
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
