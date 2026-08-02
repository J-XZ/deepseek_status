import AppKit
import Combine
import SwiftUI

/// 菜单栏供应商。
enum MenuBarVendor: Int, CaseIterable {
  case deepseek = 0
  case codex = 1
  case cursor = 2
}

/// 菜单栏数字布局：Cursor 的第一方/API 两组用量纵向排列，避免横向挤占空间。
enum MenuBarDisplayLayout {
  static let regularFontSize: CGFloat = 12
  static let cursorFontSize: CGFloat = 9

  static func cursorText(_ text: String) -> String {
    text.replacingOccurrences(of: "/", with: "\n")
  }

  static func cursorLines(_ text: String) -> [String] {
    cursorText(text).components(separatedBy: "\n")
  }
}

/// 菜单栏图标布局：按最大边缩放，保持 PDF 图标的原始宽高比。
enum MenuBarIconLayout {
  static let deepSeekMaxDimension: CGFloat = 16
  static let codexMaxDimension: CGFloat = 13
  static let cursorMaxDimension: CGFloat = 13

  static func fittingSize(_ imageSize: NSSize, maxDimension: CGFloat) -> NSSize {
    guard imageSize.width > 0, imageSize.height > 0, maxDimension > 0 else {
      return NSSize(width: maxDimension, height: maxDimension)
    }

    let scale = maxDimension / max(imageSize.width, imageSize.height)
    return NSSize(
      width: imageSize.width * scale,
      height: imageSize.height * scale
    )
  }
}

/// 菜单栏内容视图：用明确的几何布局绘制供应商信息，避免 NSStatusBarButton
/// 对多行 attributedTitle 按单行宽度计算而产生截断或错位。
private final class MenuBarStatusContentView: NSView {
  struct Segment {
    let icon: NSImage?
    let lines: [String]
    let font: NSFont
  }

  private let horizontalPadding: CGFloat = 4
  private let iconTextSpacing: CGFloat = 4
  private let separatorText = "  |  "
  private let separatorFont = NSFont.monospacedDigitSystemFont(
    ofSize: MenuBarDisplayLayout.regularFontSize,
    weight: .semibold
  )

  var segments: [Segment] = [] {
    didSet {
      invalidateIntrinsicContentSize()
      needsDisplay = true
    }
  }

  var requiredWidth: CGFloat {
    guard !segments.isEmpty else { return horizontalPadding * 2 }

    let separatorsWidth = separatorWidth * CGFloat(max(segments.count - 1, 0))
    let segmentsWidth = segments.reduce(CGFloat.zero) { partial, segment in
      partial + segmentWidth(segment)
    }
    return ceil(horizontalPadding * 2 + segmentsWidth + separatorsWidth)
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: requiredWidth, height: NSStatusBar.system.thickness)
  }

  // 让外层 NSStatusBarButton 继续接收点击和右键事件。
  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)

    var x = horizontalPadding
    let textColor = NSColor.labelColor

    for (index, segment) in segments.enumerated() {
      let lines = segment.lines.isEmpty ? [""] : segment.lines
      let iconWidth = segment.icon.map { $0.size.width + iconTextSpacing } ?? 0
      let lineHeight = max(
        fontLineHeight(segment.font),
        segment.icon?.size.height ?? 0
      )
      let totalHeight = lineHeight * CGFloat(lines.count)
      let segmentBottom = max(0, (bounds.height - totalHeight) / 2)
      let textX = x + iconWidth

      for (lineIndex, line) in lines.enumerated() {
        let attributes: [NSAttributedString.Key: Any] = [
          .font: segment.font,
          .foregroundColor: textColor
        ]
        let attributedLine = NSAttributedString(string: line, attributes: attributes)
        let lineSize = attributedLine.size()
        let lineCenterY = segmentBottom + totalHeight
          - lineHeight * (CGFloat(lineIndex) + 0.5)
        attributedLine.draw(
          at: NSPoint(x: textX, y: lineCenterY - lineSize.height / 2)
        )
      }

      if let icon = segment.icon {
        let iconCenterY = segmentBottom + totalHeight / 2
        icon.draw(
          in: NSRect(
            x: x,
            y: iconCenterY - icon.size.height / 2,
            width: icon.size.width,
            height: icon.size.height
          ),
          from: .zero,
          operation: .sourceOver,
          fraction: 1
        )
      }

      x += segmentWidth(segment)
      if index < segments.count - 1 {
        let attributes: [NSAttributedString.Key: Any] = [
          .font: separatorFont,
          .foregroundColor: textColor
        ]
        let separator = NSAttributedString(string: separatorText, attributes: attributes)
        let separatorSize = separator.size()
        separator.draw(
          at: NSPoint(
            x: x,
            y: bounds.midY - separatorSize.height / 2
          )
        )
        x += separatorWidth
      }
    }
  }

  private var separatorWidth: CGFloat {
    attributedWidth(separatorText, font: separatorFont)
  }

  private func segmentWidth(_ segment: Segment) -> CGFloat {
    let textWidth = segment.lines.map {
      attributedWidth($0, font: segment.font)
    }.max() ?? 0
    let iconWidth = segment.icon.map { $0.size.width + iconTextSpacing } ?? 0
    return ceil(iconWidth + textWidth)
  }

  private func attributedWidth(_ text: String, font: NSFont) -> CGFloat {
    NSAttributedString(
      string: text,
      attributes: [.font: font]
    ).size().width
  }

  private func fontLineHeight(_ font: NSFont) -> CGFloat {
    ceil(font.ascender - font.descender + font.leading)
  }
}

/// 弹出窗口尺寸计算：页面内容决定目标高度，屏幕可用区域决定硬上限。
enum PopoverSizing {
  static let width: CGFloat = 500
  static let fallbackHeight: CGFloat = 820
  /// 给菜单栏、Dock 和窗口边缘留出安全空间，避免小屏上沿/底部贴边。
  static let verticalSafetyMargin: CGFloat = 32

  static func largestPageHeight(_ pageHeights: [CGFloat]) -> CGFloat {
    pageHeights.max() ?? fallbackHeight
  }

  static func constrainedHeight(
    pageHeights: [CGFloat],
    visibleFrameHeight: CGFloat?
  ) -> CGFloat {
    let targetHeight = largestPageHeight(pageHeights)
    guard let visibleFrameHeight else { return targetHeight }

    let screenLimit = max(1, visibleFrameHeight - verticalSafetyMargin)
    return min(targetHeight, screenLimit)
  }
}

/// 菜单栏供应商可见性：UserDefaults 持久化，至少保留一个可见。
struct MenuBarVendorVisibility {
  static let deepseekKey = "menuBar.showDeepSeek"
  static let codexKey = "menuBar.showCodex"
  static let cursorKey = "menuBar.showCursor"

  let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var showsDeepSeek: Bool {
    defaults.object(forKey: Self.deepseekKey) as? Bool ?? true
  }

  var showsCodex: Bool {
    defaults.object(forKey: Self.codexKey) as? Bool ?? true
  }

  var showsCursor: Bool {
    defaults.object(forKey: Self.cursorKey) as? Bool ?? true
  }

  func isVisible(_ vendor: MenuBarVendor) -> Bool {
    switch vendor {
    case .deepseek:
      return showsDeepSeek
    case .codex:
      return showsCodex
    case .cursor:
      return showsCursor
    }
  }

  /// 切换可见性；若切换后全部隐藏则拒绝并返回 false。
  @discardableResult
  func toggle(_ vendor: MenuBarVendor) -> Bool {
    switch vendor {
    case .deepseek:
      let newValue = !showsDeepSeek
      guard newValue || showsCodex || showsCursor else { return false }
      defaults.set(newValue, forKey: Self.deepseekKey)
    case .codex:
      let newValue = !showsCodex
      guard newValue || showsDeepSeek || showsCursor else { return false }
      defaults.set(newValue, forKey: Self.codexKey)
    case .cursor:
      let newValue = !showsCursor
      guard newValue || showsDeepSeek || showsCodex else { return false }
      defaults.set(newValue, forKey: Self.cursorKey)
    }
    return true
  }
}

/// 应用代理：负责创建状态栏控制器。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var statusItemController: StatusItemController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let visibility = MenuBarVendorVisibility()
    let statusStore = DeepSeekStatusStore()
    let loginItemStore = LoginItemStore()
    let store = BalanceStore(statusStore: statusStore, loginItemStore: loginItemStore)
    let codexStore = CodexUsageStore()
    let cursorStore = CursorUsageStore()
    let codexStatusStore = StatusPageStatusStore(
      client: StatusPageClient(
        baseURL: URL(string: "https://status.openai.com")!
      ),
      officialStatusPageURL: URL(string: "https://status.openai.com")!
    )
    let cursorStatusStore = StatusPageStatusStore(
      client: StatusPageClient(
        baseURL: URL(string: "https://status.cursor.com")!
      ),
      officialStatusPageURL: URL(string: "https://status.cursor.com")!
    )
    // 被隐藏的供应商不显示、不后台收集、不写历史；仅在显示时启停。
    statusStore.setEnabled(visibility.showsDeepSeek)
    store.setEnabled(visibility.showsDeepSeek)
    codexStore.setEnabled(visibility.showsCodex)
    cursorStore.setEnabled(visibility.showsCursor)
    codexStatusStore.setEnabled(visibility.showsCodex)
    cursorStatusStore.setEnabled(visibility.showsCursor)
    statusItemController = StatusItemController(
      store: store,
      statusStore: statusStore,
      loginItemStore: loginItemStore,
      codexStore: codexStore,
      cursorStore: cursorStore,
      codexStatusStore: codexStatusStore,
      cursorStatusStore: cursorStatusStore,
      visibility: visibility
    )
  }
}

/// 原生状态栏控制器：
/// - 左键：显示 SwiftUI 弹出窗口（DeepSeek/Codex 用量、趋势、状态、设置）
/// - 右键：显示包含“退出应用”的上下文菜单
@MainActor
final class StatusItemController: NSObject {
  private let store: BalanceStore
  private let statusStore: DeepSeekStatusStore
  private let loginItemStore: LoginItemStore
  private let codexStore: CodexUsageStore
  private let cursorStore: CursorUsageStore
  private let codexStatusStore: StatusPageStatusStore
  private let cursorStatusStore: StatusPageStatusStore

  private let statusItem: NSStatusItem
  private let popover: NSPopover
  private let visibility: MenuBarVendorVisibility
  private var menuBarContentView: MenuBarStatusContentView?
  private var vendorPageHeights: [UsageTab: CGFloat] = [:]
  private lazy var settingsWindow = SettingsWindow(
    store: store,
    loginItemStore: loginItemStore
  )
  private var cancellables: Set<AnyCancellable> = []

  init(
    store: BalanceStore,
    statusStore: DeepSeekStatusStore,
    loginItemStore: LoginItemStore,
    codexStore: CodexUsageStore,
    cursorStore: CursorUsageStore,
    codexStatusStore: StatusPageStatusStore,
    cursorStatusStore: StatusPageStatusStore,
    visibility: MenuBarVendorVisibility = MenuBarVendorVisibility()
  ) {
    self.store = store
    self.statusStore = statusStore
    self.loginItemStore = loginItemStore
    self.codexStore = codexStore
    self.cursorStore = cursorStore
    self.codexStatusStore = codexStatusStore
    self.cursorStatusStore = cursorStatusStore
    self.visibility = visibility
    self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    self.popover = NSPopover()
    super.init()

    configureButton()
    configurePopover()
    subscribeToStore()
  }

  // MARK: - 按钮

  private func menuBarIcon(named name: String, size: CGFloat) -> NSImage? {
    // NSImage(named:) may return a cached shared instance. Always copy it before
    // changing size so the context-menu icon cannot resize the status-bar icon.
    guard let icon = NSImage(named: name)?.copy() as? NSImage else {
      return nil
    }
    icon.isTemplate = true
    icon.size = MenuBarIconLayout.fittingSize(icon.size, maxDimension: size)
    return icon
  }

  /// attributedTitle 中的附件图像不会走系统的模板渲染（会固定显示为黑色），
  /// 因此按菜单栏当前外观手动着色：浅色菜单栏黑色、深色菜单栏白色。
  private func menuBarTintedIcon(named name: String, size: CGFloat, isDark: Bool) -> NSImage? {
    guard let icon = menuBarIcon(named: name, size: size) else { return nil }
    return tintedImage(icon, color: isDark ? .white : .black)
  }

  private func tintedImage(_ image: NSImage, color: NSColor) -> NSImage {
    let result = NSImage(size: image.size)
    result.lockFocus()
    image.draw(in: NSRect(origin: .zero, size: image.size))
    if let context = NSGraphicsContext.current?.cgContext {
      context.setBlendMode(.sourceAtop)
      color.setFill()
      NSRect(origin: .zero, size: image.size).fill()
    }
    result.unlockFocus()
    return result
  }

  private func configureButton() {
    guard let button = statusItem.button else { return }

    button.imagePosition = .noImage
    button.title = ""
    button.attributedTitle = NSAttributedString(string: "")

    let contentView = MenuBarStatusContentView(frame: button.bounds)
    contentView.autoresizingMask = [.width, .height]
    button.addSubview(contentView)
    menuBarContentView = contentView
    updateTitle()

    button.target = self
    button.action = #selector(handleStatusItemClick(_:))
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
  }

  /// 菜单栏组合展示：`DeepSeek 图标 + 额度 | Codex 图标 + 剩余用量 | Cursor 图标 + 剩余用量`。
  /// Cursor 的第一方/API 两组用量使用较小字体纵向排列。
  /// 被隐藏的供应商不显示。内容视图使用系统标签颜色，图标按当前外观手动着色。
  private func updateTitle() {
    guard let button = statusItem.button else { return }

    let font = NSFont.monospacedDigitSystemFont(
      ofSize: MenuBarDisplayLayout.regularFontSize,
      weight: .semibold
    )
    let cursorFont = NSFont.monospacedDigitSystemFont(
      ofSize: MenuBarDisplayLayout.cursorFontSize,
      weight: .semibold
    )
    button.font = font
    button.toolTip = L10n.string(.appTitle, language: store.language)

    let isDark = (button.window?.effectiveAppearance ?? NSApp.effectiveAppearance)
      .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

    var segments: [MenuBarStatusContentView.Segment] = []
    if visibility.showsDeepSeek {
      segments.append(
        MenuBarStatusContentView.Segment(
          icon: menuBarTintedIcon(
            named: "DeepSeekIcon",
            size: MenuBarIconLayout.deepSeekMaxDimension,
            isDark: isDark
          ),
          lines: [store.menuBarText],
          font: font
        )
      )
    }
    if visibility.showsCodex {
      segments.append(
        MenuBarStatusContentView.Segment(
          icon: menuBarTintedIcon(
            named: "CodexIcon",
            size: MenuBarIconLayout.codexMaxDimension,
            isDark: isDark
          ),
          lines: [codexStore.menuBarText],
          font: font
        )
      )
    }
    if visibility.showsCursor {
      segments.append(
        MenuBarStatusContentView.Segment(
          icon: menuBarTintedIcon(
            named: "CursorIcon",
            size: MenuBarIconLayout.cursorMaxDimension,
            isDark: isDark
          ),
          lines: MenuBarDisplayLayout.cursorLines(cursorStore.menuBarText),
          font: cursorFont
        )
      )
    }

    guard let contentView = menuBarContentView else { return }
    contentView.segments = segments
    statusItem.length = contentView.requiredWidth
    contentView.frame = button.bounds

    let deepseekLabel = L10n.string(
      .a11yMenuBar, language: store.language, store.menuBarText
    )
    let codexLabel = L10n.string(
      .a11yMenuBarCodex, language: store.language, codexStore.menuBarText
    )
    let cursorLabel = L10n.string(
      .a11yMenuBarCursor, language: store.language, cursorStore.menuBarText
    )
    button.setAccessibilityLabel([deepseekLabel, codexLabel, cursorLabel]
      .enumerated()
      .filter { index, _ in
        switch index {
        case 0: return visibility.showsDeepSeek
        case 1: return visibility.showsCodex
        default: return visibility.showsCursor
        }
      }
      .map(\.element)
      .joined(separator: " | "))
  }

  // MARK: - 弹窗

  private func configurePopover() {
    let rootView = BalancePopoverView(
      store: store,
      statusStore: statusStore,
      loginItemStore: loginItemStore,
      codexStore: codexStore,
      cursorStore: cursorStore,
      codexStatusStore: codexStatusStore,
      cursorStatusStore: cursorStatusStore,
      visibility: visibility,
      onPageHeightsChange: { [weak self] pageHeights in
        self?.updatePopoverSize(for: pageHeights)
      }
    )
    .environment(\.locale, store.language.locale)
    popover.contentViewController = NSHostingController(rootView: rootView)
    popover.contentSize = NSSize(
      width: PopoverSizing.width,
      height: PopoverSizing.fallbackHeight
    )
    popover.behavior = .transient
  }

  private func updatePopoverSize(for pageHeights: [UsageTab: CGFloat]) {
    vendorPageHeights = pageHeights
    guard let button = statusItem.button else { return }
    applyPopoverSize(for: button)
  }

  private func applyPopoverSize(for button: NSStatusBarButton) {
    let visibleFrameHeight = button.window?.screen?.visibleFrame.height
      ?? NSScreen.main?.visibleFrame.height
    let height = PopoverSizing.constrainedHeight(
      pageHeights: Array(vendorPageHeights.values),
      visibleFrameHeight: visibleFrameHeight
    )
    let size = NSSize(width: PopoverSizing.width, height: height)
    popover.contentSize = size
    popover.contentViewController?.preferredContentSize = size
  }

  private func togglePopover(_ sender: NSStatusBarButton) {
    if popover.isShown {
      popover.performClose(nil)
    } else {
      applyPopoverSize(for: sender)
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
    menu.autoenablesItems = false

    let header = NSMenuItem(
      title: L10n.string(.appTitle, language: store.language),
      action: nil,
      keyEquivalent: ""
    )
    header.isEnabled = false
    header.image = menuBarIcon(named: "DeepSeekIcon", size: 18)
    menu.addItem(header)
    menu.addItem(.separator())

    let refreshItem = NSMenuItem(
      title: L10n.string(.footerRefresh, language: store.language),
      action: #selector(refreshApp),
      keyEquivalent: "r"
    )
    refreshItem.keyEquivalentModifierMask = [.command]
    refreshItem.target = self
    refreshItem.image = NSImage(
      systemSymbolName: "arrow.clockwise",
      accessibilityDescription: nil
    )
    menu.addItem(refreshItem)

    let openItem = NSMenuItem(
      title: L10n.string(.menuOpenDashboard, language: store.language),
      action: #selector(openDashboard),
      keyEquivalent: "o"
    )
    openItem.keyEquivalentModifierMask = [.command]
    openItem.target = self
    openItem.image = NSImage(
      systemSymbolName: "rectangle.on.rectangle",
      accessibilityDescription: nil
    )
    menu.addItem(openItem)

    let settingsItem = NSMenuItem(
      title: L10n.string(.menuSettings, language: store.language),
      action: #selector(openSettings),
      keyEquivalent: ","
    )
    settingsItem.keyEquivalentModifierMask = [.command]
    settingsItem.target = self
    settingsItem.image = NSImage(
      systemSymbolName: "gearshape",
      accessibilityDescription: nil
    )
    menu.addItem(settingsItem)

    menu.addItem(.separator())

    let visibilityHeader = NSMenuItem(
      title: L10n.string(.menuBarVisibility, language: store.language),
      action: nil,
      keyEquivalent: ""
    )
    visibilityHeader.isEnabled = false
    menu.addItem(visibilityHeader)

    for vendor in MenuBarVendor.allCases {
      let item = NSMenuItem(
        title: L10n.string(
          vendorTitleKey(vendor),
          language: store.language
        ),
        action: #selector(toggleVendorVisibility(_:)),
        keyEquivalent: ""
      )
      item.target = self
      item.state = visibility.isVisible(vendor) ? .on : .off
      item.tag = vendor.rawValue
      menu.addItem(item)
    }

    menu.addItem(.separator())

    let quitItem = NSMenuItem(
      title: L10n.string(.footerQuit, language: store.language),
      action: #selector(quitApp),
      keyEquivalent: "q"
    )
    quitItem.keyEquivalentModifierMask = [.command]
    quitItem.target = self
    quitItem.image = NSImage(
      systemSymbolName: "power",
      accessibilityDescription: nil
    )
    menu.addItem(quitItem)

    // 临时挂上 menu 并模拟点击以显示菜单，之后还原，避免影响左键弹窗。
    statusItem.menu = menu
    statusItem.button?.performClick(nil)
    statusItem.menu = nil
  }

  @objc private func refreshApp() {
    Task {
      await store.refreshAll()
      await codexStore.refreshIfNeeded(maximumAge: 0)
      await cursorStore.refreshIfNeeded(maximumAge: 0)
      await statusStore.refreshIfNeeded(maximumAge: 0)
      await codexStatusStore.refreshIfNeeded(maximumAge: 0)
      await cursorStatusStore.refreshIfNeeded(maximumAge: 0)
    }
  }

  @objc private func openDashboard() {
    guard let button = statusItem.button else { return }
    togglePopover(button)
  }

  @objc private func openSettings() {
    if popover.isShown {
      popover.performClose(nil)
    }
    settingsWindow.show()
  }

  @objc private func quitApp() {
    NSApplication.shared.terminate(nil)
  }

  @objc private func toggleVendorVisibility(_ sender: NSMenuItem) {
    guard let vendor = MenuBarVendor(rawValue: sender.tag) else { return }
    guard visibility.toggle(vendor) else { return }
    switch vendor {
    case .deepseek:
      statusStore.setEnabled(visibility.showsDeepSeek)
      store.setEnabled(visibility.showsDeepSeek)
    case .codex:
      codexStore.setEnabled(visibility.showsCodex)
      codexStatusStore.setEnabled(visibility.showsCodex)
    case .cursor:
      cursorStore.setEnabled(visibility.showsCursor)
      cursorStatusStore.setEnabled(visibility.showsCursor)
    }
    updateTitle()
    showContextMenu()
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
    codexStore.objectWillChange
      .sink { [weak self] _ in
        Task { @MainActor in
          self?.updateTitle()
        }
      }
      .store(in: &cancellables)
    cursorStore.objectWillChange
      .sink { [weak self] _ in
        Task { @MainActor in
          self?.updateTitle()
        }
      }
      .store(in: &cancellables)
  }

  private func vendorTitleKey(_ vendor: MenuBarVendor) -> L10nKey {
    switch vendor {
    case .deepseek:
      return .menuShowDeepSeek
    case .codex:
      return .menuShowCodex
    case .cursor:
      return .menuShowCursor
    }
  }
}
