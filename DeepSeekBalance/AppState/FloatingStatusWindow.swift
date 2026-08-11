import AppKit
import CoreGraphics
import QuartzCore
import SwiftUI

/// 悬浮窗控制器：在所有窗口之上浮动显示与菜单栏完全一致的镜像内容。
/// 可拖动，位置持久化；由设置开关（floatingWindow.enabled）控制启停。
@MainActor
final class FloatingStatusWindow: NSObject {
  // MARK: - 设置持久化

  static let enabledKey = "floatingWindow.enabled"
  static let originKey = "floatingWindow.origin"
  static let snapToMenuBarKey = "floatingWindow.snapToMenuBar"

  static var isEnabled: Bool {
    UserDefaults.standard.bool(forKey: enabledKey)
  }

  static func setEnabled(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: enabledKey)
  }

  /// 是否贴顶菜单栏：开启后窗口始终贴在菜单栏正下方，只允许水平拖动。
  /// 默认开启，首次使用即贴顶，不再落在屏幕底部留一小段。
  static var snapsToMenuBar: Bool {
    if UserDefaults.standard.object(forKey: snapToMenuBarKey) == nil {
      return true
    }
    return UserDefaults.standard.bool(forKey: snapToMenuBarKey)
  }

  static func setSnapsToMenuBar(_ snaps: Bool) {
    UserDefaults.standard.set(snaps, forKey: snapToMenuBarKey)
  }

  private let panel: NSPanel
  private let contentView = FloatingStatusContentView()
  private let obstacleScanner = ScreenObstacleScanner()
  /// 未授权截屏时只引导一次，避免每次双击都打扰。
  private var didShowScreenPermissionPrompt = false

  /// 内容视图：悬停回调等由外部（StatusItemController）接线。
  var hoverContent: FloatingStatusContentView { contentView }

  /// 悬浮窗当前所在屏幕（未显示时为 nil）。
  var screen: NSScreen? { panel.screen }
  private var isFirstShow = true

  override init() {
    let panel = NSPanel(
      contentRect: NSRect(
        x: 0,
        y: 0,
        width: 200,
        height: FloatingStatusContentView.fixedHeight
      ),
      styleMask: [.nonactivatingPanel, .borderless],
      backing: .buffered,
      defer: false
    )
    panel.isFloatingPanel = true
    panel.level = .floating
    // 跟随所有 Space 并在全屏应用之上显示，保证「悬浮在所有窗口前」。
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isMovableByWindowBackground = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    // 透明背景：圆角卡片与内容由内容视图自绘。
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = false
    panel.contentView = contentView
    self.panel = panel
    super.init()

    // 双击：智能选择当前屏幕内遮挡最少的位置。
    contentView.onDoubleClick = { [weak self] in
      self?.smartPosition()
    }

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowDidMove(_:)),
      name: NSWindow.didMoveNotification,
      object: panel
    )
  }

  var isVisible: Bool { panel.isVisible }

  /// 更新镜像内容：按内容宽度重设窗口尺寸，保持窗口中心点不变。
  func setSegments(_ segments: [MenuBarStatusContentView.Segment]) {
    contentView.segments = segments
    let naturalWidth = FloatingStatusContentView.requiredWidth(for: segments)
    let oldFrame = panel.frame
    let width = min(naturalWidth, maximumVisibleWidth)
    var target = clampedToVisibleFrame(
      NSRect(
        x: oldFrame.midX - width / 2,
        y: oldFrame.midY - FloatingStatusContentView.fixedHeight / 2,
        width: width,
        height: FloatingStatusContentView.fixedHeight
      )
    )
    if Self.snapsToMenuBar {
      target.origin.y = snappedOrigin().y
    }
    guard abs(oldFrame.width - target.width) > 0.5
      || abs(oldFrame.height - target.height) > 0.5
      || abs(oldFrame.minX - target.minX) > 0.5
      || abs(oldFrame.minY - target.minY) > 0.5
    else { return }
    panel.setFrame(
      target,
      display: true
    )
  }

  func show() {
    guard !panel.isVisible else { return }
    if isFirstShow {
      isFirstShow = false
      let origin: NSPoint
      if Self.snapsToMenuBar {
        origin = snappedOrigin()
      } else {
        origin = clampedToVisibleFrame(
          NSRect(origin: restoredOrigin ?? defaultOrigin, size: panel.frame.size)
        ).origin
      }
      panel.setFrameOrigin(origin)
    } else {
      var origin = clampedToVisibleFrame(panel.frame).origin
      if Self.snapsToMenuBar {
        origin.y = snappedOrigin().y
      }
      panel.setFrameOrigin(origin)
    }
    panel.orderFrontRegardless()
  }

  func hide() {
    panel.orderOut(nil)
    contentView.hideContextPopover()
    contentView.cancelPendingInteraction()
  }

  /// 贴顶模式下把窗口吸回菜单栏下方；自由模式不做任何事。
  /// 切换设置或外部改变位置后调用，保证设置页/右键开关立即生效。
  func applySnapToMenuBarIfNeeded() {
    guard Self.snapsToMenuBar else { return }
    let targetY = snappedOrigin().y
    guard abs(panel.frame.minY - targetY) > 0.5 else { return }
    var origin = panel.frame.origin
    origin.y = targetY
    panel.setFrameOrigin(origin)
  }

  /// 双击智能定位：只在当前屏幕内计算，移动后沿用现有位置持久化机制。
  func smartPosition() {
    let currentFrame = panel.frame
    let screens = NSScreen.screens.map(Self.geometry(for:))
    let fallback = NSScreen.screens.firstIndex { $0 === (panel.screen ?? NSScreen.main) }
    let snapshot = screenSnapshot(for: screens[bestScreenIndexOrFirst(screens: screens, frame: currentFrame, fallback: fallback)])
    guard let index = FloatingPlacement.bestScreenIndex(
      frame: currentFrame,
      screens: screens,
      fallback: fallback
    ), screens.indices.contains(index),
      let origin = FloatingPlacement.bestOrigin(
        frame: currentFrame,
        screen: screens[index],
        snappedToMenuBar: Self.snapsToMenuBar,
        snapshot: snapshot,
        currentOrigin: currentFrame.origin
      )
    else { return }

    guard abs(origin.x - currentFrame.minX) > 0.5
      || abs(origin.y - currentFrame.minY) > 0.5
    else { return }

    let target = CGRect(origin: origin, size: currentFrame.size)
    // 短而克制的移动动画；不改变窗口层级，目标位置已由纯逻辑钳制在当前屏幕内。
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.18
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      panel.animator().setFrame(target, display: true)
    }
  }

  private func bestScreenIndexOrFirst(
    screens: [FloatingScreenGeometry],
    frame: CGRect,
    fallback: Int?
  ) -> Int {
    FloatingPlacement.bestScreenIndex(
      frame: frame,
      screens: screens,
      fallback: fallback
    ) ?? 0
  }

  /// 截屏优先；未授权或采集失败时回退 CGWindow 列表，再不行返回空（纯逻辑降级）。
  private func screenSnapshot(for screen: FloatingScreenGeometry) -> ScreenSnapshot {
    guard let nsScreen = NSScreen.screens.first(where: {
      FloatingPlacement.sameRect($0.visibleFrame, screen.visibleFrame)
    }) else {
      return ScreenSnapshot(obstacles: windowObstacles(), darkRegions: [])
    }

    if !ScreenObstacleScanner.hasScreenCaptureAccess {
      promptForScreenCaptureIfNeeded()
    }
    if ScreenObstacleScanner.hasScreenCaptureAccess,
      let snapshot = obstacleScanner.captureSnapshot(screen: nsScreen)
    {
      return snapshot
    }
    return ScreenSnapshot(obstacles: windowObstacles(), darkRegions: [])
  }

  private func promptForScreenCaptureIfNeeded() {
    guard !didShowScreenPermissionPrompt else { return }
    didShowScreenPermissionPrompt = true
    // 首次调用会让系统弹出屏幕录制授权框；若系统已决定拒绝，
    // CGRequestScreenCaptureAccess() 返回 false，再展示自定义引导。
    if CGRequestScreenCaptureAccess() {
      return
    }
    let alert = NSAlert()
    alert.messageText = L10n.string(.screenPermissionTitle, language: AppLanguage.initial())
    alert.informativeText = L10n.string(
      .screenPermissionMessage,
      language: AppLanguage.initial()
    )
    alert.addButton(withTitle: L10n.string(.screenPermissionOpenSettings, language: AppLanguage.initial()))
    alert.addButton(withTitle: L10n.string(.actionCancel, language: AppLanguage.initial()))
    if alert.runModal() == .alertFirstButtonReturn {
      if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
        NSWorkspace.shared.open(url)
      }
    }
  }

  private static func geometry(for screen: NSScreen) -> FloatingScreenGeometry {
    let insets = screen.safeAreaInsets
    return FloatingScreenGeometry(
      visibleFrame: screen.visibleFrame,
      safeAreaInsets: FloatingSafeAreaInsets(
        top: insets.top,
        left: insets.left,
        bottom: insets.bottom,
        right: insets.right
      )
    )
  }

  /// 收集除本应用窗口外的其他可见窗口作为遮挡障碍。
  /// CGWindow 信息可能受系统权限限制，获取失败时返回空数组，由纯逻辑降级。
  private func windowObstacles() -> [ScreenObstacle] {
    guard let info = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements],
      kCGNullWindowID
    ) as? [[String: Any]] else {
      return []
    }
    let ownNumbers = Set(NSApp.windows.compactMap { window -> CGWindowID? in
      let number = window.windowNumber
      guard number >= 0, let id = CGWindowID(exactly: number) else { return nil }
      return id
    })
    var rects: [ScreenObstacle] = []
    for entry in info {
      guard let number = (entry[kCGWindowNumber as String] as? NSNumber)?.intValue,
        number >= 0,
        !ownNumbers.contains(CGWindowID(number))
      else { continue }
      if let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha <= 0 {
        continue
      }
      if let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue, layer < 0 {
        continue
      }
      guard let bounds = entry[kCGWindowBounds as String] as? [String: Any],
        let x = (bounds["X"] as? NSNumber)?.doubleValue,
        let y = (bounds["Y"] as? NSNumber)?.doubleValue,
        let width = (bounds["Width"] as? NSNumber)?.doubleValue,
        let height = (bounds["Height"] as? NSNumber)?.doubleValue
      else { continue }
      let rect = CGRect(x: x, y: y, width: width, height: height)
      guard rect.width > 0, rect.height > 0,
        rect.width < 100_000, rect.height < 100_000
      else { continue }
      // CGWindow 坐标是左上原点，悬浮窗 frame/visibleFrame 是左下原点，
      // 必须翻转 y 后再参与遮挡评分，否则会把上下方向判断反。
      let globalMaxY = NSScreen.screens.map(\.frame.maxY).max() ?? rect.maxY
      rects.append(
        ScreenObstacle(
          rect: FloatingPlacement.appKitRect(fromCG: rect, globalMaxY: globalMaxY),
          darkRatio: 0
        )
      )
    }
    return rects
  }

  // MARK: - 位置

  private var restoredOrigin: NSPoint? {
    guard let raw = UserDefaults.standard.string(forKey: Self.originKey) else { return nil }
    let parts = raw.split(separator: ",").compactMap { Double($0) }
    guard parts.count == 2, let x = parts.first, let y = parts.last else { return nil }
    return NSPoint(x: x, y: y)
  }

  /// 可见区域宽度上限：内容宽于屏幕时截断为屏幕可容纳宽度，避免负坐标越界。
  private var maximumVisibleWidth: CGFloat {
    let width = visibleFrame?.width ?? 800
    return max(80, width - 16)
  }

  /// 把窗口 frame 钳制到所在屏幕可见区域内，宽高超出时压缩并留 8pt 边距。
  private func clampedToVisibleFrame(_ frame: NSRect) -> NSRect {
    guard let visible = visibleFrame else { return frame }
    let width = min(frame.width, max(80, visible.width - 16))
    let height = min(frame.height, max(40, visible.height - 16))
    let minX = visible.minX + 8
    let minY = visible.minY + 8
    let maxX = max(minX, visible.maxX - 8 - width)
    let maxY = max(minY, visible.maxY - 8 - height)
    return NSRect(
      x: min(max(frame.minX, minX), maxX),
      y: min(max(frame.minY, minY), maxY),
      width: width,
      height: height
    )
  }

  private var visibleFrame: NSRect? {
    (panel.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
  }

  /// 贴顶位置：窗口顶部贴着菜单栏下沿，x 保留上次位置（首次为右上角）。
  private func snappedOrigin() -> NSPoint {
    guard let visible = visibleFrame else { return panel.frame.origin }
    let width = min(panel.frame.width, max(80, visible.width - 16))
    let storedX = restoredOrigin?.x
    let defaultX = visible.maxX - width - 20
    let minX = visible.minX + 8
    let maxX = max(minX, visible.maxX - 8 - width)
    return NSPoint(
      x: min(max(storedX ?? defaultX, minX), maxX),
      y: visible.maxY - panel.frame.height
    )
  }

  /// 默认位置：主屏右下角（避开菜单栏与 Dock）。
  private var defaultOrigin: NSPoint {
    let screen = NSScreen.main ?? NSScreen.screens.first
    guard let visible = screen?.visibleFrame else { return NSPoint(x: 100, y: 100) }
    return NSPoint(
      x: visible.maxX - panel.frame.width - 20,
      y: visible.minY + 20
    )
  }

  @objc private func windowDidMove(_ notification: Notification) {
    guard panel.isVisible else { return }
    let origin = panel.frame.origin
    UserDefaults.standard.set("\(origin.x),\(origin.y)", forKey: Self.originKey)
    if Self.snapsToMenuBar {
      // 拖动结束/移动后把 y 吸回菜单栏下方，x 保留用户拖动结果。
      Task { @MainActor [weak self] in
        self?.applySnapToMenuBarIfNeeded()
      }
    }
  }
}

/// 悬浮窗内容视图：毛玻璃圆角卡片背景 + 与菜单栏完全一致的镜像文本。
/// 复用 MenuBarStatusContentView 的公共绘制方法，保证两侧布局一致。
/// 支持按段悬停追踪：hoveredVendorIndex 为当前悬停的供应商段索引。
final class FloatingStatusContentView: NSView {
  static let fixedHeight: CGFloat = 32
  fileprivate static let horizontalPadding: CGFloat = 8
  fileprivate static let cornerRadius: CGFloat = 9
  fileprivate static let iconTextSpacing: CGFloat = 3
  fileprivate static let separatorText = "  ·  "
  fileprivate static let separatorFont = NSFont.monospacedDigitSystemFont(
    ofSize: MenuBarDisplayLayout.regularFontSize,
    weight: .semibold
  )

  /// 毛玻璃背景层：位于最底层，随视图尺寸自动布局。
  private let blurBackground = NSVisualEffectView()
  /// 内容绘制层：位于毛玻璃之上，绘制半透明深蓝卡片与镜像文本。
  private let contentOverlay = FloatingStatusContentOverlayView()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)

    blurBackground.material = .hudWindow
    // 轻量毛玻璃：低噪点、低通透，既能看到背景又保持文字可读。
    blurBackground.blendingMode = .behindWindow
    blurBackground.state = .active
    // 悬浮窗始终为深蓝深色风格（白字/白图标），毛玻璃强制深色外观保持一致。
    blurBackground.appearance = NSAppearance(named: .darkAqua)
    // 圆角裁剪：让视觉特效视图贴合卡片圆角轮廓。
    blurBackground.wantsLayer = true
    blurBackground.layer?.cornerRadius = Self.cornerRadius
    blurBackground.layer?.masksToBounds = true
    blurBackground.translatesAutoresizingMaskIntoConstraints = false
    addSubview(blurBackground, positioned: .below, relativeTo: nil)
    NSLayoutConstraint.activate([
      blurBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
      blurBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
      blurBackground.topAnchor.constraint(equalTo: topAnchor),
      blurBackground.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    contentOverlay.frame = bounds
    contentOverlay.autoresizingMask = [.width, .height]
    addSubview(contentOverlay)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// 悬停的供应商段索引（按 segments 顺序）；nil 表示未悬停在任何段上。
  var hoveredVendorIndex: Int? {
    didSet {
      guard oldValue != hoveredVendorIndex else { return }
      onHoverChange?(hoveredVendorIndex)
    }
  }

  /// 悬停段变化回调：参数为段索引（nil = 离开所有段）。
  var onHoverChange: ((Int?) -> Void)?

  /// 双击悬浮窗回调：由 FloatingStatusWindow 接线处理贴顶居中。
  var onDoubleClick: (() -> Void)?

  /// 单击悬浮窗回调：折线图显示时切换周期，隐藏时不产生副作用。
  var onSingleClick: (() -> Void)?

  /// 右键菜单「关闭悬浮窗」回调：由外部接线到设置持久化。
  var onToggleClose: (() -> Void)?

  /// 右键菜单「悬浮窗设置…」回调：由外部接线到设置窗口。
  var onOpenSettings: (() -> Void)?

  /// 右键控制面板「贴顶菜单栏」回调：由外部接线到设置持久化。
  var onToggleSnapToMenuBar: (() -> Void)?

  /// 右键打开控制面板前回调：由外部收起悬停趋势小面板，避免叠层。
  var onShowContextMenu: (() -> Void)?

  private lazy var contextPopover = FloatingWindowContextPopover()
  private var hoverTrackingArea: NSTrackingArea?
  private var segmentRanges: [(index: Int, range: Range<CGFloat>)] = []
  private var clickInterpreter = FloatingWindowClickInterpreter()
  private var pendingClickTask: Task<Void, Never>?
  private var isWindowDragging = false
  private var doubleClickHandled = false

  var segments: [MenuBarStatusContentView.Segment] = [] {
    didSet {
      segmentRanges = Self.computeSegmentRanges(for: segments)
      contentOverlay.segments = segments
      needsDisplay = true
    }
  }

  /// 按 drawSegments 相同的推进逻辑计算每个供应商段的 x 范围。
  static func computeSegmentRanges(
    for segments: [MenuBarStatusContentView.Segment]
  ) -> [(index: Int, range: Range<CGFloat>)] {
    var result: [(index: Int, range: Range<CGFloat>)] = []
    var x = horizontalPadding
    for (index, segment) in segments.enumerated() {
      let width = MenuBarStatusContentView.segmentWidth(segment, iconTextSpacing: iconTextSpacing)
      result.append((index, x..<(x + width)))
      x += width
      if index < segments.count - 1 {
        x += MenuBarStatusContentView.attributedWidth(separatorText, font: separatorFont)
      }
    }
    return result
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTrackingArea {
      removeTrackingArea(hoverTrackingArea)
    }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    hoverTrackingArea = area
  }

  override func mouseMoved(with event: NSEvent) {
    super.mouseMoved(with: event)
    updateHover(for: event)
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    updateHover(for: event)
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    hoveredVendorIndex = nil
  }

  override func mouseDown(with event: NSEvent) {
    let action = clickInterpreter.mouseDown(clickCount: event.clickCount)
    cancelPendingClickTask()
    if action == .doubleClick {
      doubleClickHandled = true
      onDoubleClick?()
    }
    // 不调用 super：窗口拖动由 mouseDragged 里的 performDrag 接管，
    // 以便在双击判定窗口内先取消待确认的单击。
  }

  override func mouseUp(with event: NSEvent) {
    if doubleClickHandled {
      doubleClickHandled = false
      return
    }
    let action = clickInterpreter.mouseUp(clickCount: event.clickCount)
    if action == .doubleClick {
      onDoubleClick?()
      return
    }
    scheduleSingleClickIfNeeded()
  }

  override func mouseDragged(with event: NSEvent) {
    clickInterpreter.mouseDragged()
    cancelPendingClickTask()
    guard !isWindowDragging, let window else { return }
    isWindowDragging = true
    window.performDrag(with: event)
    isWindowDragging = false
  }

  /// 右键弹出控制面板：关闭悬浮窗开关 + 直达悬浮窗设置。
  override func rightMouseDown(with event: NSEvent) {
    super.rightMouseDown(with: event)
    clickInterpreter.rightMouseDown()
    cancelPendingClickTask()
    guard let window, let screen = window.screen ?? NSScreen.main else { return }
    onShowContextMenu?()
    contextPopover.show(
      near: window.convertPoint(toScreen: event.locationInWindow),
      screen: screen,
      isEnabled: FloatingStatusWindow.isEnabled,
      isSnapped: FloatingStatusWindow.snapsToMenuBar,
      language: contextMenuLanguage,
      onToggleClose: onToggleClose,
      onOpenSettings: onOpenSettings,
      onToggleSnapToMenuBar: onToggleSnapToMenuBar
    )
  }

  /// 悬浮窗隐藏时同步收起右键控制面板。
  func hideContextPopover() {
    contextPopover.hide()
  }

  /// 悬浮窗隐藏时取消尚未确认的单击，避免后台误切换周期。
  func cancelPendingInteraction() {
    clickInterpreter.cancelPendingSingleClick()
    cancelPendingClickTask()
  }

  private func scheduleSingleClickIfNeeded() {
    guard clickInterpreter.pendingSingleClick else { return }
    cancelPendingClickTask()
    let interval = max(NSEvent.doubleClickInterval, 0.25)
    pendingClickTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
      guard !Task.isCancelled else { return }
      guard let self else { return }
      if self.clickInterpreter.confirmPendingSingleClick() == .singleClick {
        self.onSingleClick?()
      }
    }
  }

  private func cancelPendingClickTask() {
    pendingClickTask?.cancel()
    pendingClickTask = nil
  }

  /// 右键面板语言：直接读用户持久化的语言选择，与设置页保持一致。
  private var contextMenuLanguage: AppLanguage {
    if let raw = UserDefaults.standard.string(forKey: AppLanguage.userDefaultsKey),
      let language = AppLanguage(rawValue: raw)
    {
      return language
    }
    return .simplifiedChinese
  }

  private func updateHover(for event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    hoveredVendorIndex = segmentRanges.first { $0.range.contains(point.x) }?.index
  }

  /// 当前悬停段在屏幕上的 frame（含窗口偏移）。
  var hoveredSegmentScreenFrame: NSRect? {
    guard let index = hoveredVendorIndex,
      let range = segmentRanges.first(where: { $0.index == index })?.range,
      let window = window
    else { return nil }
    let viewRect = NSRect(x: range.lowerBound, y: 0, width: range.upperBound - range.lowerBound, height: bounds.height)
    return window.convertToScreen(convert(viewRect, to: nil))
  }

  /// 内容总宽度：各分段宽度 + 分隔符 + 两侧 padding。
  static func requiredWidth(for segments: [MenuBarStatusContentView.Segment]) -> CGFloat {
    guard !segments.isEmpty else { return horizontalPadding * 2 }
    let segmentsWidth = segments.reduce(CGFloat.zero) { partial, segment in
      partial + MenuBarStatusContentView.segmentWidth(segment, iconTextSpacing: iconTextSpacing)
    }
    let separatorWidth = segments.count > 1
      ? CGFloat(segments.count - 1)
        * MenuBarStatusContentView.attributedWidth(separatorText, font: separatorFont)
      : 0
    return ceil(horizontalPadding * 2 + segmentsWidth + separatorWidth)
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    // 背景与文字绘制全部由 contentOverlay 完成（位于毛玻璃层之上），
    // 避免毛玻璃把自绘内容遮挡成灰色。
  }
}

/// 悬浮窗内容绘制层：位于毛玻璃背景之上，负责半透明深蓝卡片与镜像文本。
/// 自绘内容必须放在毛玻璃上方的独立子视图里，NSVisualEffectView 会盖住
/// 父视图 draw 的内容。
private final class FloatingStatusContentOverlayView: NSView {
  /// 与父视图同步的镜像文本分段。
  var segments: [MenuBarStatusContentView.Segment] = [] {
    didSet { needsDisplay = true }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    // 悬浮窗固定为深蓝深色风格，强制深色外观保证白字/白图标稳定着色。
    appearance = NSAppearance(named: .darkAqua)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)

    let card = NSBezierPath(
      roundedRect: bounds,
      xRadius: FloatingStatusContentView.cornerRadius,
      yRadius: FloatingStatusContentView.cornerRadius
    )
    // 高透明显示：整体 alpha 约 0.55，明显能看到被覆盖的桌面内容。
    NSColor(srgbRed: 0.05, green: 0.15, blue: 0.40, alpha: 0.28).setFill()
    card.fill()
    NSColor.white.withAlphaComponent(0.18).setStroke()
    card.lineWidth = 1
    card.stroke()

    _ = MenuBarStatusContentView.drawSegments(
      segments,
      in: bounds,
      horizontalPadding: FloatingStatusContentView.horizontalPadding,
      separatorText: FloatingStatusContentView.separatorText,
      separatorFont: FloatingStatusContentView.separatorFont,
      iconTextSpacing: FloatingStatusContentView.iconTextSpacing,
      // 深蓝背景：未指定颜色的文本统一用白色。
      defaultTextColor: .white
    )
  }
}

/// 悬浮窗右键控制面板：非激活浮动小窗里的原生开关。
/// 不用 NSMenu 的原因：非激活面板 + 纯菜单栏应用弹 NSMenu 必须先激活应用，
/// 会抢走用户当前应用的焦点；独立浮动面板无需激活即可接收点击。
private final class FloatingWindowContextPopover: NSObject {
  private let panel: NSPanel
  private let hostingView: NSHostingView<FloatingWindowContextMenuView>
  private var localDismissMonitor: Any?
  private var globalDismissMonitor: Any?

  override init() {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 240, height: 122),
      styleMask: [.nonactivatingPanel, .borderless],
      backing: .buffered,
      defer: false
    )
    panel.isFloatingPanel = true
    panel.level = .floating + 2
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    // 与悬浮窗本体一致：无阴影，由毛玻璃卡片自绘轮廓。
    panel.hasShadow = false
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.ignoresMouseEvents = false
    // 与趋势小面板相同：关闭 NSHostingView 的约束参与，纯用 frame 布局，
    // 避免 borderless nonactivating panel 更新内容尺寸时抛 NSException。
    let hostingView = NSHostingView(
      rootView: FloatingWindowContextMenuView(
        isEnabled: true,
        isSnapped: true,
        language: .simplifiedChinese,
        onToggleClose: nil,
        onOpenSettings: nil,
        onToggleSnapToMenuBar: nil
      )
    )
    hostingView.sizingOptions = []
    hostingView.translatesAutoresizingMaskIntoConstraints = true
    hostingView.autoresizingMask = [.width, .height]
    panel.contentView = hostingView
    self.panel = panel
    self.hostingView = hostingView
    super.init()
  }

  var isVisible: Bool { panel.isVisible }

  func show(
    near screenPoint: NSPoint,
    screen: NSScreen,
    isEnabled: Bool,
    isSnapped: Bool,
    language: AppLanguage,
    onToggleClose: (() -> Void)?,
    onOpenSettings: (() -> Void)?,
    onToggleSnapToMenuBar: (() -> Void)?
  ) {
    hostingView.rootView = FloatingWindowContextMenuView(
      isEnabled: isEnabled,
      isSnapped: isSnapped,
      language: language,
      onToggleClose: { [weak self] in
        onToggleClose?()
        self?.hide()
      },
      onOpenSettings: { [weak self] in
        onOpenSettings?()
        self?.hide()
      },
      onToggleSnapToMenuBar: {
        onToggleSnapToMenuBar?()
      }
    )

    let size = NSSize(width: 240, height: 122)
    panel.setContentSize(size)
    hostingView.frame = NSRect(origin: .zero, size: size)

    // 定位：x 对齐右键点，y 优先放右键点下方，空间不足时改上方，
    // 最后钳制到所在屏幕可见区域。
    let visible = screen.visibleFrame
    var origin = NSPoint(x: screenPoint.x - 12, y: screenPoint.y - size.height - 6)
    if origin.y < visible.minY + 8 {
      origin.y = screenPoint.y + 6
    }
    origin.x = min(max(origin.x, visible.minX + 8), max(visible.minX + 8, visible.maxX - 8 - size.width))
    origin.y = min(max(origin.y, visible.minY + 8), max(visible.minY + 8, visible.maxY - 8 - size.height))
    panel.setFrameOrigin(origin)
    panel.orderFrontRegardless()

    installDismissMonitors()
  }

  func hide() {
    panel.orderOut(nil)
    removeDismissMonitors()
  }

  /// 本应用内点击其它窗口（如悬浮窗本体、菜单栏）时收起；
  /// 其它应用的点击由全局监听兜底，无需激活本应用。
  private func installDismissMonitors() {
    removeDismissMonitors()
    localDismissMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown]
    ) { [weak self] event in
      guard let self, self.panel.isVisible, event.window !== self.panel else { return event }
      self.hide()
      return event
    }
    globalDismissMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown]
    ) { [weak self] _ in
      self?.hide()
    }
  }

  private func removeDismissMonitors() {
    if let localDismissMonitor {
      NSEvent.removeMonitor(localDismissMonitor)
    }
    localDismissMonitor = nil
    if let globalDismissMonitor {
      NSEvent.removeMonitor(globalDismissMonitor)
    }
    globalDismissMonitor = nil
  }
}

/// 控制面板内容：关闭悬浮窗开关 + 贴顶菜单栏开关 + 悬浮窗设置入口。
private struct FloatingWindowContextMenuView: View {
  var isEnabled: Bool
  var language: AppLanguage
  var onToggleClose: (() -> Void)?
  var onOpenSettings: (() -> Void)?
  var onToggleSnapToMenuBar: (() -> Void)?
  @State private var isSnapped: Bool

  init(
    isEnabled: Bool,
    isSnapped: Bool,
    language: AppLanguage,
    onToggleClose: (() -> Void)?,
    onOpenSettings: (() -> Void)?,
    onToggleSnapToMenuBar: (() -> Void)?
  ) {
    self.isEnabled = isEnabled
    self.language = language
    self.onToggleClose = onToggleClose
    self.onOpenSettings = onOpenSettings
    self.onToggleSnapToMenuBar = onToggleSnapToMenuBar
    self._isSnapped = State(initialValue: isSnapped)
  }

  var body: some View {
    VStack(spacing: 0) {
      Toggle(
        isOn: Binding(
          get: { isEnabled },
          set: { _ in onToggleClose?() }
        )
      ) {
        Text(L10n.string(.floatingWindowClose, language: language))
          .font(.system(size: 13))
          .foregroundColor(.white)
      }
      .toggleStyle(FloatingWindowSwitchStyle())
      .padding(.horizontal, 12)
      .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)

      Divider().overlay(Color.white.opacity(0.18))

      Toggle(
        isOn: $isSnapped
      ) {
        Text(L10n.string(.floatingWindowSnapToMenuBar, language: language))
          .font(.system(size: 13))
          .foregroundColor(.white)
      }
      .onChange(of: isSnapped) { _ in
        onToggleSnapToMenuBar?()
      }
      .toggleStyle(FloatingWindowSwitchStyle())
      .padding(.horizontal, 12)
      .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)

      Divider().overlay(Color.white.opacity(0.18))

      Button(action: { onOpenSettings?() }) {
        Label(L10n.string(.floatingWindowSettings, language: language), systemImage: "gearshape")
          .font(.system(size: 13))
          .foregroundColor(.white)
          .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 12)
    }
    .frame(width: 240, height: 122)
    .background(
      ZStack {
        // 与悬浮窗相同的 hudWindow 毛玻璃材质。
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(Color.clear)
          .overlay(
            HudWindowMaterial()
              .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
          )
        // 与悬浮窗内容层相同的半透明深蓝着色。
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(Color(red: 0.05, green: 0.15, blue: 0.40).opacity(0.28))
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .stroke(Color.white.opacity(0.18), lineWidth: 1)
      }
    )
    .preferredColorScheme(.dark)
  }
}

/// 悬浮窗控制面板专用开关：开启时为绿色底纹，关闭时为灰色底纹，
/// 在深蓝半透明背景上仍能一眼看清开关状态。
private struct FloatingWindowSwitchStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 8) {
      configuration.label
      Spacer()
      ZStack(alignment: configuration.isOn ? .trailing : .leading) {
        Capsule()
          .fill(
            configuration.isOn
              ? Color(red: 0.16, green: 0.72, blue: 0.36)
              : Color.white.opacity(0.22)
          )
          .frame(width: 36, height: 20)
        Circle()
          .fill(Color.white)
          .frame(width: 16, height: 16)
          .padding(2)
      }
      .contentShape(Capsule())
      .onTapGesture {
        configuration.isOn.toggle()
      }
      .animation(.easeOut(duration: 0.15), value: configuration.isOn)
    }
  }
}
