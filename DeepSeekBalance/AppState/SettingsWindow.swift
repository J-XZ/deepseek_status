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
    let settingsView = SettingsView(
      store: store,
      loginItemStore: loginItemStore,
      visibility: visibility,
      onVisibilityChange: onVisibilityChange
    )
    let hostingController = NSHostingController(rootView: settingsView)
    hostingController.sizingOptions = [.intrinsicContentSize]
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
      styleMask: [.titled, .closable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    panel.title = L10n.string(.settingsTitle, language: store.language)
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.level = .floating
    panel.titlebarAppearsTransparent = true
    panel.titleVisibility = .hidden
    panel.toolbarStyle = .unifiedCompact
    panel.standardWindowButton(.zoomButton)?.isHidden = true
    panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
    panel.isMovableByWindowBackground = true
    // 与主弹窗相同，交给 NSHostingController 管理根视图；直接把 NSHostingView
    // 设为 contentView 会在标题栏透明的 NSPanel 首次展示时丢失布局约束，
    // 表现为窗口存在但 SwiftUI 内容区完全空白。
    panel.contentViewController = hostingController
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
    panel.contentView?.layoutSubtreeIfNeeded()
    resizeToFittingSize()
    if !panel.isVisible {
      panel.center()
    }
    panel.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func updateTitle() {
    panel.title = L10n.string(.settingsTitle, language: store.language)
    panel.appearance = AppVisualStyle.nsAppearance
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
    guard let hostingController = panel.contentViewController as? NSHostingController<SettingsView>
    else { return }
    hostingController.view.layoutSubtreeIfNeeded()
    let fitting = hostingController.view.fittingSize
    guard fitting.height > 0 else { return }
    let target = NSSize(width: 460, height: fitting.height)
    if panel.contentView?.frame.size != target {
      panel.setContentSize(target)
    }
  }
}
