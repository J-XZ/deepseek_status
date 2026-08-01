import AppKit
import Foundation
import ServiceManagement

/// 登录项状态：requiresApproval 不是普通关闭状态，因此不能只用 Bool。
enum LoginItemStatus: Equatable, Sendable {
  case enabled
  case notRegistered
  case requiresApproval
  case notFound
  case error(String)
}

@MainActor
protocol LoginItemManaging: Sendable {
  func currentStatus() async -> LoginItemStatus
  func setEnabled(_ enabled: Bool) async throws -> LoginItemStatus
  func openSystemSettings()
}

/// 基于 SMAppService.mainApp 的真实实现。调用在 @MainActor 上完成。
@MainActor
final class SMAppLoginItemManager: LoginItemManaging {
  func currentStatus() async -> LoginItemStatus {
    switch SMAppService.mainApp.status {
    case .enabled:
      return .enabled
    case .notRegistered:
      return .notRegistered
    case .requiresApproval:
      return .requiresApproval
    case .notFound:
      return .notFound
    @unknown default:
      return .error("unknown status")
    }
  }

  func setEnabled(_ enabled: Bool) async throws -> LoginItemStatus {
    if enabled {
      do {
        try SMAppService.mainApp.register()
      } catch {
        // 已注册视为幂等成功。
        if SMAppService.mainApp.status != .enabled {
          throw error
        }
      }
    } else {
      do {
        try await SMAppService.mainApp.unregister()
      } catch {
        // 已取消视为幂等成功。
        if SMAppService.mainApp.status != .notRegistered {
          throw error
        }
      }
    }
    // 操作后重新读取真实系统状态，不只更新本地 Bool。
    return await currentStatus()
  }

  func openSystemSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }
}

/// 登录项 UI 状态：操作失败后回滚到真实系统状态并展示错误。
@MainActor
final class LoginItemStore: ObservableObject {
  @Published private(set) var status: LoginItemStatus
  @Published private(set) var isUpdating = false
  @Published private(set) var lastError: String?

  private let manager: any LoginItemManaging
  private var observations: [NotificationObservation] = []

  init(
    manager: (any LoginItemManaging)? = nil,
    initialSync: Bool = true
  ) {
    self.manager = manager ?? SMAppLoginItemManager()
    self.status = .notRegistered

    if initialSync {
      Task { [weak self] in
        await self?.syncFromSystem()
      }
    }

    // app didBecomeActive 时重新同步，用户可能在系统设置中修改了登录项。
    let center = NotificationCenter.default
    observations.append(
      NotificationObservation(
        center: center,
        token: center.addObserver(
          forName: NSApplication.didBecomeActiveNotification,
          object: nil,
          queue: .main
        ) { [weak self] _ in
          Task { @MainActor [weak self] in await self?.syncFromSystem() }
        }
      )
    )
  }

  deinit {
    for observation in observations {
      observation.remove()
    }
  }

  func syncFromSystem() async {
    guard !isUpdating else { return }
    status = await manager.currentStatus()
  }

  func setEnabled(_ enabled: Bool) async {
    isUpdating = true
    lastError = nil
    defer { isUpdating = false }
    do {
      status = try await manager.setEnabled(enabled)
    } catch {
      // 失败后回滚到真实系统状态。
      status = await manager.currentStatus()
      lastError = AppDisplayError.sanitized(error.localizedDescription)
    }
  }

  func openSystemSettings() {
    manager.openSystemSettings()
  }
}
