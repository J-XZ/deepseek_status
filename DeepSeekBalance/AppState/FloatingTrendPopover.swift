import AppKit
import SwiftUI

/// 悬浮窗悬停趋势小面板：悬停在悬浮窗某供应商段上时，
/// 在该段上方浮现对应的趋势折线图（复用弹窗内现有图表视图）。
@MainActor
final class FloatingTrendPopover: NSObject {
  private let panel: NSPanel
  private let hostingView = NSHostingView<FloatingTrendCard>(
    rootView: FloatingTrendCard(
      content: nil,
      period: .fourteenDays,
      language: .simplifiedChinese
    )
  )
  private var currentVendor: MenuBarVendor?
  /// 当前周期：单击切换，仅运行时状态；App 重启后恢复 14 天。
  var currentPeriod: TrendPeriod = .fourteenDays
  var currentLanguage: AppLanguage = .simplifiedChinese

  /// 图表数据源（由 StatusItemController 在悬停回调中注入）。
  var chartProvider: ((MenuBarVendor) -> AnyView?)?

  override init() {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
      styleMask: [.nonactivatingPanel, .borderless],
      backing: .buffered,
      defer: false
    )
    panel.isFloatingPanel = true
    panel.level = .floating + 1
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.ignoresMouseEvents = true
    // 关键：关闭 NSHostingView 的约束参与。borderless nonactivating panel
    // 承载 NSHostingView 时，SwiftUI 更新窗口内容尺寸极值会在约束阶段抛
    // NSException 导致闪退；sizingOptions = [] 让它纯用 frame 布局。
    hostingView.sizingOptions = []
    hostingView.translatesAutoresizingMaskIntoConstraints = true
    hostingView.autoresizingMask = [.width, .height]
    panel.contentView = hostingView
    self.panel = panel
    super.init()
  }

  var isVisible: Bool { panel.isVisible }

  /// 在给定段附近展示趋势图（优先段下方，空间不足时改上方）。
  func showChart(
    vendor: MenuBarVendor,
    near segmentScreenFrame: NSRect,
    screen: NSScreen,
    language: AppLanguage
  ) {
    guard currentVendor != vendor, let chart = chartProvider?(vendor) else { return }
    currentVendor = vendor
    currentLanguage = language

    let card = FloatingTrendCard(
      content: chart,
      period: currentPeriod,
      language: currentLanguage
    )
    hostingView.rootView = card

    // 固定内容尺寸：周期标签行 + 图表视图统一 280×240（图表 160 + 估算行 + 图例），
    // 避免依赖 hostingView 尺寸拟合（sizingOptions = [] 下拟合不可靠）。
    let contentSize = NSSize(width: 300, height: 282)
    panel.setContentSize(contentSize)
    hostingView.frame = NSRect(origin: .zero, size: contentSize)

    // 定位：x 对齐段中心，y 优先段下方（minY - 8 - height），
    // 下方放不下时改段上方；最后钳制到所在屏幕可见区域。
    let visible = screen.visibleFrame
    let width = contentSize.width
    let height = contentSize.height
    var origin = NSPoint(
      x: segmentScreenFrame.midX - width / 2,
      y: segmentScreenFrame.minY - 8 - height
    )
    if origin.y < visible.minY + 8 {
      origin.y = segmentScreenFrame.maxY + 8
    }
    if origin.x < visible.minX + 8 {
      origin.x = visible.minX + 8
    }
    if origin.x + width > visible.maxX - 8 {
      origin.x = visible.maxX - 8 - width
    }
    if origin.y + height > visible.maxY - 8 {
      origin.y = visible.maxY - 8 - height
    }
    if origin.y < visible.minY + 8 {
      origin.y = visible.minY + 8
    }
    panel.setFrameOrigin(origin)
    panel.orderFrontRegardless()
  }

  /// 数据更新后重绘当前悬停的图表；没有正在展示的图表时什么都不做。
  func refreshChart(language: AppLanguage) {
    guard let vendor = currentVendor, panel.isVisible, let chart = chartProvider?(vendor) else {
      return
    }
    currentLanguage = language
    hostingView.rootView = FloatingTrendCard(
      content: chart,
      period: currentPeriod,
      language: currentLanguage
    )
  }

  func hide() {
    currentVendor = nil
    panel.orderOut(nil)
  }
}

/// 深色小卡片：包裹趋势图视图，使用与悬浮窗相同的 hudWindow 毛玻璃。
private struct FloatingTrendCard: View {
  var content: AnyView?
  var period: TrendPeriod
  var language: AppLanguage

  var body: some View {
    VStack(alignment: .trailing, spacing: 6) {
      // 当前周期：小号浅色文字，克制地提示单击可切换。
      Text(period.displayName(language: language))
        .font(AppTypography.caption.weight(.medium))
        .foregroundStyle(Color.white.opacity(0.92))
      Group {
        if let content {
          content
            // 悬浮窗深色半透明背景：坐标轴与说明文字切到更浅的白色层级。
            .environment(\.trendChartHighContrast, true)
            // 固定图表区域尺寸，避免依赖外部拟合；高度含图例/估算行。
            .frame(width: 280, height: 240)
        } else {
          Color.clear.frame(width: 1, height: 1)
        }
      }
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        // 与悬浮窗相同的 hudWindow 毛玻璃材质。
        .fill(Color.clear)
        .overlay(HudWindowMaterial().clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous)))
        // 深蓝着色叠加，保持与悬浮窗一致的深色基调。
        .overlay(
          // 高透明：趋势卡尽量少遮挡其后的窗口与桌面内容。
          Color(red: 0.05, green: 0.15, blue: 0.40).opacity(0.22)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
    )
    .preferredColorScheme(.dark)
  }
}

/// 与悬浮窗一致的 hudWindow 毛玻璃材质（SwiftUI 侧 NSVisualEffectView 包装）。
struct HudWindowMaterial: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .hudWindow
    view.blendingMode = .behindWindow
    view.state = .active
    view.appearance = NSAppearance(named: .darkAqua)
    return view
  }

  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
