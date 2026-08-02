import AppKit
import Combine
import SwiftUI

/// 通用设置独立小窗：由菜单栏图标右键菜单「设置」打开。
/// 浮动面板样式，不进入 Dock；关闭窗口即收起，内容随 store 自动刷新。
@MainActor
final class SettingsWindow: NSObject {
  private let panel: NSPanel
  private let store: BalanceStore
  private var cancellables = Set<AnyCancellable>()

  init(store: BalanceStore, loginItemStore: LoginItemStore) {
    self.store = store
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
      rootView: SettingsView(store: store, loginItemStore: loginItemStore)
    )
    self.panel = panel
    super.init()

    store.objectWillChange
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.updateTitle()
      }
      .store(in: &cancellables)
  }

  func show() {
    updateTitle()
    if !panel.isVisible {
      panel.center()
    }
    panel.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func updateTitle() {
    panel.title = L10n.string(.settingsTitle, language: store.language)
  }
}
