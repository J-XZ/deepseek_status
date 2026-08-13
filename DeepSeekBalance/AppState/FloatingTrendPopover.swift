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
    panel.appearance = AppVisualStyle.nsAppearance
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
    hostingView.appearance = AppVisualStyle.nsAppearance
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

/// 趋势小面板：使用跟随系统外观的中性菜单材质。
private struct FloatingTrendCard: View {
  var content: AnyView?
  var period: TrendPeriod
  var language: AppLanguage

  var body: some View {
    VStack(alignment: .trailing, spacing: 6) {
      Text(period.displayName(language: language))
        .font(AppTypography.caption.weight(.medium))
        .foregroundStyle(.secondary)
      Group {
        if let content {
          content
            // 固定图表区域尺寸，避免依赖外部拟合；高度含图例/估算行。
            .frame(width: 280, height: 240)
        } else {
          Color.clear.frame(width: 1, height: 1)
        }
      }
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(Color.clear)
        .overlay(HudWindowMaterial().clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)))
        .overlay(
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(
              Color(nsColor: .separatorColor).opacity(0.55),
              lineWidth: AppVisualStyle.hairlineWidth
            )
        )
    )
    .preferredColorScheme(.light)
  }
}

/// 悬浮面板共用的系统菜单材质。
struct HudWindowMaterial: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .menu
    view.blendingMode = .behindWindow
    view.state = .active
    return view
  }

  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
