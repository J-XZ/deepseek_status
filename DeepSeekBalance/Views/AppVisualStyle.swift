import AppKit
import SwiftUI

/// 全应用共享的浅色视觉系统。颜色、圆角、发丝线和常用容器集中在这里，
/// 避免各供应商页面各自硬编码灰阶后产生层级和控件状态不一致。
enum AppVisualStyle {
  static let nsAppearance = NSAppearance(named: .aqua)
  static let accent = Color.accentColor
  /// 浅色界面专用语义色：比 SwiftUI 默认亮色更深，在半透明材质上也保持对比。
  static let positive = Color(nsColor: NSColor(
    srgbRed: 0.12,
    green: 0.48,
    blue: 0.23,
    alpha: 1
  ))
  static let warning = Color(nsColor: NSColor(
    srgbRed: 0.72,
    green: 0.41,
    blue: 0.04,
    alpha: 1
  ))
  static let danger = Color(nsColor: NSColor(
    srgbRed: 0.78,
    green: 0.17,
    blue: 0.14,
    alpha: 1
  ))
  static let progressBlue = Color(nsColor: NSColor(
    srgbRed: 0.08,
    green: 0.42,
    blue: 0.82,
    alpha: 1
  ))

  static let cardCornerRadius: CGFloat = 12
  static let insetCornerRadius: CGFloat = 9
  static let contentPadding: CGFloat = 16
  /// Retina 上恰好一个物理像素；用于所有装饰性轮廓与自绘分隔线。
  static let hairlineWidth: CGFloat = 0.5

  static let windowTint = Color(nsColor: .windowBackgroundColor).opacity(0.92)
  static let surface = Color.white.opacity(0.72)
  static let elevatedSurface = surface
  static let insetSurface = Color(nsColor: .controlBackgroundColor).opacity(0.38)
  static let toolbarSurface = Color(nsColor: .controlBackgroundColor).opacity(0.5)
  static let border = Color(nsColor: .separatorColor).opacity(0.5)
  static let track = Color(nsColor: .quaternaryLabelColor).opacity(0.34)
  static let divider = Color(nsColor: .separatorColor).opacity(0.54)
}

enum AppCardLevel {
  case standard
  case elevated
  case toolbar
}

private struct AppCardModifier: ViewModifier {
  let level: AppCardLevel
  let padding: CGFloat
  let cornerRadius: CGFloat

  private var fill: Color {
    switch level {
    case .standard:
      return AppVisualStyle.surface
    case .elevated:
      return AppVisualStyle.elevatedSurface
    case .toolbar:
      return AppVisualStyle.toolbarSurface
    }
  }

  func body(content: Content) -> some View {
    content
      .padding(padding)
      .background {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(fill)
      }
      .overlay {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .strokeBorder(
            AppVisualStyle.border,
            lineWidth: AppVisualStyle.hairlineWidth
          )
      }
  }
}

private struct AppInsetCardModifier: ViewModifier {
  let padding: CGFloat

  func body(content: Content) -> some View {
    content
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(padding)
      .background(
        AppVisualStyle.insetSurface,
        in: RoundedRectangle(cornerRadius: AppVisualStyle.insetCornerRadius, style: .continuous)
      )
  }
}

extension View {
  func appCard(
    level: AppCardLevel = .standard,
    padding: CGFloat = AppVisualStyle.contentPadding,
    cornerRadius: CGFloat = AppVisualStyle.cardCornerRadius
  ) -> some View {
    modifier(
      AppCardModifier(
        level: level,
        padding: padding,
        cornerRadius: cornerRadius
      )
    )
  }

  func appInsetCard(
    padding: CGFloat = 12
  ) -> some View {
    modifier(AppInsetCardModifier(padding: padding))
  }
}

/// 统一状态标签：仅状态点使用语义色，不再用彩色胶囊包裹文字。
struct AppStatusBadge: View {
  let text: String
  let tint: Color
  var showsDot = true

  var body: some View {
    HStack(spacing: 5) {
      if showsDot {
        Circle()
          .fill(tint)
          .frame(width: 6, height: 6)
      }
      Text(text)
        .lineLimit(1)
    }
    .font(AppTypography.badge)
    .frame(height: 22)
    .foregroundStyle(.secondary)
  }
}

/// 供应商页统一标题模板：原始模板图标、标题/摘要与状态区域共用一条基线。
struct AppProviderHeader<Trailing: View>: View {
  let imageName: String
  let title: String
  let subtitle: String
  let accessibilityLabel: String
  @ViewBuilder let trailing: () -> Trailing

  var body: some View {
    HStack(spacing: 12) {
      Image(imageName)
        .renderingMode(.template)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .foregroundStyle(.primary)
        .frame(width: 24, height: 24)
        .frame(width: 32, height: 40)
        .accessibilityLabel(accessibilityLabel)

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(AppTypography.title)
          .foregroundStyle(.primary)
        Text(subtitle)
          .font(AppTypography.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      Spacer(minLength: 8)
      trailing()
    }
  }
}

/// 小节标题使用小号系统符号建立扫描锚点，不增加额外底块或描边。
struct AppSectionHeader: View {
  let title: String
  var systemImage: String? = nil

  var body: some View {
    HStack(spacing: 7) {
      if let systemImage {
        Image(systemName: systemImage)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 16, height: 16)
      }
      Text(title)
        .font(AppTypography.section)
    }
  }
}

/// 所有供应商共享的进度轨道与理想用量标记。
struct AppUsageProgressBar: View {
  let progress: Double
  let color: Color
  var expected: Double?
  var expectedAccessibilityLabel: String
  var height: CGFloat

  init(
    progress: Double,
    color: Color,
    expected: Double? = nil,
    expectedAccessibilityLabel: String = "Ideal usage",
    height: CGFloat = 8
  ) {
    self.progress = progress
    self.color = color
    self.expected = expected
    self.expectedAccessibilityLabel = expectedAccessibilityLabel
    self.height = height
  }

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(AppVisualStyle.track)
        Capsule()
          .fill(color)
          .frame(width: proxy.size.width * max(0, min(1, progress)))
        if let expected {
          Capsule()
            .fill(AppVisualStyle.danger)
            .frame(width: 3, height: height + 4)
            .position(
              x: UsageFormatting.markerX(width: proxy.size.width, expected: expected),
              y: height / 2
            )
            .accessibilityLabel(expectedAccessibilityLabel)
        }
      }
    }
    .frame(height: height)
    .accessibilityValue("\(Int(max(0, min(1, progress)) * 100))%")
  }
}
