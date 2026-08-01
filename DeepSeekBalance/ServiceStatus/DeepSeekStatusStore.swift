import AppKit
import Foundation

/// 官方服务状态状态机：
/// - 有成功数据时保留旧值，失败只标记 stale；
/// - 首次失败显示 unavailable，绝不把“状态接口不可访问”解释为服务宕机。
@MainActor
final class DeepSeekStatusStore: ObservableObject {
  enum LoadState: Equatable {
    case idle
    case loading
    case loaded
    case unavailable
  }

  @Published private(set) var status: DeepSeekServiceStatus?
  @Published private(set) var loadState: LoadState = .idle
  @Published private(set) var lastSuccessfulUpdate: Date?
  @Published private(set) var isStale = false
  @Published private(set) var error: AppDisplayError?

  let client: any DeepSeekStatusFetching
  let clock: any DateProviding
  let refreshInterval: TimeInterval

  private var refreshTask: Task<Void, Never>?
  private var isFetching = false

  static let officialStatusPageURL = URL(string: "https://status.deepseek.com/")!

  init(
    client: any DeepSeekStatusFetching = DeepSeekStatusClient(),
    clock: any DateProviding = SystemClock(),
    refreshInterval: TimeInterval = 300,
    startupRefresh: Bool = true
  ) {
    self.client = client
    self.clock = clock
    self.refreshInterval = refreshInterval

    if startupRefresh {
      refreshTask = Task { [weak self] in
        await self?.refresh()
      }
    }
  }

  /// 弹出菜单打开时：缓存超过 60 秒（或从未成功）则刷新。
  func refreshIfNeeded(maximumAge: TimeInterval = 60) async {
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
    NSWorkspace.shared.open(Self.officialStatusPageURL)
  }
}
