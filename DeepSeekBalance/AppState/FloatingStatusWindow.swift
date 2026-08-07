import AppKit

/// 悬浮窗控制器：在所有窗口之上浮动显示与菜单栏完全一致的镜像内容。
/// 可拖动，位置持久化；由设置开关（floatingWindow.enabled）控制启停。
@MainActor
final class FloatingStatusWindow: NSObject {
  // MARK: - 设置持久化

  static let enabledKey = "floatingWindow.enabled"
  static let originKey = "floatingWindow.origin"

  static var isEnabled: Bool {
    UserDefaults.standard.bool(forKey: enabledKey)
  }

  static func setEnabled(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: enabledKey)
  }

  private let panel: NSPanel
  private let contentView = FloatingStatusContentView()

  /// 内容视图：悬停回调等由外部（StatusItemController）接线。
  var hoverContent: FloatingStatusContentView { contentView }

  /// 悬浮窗当前所在屏幕（未显示时为 nil）。
  var screen: NSScreen? { panel.screen }
  private var isFirstShow = true

  override init() {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: FloatingStatusContentView.fixedHeight),
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
    let width = FloatingStatusContentView.requiredWidth(for: segments)
    let height = FloatingStatusContentView.fixedHeight
    let oldFrame = panel.frame
    guard abs(oldFrame.width - width) > 0.5 || abs(oldFrame.height - height) > 0.5 else { return }
    let center = NSPoint(x: oldFrame.midX, y: oldFrame.midY)
    panel.setFrame(
      NSRect(
        x: center.x - width / 2,
        y: center.y - height / 2,
        width: width,
        height: height
      ),
      display: true
    )
  }

  func show() {
    guard !panel.isVisible else { return }
    if isFirstShow {
      isFirstShow = false
      panel.setFrameOrigin(restoredOrigin ?? defaultOrigin)
    }
    panel.orderFrontRegardless()
  }

  func hide() {
    panel.orderOut(nil)
  }

  // MARK: - 位置

  private var restoredOrigin: NSPoint? {
    guard let raw = UserDefaults.standard.string(forKey: Self.originKey) else { return nil }
    let parts = raw.split(separator: ",").compactMap { Double($0) }
    guard parts.count == 2, let x = parts.first, let y = parts.last else { return nil }
    return NSPoint(x: x, y: y)
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
  }
}

/// 悬浮窗内容视图：毛玻璃圆角卡片背景 + 与菜单栏完全一致的镜像文本。
/// 复用 MenuBarStatusContentView 的公共绘制方法，保证两侧布局一致。
/// 支持按段悬停追踪：hoveredVendorIndex 为当前悬停的供应商段索引。
final class FloatingStatusContentView: NSView {
  static let fixedHeight: CGFloat = 32
  fileprivate static let horizontalPadding: CGFloat = 10
  fileprivate static let cornerRadius: CGFloat = 9
  fileprivate static let iconTextSpacing: CGFloat = 4
  fileprivate static let separatorText = "  |  "
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

  private var hoverTrackingArea: NSTrackingArea?
  private var segmentRanges: [(index: Int, range: Range<CGFloat>)] = []

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
    // 半透明深蓝着色：叠加在毛玻璃之上，保留深色基调保证白字/白图标可读，
    // 同时透过下方毛玻璃清晰看到桌面内容。
    NSColor(srgbRed: 0.05, green: 0.15, blue: 0.40, alpha: 0.35).setFill()
    card.fill()
    NSColor.white.withAlphaComponent(0.25).setStroke()
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
