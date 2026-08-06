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

/// 悬浮窗内容视图：圆角卡片背景 + 与菜单栏完全一致的镜像文本。
/// 复用 MenuBarStatusContentView 的公共绘制方法，保证两侧布局一致。
final class FloatingStatusContentView: NSView {
  static let fixedHeight: CGFloat = 32
  private static let horizontalPadding: CGFloat = 10
  private static let cornerRadius: CGFloat = 9
  private static let iconTextSpacing: CGFloat = 4
  private static let separatorText = "  |  "
  private static let separatorFont = NSFont.monospacedDigitSystemFont(
    ofSize: MenuBarDisplayLayout.regularFontSize,
    weight: .semibold
  )

  var segments: [MenuBarStatusContentView.Segment] = [] {
    didSet { needsDisplay = true }
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

    let card = NSBezierPath(
      roundedRect: bounds,
      xRadius: Self.cornerRadius,
      yRadius: Self.cornerRadius
    )
    // 深蓝背景：无论系统外观如何，保证白字/白图标可读。
    NSColor(srgbRed: 0.05, green: 0.15, blue: 0.40, alpha: 0.95).setFill()
    card.fill()
    NSColor.white.withAlphaComponent(0.25).setStroke()
    card.lineWidth = 1
    card.stroke()

    _ = MenuBarStatusContentView.drawSegments(
      segments,
      in: bounds,
      horizontalPadding: Self.horizontalPadding,
      separatorText: Self.separatorText,
      separatorFont: Self.separatorFont,
      iconTextSpacing: Self.iconTextSpacing,
      // 深蓝背景：未指定颜色的文本统一用白色。
      defaultTextColor: .white
    )
  }
}
