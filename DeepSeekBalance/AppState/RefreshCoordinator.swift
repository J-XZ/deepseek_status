import Foundation

/// 刷新协调器：防重复请求、任务替换与取消。
/// 同一凭据同时只有一个有效请求；凭据变化或强制刷新时替换并取消旧任务。
@MainActor
final class RefreshCoordinator {
  var onIsRefreshingChange: ((Bool) -> Void)?

  private(set) var isRefreshing = false {
    didSet {
      if oldValue != isRefreshing {
        onIsRefreshingChange?(isRefreshing)
      }
    }
  }

  private var activeTask: Task<Void, Never>?
  private var activeCredentialID: String?
  private var generation = 0

  /// 返回 false 表示已有同一凭据的任务在进行中且非强制刷新，调用方应加入该任务。
  func begin(credentialID: String, force: Bool) -> Bool {
    if activeTask != nil, activeCredentialID == credentialID, !force {
      return false
    }
    activeTask?.cancel()
    return true
  }

  /// 采纳任务并返回本次代次令牌。同一凭据同时只有一个有效请求；凭据变化或
  /// 强制刷新时替换并取消旧任务。
  func adopt(_ task: Task<Void, Never>, credentialID: String) -> Int {
    activeTask?.cancel()
    generation += 1
    let token = generation
    activeTask = task
    activeCredentialID = credentialID
    isRefreshing = true
    return token
  }

  /// 任务完成后由调用方在主线程同步清理（不再依赖额外的 Task 调度时机，
  /// 避免上一次任务的清理尚未执行时 begin 误判为“仍在刷新”）。
  /// 令牌与当前代次不符时（已被新任务替换或取消）不做任何清理。
  func finish(token: Int) {
    guard token == generation else { return }
    activeTask = nil
    activeCredentialID = nil
    isRefreshing = false
  }

  func awaitCurrent() async {
    await activeTask?.value
  }

  func cancelAll() {
    activeTask?.cancel()
    generation += 1
    activeTask = nil
    activeCredentialID = nil
    isRefreshing = false
  }
}
