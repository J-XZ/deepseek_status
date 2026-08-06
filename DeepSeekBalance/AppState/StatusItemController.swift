import AppKit
import Combine
import QuartzCore
import SwiftUI

/// 菜单栏供应商。
enum MenuBarVendor: Int, CaseIterable {
  case deepseek = 0
  case codex = 1
  case cursor = 2
  case openCode = 3
  case vps = 4
  case commandCode = 5
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
  /// 进度条绿色：低饱和度暗绿（鼠尾草绿），
  /// 避免亮绿色在渐变中过于刺眼、与其他颜色不协调。
  private static let progressGreen = NSColor(
    srgbRed: 0.31,
    green: 0.55,
    blue: 0.33,
    alpha: 1.0
  )
  /// 进度条中间色：浅天蓝，明度与黄/红两色一致（约 0.72），
  /// 避免系统蓝（明度 0.5）在渐变中显得过于浓烈、与其他颜色不协调。
  private static let progressBlue = NSColor(
    srgbRed: 0.45,
    green: 0.75,
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

  /// 余额下跌颜色：$0.5 ↓ → 无色，$2 ↓ → 黄，$5 ↓ → 红，连续插值。
  static func color(forBalanceDrop dropUSD: Double?, isDark: Bool) -> NSColor? {
    guard let dropUSD, dropUSD > 0.5 else { return nil }
    let gap = min(30, max(0, CGFloat(dropUSD - 0.5) / 4.5 * 30))
    return color(for: Int(gap.rounded()), isDark: isDark)
  }

  /// 进度条渐变与菜单栏共用阈值（-10 完全绿 / +10 完全黄 / +30 完全红），
  /// 但把 0 点的中间色从菜单栏的系统白/标签色替换为蓝色，
  /// 并把绿色替换为低饱和度暗绿以适配进度条配色。
  static func progressColor(forGap gap: Double?) -> NSColor? {
    guard let gap, gap.isFinite else { return nil }
    return interpolated(
      value: CGFloat(gap),
      stops: [
        (-greenPeakGap, progressGreen),
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
  static let commandCodeMaxDimension: CGFloat = 13

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
/// 悬浮窗镜像复用同一视图绘制，保持内容一致。
final class MenuBarStatusContentView: NSView {
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
    _ = Self.drawSegments(
      segments,
      in: bounds,
      horizontalPadding: horizontalPadding,
      separatorText: separatorText,
      separatorFont: separatorFont,
      iconTextSpacing: iconTextSpacing
    )
  }

  // MARK: - 公共绘制（菜单栏与悬浮窗共用）

  /// 把一段文字按字体与颜色构造成属性字符串；color 为空时使用默认文本色。
  static func attributedText(
    _ line: String,
    font: NSFont,
    color: NSColor?,
    defaultColor: NSColor = .labelColor
  ) -> NSAttributedString {
    NSAttributedString(
      string: line,
      attributes: [
        .font: font,
        .foregroundColor: color ?? defaultColor
      ]
    )
  }

  /// 按「分段 + 分隔符」布局绘制内容，返回内容总宽度（不含 padding）。
  /// 多行分段按 lineHeight 逐行纵向排布；垂直方向按 bounds 居中。
  /// 菜单栏视图与悬浮窗共用，保证两侧文本布局一致。
  /// defaultTextColor 用于未指定颜色的文本（悬浮窗深色背景上传白色）。
  @discardableResult
  static func drawSegments(
    _ segments: [Segment],
    in bounds: NSRect,
    horizontalPadding: CGFloat,
    separatorText: String,
    separatorFont: NSFont,
    iconTextSpacing: CGFloat = 4,
    defaultTextColor: NSColor = .labelColor
  ) -> CGFloat {
    guard !segments.isEmpty else { return 0 }

    var x = horizontalPadding
    let textColor = defaultTextColor

    for (index, segment) in segments.enumerated() {
      let lines = segment.lines.isEmpty ? [""] : segment.lines
      let iconWidth = segment.icon.map { $0.size.width + iconTextSpacing } ?? 0
      let lineHeight = segment.lineHeight ?? Self.fontLineHeight(segment.font)
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
        let attributedLine = attributedText(
          line,
          font: segment.font,
          color: lineColor,
          defaultColor: defaultTextColor
        )
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

      x += Self.segmentWidth(segment, iconTextSpacing: iconTextSpacing)
      if index < segments.count - 1 {
        let separator = attributedText(separatorText, font: separatorFont, color: textColor)
        let separatorSize = separator.size()
        separator.draw(
          at: NSPoint(
            x: x,
            y: bounds.midY - separatorSize.height / 2
          )
        )
        x += separator.size().width
      }
    }
    return x - horizontalPadding
  }

  private var separatorWidth: CGFloat {
    Self.attributedWidth(separatorText, font: separatorFont)
  }

  private func segmentWidth(_ segment: Segment) -> CGFloat {
    Self.segmentWidth(segment, iconTextSpacing: iconTextSpacing)
  }

  static func segmentWidth(_ segment: Segment, iconTextSpacing: CGFloat) -> CGFloat {
    let textWidth = segment.lines.map {
      attributedWidth($0, font: segment.font)
    }.max() ?? 0
    let iconWidth = segment.icon.map { $0.size.width + iconTextSpacing } ?? 0
    return ceil(iconWidth + textWidth)
  }

  static func attributedWidth(_ text: String, font: NSFont) -> CGFloat {
    NSAttributedString(
      string: text,
      attributes: [.font: font]
    ).size().width
  }

  static func fontLineHeight(_ font: NSFont) -> CGFloat {
    ceil(font.ascender - font.descender + font.leading)
  }
}

/// 弹出窗口尺寸计算：每个供应商页独立决定目标高度，屏幕可用区域决定硬上限。
enum PopoverSizing {
  static let width: CGFloat = 500
  static let horizontalPadding: CGFloat = 14
  static let contentWidth: CGFloat = width - horizontalPadding * 2
  static let fallbackHeight: CGFloat = 820
  /// 给菜单栏、Dock 和窗口边缘留出安全空间，避免小屏上沿/底部贴边。
  static let verticalSafetyMargin: CGFloat = 32

  /// 当前选中供应商页的自然高度；尚未测量到该页时退回默认高度。
  static func pageHeight(
    _ pageHeights: [UsageTab: CGFloat],
    for tab: UsageTab
  ) -> CGFloat {
    pageHeights[tab] ?? fallbackHeight
  }

  static func constrainedHeight(
    pageHeight: CGFloat,
    visibleFrameHeight: CGFloat?
  ) -> CGFloat {
    let targetHeight = pageHeight
    guard let visibleFrameHeight else { return targetHeight }

    let screenLimit = max(1, visibleFrameHeight - verticalSafetyMargin)
    return min(targetHeight, screenLimit)
  }

  /// 异步刷新期间只允许弹窗变大，不允许已显示的弹窗被低估后突然缩小。
  /// 切换供应商标签页时（allowsShrink = true）放行收缩，让窗口平滑缩到新页面
  /// 自己的高度；关闭后重新打开时也会按最新页面高度重新计算。
  static func stableHeight(
    targetHeight: CGFloat,
    currentHeight: CGFloat,
    isPopoverShown: Bool,
    maximumHeight: CGFloat? = nil,
    allowsShrink: Bool = false
  ) -> CGFloat {
    let boundedTarget = maximumHeight.map { min(targetHeight, max(1, $0)) } ?? targetHeight
    guard !allowsShrink, isPopoverShown, currentHeight.isFinite, currentHeight > 0 else {
      return boundedTarget
    }
    let boundedCurrent = maximumHeight.map { min(currentHeight, max(1, $0)) } ?? currentHeight
    return max(boundedTarget, boundedCurrent)
  }

  /// 弹窗内容区域尺寸换算成窗口尺寸：加上箭头/边框差值后窗口才能完整容纳内容。
  static func windowHeight(contentHeight: CGFloat, chromeHeight: CGFloat) -> CGFloat {
    max(1, contentHeight + chromeHeight)
  }

  /// 屏幕可用高度减去安全边距与箭头/边框差值后，内容高度允许的上限。
  static func contentHeightLimit(
    visibleFrameHeight: CGFloat?,
    chromeHeight: CGFloat
  ) -> CGFloat? {
    visibleFrameHeight.map { max(1, $0 - verticalSafetyMargin - chromeHeight) }
  }
}

/// Tab 键切换供应商页的共享状态。视图与控制器共同观察此对象：
/// - 控制器 (StatusItemController) 的键盘监听写入此处，切换窗口高度；
/// - 视图 (BalancePopoverView) 的 @ObservedObject 驱动视图重渲染。
@MainActor
final class PopoverTabSelection: ObservableObject {
  @Published var selectedTab: UsageTab = .deepseek
  /// 固定弹窗：为 true 时失焦不自动关闭弹窗。
  @Published var isPinned = false
}

/// 菜单栏供应商可见性与顺序：UserDefaults 持久化，至少保留一个可见。
/// 作为 ObservableObject 供设置页观察，写入后发送 objectWillChange，
/// 让 SwiftUI 列表随顺序/开关变化立即重绘。
final class MenuBarVendorVisibility: ObservableObject {
  static let deepseekKey = "menuBar.showDeepSeek"
  static let codexKey = "menuBar.showCodex"
  static let cursorKey = "menuBar.showCursor"
  static let openCodeKey = "menuBar.showOpenCode"
  static let vpsKey = "menuBar.showVPS"
  static let commandCodeKey = "menuBar.showCommandCode"
  /// 菜单栏供应商顺序：按 UserDefaults 中保存的 rawValue 序列展开，
  /// 未保存过或包含未知/重复值时按默认顺序兜底。
  static let orderKey = "menuBar.order"

  let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// 供应商在菜单栏与弹窗中的显示顺序，按已保存顺序排列。
  /// 读取时容忍旧版本遗留的不完整/乱序数据：缺失的供应商按声明顺序补在
  /// 末尾，重复值丢弃，保证返回的列表始终是全部供应商的一次排列。
  var orderedVendors: [MenuBarVendor] {
    guard let rawValues = defaults.object(forKey: Self.orderKey) as? [Int] else {
      return MenuBarVendor.allCases
    }
    var result: [MenuBarVendor] = []
    var seen = Set<MenuBarVendor>()
    for raw in rawValues {
      guard let vendor = MenuBarVendor(rawValue: raw), seen.insert(vendor).inserted else {
        continue
      }
      result.append(vendor)
    }
    for vendor in MenuBarVendor.allCases where !seen.contains(vendor) {
      result.append(vendor)
    }
    return result
  }

  /// 可见供应商按菜单栏顺序排列。
  var orderedVisibleVendors: [MenuBarVendor] {
    orderedVendors.filter { isVisible($0) }
  }

  /// 把 visible 供应商顺序作为菜单栏显示顺序保存；隐藏供应商按声明顺序
  /// 补在末尾，保证存储序列始终包含全部供应商。返回调整后的完整顺序。
  @discardableResult
  func move(_ visible: [MenuBarVendor]) -> [MenuBarVendor] {
    let result = completeOrder(visiblePrefix: visible)
    defaults.set(result.map(\.rawValue), forKey: Self.orderKey)
    objectWillChange.send()
    return result
  }

  /// 把 vendor 在可见列表中上移/下移一位（before 语义：移到该位置前）。
  /// 返回调整后的可见顺序；隐藏供应商按声明顺序补在末尾，保证存储完整。
  @discardableResult
  func move(_ vendor: MenuBarVendor, before target: MenuBarVendor?) -> [MenuBarVendor] {
    var list = orderedVisibleVendors
    guard let fromIndex = list.firstIndex(of: vendor) else { return list }
    list.remove(at: fromIndex)
    if let target, let toIndex = list.firstIndex(of: target) {
      list.insert(vendor, at: toIndex)
    } else {
      list.append(vendor)
    }
    defaults.set(completeOrder(visiblePrefix: list).map(\.rawValue), forKey: Self.orderKey)
    objectWillChange.send()
    return list
  }

  /// 把可见前缀补全为包含全部供应商的完整顺序（隐藏项按声明顺序补尾）。
  private func completeOrder(visiblePrefix: [MenuBarVendor]) -> [MenuBarVendor] {
    var result = visiblePrefix
    var seen = Set(result)
    for vendor in MenuBarVendor.allCases where seen.insert(vendor).inserted {
      result.append(vendor)
    }
    return result
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

  var showsCommandCode: Bool {
    defaults.object(forKey: Self.commandCodeKey) as? Bool ?? true
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
    case .commandCode:
      return showsCommandCode
    }
  }

  /// 切换可见性；若切换后全部隐藏则拒绝并返回 false。
  @discardableResult
  func toggle(_ vendor: MenuBarVendor) -> Bool {
    switch vendor {
    case .deepseek:
      let newValue = !showsDeepSeek
      guard newValue || showsCodex || showsCursor || showsOpenCode || showsVPS || showsCommandCode
      else { return false }
      defaults.set(newValue, forKey: Self.deepseekKey)
    case .codex:
      let newValue = !showsCodex
      guard newValue || showsDeepSeek || showsCursor || showsOpenCode || showsVPS || showsCommandCode
      else { return false }
      defaults.set(newValue, forKey: Self.codexKey)
    case .cursor:
      let newValue = !showsCursor
      guard newValue || showsDeepSeek || showsCodex || showsOpenCode || showsVPS || showsCommandCode
      else { return false }
      defaults.set(newValue, forKey: Self.cursorKey)
    case .openCode:
      let newValue = !showsOpenCode
      guard newValue || showsDeepSeek || showsCodex || showsCursor || showsVPS || showsCommandCode
      else { return false }
      defaults.set(newValue, forKey: Self.openCodeKey)
    case .vps:
      let newValue = !showsVPS
      guard newValue || showsDeepSeek || showsCodex || showsCursor || showsOpenCode || showsCommandCode
      else {
        return false
      }
      defaults.set(newValue, forKey: Self.vpsKey)
    case .commandCode:
      let newValue = !showsCommandCode
      guard newValue || showsDeepSeek || showsCodex || showsCursor || showsOpenCode || showsVPS
      else {
        return false
      }
      defaults.set(newValue, forKey: Self.commandCodeKey)
    }
    objectWillChange.send()
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
    let commandCodeStore = CommandCodeUsageStore()
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
    commandCodeStore.setEnabled(visibility.showsCommandCode)
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
      commandCodeStore: commandCodeStore,
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
  private let commandCodeStore: CommandCodeUsageStore
  private let codexStatusStore: StatusPageStatusStore
  private let cursorStatusStore: StatusPageStatusStore

  private let statusItem: NSStatusItem
  private let popover: NSPopover
  private let visibility: MenuBarVendorVisibility
  private var menuBarContentView: MenuBarStatusContentView?
  private let tabSelection = PopoverTabSelection()
  private var vendorPageHeights: [UsageTab: CGFloat] = [:]
  /// 当前选中页（由 tabSelection 驱动，视图层与控制器层统一来源）。
  private var selectedUsageTab: UsageTab { tabSelection.selectedTab }
  private var previousTab: UsageTab = .deepseek
  private var lastSizedTab: UsageTab?
  /// 标签切换后等待新选中页的首个实测值：实测值一到（即使与旧值相同）就
  /// 重算窗口高度；切换瞬间不用旧值/回退值调整，避免窗口先跳错再校正。
  private var awaitingFreshPageHeight = false
  private var lastAppliedPopoverSize = NSSize(
    width: PopoverSizing.width,
    height: PopoverSizing.fallbackHeight
  )
  /// 弹窗窗口相对内容区域的箭头/边框差值，首次展示时在窗口自然排布状态下测量。
  /// 手工窗口动画必须按“内容 + 差值”换算，否则窗口会比内容小，裁掉底部和边缘内容。
  private var popoverChromeHeight: CGFloat = 0
  private lazy var settingsWindow = SettingsWindow(
    store: store,
    loginItemStore: loginItemStore,
    visibility: visibility,
    onVisibilityChange: { [weak self] vendor in
      self?.applyVendorVisibility(vendor)
    }
  )
  /// 悬浮窗：与菜单栏内容镜像，由设置开关启停。
  private lazy var floatingWindow = FloatingStatusWindow()
  /// 悬浮窗悬停趋势小面板：悬停供应商段时浮现对应趋势图。
  private lazy var floatingTrendPopover = FloatingTrendPopover()
  private var cancellables: Set<AnyCancellable> = []
  private var titleUpdateTask: Task<Void, Never>?
  private var popoverDismissObservations: [NotificationObservation] = []
  private var outsideClickMonitor: Any?
  /// Tab 键本地键盘监听（应用激活后接收事件）。
  private var tabKeyLocalMonitor: Any?
  /// Tab 键全局键盘监听（应用未激活时兜底，事件管道不受激活状态影响）。
  private var tabKeyGlobalMonitor: Any?
  private var pendingPopoverSizeTask: Task<Void, Never>?
  /// 同页内容回缩（收起服务状态卡片）时，等高度稳定后放行一次窗口收缩的任务。
  private var shrinkSettleTask: Task<Void, Never>?
  /// 弹窗高度动画任务与代次号：代次号保证只有最新一次动画结束时才清空
  /// 任务引用，避免旧动画结束后误清新动画的引用。
  private var popoverSizeAnimationTask: Task<Void, Never>?
  private var popoverSizeAnimationGeneration = 0

  init(
    store: BalanceStore,
    statusStore: DeepSeekStatusStore,
    loginItemStore: LoginItemStore,
    codexStore: CodexUsageStore,
    cursorStore: CursorUsageStore,
    openCodeStore: OpenCodeUsageStore,
    vpsStore: VPSUsageStore,
    commandCodeStore: CommandCodeUsageStore,
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
    self.commandCodeStore = commandCodeStore
    self.codexStatusStore = codexStatusStore
    self.cursorStatusStore = cursorStatusStore
    self.visibility = visibility
    self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    self.popover = NSPopover()
    super.init()

    configureButton()
    configurePopover()
    subscribeToStore()
    installTabKeyMonitors()
    wireFloatingHover()
    // 标签切换订阅：视图（按钮、Tab 键）与控制器（键盘监听）共用同一
    // tabSelection；任何路径的切换都会触发窗口高度重算。
    tabSelection.$selectedTab.dropFirst().sink { [weak self] tab in
      guard let self, tab != self.previousTab else { return }
      self.previousTab = tab
      self.awaitingFreshPageHeight = true
      self.pendingPopoverSizeTask?.cancel()
      self.shrinkSettleTask?.cancel()
      self.shrinkSettleTask = nil
      // 切换页面后放弃输入焦点：页面内容已整体替换，让焦点留在窗口根部，
      // 避免旧输入框的焦点残留到新页面、或让 Tab 键后续被输入框消费。
      Task { @MainActor [weak self] in
        self?.popover.contentViewController?.view.window?.makeFirstResponder(nil)
      }
    }
    .store(in: &cancellables)
    // 图钉状态订阅：固定时切换为 .applicationDefined，系统不再因点击外部/
    // 失活自动关闭弹窗（.transient 的系统级关闭会绕过 closePopover 的
    // pin 守卫，导致固定失效）；取消固定时恢复 .transient 正常行为。
    tabSelection.$isPinned.dropFirst().sink { [weak self] pinned in
      self?.applyPinBehavior(pinned)
    }
    .store(in: &cancellables)

    // 悬浮窗开关：开启时立即显示并用当前内容填充，关闭时收起。
    // UserDefaults.didChangeNotification 覆盖设置页（同进程）与外部修改。
    if FloatingStatusWindow.isEnabled {
      floatingWindow.show()
    }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(floatingWindowSettingChanged(_:)),
      name: UserDefaults.didChangeNotification,
      object: nil
    )
  }

  /// 悬浮窗开关变化：开启显示（内容在 updateTitle 时同步），关闭隐藏。
  /// UserDefaults 通知可能来自后台线程，统一切回主线程处理。
  @objc private func floatingWindowSettingChanged(_ notification: Notification) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      if FloatingStatusWindow.isEnabled {
        self.floatingWindow.show()
        self.updateTitle()
      } else {
        self.floatingWindow.hide()
        self.floatingTrendPopover.hide()
      }
    }
  }

  /// 悬浮窗悬停接线：悬停供应商段时在其附近浮现趋势图，移出后隐藏。
  private func wireFloatingHover() {
    floatingTrendPopover.chartProvider = { [weak self] vendor in
      self?.trendChartView(for: vendor)
    }
    floatingWindow.hoverContent.onHoverChange = { [weak self] index in
      guard let self else { return }
      guard let index else {
        self.floatingTrendPopover.hide()
        return
      }
      let vendors = self.visibility.orderedVisibleVendors
      guard vendors.indices.contains(index) else { return }
      let vendor = vendors[index]
      // 用悬浮窗所在屏幕定位，避免小图跑到别的屏幕。
      guard let segmentFrame = self.floatingWindow.hoverContent.hoveredSegmentScreenFrame,
        let screen = self.floatingWindow.screen ?? NSScreen.main
      else { return }
      self.floatingTrendPopover.showChart(vendor: vendor, near: segmentFrame, screen: screen)
    }
  }

  /// 按供应商构建趋势图视图（复用弹窗内现有图表），无历史数据时返回空占位。
  private func trendChartView(for vendor: MenuBarVendor) -> AnyView? {
    let language = store.language
    let now = Date()
    let chart: AnyView
    switch vendor {
    case .deepseek:
      let currency = store.selectedCurrency ?? "CNY"
      chart = AnyView(
        BalanceTrendChartView(
          samples: store.historySamples,
          currency: currency,
          language: language,
          now: now
        )
      )
    case .codex:
      chart = AnyView(
        CodexTrendChartView(
          samples: codexStore.historySamples,
          language: language,
          now: now
        )
      )
    case .cursor:
      chart = AnyView(
        CursorTrendChartView(
          samples: cursorStore.historySamples,
          language: language,
          now: now
        )
      )
    case .openCode:
      chart = AnyView(
        OpenCodeTrendChartView(
          samples: openCodeStore.historySamples,
          showGoTrend: openCodeStore.snapshot?.isGoSubscribed == true,
          language: language,
          now: now
        )
      )
    case .vps:
      chart = AnyView(
        VPSTrendChartView(
          samples: vpsStore.historySamples,
          language: language,
          now: now,
          currentRemainingGB: vpsStore.snapshot?.remainingBandwidthGB,
          cycleStart: vpsStore.snapshot?.cycleStart,
          cycleEnd: vpsStore.snapshot?.cycleEnd
        )
      )
    case .commandCode:
      chart = AnyView(
        CommandCodeTrendChartView(
          samples: commandCodeStore.historySamples,
          language: language,
          now: now,
          windowLimits: commandCodeStore.usage?.windowLimits
        )
      )
    }
    return AnyView(chart)
  }

  /// 根据固定状态设置弹窗行为：
  /// - 固定：.applicationDefined，系统不自动关闭，只受手动关闭逻辑控制
  /// - 未固定：.transient，保留原有失焦自动关闭
  private func applyPinBehavior(_ pinned: Bool) {
    popover.behavior = pinned ? .applicationDefined : .transient
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    titleUpdateTask?.cancel()
    pendingPopoverSizeTask?.cancel()
    shrinkSettleTask?.cancel()
    popoverSizeAnimationTask?.cancel()
    for observation in popoverDismissObservations {
      observation.remove()
    }
    if let outsideClickMonitor {
      NSEvent.removeMonitor(outsideClickMonitor)
    }
    if let tabKeyLocalMonitor {
      NSEvent.removeMonitor(tabKeyLocalMonitor)
    }
    if let tabKeyGlobalMonitor {
      NSEvent.removeMonitor(tabKeyGlobalMonitor)
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

    // 过去 24 小时 OpenCode Zen 余额下跌量（正值表示下跌）。
    let openCodeZenDrop24h: Double? = {
      UsageHistoryWindow.change24h(
        samples: openCodeStore.historySamples,
        value: { $0.zenBalanceUSD },
        date: \.bucketStart
      ).map { -$0 }
    }()

    // 过去 24 小时 Vultr 信用额度下跌量（正值表示下跌）。
    let vpsCreditDrop24h: Double? = {
      UsageHistoryWindow.change24h(
        samples: vpsStore.historySamples,
        value: { $0.availableCreditUSD },
        date: \.bucketStart
      ).map { -$0 }
    }()

    // 过去 24 小时 DeepSeek 余额下跌量（正值表示下跌）。
    // 优先按人民币余额折算为美元（汇率按 7 估算），无人民币样本时直接按美元计算。
    let deepseekBalanceDropUSD: Double? = {
      let cnySamples = store.historySamples.filter { $0.currency.uppercased() == "CNY" }
      let usdSamples = store.historySamples.filter { $0.currency.uppercased() == "USD" }
      let source = cnySamples.isEmpty ? usdSamples : cnySamples
      let divisor = cnySamples.isEmpty ? 1.0 : 7.0
      return UsageHistoryWindow.change24h(
        samples: source,
        value: { sample in
          guard let decimal = Decimal(
            string: sample.totalBalance,
            locale: Locale(identifier: "en_US_POSIX")
          ) else { return nil }
          return NSDecimalNumber(decimal: decimal).doubleValue
        },
        date: \.bucketStart
      ).map { -$0 / divisor }
    }()

    // 按供应商构建分段；isDark 控制图标着色与文字颜色插值。
    func buildSegments(isDark: Bool) -> [MenuBarStatusContentView.Segment] {
      visibility.orderedVisibleVendors.map { vendor in
        menuBarSegment(
          for: vendor,
          isDark: isDark,
          openCodeMonthlyGap: openCodeMonthlyGap,
          openCodeZenDrop24h: openCodeZenDrop24h,
          vpsCreditDrop24h: vpsCreditDrop24h,
          deepseekBalanceDropUSD: deepseekBalanceDropUSD,
          font: font,
          cursorFont: cursorFont
        )
      }
    }

    // 悬浮窗镜像：启用后详情全部由悬浮窗承载（始终按深色风格生成以适配
    // 深蓝背景），菜单栏只保留一个 DeepSeek 图标。
    var segments: [MenuBarStatusContentView.Segment]
    if FloatingStatusWindow.isEnabled {
      floatingWindow.setSegments(buildSegments(isDark: true))
      segments = [
        MenuBarStatusContentView.Segment(
          icon: menuBarTintedIcon(
            named: "DeepSeekIcon",
            size: MenuBarIconLayout.deepSeekMaxDimension,
            isDark: isDark
          ),
          lines: [],
          font: font,
          lineHeight: nil,
          verticalInset: 0,
          lineColors: []
        )
      ]
    } else {
      segments = buildSegments(isDark: isDark)
      floatingWindow.setSegments(segments)
    }

    guard let contentView = menuBarContentView else { return }
    contentView.segments = segments
    statusItem.length = contentView.requiredWidth
    contentView.frame = button.bounds

    let visibleVendors = visibility.orderedVisibleVendors
    let labels = visibleVendors.map { vendor -> String in
      switch vendor {
      case .deepseek:
        return L10n.string(.a11yMenuBar, language: store.language, store.menuBarText)
      case .codex:
        return L10n.string(.a11yMenuBarCodex, language: store.language, codexStore.menuBarText)
      case .cursor:
        return L10n.string(.a11yMenuBarCursor, language: store.language, cursorStore.menuBarText)
      case .openCode:
        return L10n.string(
          .a11yMenuBarOpenCode,
          language: store.language,
          openCodeStore.menuBarLines.joined(separator: ", ")
        )
      case .vps:
        return L10n.string(
          .a11yMenuBarVPS,
          language: store.language,
          vpsStore.menuBarLines(language: store.language).joined(separator: ", ")
        )
      case .commandCode:
        return L10n.string(
          .a11yMenuBarCommandCode,
          language: store.language,
          commandCodeStore.menuBarText
        )
      }
    }
    button.setAccessibilityLabel(labels.joined(separator: " | "))
  }

  /// 按供应商构建菜单栏分段。
  private func menuBarSegment(
    for vendor: MenuBarVendor,
    isDark: Bool,
    openCodeMonthlyGap: Int?,
    openCodeZenDrop24h: Double?,
    vpsCreditDrop24h: Double?,
    deepseekBalanceDropUSD: Double?,
    font: NSFont,
    cursorFont: NSFont
  ) -> MenuBarStatusContentView.Segment {
    switch vendor {
    case .deepseek:
      return MenuBarStatusContentView.Segment(
        icon: menuBarTintedIcon(
          named: "DeepSeekIcon",
          size: MenuBarIconLayout.deepSeekMaxDimension,
          isDark: isDark
        ),
        lines: [store.menuBarText],
        font: font,
        lineHeight: nil,
        verticalInset: 0,
        // 余额下跌渐变与 VPS 信用额度一致：≤ $0.5 无色，$2 黄，$5 红。
        lineColors: [
          MenuBarUsageColor.color(forBalanceDrop: deepseekBalanceDropUSD, isDark: isDark)
        ]
      )
    case .codex:
      return MenuBarStatusContentView.Segment(
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
    case .cursor:
      return MenuBarStatusContentView.Segment(
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
    case .openCode:
      return MenuBarStatusContentView.Segment(
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
          MenuBarUsageColor.color(forBalanceDrop: openCodeZenDrop24h, isDark: isDark)
        ]
      )
    case .vps:
      return MenuBarStatusContentView.Segment(
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
          MenuBarUsageColor.color(forBalanceDrop: vpsCreditDrop24h, isDark: isDark)
        ]
      )
    case .commandCode:
      return MenuBarStatusContentView.Segment(
        icon: menuBarTintedIcon(
          named: "CommandCodeIcon",
          size: MenuBarIconLayout.commandCodeMaxDimension,
          isDark: isDark
        ),
        lines: [commandCodeStore.menuBarText],
        font: font,
        lineHeight: nil,
        verticalInset: 0,
        lineColors: [
          MenuBarUsageColor.color(
            for: commandCodeStore.usage?.usageGapPercent,
            isDark: isDark
          )
        ]
      )
    }
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
      commandCodeStore: commandCodeStore,
      codexStatusStore: codexStatusStore,
      cursorStatusStore: cursorStatusStore,
      visibility: visibility,
      tabSelection: tabSelection,
      onPageHeightsChange: { [weak self] pageHeights in
        self?.updatePopoverSize(for: pageHeights)
      }
    )
    .environment(\.locale, store.language.locale)
    let hostingController = NSHostingController(rootView: rootView)
    // NSPopover 每次布局都会按 popover.contentSize 重排窗口，setFrame 会被
    // 顶回旧高度；窗口尺寸由 applyPopoverSize/动画逐帧写 contentSize 与
    // preferredContentSize 独占控制（见 applyPopoverSize 与 animatePopoverHeight）。
    hostingController.sizingOptions = [.intrinsicContentSize]
    popover.contentViewController = hostingController
    popover.contentSize = NSSize(
      width: PopoverSizing.width,
      height: PopoverSizing.fallbackHeight
    )
    // 关闭系统自带缩放过渡：过渡期间整个窗口（含顶部切换栏）会从箭头处
    // 缩放漂移，视觉上就是切换栏在上下乱动。关闭后弹窗原地瞬时出现，
    // 切换栏从第一帧起就钉在最终位置；标签切换的高度变化仍由
    // applyPopoverSize 里的窗口动画平滑过渡（顶部始终固定）。
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
    // 用事件自带的点击位置（全局事件已是屏幕坐标、左下原点），而不是
    // NSEvent.mouseLocation：光标可能停在任何地方（甚至就在弹窗内），
    // 与这次点击的位置无关；用光标位置判断会把弹窗内的点击误判为外部点击
    // 而随机关闭弹窗。
    let point = event.locationInWindow
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
    guard !tabSelection.isPinned else { return }
    shrinkSettleTask?.cancel()
    shrinkSettleTask = nil
    if popover.isShown {
      popover.performClose(nil)
    }
  }

  private func updatePopoverSize(for measured: [UsageTab: CGFloat]) {
    var merged = vendorPageHeights
    var changed = false
    for (tab, height) in measured where height.isFinite && height > 0 {
      if merged[tab] != height {
        merged[tab] = height
        changed = true
      }
    }
    // 标签切换后即使实测值与旧值相同也要重算一次窗口高度（此时窗口还是
    // 上一页的高度）；其余情况只在数值真正变化时处理。
    guard changed
      || (awaitingFreshPageHeight && measured.keys.contains(selectedUsageTab))
    else { return }
    if measured.keys.contains(selectedUsageTab) {
      awaitingFreshPageHeight = false
    }
    vendorPageHeights = merged
    // 数据到达会让页面自然高度在短时间内连续变化多次（图表 loading → 完成、
    // 多供应商并发刷新）；合并成一次平滑调整，避免弹窗尺寸反复跳变。
    pendingPopoverSizeTask?.cancel()
    pendingPopoverSizeTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(160))
      guard !Task.isCancelled else { return }
      self?.applyPopoverSize()
    }
    scheduleShrinkSettleIfNeeded()
  }

  /// 同页内容回缩（如收起服务状态卡片）时，常规路径只允许窗口变大，窗口会
  /// 停留在展开时的最大高度。展开/收起动画期间高度逐帧变化，这里等高度稳定
  /// （期间无新测量、动画已结束）后再放行一次收缩，把窗口缩回新的自然高度；
  /// 任何新测量都会取消并重置这个等待，动画中间帧不会触发收缩。
  private func scheduleShrinkSettleIfNeeded() {
    guard popover.isShown,
      let pageHeight = vendorPageHeights[selectedUsageTab],
      let window = popover.contentViewController?.view.window
    else { return }
    let currentContentHeight = max(0, window.frame.height - popoverChromeHeight)
    guard pageHeight < currentContentHeight - 0.5 else { return }
    shrinkSettleTask?.cancel()
    shrinkSettleTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled, let self, self.popover.isShown else { return }
      self.applyPopoverSize(allowsShrinkOverride: true)
    }
  }

  // MARK: - Tab 键切换供应商页（控制器级监听）

  /// 当前可见的供应商标签页列表（与视图层 visibleTabs 保持一致的排序逻辑）。
  private var visibleTabs: [UsageTab] {
    visibility.orderedVisibleVendors.compactMap { vendor in
      UsageTab.allCases.first { $0.vendor == vendor }
    }
  }

  /// 弹窗展示期间监听 Tab 键的本地与全局监听。在应用初始化时安装一次，
  /// 持续到应用退出；弹窗关闭时 guard popover.isShown 跳过处理，避免
  /// 干扰其他应用或自身设置窗口。本地监听只在应用激活后收到事件，全局
  /// 监听兜底首次打开弹窗时短暂的激活空窗。
  private func installTabKeyMonitors() {
    guard tabKeyLocalMonitor == nil else { return }
    tabKeyLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      self?.handleTabKeyDown(event) ?? event
    }
    tabKeyGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self else { return }
      handleTabKeyDown(event)
    }
  }

  /// 处理 Tab 键切换供应商页。应用激活时本地监听调用此方法并消费事件
  ///（返回 nil）；应用未激活时全局监听调用此方法，事件无法拦截，继续
  /// 送至前台应用（风险仅在首次打开的几十毫秒空窗，可接受）。
  /// Tab 永远只用于切换供应商页，不移动焦点：即使当前焦点在输入框或
  /// 其他控件上，也拦截事件并切换页面，避免焦点漂移后 Tab 失效。
  private func handleTabKeyDown(_ event: NSEvent) -> NSEvent? {
    guard popover.isShown, event.keyCode == 48 else { return event }
    let tabs = visibleTabs
    guard tabs.count > 1, let currentIndex = tabs.firstIndex(of: selectedUsageTab)
    else { return event }
    let backward = event.modifierFlags.contains(.shift)
    let nextIndex = backward
      ? (currentIndex - 1 + tabs.count) % tabs.count
      : (currentIndex + 1) % tabs.count
    tabSelection.selectedTab = tabs[nextIndex]
    return nil
  }

  private func applyPopoverSize(
    for button: NSStatusBarButton? = nil,
    allowsShrinkOverride: Bool = false
  ) {
    let button = button ?? statusItem.button
    guard let button else { return }
    let visibleFrameHeight = button.window?.screen?.visibleFrame.height
      ?? NSScreen.main?.visibleFrame.height
    let pageHeight = PopoverSizing.pageHeight(vendorPageHeights, for: selectedUsageTab)
    guard popover.isShown, let window = popover.contentViewController?.view.window else {
      // 未展示：同步 contentSize，NSPopover 打开时会按此自然排布窗口。
      let height = PopoverSizing.constrainedHeight(
        pageHeight: pageHeight,
        visibleFrameHeight: visibleFrameHeight
      )
      let size = NSSize(width: PopoverSizing.width, height: height)
      guard size != lastAppliedPopoverSize else {
        lastSizedTab = selectedUsageTab
        return
      }
      popover.contentSize = size
      popover.contentViewController?.preferredContentSize = size
      lastAppliedPopoverSize = size
      lastSizedTab = selectedUsageTab
      return
    }
    // 弹窗已展示：目标内容尺寸计算完成后进入逐帧动画。NSPopover 每次布局
    // 都会按 popover.contentSize 重排窗口（顶部贴箭头、底部方向伸缩），
    // 动画每帧同步写 contentSize/preferredContentSize，重排结果即插值高度，
    // 顶部（maxY）始终不变，窗口只从底部方向伸缩，切换栏所在位置固定。
    let chromeHeight = popoverChromeHeight
    let maximumContentHeight = PopoverSizing.contentHeightLimit(
      visibleFrameHeight: visibleFrameHeight,
      chromeHeight: chromeHeight
    )
    let constrained = maximumContentHeight.map {
      min(pageHeight, max(1, $0))
    } ?? pageHeight
    // 页面内容超出屏幕上限（需在弹窗内滚动）：窗口只能到封顶高度，用短动画
    // 快速落定，避免对巨大内容做长时间逐帧同步布局（展开服务状态时抖动）。
    let capped = constrained < pageHeight
    // 只有切换标签页这一条路径允许窗口收缩到新页面高度；
    // 同一页面内数据到达导致的测量变化仍只允许变大。收起服务状态卡片等
    // "内容回缩且已稳定"的场景由 shrinkSettleTask 放行收缩。
    let allowsShrink =
      allowsShrinkOverride || (lastSizedTab != nil && lastSizedTab != selectedUsageTab)
    let currentContentHeight = max(0, window.frame.height - chromeHeight)
    let stableHeight = PopoverSizing.stableHeight(
      targetHeight: constrained,
      currentHeight: currentContentHeight,
      isPopoverShown: true,
      maximumHeight: maximumContentHeight,
      allowsShrink: allowsShrink
    )
    let contentSize = NSSize(width: PopoverSizing.width, height: stableHeight)
    // 已到位判断以窗口实际 frame 为准（不依赖 lastAppliedPopoverSize）：
    // 该值只记录隐藏态的 contentSize，与展示后的真实窗口高度可能脱节，
    // 一旦脱节窗口会永远卡在旧高度上，页面内容溢出并把顶部切换栏挤出。
    let targetHeight = PopoverSizing.windowHeight(
      contentHeight: contentSize.height,
      chromeHeight: chromeHeight
    )
    guard abs(window.frame.height - targetHeight) >= 0.5 else {
      lastSizedTab = selectedUsageTab
      return
    }
    let targetFrame = NSRect(
      x: window.frame.minX,
      y: window.frame.maxY - targetHeight,
      // 宽度保持 NSPopover 打开时的自然宽度（内容 + 两侧箭头/边框），
      // 手工动画只动高度；强行改宽会把边缘内容裁掉。
      width: window.frame.width,
      height: targetHeight
    )
    // 高度变化用逐帧同步动画平滑过渡：animator() 动画由窗口服务器驱动，
    // 主线程的视图布局不与之逐帧同步，内容重排滞后于窗口帧，切换栏在动画
    // 期间漂移；这里改为在主线程逐帧 setFrame 并强制同步布局，每一帧窗口
    // 与内容严格一致。顶部与左缘锁定动画开始时的值，窗口只从底部方向伸缩，
    // 切换栏位置全程固定。
    animatePopoverHeight(to: targetFrame, duration: capped ? 0.12 : 0.22)
    lastSizedTab = selectedUsageTab
  }

  // MARK: - 弹窗高度动画

  /// 逐帧同步动画窗口高度。NSPopover 在每次布局后都会按 popover.contentSize
  /// 重排窗口 frame（顶部贴箭头、从底部方向伸缩），只 setFrame 会在下一次
  /// 布局时被顶回旧高度——上一版“只动 setFrame”的逐帧动画因此完全无效。
  /// 这里每帧先写 popover.contentSize / preferredContentSize 再 setFrame：
  /// NSPopover 重排时用的就是本帧的目标高度，窗口每帧都被放到插值高度上，
  /// 实现底部方向平滑伸缩；顶部（切换栏）始终固定。
  private func animatePopoverHeight(to targetFrame: NSRect, duration: TimeInterval = 0.22) {
    guard popover.isShown, let window = popover.contentViewController?.view.window else {
      return
    }
    let startFrame = window.frame
    guard abs(startFrame.height - targetFrame.height) >= 0.5 else { return }
    popoverSizeAnimationTask?.cancel()
    popoverSizeAnimationGeneration += 1
    let generation = popoverSizeAnimationGeneration
    let startTime = CACurrentMediaTime()
    let chromeHeight = popoverChromeHeight
    let setContentSize: @MainActor (CGFloat) -> Void = { [weak self] height in
      guard let self else { return }
      let contentSize = NSSize(
        width: PopoverSizing.width,
        height: max(1, height - chromeHeight)
      )
      self.popover.contentSize = contentSize
      self.popover.contentViewController?.preferredContentSize = contentSize
    }
    popoverSizeAnimationTask = Task { @MainActor [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        guard popover.isShown, let window = self.popover.contentViewController?.view.window else {
          break
        }
        let progress = min(1, (CACurrentMediaTime() - startTime) / duration)
        let eased = 1 - pow(1 - progress, 3)
        let height = startFrame.height + (targetFrame.height - startFrame.height) * eased
        setContentSize(height)
        window.setFrame(
          NSRect(
            x: startFrame.minX,
            y: startFrame.maxY - height,
            width: startFrame.width,
            height: height
          ),
          display: true
        )
        // 触发布局让 NSPopover 按本帧 contentSize 重排窗口。
        window.contentView?.layoutSubtreeIfNeeded()
        // 每帧都强制移除滚动条：SwiftUI 布局轮次可能重新打开它们，
        // 只在某帧配置一次会在下一帧被覆盖（滚动条闪现导致横向挤压）。
        self.hideScrollIndicatorsInPopover()
        if progress >= 1 {
          setContentSize(targetFrame.height)
          window.setFrame(targetFrame, display: true)
          window.contentView?.layoutSubtreeIfNeeded()
          self.hideScrollIndicatorsInPopover()
          break
        }
        try? await Task.sleep(for: .milliseconds(16))
      }
      if self.popoverSizeAnimationGeneration == generation {
        self.popoverSizeAnimationTask = nil
      }
    }
  }

  private func togglePopover(_ sender: NSStatusBarButton) {
    if popover.isShown {
      closePopover()
    } else {
      applyPinBehavior(tabSelection.isPinned)
      applyPopoverSize(for: sender)
      // LSUIElement 应用展示 NSPopover 时不会自动激活；本地键盘监听（Tab
      // 切换）只在应用激活后收得到事件，先激活再展示，用户无需先点击页面。
      NSApp.activate(ignoringOtherApps: true)
      popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
      // 弹窗刚显示时窗口可能还没完成自然排布；等一帧再测量箭头/边框差值，
      // 保证测到的 contentView 尺寸是 NSPopover 按 contentSize 排布的最终值。
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(150))
        guard let self, popover.isShown else { return }
        self.measurePopoverChrome()
        self.hideScrollIndicatorsInPopover()
      }
    }
  }

  /// 递归移除弹窗内所有 NSScrollView 的滚动条。
  /// 切换供应商页时内容高度变化会让滚动条瞬时出现/消失：legacy 滚动条会
  /// 占据布局宽度把整页向左挤压，overlay 滚动条则覆盖内容右缘，都表现为
  /// “页面左右抖动”。SwiftUI 的 scrollIndicators(.hidden) 在部分系统设置
  /// 下不生效，这里直接从 AppKit 层强制移除，滚动功能保留。
  private func hideScrollIndicatorsInPopover() {
    guard let contentView = popover.contentViewController?.view else { return }
    func visit(_ view: NSView) {
      if let scrollView = view as? NSScrollView {
        scrollView.hasVerticalScroller = false
        scrollView.verticalScroller = nil
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScroller = nil
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
      }
      for subview in view.subviews {
        visit(subview)
      }
    }
    visit(contentView)
  }

  /// 弹窗刚显示时窗口由 NSPopover 按 contentSize 自然排布；此刻窗口与
  /// 内容区域的差值（箭头 + 边框）就是所有手工窗口动画需要补上的余量。
  /// 每次展示都重新测量，窗口重新打开时必然回到自然排布状态。
  private func measurePopoverChrome() {
    guard let window = popover.contentViewController?.view.window,
      let contentView = window.contentView
    else {
      return
    }
    popoverChromeHeight = max(0, window.frame.height - contentView.frame.height)
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
    closePopover()

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
    closePopover()
    settingsWindow.show()
  }

  @objc private func quitApp() {
    NSApplication.shared.terminate(nil)
  }

  /// 可见性或顺序变化后的副作用：启停对应 Store 并刷新菜单栏标题。
  /// 设置页切换开关与调整顺序都会回调到这里。
  private func applyVendorVisibility(_ vendor: MenuBarVendor) {
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
    case .commandCode:
      commandCodeStore.setEnabled(visibility.showsCommandCode)
    }
    updateTitle()
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
    commandCodeStore.objectWillChange
      .sink { [weak self] _ in
        self?.scheduleTitleUpdate()
      }
      .store(in: &cancellables)
  }
}

// MARK: - 菜单栏供应商扩展

extension MenuBarVendor {
  /// 供应商在菜单栏/设置页中的显示名称文案 key。
  var titleKey: L10nKey {
    switch self {
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
    case .commandCode:
      return .menuShowCommandCode
    }
  }
}
