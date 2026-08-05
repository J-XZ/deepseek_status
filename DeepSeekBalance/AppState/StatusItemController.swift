import AppKit
import Combine
import SwiftUI

/// 菜单栏供应商。
enum MenuBarVendor: Int, CaseIterable {
  case deepseek = 0
  case codex = 1
  case cursor = 2
  case openCode = 3
  case vps = 4
}

/// 菜单栏数字布局：Cursor 和 OpenCode 的多组用量纵向排列，避免横向挤占空间。
enum MenuBarDisplayLayout {
  static let regularFontSize: CGFloat = 12
  static let cursorFontSize: CGFloat = 9
  static let cursorLineHeight: CGFloat = 10
  static let cursorVerticalInset: CGFloat = 1

  static func cursorText(_ text: String) -> String {
    text.replacingOccurrences(of: "/", with: "\n")
  }

  static func cursorLines(_ text: String) -> [String] {
    cursorText(text).components(separatedBy: "\n")
  }
}

enum MenuBarUsageColor {
  /// 整段连续渐变：-10 及以下完全绿 → 0 系统色 → +10 黄 → +30 红，
  /// 任意相邻颜色之间都做线性插值，不使用固定色彩档位。
  static let greenPeakGap: CGFloat = 10
  static let yellowPeakGap: CGFloat = 10
  static let redPeakGap: CGFloat = 30
  static let colorAlpha: CGFloat = 0.96

  private static let brightGreen = NSColor(
    calibratedRed: 0.55,
    green: 1.0,
    blue: 0.55,
    alpha: 1.0
  )
  private static let brightYellow = NSColor(
    calibratedRed: 1.0,
    green: 0.94,
    blue: 0.58,
    alpha: 1.0
  )
  private static let brightRed = NSColor(
    calibratedRed: 1.0,
    green: 0.64,
    blue: 0.64,
    alpha: 1.0
  )
  private static let progressBlue = NSColor(
    srgbRed: 0.0,
    green: 0.478,
    blue: 1.0,
    alpha: 1.0
  )

  static func color(for gap: Int?, isDark: Bool) -> NSColor? {
    guard let gap else { return nil }
    guard gap != 0 else { return nil }
    let gapValue = CGFloat(gap)
    let baseColor = isDark ? NSColor.white : NSColor.labelColor
    return interpolated(
      value: gapValue,
      stops: [
        (-greenPeakGap, brightGreen),
        (0, baseColor),
        (yellowPeakGap, brightYellow),
        (redPeakGap, brightRed),
      ]
    )
  }

  /// 进度条渐变与菜单栏共用阈值（-10 完全绿 / +10 完全黄 / +30 完全红），
  /// 但把 0 点的中间色从菜单栏的系统白/标签色替换为蓝色。
  static func progressColor(forGap gap: Double?) -> NSColor? {
    guard let gap, gap.isFinite else { return nil }
    return interpolated(
      value: CGFloat(gap),
      stops: [
        (-greenPeakGap, brightGreen),
        (0, progressBlue),
        (yellowPeakGap, brightYellow),
        (redPeakGap, brightRed),
      ]
    )
  }

  /// Vultr 风险分同样使用连续渐变：0（安全）→ 0.5（黄）→ 1（红）。
  static func color(forTrafficRisk risk: Double?, isDark: Bool) -> NSColor? {
    guard let risk, risk.isFinite else { return nil }
    return interpolated(
      value: CGFloat(risk),
      stops: [
        (0, brightGreen),
        (0.5, brightYellow),
        (1, brightRed),
      ]
    )
  }

  /// 在多个颜色停靠点之间按数值线性插值，超出两端时钳制到端点颜色。
  private static func interpolated(
    value: CGFloat,
    stops: [(value: CGFloat, color: NSColor)]
  ) -> NSColor? {
    guard let first = stops.first, let last = stops.last else { return nil }
    let clamped = min(max(value, first.value), last.value)
    for index in 0..<(stops.count - 1) {
      let lower = stops[index]
      let upper = stops[index + 1]
      if clamped <= upper.value {
        let span = upper.value - lower.value
        let fraction = span > 0 ? (clamped - lower.value) / span : 0
        return blend(lower.color, upper.color, fraction: fraction)
          .withAlphaComponent(colorAlpha)
      }
    }
    return last.color.withAlphaComponent(colorAlpha)
  }

  private static func blend(
    _ from: NSColor,
    _ to: NSColor,
    fraction: CGFloat
  ) -> NSColor {
    from.blended(
      withFraction: min(max(fraction, 0), 1),
      of: to
    ) ?? to
  }
}

/// 菜单栏图标布局：按最大边缩放，保持 PDF 图标的原始宽高比。
enum MenuBarIconLayout {
  static let deepSeekMaxDimension: CGFloat = 16
  static let codexMaxDimension: CGFloat = 13
  static let cursorMaxDimension: CGFloat = 13
  static let openCodeMaxDimension: CGFloat = 13
  static let vpsMaxDimension: CGFloat = 13

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
    let lineHeight: CGFloat?
    let verticalInset: CGFloat
    let lineColors: [NSColor?]
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
      let lineHeight = segment.lineHeight ?? fontLineHeight(segment.font)
      let textHeight = lineHeight * CGFloat(lines.count)
      let iconHeight = segment.icon?.size.height ?? 0
      let contentHeight = max(textHeight, iconHeight)
        + segment.verticalInset * 2
      let segmentBottom = max(0, (bounds.height - contentHeight) / 2)
      let textBottom = segmentBottom + (contentHeight - textHeight) / 2
      let textX = x + iconWidth

      for (lineIndex, line) in lines.enumerated() {
        let lineColor = segment.lineColors.indices.contains(lineIndex)
          ? segment.lineColors[lineIndex]
          : nil
        let attributes: [NSAttributedString.Key: Any] = [
          .font: segment.font,
          .foregroundColor: lineColor ?? textColor
        ]
        let attributedLine = NSAttributedString(string: line, attributes: attributes)
        let lineSize = attributedLine.size()
        let lineCenterY = textBottom + textHeight
          - lineHeight * (CGFloat(lineIndex) + 0.5)
        attributedLine.draw(
          at: NSPoint(x: textX, y: lineCenterY - lineSize.height / 2)
        )
      }

      if let icon = segment.icon {
        let iconCenterY = segmentBottom + contentHeight / 2
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
  static let horizontalPadding: CGFloat = 14
  static let contentWidth: CGFloat = width - horizontalPadding * 2
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

  /// 异步刷新期间只允许弹窗变大，不允许已显示的弹窗被低估后突然缩小。
  /// 关闭后重新打开时仍会按最新页面高度重新计算，因此真实内容减少不会永久占用空间。
  static func stableHeight(
    targetHeight: CGFloat,
    currentHeight: CGFloat,
    isPopoverShown: Bool,
    maximumHeight: CGFloat? = nil
  ) -> CGFloat {
    let boundedTarget = maximumHeight.map { min(targetHeight, max(1, $0)) } ?? targetHeight
    guard isPopoverShown, currentHeight.isFinite, currentHeight > 0 else {
      return boundedTarget
    }
    let boundedCurrent = maximumHeight.map { min(currentHeight, max(1, $0)) } ?? currentHeight
    return max(boundedTarget, boundedCurrent)
  }
}

/// 菜单栏供应商可见性：UserDefaults 持久化，至少保留一个可见。
struct MenuBarVendorVisibility {
  static let deepseekKey = "menuBar.showDeepSeek"
  static let codexKey = "menuBar.showCodex"
  static let cursorKey = "menuBar.showCursor"
  static let openCodeKey = "menuBar.showOpenCode"
  static let vpsKey = "menuBar.showVPS"

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

  var showsOpenCode: Bool {
    defaults.object(forKey: Self.openCodeKey) as? Bool ?? true
  }

  var showsVPS: Bool {
    defaults.object(forKey: Self.vpsKey) as? Bool ?? true
  }

  func isVisible(_ vendor: MenuBarVendor) -> Bool {
    switch vendor {
    case .deepseek:
      return showsDeepSeek
    case .codex:
      return showsCodex
    case .cursor:
      return showsCursor
    case .openCode:
      return showsOpenCode
    case .vps:
      return showsVPS
    }
  }

  /// 切换可见性；若切换后全部隐藏则拒绝并返回 false。
  @discardableResult
  func toggle(_ vendor: MenuBarVendor) -> Bool {
    switch vendor {
    case .deepseek:
      let newValue = !showsDeepSeek
      guard newValue || showsCodex || showsCursor || showsOpenCode || showsVPS else { return false }
      defaults.set(newValue, forKey: Self.deepseekKey)
    case .codex:
      let newValue = !showsCodex
      guard newValue || showsDeepSeek || showsCursor || showsOpenCode || showsVPS else { return false }
      defaults.set(newValue, forKey: Self.codexKey)
    case .cursor:
      let newValue = !showsCursor
      guard newValue || showsDeepSeek || showsCodex || showsOpenCode || showsVPS else { return false }
      defaults.set(newValue, forKey: Self.cursorKey)
    case .openCode:
      let newValue = !showsOpenCode
      guard newValue || showsDeepSeek || showsCodex || showsCursor || showsVPS else { return false }
      defaults.set(newValue, forKey: Self.openCodeKey)
    case .vps:
      let newValue = !showsVPS
      guard newValue || showsDeepSeek || showsCodex || showsCursor || showsOpenCode else {
        return false
      }
      defaults.set(newValue, forKey: Self.vpsKey)
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
    let openCodeStore = OpenCodeUsageStore()
    let vpsStore = VPSUsageStore()
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
    openCodeStore.setEnabled(visibility.showsOpenCode)
    vpsStore.setEnabled(visibility.showsVPS)
    codexStatusStore.setEnabled(visibility.showsCodex)
    cursorStatusStore.setEnabled(visibility.showsCursor)
    statusItemController = StatusItemController(
      store: store,
      statusStore: statusStore,
      loginItemStore: loginItemStore,
      codexStore: codexStore,
      cursorStore: cursorStore,
      openCodeStore: openCodeStore,
      vpsStore: vpsStore,
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
  private let openCodeStore: OpenCodeUsageStore
  private let vpsStore: VPSUsageStore
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
  private var titleUpdateTask: Task<Void, Never>?
  private var popoverDismissObservations: [NotificationObservation] = []
  private var outsideClickMonitor: Any?

  init(
    store: BalanceStore,
    statusStore: DeepSeekStatusStore,
    loginItemStore: LoginItemStore,
    codexStore: CodexUsageStore,
    cursorStore: CursorUsageStore,
    openCodeStore: OpenCodeUsageStore,
    vpsStore: VPSUsageStore,
    codexStatusStore: StatusPageStatusStore,
    cursorStatusStore: StatusPageStatusStore,
    visibility: MenuBarVendorVisibility = MenuBarVendorVisibility()
  ) {
    self.store = store
    self.statusStore = statusStore
    self.loginItemStore = loginItemStore
    self.codexStore = codexStore
    self.cursorStore = cursorStore
    self.openCodeStore = openCodeStore
    self.vpsStore = vpsStore
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

  deinit {
    titleUpdateTask?.cancel()
    for observation in popoverDismissObservations {
      observation.remove()
    }
    if let outsideClickMonitor {
      NSEvent.removeMonitor(outsideClickMonitor)
    }
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

  /// 品牌图标在菜单栏统一绘制为白色。
  private func menuBarBrandIcon(named name: String, size: CGFloat) -> NSImage? {
    guard let icon = menuBarIcon(named: name, size: size) else { return nil }
    return tintedImage(icon, color: .white)
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

  /// 菜单栏组合展示：AI 供应商与 Vultr 的剩余用量；多组数值使用较小字体纵向排列。
  /// 被隐藏的供应商不显示。内容视图使用系统标签颜色，图标按当前外观手动着色。
  private func updateTitle() {
    titleUpdateTask?.cancel()
    titleUpdateTask = nil
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

    let openCodeMonthlyGap: Int? = {
      guard let subscription = openCodeStore.snapshot?.goSubscription,
        let monthly = subscription.monthly
      else {
        return nil
      }
      let now = openCodeStore.clock.now()
      return monthly.usageGapPercent(now: now)
        ?? monthly.usageGapPercent(now: now, windowEnd: subscription.renewsAt)
    }()

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
          font: font,
          lineHeight: nil,
          verticalInset: 0,
          lineColors: []
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
          font: font,
          lineHeight: nil,
          verticalInset: 0,
          lineColors: [
            MenuBarUsageColor.color(
              for: codexStore.usage?.usageGapPercent,
              isDark: isDark
            )
          ]
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
          font: cursorFont,
          lineHeight: MenuBarDisplayLayout.cursorLineHeight,
          verticalInset: MenuBarDisplayLayout.cursorVerticalInset,
          lineColors: [
            MenuBarUsageColor.color(
              for: cursorStore.usage?.usageGapPercent,
              isDark: isDark
            ),
            MenuBarUsageColor.color(
              for: cursorStore.usage?.apiUsageGapPercent,
              isDark: isDark
            )
          ]
        )
      )
    }
    if visibility.showsOpenCode {
      segments.append(
        MenuBarStatusContentView.Segment(
          icon: menuBarBrandIcon(
            named: "OpenCodeIcon",
            size: MenuBarIconLayout.openCodeMaxDimension
          ),
          lines: openCodeStore.menuBarLines,
          font: cursorFont,
          lineHeight: MenuBarDisplayLayout.cursorLineHeight,
          verticalInset: MenuBarDisplayLayout.cursorVerticalInset,
          lineColors: [
            MenuBarUsageColor.color(for: openCodeMonthlyGap, isDark: isDark),
            nil
          ]
        )
      )
    }
    if visibility.showsVPS {
      segments.append(
        MenuBarStatusContentView.Segment(
          icon: menuBarBrandIcon(
            named: "VultrIcon",
            size: MenuBarIconLayout.vpsMaxDimension
          ),
          lines: vpsStore.menuBarLines(language: store.language),
          font: cursorFont,
          lineHeight: MenuBarDisplayLayout.cursorLineHeight,
          verticalInset: MenuBarDisplayLayout.cursorVerticalInset,
          lineColors: [
            MenuBarUsageColor.color(
              forTrafficRisk: vpsStore.trafficForecast?.riskScore,
              isDark: isDark
            ),
            nil
          ]
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
    let openCodeLabel = L10n.string(
      .a11yMenuBarOpenCode,
      language: store.language,
      openCodeStore.menuBarLines.joined(separator: ", ")
    )
    let vpsLabel = L10n.string(
      .a11yMenuBarVPS,
      language: store.language,
      vpsStore.menuBarLines(language: store.language).joined(separator: ", ")
    )
    button.setAccessibilityLabel([deepseekLabel, codexLabel, cursorLabel, openCodeLabel, vpsLabel]
      .enumerated()
      .filter { index, _ in
        switch index {
        case 0: return visibility.showsDeepSeek
        case 1: return visibility.showsCodex
        case 2: return visibility.showsCursor
        case 3: return visibility.showsOpenCode
        default: return visibility.showsVPS
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
      openCodeStore: openCodeStore,
      vpsStore: vpsStore,
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
    popover.animates = false
    popover.behavior = .transient
    observePopoverDismissal()
  }

  // MARK: - 失焦自动关闭

  /// 菜单栏辅助应用（LSUIElement）在展示 NSPopover 时不会自动激活自身，
  /// 系统对 .transient 的“点击外部关闭”与“应用失活关闭”都不会可靠触发。
  /// 这里显式补齐三类失焦路径，保证详情页失焦后自动关闭：
  /// - 点击其它应用窗口/桌面：全局事件监控（应用未激活时触发）
  /// - Cmd-Tab 切换、点按 Dock 等导致应用失活：didResignActive
  /// - 弹窗窗口失去 key 状态：didResignKey
  private func observePopoverDismissal() {
    let center = NotificationCenter.default
    popoverDismissObservations.append(
      NotificationObservation(
        center: center,
        token: center.addObserver(
          forName: NSApplication.didResignActiveNotification,
          object: nil,
          queue: .main
        ) { [weak self] _ in
          Task { @MainActor [weak self] in
            self?.closePopover()
          }
        }
      )
    )
    popoverDismissObservations.append(
      NotificationObservation(
        center: center,
        token: center.addObserver(
          forName: NSWindow.didResignKeyNotification,
          object: nil,
          queue: .main
        ) { [weak self] notification in
          Task { @MainActor [weak self] in
            guard let self else { return }
            guard let window = notification.object as? NSWindow,
              window === self.popover.contentViewController?.view.window
            else {
              return
            }
            self.closePopover()
          }
        }
      )
    )
    // 全局监控仅在应用未激活时收到事件；点击位置落在弹窗窗口或状态栏按钮
    // 内时不关闭（分别由弹窗自身激活与按钮 toggle 处理），其余情况全部关闭。
    outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown]
    ) { [weak self] event in
      Task { @MainActor [weak self] in
        self?.handleOutsideClick(event)
      }
    }
  }

  @MainActor
  private func handleOutsideClick(_ event: NSEvent) {
    guard popover.isShown else { return }
    // 全局事件可能来自其它窗口/屏幕，坐标空间容易混淆；
    // NSEvent.mouseLocation 与 NSWindow.frame 同为屏幕坐标（左下原点）。
    let point = NSEvent.mouseLocation
    if let window = popover.contentViewController?.view.window, window.frame.contains(point) {
      return
    }
    if let button = statusItem.button {
      // AX frame 为左上原点，转换到与 point 一致的左下原点。
      let axFrame = button.accessibilityFrame()
      let screenHeight = NSScreen.main?.frame.height ?? 0
      let buttonFrame = CGRect(
        x: axFrame.minX,
        y: screenHeight - axFrame.maxY,
        width: axFrame.width,
        height: axFrame.height
      )
      if buttonFrame.contains(point) {
        return
      }
    }
    closePopover()
  }

  private func closePopover() {
    if popover.isShown {
      popover.performClose(nil)
    }
  }

  private func updatePopoverSize(for pageHeights: [UsageTab: CGFloat]) {
    guard pageHeights != vendorPageHeights else { return }
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
    let stableHeight = PopoverSizing.stableHeight(
      targetHeight: height,
      currentHeight: popover.contentSize.height,
      isPopoverShown: popover.isShown,
      maximumHeight: visibleFrameHeight.map {
        max(1, $0 - PopoverSizing.verticalSafetyMargin)
      }
    )
    let size = NSSize(width: PopoverSizing.width, height: stableHeight)
    popover.contentSize = size
    popover.contentViewController?.preferredContentSize = size
  }

  private func togglePopover(_ sender: NSStatusBarButton) {
    if popover.isShown {
      closePopover()
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
      await openCodeStore.refreshIfNeeded(maximumAge: 0)
      await vpsStore.refreshIfNeeded(maximumAge: 0)
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
    case .openCode:
      openCodeStore.setEnabled(visibility.showsOpenCode)
    case .vps:
      vpsStore.setEnabled(visibility.showsVPS)
    }
    updateTitle()
    showContextMenu()
  }

  // MARK: - 菜单栏文字更新

  /// 将同一轮刷新产生的多次 objectWillChange 合并成一次菜单栏重绘。
  /// 图标模板化、着色和宽度测量都在主线程完成，合并更新可明显降低弹窗打开时的卡顿。
  private func scheduleTitleUpdate() {
    guard titleUpdateTask == nil else { return }
    titleUpdateTask = Task { @MainActor [weak self] in
      await Task.yield()
      guard let self else { return }
      self.titleUpdateTask = nil
      self.updateTitle()
    }
  }

  private func subscribeToStore() {
    store.objectWillChange
      .sink { [weak self] _ in
        self?.scheduleTitleUpdate()
      }
      .store(in: &cancellables)
    codexStore.objectWillChange
      .sink { [weak self] _ in
        self?.scheduleTitleUpdate()
      }
      .store(in: &cancellables)
    cursorStore.objectWillChange
      .sink { [weak self] _ in
        self?.scheduleTitleUpdate()
      }
      .store(in: &cancellables)
    openCodeStore.objectWillChange
      .sink { [weak self] _ in
        self?.scheduleTitleUpdate()
      }
      .store(in: &cancellables)
    vpsStore.objectWillChange
      .sink { [weak self] _ in
        self?.scheduleTitleUpdate()
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
    case .openCode:
      return .menuShowOpenCode
    case .vps:
      return .menuShowVPS
    }
  }
}
