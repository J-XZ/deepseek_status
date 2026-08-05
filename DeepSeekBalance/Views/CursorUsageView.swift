import AppKit
import SwiftUI

/// Cursor 用量标签页：订阅方案、计费周期用量、费用明细与账号信息。
struct CursorUsageView: View {
  @ObservedObject var store: CursorUsageStore
  let language: AppLanguage
  let appearance: AppAppearance

  @Environment(\.controlActiveState) private var controlActiveState

  private var cardBackground: Color {
    appearance == .dark ? Color(white: 0.14) : Color(white: 0.96)
  }

  private var cardBorder: Color {
    appearance == .dark ? Color.primary.opacity(0.28) : Color.primary.opacity(0.16)
  }

  private var amountForegroundStyle: Color {
    controlActiveState == .inactive ? .secondary : .primary
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      headerCard
      if let usage = store.usage {
        usageCard(usage)
        spendCard(usage)
        if let error = store.lastDisplayError {
          Text(error.text(language: language))
            .font(AppTypography.caption)
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
      } else if store.isRefreshing || store.status == .loading {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text(L10n.string(.cursorLoading, language: language))
            .foregroundStyle(.secondary)
        }
      } else {
        emptyView
      }
    }
  }

  private var headerCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        Image("CursorIcon")
          .renderingMode(.template)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 24, height: 24)
          .padding(8)
          .background(Color.accentColor.opacity(0.12), in: Circle())
          .accessibilityLabel(L10n.string(.a11yCursorIcon, language: language))
        VStack(alignment: .leading, spacing: 2) {
          Text(L10n.string(.cursorTitle, language: language))
            .font(AppTypography.title)
          Text(store.menuBarText)
            .font(AppTypography.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        Spacer()
        if let plan = CursorUsageFormatter.planDisplayName(store.profile?.planTier) {
          Text(plan)
            .font(AppTypography.badge)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.14), in: Capsule())
            .foregroundStyle(Color.accentColor)
        }
        statusBadge
      }
      if let email = store.profile?.email, !email.isEmpty {
        Label(
          L10n.string(.cursorAccount, language: language, email),
          systemImage: "person.crop.circle"
        )
        .font(AppTypography.caption)
        .foregroundStyle(.secondary)
      }
    }
  }

  private var statusBadge: some View {
    Text(statusText)
      .font(AppTypography.badge)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(statusColor.opacity(0.14), in: Capsule())
      .foregroundStyle(statusColor)
  }

  private var statusText: String {
    switch store.status {
    case .idle, .loading:
      return L10n.string(.statusLoading, language: language)
    case .loaded:
      return L10n.string(.statusLoaded, language: language)
    case .notConfigured:
      return L10n.string(.cursorNotConfigured, language: language)
    case .authInvalid:
      return L10n.string(.cursorAuthInvalid, language: language)
    case .networkError, .serverError, .decodingError:
      return L10n.string(.statusRequestFailed, language: language)
    }
  }

  private var statusColor: Color {
    switch store.status {
    case .loaded:
      return .green
    case .idle, .loading:
      return .blue
    case .notConfigured, .authInvalid:
      return .orange
    case .networkError, .serverError, .decodingError:
      return .red
    }
  }

  private func usageCard(_ usage: CursorUsageResponse) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(L10n.string(.cursorPlan, language: language))
          .font(AppTypography.section)
        Spacer()
        if usage.hasNoPlanUsage {
          Text(L10n.string(.cursorNoLimit, language: language))
            .font(AppTypography.badge)
            .foregroundStyle(.secondary)
        } else {
          Text(
            usage.limitReached
              ? L10n.string(.cursorLimitReached, language: language)
              : L10n.string(.cursorLimitAllowed, language: language)
          )
          .font(AppTypography.badge)
          .foregroundStyle(usage.limitReached ? .red : .green)
        }
      }

      if usage.hasNoPlanUsage {
        Text(L10n.string(.cursorNoLimit, language: language))
          .font(AppTypography.caption)
          .foregroundStyle(.secondary)
      } else if let billingCycleStart = usage.billingCycleStartDate,
        let billingCycleEnd = usage.billingCycleEndDate
      {
        windowRow(
          billingCycleStart: billingCycleStart,
          billingCycleEnd: billingCycleEnd,
          usedPercent: usage.usedPercent,
          remainingPercent: usage.remainingPercent,
          gap: usage.usageGapPercent
        )
      }

      if let apiUsed = usage.apiUsedPercent {
        HStack {
          Text(L10n.string(.cursorApiChannel, language: language))
            .font(AppTypography.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          Spacer()
          Text(windowProgressText(
            usedPercent: apiUsed,
            remainingPercent: max(0, min(100, 100 - apiUsed)),
            gap: usage.apiUsageGapPercent
          ))
          .font(AppTypography.caption.monospacedDigit())
          .foregroundStyle(amountForegroundStyle)
        }
        usageBar(
          usedPercent: apiUsed,
          expected: apiExpected(usage)
        )
      }

      if let last = store.lastUpdated {
        Label(
          L10n.string(
            .cursorLastUpdated,
            language: language,
            last.formatted(
              Date.FormatStyle(date: .abbreviated, time: .shortened).locale(language.locale)
            )
          ),
          systemImage: "clock"
        )
        .font(AppTypography.caption)
        .foregroundStyle(.secondary)
      }
    }
  }

  /// 进度条文案：有差距（实际已用 − 理想已用）时显示“已用 X% · 剩余 Y%（±Z%）”，
  /// 与 OpenCode 详情页保持一致；无差距信息时不带括号。
  private func windowProgressText(
    usedPercent: Int,
    remainingPercent: Int,
    gap: Int?
  ) -> String {
    guard let gap else {
      return L10n.string(
        .cursorWindowUsedRemaining,
        language: language,
        usedPercent,
        remainingPercent
      )
    }
    let signedGap = "\(gap >= 0 ? "+" : "")\(gap)%"
    return L10n.string(
      .cursorWindowUsedRemainingWithGap,
      language: language,
      usedPercent,
      remainingPercent,
      signedGap
    )
  }

  /// 计费周期窗口：已用/剩余进度条 + 理想用量红线 + 重置时间。
  private func windowRow(
    billingCycleStart: Date,
    billingCycleEnd: Date,
    usedPercent: Int?,
    remainingPercent: Int?,
    gap: Int?
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(L10n.string(.cursorWindowTitle, language: language))
          .font(AppTypography.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Text(windowProgressText(
          usedPercent: usedPercent ?? 0,
          remainingPercent: remainingPercent ?? 0,
          gap: gap
        ))
        .font(AppTypography.caption.monospacedDigit())
        .foregroundStyle(amountForegroundStyle)
      }
      usageBar(
        usedPercent: usedPercent ?? 0,
        expected: CursorUsageFormatter.expectedUsedPercent(
          start: billingCycleStart,
          end: billingCycleEnd
        )
      )
      Text(L10n.string(
        .cursorResetAt,
        language: language,
        billingCycleEnd.formatted(
          Date.FormatStyle(date: .abbreviated, time: .shortened).locale(language.locale)
        )
      ))
      .font(AppTypography.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.bottom, 2)
  }

  /// API 通道的理想用量红线：与第一方模型共用同一计费周期推算。
  private func apiExpected(_ usage: CursorUsageResponse) -> Double? {
    guard let start = usage.billingCycleStartDate, let end = usage.billingCycleEndDate else {
      return nil
    }
    return CursorUsageFormatter.expectedUsedPercent(start: start, end: end)
  }

  /// 自绘进度条：轨道、填充与理想用量红线共用固定 6pt 高度坐标系，
  /// 红线严格与轨道等长、不超出；位置按期望百分比定位并夹在轨道内。
  private func usageBar(
    usedPercent: Int,
    expected: Double? = nil
  ) -> some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule()
          .fill(trackColor)
        Capsule()
          .fill(barColor(usedPercent, idealPercent: expected))
          .frame(width: geo.size.width * CGFloat(min(max(usedPercent, 0), 100)) / 100)
        if let expected {
          Rectangle()
            .fill(.red)
            .frame(width: 3, height: 6)
            .position(x: markerX(width: geo.size.width, expected: expected), y: 3)
            .accessibilityLabel(L10n.string(.cursorExpectedMarker, language: language))
        }
      }
    }
    .frame(height: 6)
  }

  private var trackColor: Color {
    appearance == .dark ? Color(white: 0.25) : Color(white: 0.85)
  }

  private func barColor(_ usedPercent: Int, idealPercent: Double?) -> Color {
    let gap = idealPercent.map { Double(usedPercent) - $0 }
    return MenuBarUsageColor.progressColor(forGap: gap).map(Color.init(nsColor:)) ?? .blue
  }

  /// 红线中心 x：夹在 [2, 宽度−2] 内，保证 3pt 宽红线不超出轨道左右边缘。
  private func markerX(width: CGFloat, expected: Double) -> CGFloat {
    let fraction = CGFloat(min(max(expected / 100, 0), 1))
    return min(max(width * fraction, 2), max(width - 2, 2))
  }

  private func spendCard(_ usage: CursorUsageResponse) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(L10n.string(.cursorSpendTitle, language: language))
        .font(AppTypography.section)
      if let planUsage = usage.planUsage {
        spendRow(
          title: L10n.string(.cursorSpendTotal, language: language),
          cents: planUsage.totalSpend
        )
        spendRow(
          title: L10n.string(.cursorSpendIncluded, language: language),
          cents: planUsage.includedSpend
        )
        spendRow(
          title: L10n.string(.cursorSpendBonus, language: language),
          cents: planUsage.bonusSpend
        )
        if let limit = planUsage.limit {
          HStack {
            Text(L10n.string(.cursorSpendLimit, language: language))
              .foregroundStyle(.secondary)
            Spacer()
            Text(
              CursorUsageFormatter.formatCents(limit, locale: language.locale) ?? "—"
            )
            .font(AppTypography.value)
            .foregroundStyle(amountForegroundStyle)
          }
        }
      }
      if usage.limitReached {
        Text(L10n.string(.cursorLimitReached, language: language))
          .font(AppTypography.caption)
          .foregroundStyle(.red)
      }
    }
  }

  private func spendRow(title: String, cents: Double?) -> some View {
    HStack {
      Text(title)
        .foregroundStyle(.secondary)
      Spacer()
      Text(CursorUsageFormatter.formatCents(cents, locale: language.locale) ?? "—")
        .font(AppTypography.value)
        .foregroundStyle(amountForegroundStyle)
    }
  }

  @ViewBuilder
  private var emptyView: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(emptyTitle)
        .font(AppTypography.section)
      if store.status == .notConfigured {
        Text(L10n.string(.cursorNotConfiguredDetail, language: language))
          .font(AppTypography.caption)
          .foregroundStyle(.secondary)
      }
      if let error = store.lastDisplayError {
        Text(error.text(language: language))
          .font(AppTypography.caption)
          .foregroundStyle(.red)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var emptyTitle: String {
    switch store.status {
    case .notConfigured:
      return L10n.string(.cursorNotConfigured, language: language)
    case .authInvalid:
      return L10n.string(.cursorAuthInvalid, language: language)
    default:
      return L10n.string(.cursorEmpty, language: language)
    }
  }
}
