import AppKit
import Combine
import SwiftUI

/// 应用代理：负责创建状态栏控制器。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var statusItemController: StatusItemController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let statusStore = DeepSeekStatusStore()
    let loginItemStore = LoginItemStore()
    let store = BalanceStore(statusStore: statusStore, loginItemStore: loginItemStore)
    statusItemController = StatusItemController(
      store: store,
      statusStore: statusStore,
      loginItemStore: loginItemStore
    )
  }
}

/// 原生状态栏控制器：
/// - 左键：显示 SwiftUI 弹出窗口（余额、趋势、状态、设置）
/// - 右键：显示包含“退出应用”的上下文菜单
@MainActor
final class StatusItemController: NSObject {
  private let store: BalanceStore
  private let statusStore: DeepSeekStatusStore
  private let loginItemStore: LoginItemStore

  private let statusItem: NSStatusItem
  private let popover: NSPopover
  private var cancellables: Set<AnyCancellable> = []

  init(
    store: BalanceStore,
    statusStore: DeepSeekStatusStore,
    loginItemStore: LoginItemStore
  ) {
    self.store = store
    self.statusStore = statusStore
    self.loginItemStore = loginItemStore
    self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    self.popover = NSPopover()
    super.init()

    configureButton()
    configurePopover()
    subscribeToStore()
  }

  // MARK: - 按钮

  private func configureButton() {
    guard let button = statusItem.button else { return }

    if let icon = NSImage(named: "DeepSeekIcon") {
      icon.isTemplate = true
      icon.size = NSSize(width: 14, height: 14)
      button.image = icon
    }
    button.imagePosition = .imageLeading
    button.imageHugsTitle = true
    button.toolTip = L10n.string(.appTitle, language: store.language)
    updateTitle()

    button.target = self
    button.action = #selector(handleStatusItemClick(_:))
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
  }

  private func updateTitle() {
    guard let button = statusItem.button else { return }
    let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    button.attributedTitle = NSAttributedString(
      string: store.menuBarText,
      attributes: [
        .font: font,
        .foregroundColor: NSColor.labelColor,
      ]
    )
    button.setAccessibilityLabel(
      L10n.string(.a11yMenuBar, language: store.language, store.menuBarText)
    )
  }

  // MARK: - 弹窗

  private func configurePopover() {
    let rootView = BalancePopoverView(
      store: store,
      statusStore: statusStore,
      loginItemStore: loginItemStore
    )
    .environment(\.locale, store.language.locale)
    popover.contentViewController = NSHostingController(rootView: rootView)
    popover.contentSize = NSSize(width: 500, height: 620)
    popover.behavior = .transient
  }

  private func togglePopover(_ sender: NSStatusBarButton) {
    if popover.isShown {
      popover.performClose(nil)
    } else {
      popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }
  }

  // MARK: - 右键菜单

  @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
    if NSApp.currentEvent?.type == .rightMouseUp {
      showContextMenu()
    } else {
      togglePopover(sender)
    }
  }

  private func showContextMenu() {
    if popover.isShown {
      popover.performClose(nil)
    }

    let menu = NSMenu()
    let quitItem = NSMenuItem(
      title: L10n.string(.footerQuit, language: store.language),
      action: #selector(quitApp),
      keyEquivalent: ""
    )
    quitItem.target = self
    menu.addItem(quitItem)

    // 临时挂上 menu 并模拟点击以显示菜单，之后还原，避免影响左键弹窗。
    statusItem.menu = menu
    statusItem.button?.performClick(nil)
    statusItem.menu = nil
  }

  @objc private func quitApp() {
    NSApplication.shared.terminate(nil)
  }

  // MARK: - 菜单栏文字更新

  private func subscribeToStore() {
    store.objectWillChange
      .sink { [weak self] _ in
        Task { @MainActor in
          self?.updateTitle()
        }
      }
      .store(in: &cancellables)
  }
}
