import AppKit
import SwiftUI

/// Codex 用量标签页：订阅方案、用量窗口、额外额度与账号信息。
struct CodexUsageView: View {
  @ObservedObject var store: CodexUsageStore
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
        creditsCard(usage)
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
          Text(L10n.string(.codexLoading, language: language))
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
        Image("CodexIcon")
          .renderingMode(.template)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 24, height: 24)
          .padding(8)
          .background(Color.accentColor.opacity(0.12), in: Circle())
          .accessibilityLabel(L10n.string(.a11yCodexIcon, language: language))
        VStack(alignment: .leading, spacing: 2) {
          Text(L10n.string(.codexTitle, language: language))
            .font(AppTypography.title)
          Text(store.menuBarText)
            .font(AppTypography.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        Spacer()
        if let plan = store.usage.flatMap({ CodexUsageFormatter.planDisplayName($0.planType) }) {
          Text(plan)
            .font(AppTypography.badge)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.14), in: Capsule())
            .foregroundStyle(Color.accentColor)
        }
        statusBadge
      }
      if let email = store.usage?.email, !email.isEmpty {
        Label(
          L10n.string(.codexAccount, language: language, email),
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
      return L10n.string(.codexNotConfigured, language: language)
    case .authInvalid:
      return L10n.string(.codexAuthInvalid, language: language)
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

  private func usageCard(_ usage: CodexUsageResponse) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(L10n.string(.codexPlan, language: language))
          .font(AppTypography.section)
        Spacer()
        if let rateLimit = usage.rateLimit {
          Text(
            rateLimit.limitReached
              ? L10n.string(.codexLimitReached, language: language)
              : L10n.string(.codexLimitAllowed, language: language)
          )
          .font(AppTypography.badge)
          .foregroundStyle(rateLimit.limitReached ? .red : .green)
        } else {
          Text(freePlanText(for: usage))
            .font(AppTypography.badge)
            .foregroundStyle(.blue)
        }
      }

      if usage.rateLimit == nil {
        if usage.planType?.lowercased() == "free" {
          Text(L10n.string(.codexFreePlan, language: language))
            .font(AppTypography.caption)
            .foregroundStyle(.secondary)
        }
      } else {
        if let primary = usage.rateLimit?.primaryWindow {
          windowRow(primary, isPrimary: true)
        }
        fiveHourRow(for: usage)
      }

      ForEach(usage.additionalRateLimits ?? []) { limit in
        if let window = limit.rateLimit?.primaryWindow,
          let name = limit.limitName, !name.isEmpty
        {
          windowRow(window, title: name)
        }
      }

      if let last = store.lastUpdated {
        Label(
          L10n.string(
            .codexLastUpdated,
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

  /// 无用量限制信息时的徽章文案：免费计划明确标注，否则通用“无限制信息”。
  private func freePlanText(for usage: CodexUsageResponse) -> String {
    switch usage.planType?.lowercased() {
    case "free":
      return L10n.string(.codexFreePlan, language: language)
    default:
      return L10n.string(.codexNoLimit, language: language)
    }
  }

  /// 5 小时窗口：官方目前未下发该限制，预留展示——未下发时按
  /// “已用 0% · 剩余 100%”显示并标注当前无限制；将来下发后自动显示真实数据。
  @ViewBuilder
  private func fiveHourRow(for usage: CodexUsageResponse) -> some View {
    if let secondary = usage.rateLimit?.secondaryWindow {
      windowRow(secondary, isPrimary: false)
    } else {
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text(L10n.string(.codexWindowFiveHour, language: language))
            .font(AppTypography.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          Spacer()
          Text(L10n.string(
            .codexWindowUsedRemaining,
            language: language,
            0,
            100
          ))
          .font(AppTypography.caption.monospacedDigit())
          .foregroundStyle(amountForegroundStyle)
        }
        usageBar(usedPercent: 0)
        Text(L10n.string(.codexWindowFiveHourNone, language: language))
          .font(AppTypography.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.bottom, 2)
    }
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
            .accessibilityLabel(L10n.string(.codexExpectedMarker, language: language))
        }
      }
    }
    .frame(height: 6)
  }

  private func usageBar(_ window: CodexUsageWindow) -> some View {
    usageBar(
      usedPercent: window.usedPercent,
      expected: CodexUsageFormatter.expectedUsedPercent(
        resetAt: window.resetAt,
        limitWindowSeconds: window.limitWindowSeconds
      )
    )
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

  /// 进度条文案：有差距（实际已用 − 理想已用）时显示“已用 X% · 剩余 Y%（±Z%）”，
  /// 与 OpenCode 详情页保持一致；无差距信息时不带括号。
  private func windowProgressText(
    usedPercent: Int,
    remainingPercent: Int,
    gap: Int?
  ) -> String {
    guard let gap else {
      return L10n.string(
        .codexWindowUsedRemaining,
        language: language,
        usedPercent,
        remainingPercent
      )
    }
    let signedGap = "\(gap >= 0 ? "+" : "")\(gap)%"
    return L10n.string(
      .codexWindowUsedRemainingWithGap,
      language: language,
      usedPercent,
      remainingPercent,
      signedGap
    )
  }

  private func windowRow(_ window: CodexUsageWindow, isPrimary: Bool = false, title: String? = nil) -> some View {
    let expected = CodexUsageFormatter.expectedUsedPercent(
      resetAt: window.resetAt,
      limitWindowSeconds: window.limitWindowSeconds
    )
    let gap = expected.map { window.usedPercent - Int($0.rounded()) }

    return VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title ?? CodexUsageFormatter.windowTitle(
          limitWindowSeconds: window.limitWindowSeconds,
          language: language
        ))
        .font(AppTypography.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        Spacer()
        Text(windowProgressText(
          usedPercent: window.usedPercent,
          remainingPercent: window.remainingPercent,
          gap: gap
        ))
        .font(AppTypography.caption.monospacedDigit())
        .foregroundStyle(amountForegroundStyle)
      }
      usageBar(window)
      if let reset = CodexUsageFormatter.resetDate(
        resetAt: window.resetAt,
        locale: language.locale
      ) {
        Text(L10n.string(
          .codexResetAt,
          language: language,
          reset.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened).locale(language.locale)
          )
        ))
        .font(AppTypography.caption)
        .foregroundStyle(.secondary)
      }
    }
    .padding(.bottom, 2)
  }

  @ViewBuilder
  private func creditsCard(_ usage: CodexUsageResponse) -> some View {
    if let credits = usage.credits {
      VStack(alignment: .leading, spacing: 6) {
        Text(L10n.string(.codexCreditsTitle, language: language))
          .font(AppTypography.section)
        HStack {
          Text(creditsText(credits))
            .foregroundStyle(.secondary)
          Spacer()
          Text(creditsValue(credits))
            .font(AppTypography.value)
            .foregroundStyle(amountForegroundStyle)
        }
        if credits.overageLimitReached {
          Text(L10n.string(.codexLimitReached, language: language))
            .font(AppTypography.caption)
            .foregroundStyle(.red)
        }
      }
    }
  }

  private func creditsText(_ credits: CodexCredits) -> String {
    if credits.unlimited {
      return L10n.string(.codexCreditsUnlimited, language: language)
    }
    if credits.hasCredits {
      return L10n.string(.codexCreditsBalance, language: language)
    }
    return L10n.string(.codexCreditsNone, language: language)
  }

  private func creditsValue(_ credits: CodexCredits) -> String {
    if credits.unlimited {
      return "∞"
    }
    if credits.hasCredits {
      return credits.balance ?? "—"
    }
    return "—"
  }

  @ViewBuilder
  private var emptyView: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(emptyTitle)
        .font(AppTypography.section)
      if store.status == .notConfigured {
        Text(L10n.string(.codexNotConfiguredDetail, language: language))
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
      return L10n.string(.codexNotConfigured, language: language)
    case .authInvalid:
      return L10n.string(.codexAuthInvalid, language: language)
    default:
      return L10n.string(.codexEmpty, language: language)
    }
  }
}

extension CodexAdditionalRateLimit: Identifiable {
  var id: String { limitName ?? UUID().uuidString }
}
