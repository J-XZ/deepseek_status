import Foundation

/// 官方服务状态加载阶段（DeepSeek / Codex / Cursor 共用）。
enum ServiceStatusLoadState: Equatable {
  case idle
  case loading
  case loaded
  case unavailable
}

/// 官方服务状态 store 的统一接口，供状态卡片视图消费。
/// 三种供应商（DeepSeek Flashcat、Codex/Cursor Atlassian Statuspage）各自实现，
/// 视图不感知底层协议差异。
@MainActor
protocol ServiceStatusStoring: ObservableObject {
  /// 当前服务状态；首次成功前为 nil。
  var status: DeepSeekServiceStatus? { get }

  /// 加载阶段。
  var loadState: ServiceStatusLoadState { get }

  /// 最近一次成功更新时间。
  var lastSuccessfulUpdate: Date? { get }

  /// 保留旧数据但最近一次请求失败时置为 true。
  var isStale: Bool { get }

  /// 展示用错误；nil 表示无错误。
  var error: AppDisplayError? { get }

  /// 官方状态页 URL（用于“打开官方状态页”按钮）。
  var officialStatusPageURL: URL { get }

  /// 立即刷新。
  func refresh() async

  /// 缓存超过 maximumAge（或从未成功）时刷新。
  func refreshIfNeeded(maximumAge: TimeInterval) async

  /// 打开官方状态页。
  func openOfficialStatusPage()
}
