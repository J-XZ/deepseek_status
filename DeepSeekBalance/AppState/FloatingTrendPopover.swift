import AppKit
import SwiftUI

/// 悬浮窗悬停趋势小面板：悬停在悬浮窗某供应商段上时，
/// 在该段上方浮现对应的趋势折线图（复用弹窗内现有图表视图）。
@MainActor
final class FloatingTrendPopover: NSObject {
  private let panel: NSPanel
  private let hostingView = NSHostingView<FloatingTrendCard>(rootView: FloatingTrendCard())
  private var currentVendor: MenuBarVendor?

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
    screen: NSScreen
  ) {
    guard currentVendor != vendor, let chart = chartProvider?(vendor) else { return }
    currentVendor = vendor

    let card = FloatingTrendCard(content: chart)
    hostingView.rootView = card

    // 固定内容尺寸：图表视图统一 280×240（图表 160 + 估算行 + 图例），
    // 避免依赖 hostingView 尺寸拟合（sizingOptions = [] 下拟合不可靠）。
    let contentSize = NSSize(width: 300, height: 260)
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

  func hide() {
    currentVendor = nil
    panel.orderOut(nil)
  }
}

/// 深色小卡片：包裹趋势图视图，使用与悬浮窗相同的 hudWindow 毛玻璃。
private struct FloatingTrendCard: View {
  var content: AnyView?

  var body: some View {
    Group {
      if let content {
        content
          // 固定图表区域尺寸，避免依赖外部拟合；高度含图例/估算行。
          .frame(width: 280, height: 240)
      } else {
        Color.clear.frame(width: 1, height: 1)
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
          Color(red: 0.05, green: 0.15, blue: 0.40).opacity(0.35)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.white.opacity(0.25), lineWidth: 1)
        )
    )
    .preferredColorScheme(.dark)
  }
}

/// 与悬浮窗一致的 hudWindow 毛玻璃材质（SwiftUI 侧 NSVisualEffectView 包装）。
private struct HudWindowMaterial: NSViewRepresentable {
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
