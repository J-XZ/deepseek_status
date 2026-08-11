import SwiftUI
import Combine

/// 通用设置独立小窗：由菜单栏图标右键菜单「设置」打开。
/// 浮动面板样式，不进入 Dock；关闭窗口即收起，内容随 store 自动刷新。
@MainActor
final class SettingsWindow: NSObject {
  private let panel: NSPanel
  private let store: BalanceStore
  private let visibility: MenuBarVendorVisibility
  private var cancellables = Set<AnyCancellable>()

  init(
    store: BalanceStore,
    loginItemStore: LoginItemStore,
    visibility: MenuBarVendorVisibility,
    onVisibilityChange: @escaping (MenuBarVendor) -> Void
  ) {
    self.store = store
    self.visibility = visibility
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.titled, .closable, .utilityWindow],
      backing: .buffered,
      defer: false
    )
    panel.title = L10n.string(.settingsTitle, language: store.language)
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.level = .floating
    panel.contentView = NSHostingView(
      rootView: SettingsView(
        store: store,
        loginItemStore: loginItemStore,
        visibility: visibility,
        onVisibilityChange: onVisibilityChange
      )
    )
    self.panel = panel
    super.init()

    store.objectWillChange
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.updateLayout()
      }
      .store(in: &cancellables)
    visibility.objectWillChange
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.updateLayout()
      }
      .store(in: &cancellables)
  }

  func show() {
    updateTitle()
    resizeToFittingSize()
    if !panel.isVisible {
      panel.center()
    }
    panel.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func updateTitle() {
    panel.title = L10n.string(.settingsTitle, language: store.language)
  }

  /// 语言、可见供应商等变化后，等 SwiftUI 完成布局再按理想尺寸调整窗口，
  /// 避免设置窗口开着时文案变长被裁掉。
  private func updateLayout() {
    updateTitle()
    guard panel.isVisible else { return }
    Task { @MainActor [weak self] in
      await Task.yield()
      self?.resizeToFittingSize()
    }
  }

  private func resizeToFittingSize() {
    guard let hostingView = panel.contentView as? NSHostingView<SettingsView> else { return }
    let fitting = hostingView.fittingSize
    guard fitting.height > 0 else { return }
    let target = NSSize(width: 400, height: fitting.height)
    if panel.contentView?.frame.size != target {
      panel.setContentSize(target)
    }
  }
}
