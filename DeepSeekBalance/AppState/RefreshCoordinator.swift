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

  func adopt(_ task: Task<Void, Never>, credentialID: String) {
    activeTask?.cancel()
    generation += 1
    let myGeneration = generation
    activeTask = task
    activeCredentialID = credentialID
    isRefreshing = true

    Task { [weak self] in
      _ = await task.value
      guard let self, self.generation == myGeneration else { return }
      self.activeTask = nil
      self.activeCredentialID = nil
      self.isRefreshing = false
    }
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
