import SwiftUI

/// Command Code 用量标签页：订阅方案、额度使用、窗口限制与账号信息。
/// 完全仿照 Cursor 用量页的卡片结构。
struct CommandCodeUsageView: View {
  @ObservedObject var store: CommandCodeUsageStore
  let language: AppLanguage

  @Environment(\.controlActiveState) private var controlActiveState

  private var amountForegroundStyle: Color {
    controlActiveState == .inactive ? .secondary : .primary
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      headerCard
      Divider()
        .overlay(AppVisualStyle.divider)
      if let usage = store.usage {
        usageCard(usage)
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
          Text(L10n.string(.commandCodeLoading, language: language))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appInsetCard()
      } else {
        emptyView
      }
    }
  }

  private var headerCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      AppProviderHeader(
        imageName: "CommandCodeIcon",
        title: L10n.string(.commandCodeTitle, language: language),
        subtitle: store.menuBarText,
        accessibilityLabel: L10n.string(.a11yCommandCodeIcon, language: language)
      ) {
        HStack(spacing: 6) {
          if let plan = store.usage?.planDisplayName {
            AppStatusBadge(text: plan, tint: AppVisualStyle.accent, showsDot: false)
          }
          statusBadge
        }
      }
      if let email = store.usage?.user?.email, !email.isEmpty {
        Label(
          L10n.string(.commandCodeAccount, language: language, email),
          systemImage: "person.crop.circle"
        )
        .font(AppTypography.caption)
        .foregroundStyle(.secondary)
      }
    }
  }

  private var statusBadge: some View {
    AppStatusBadge(text: statusText, tint: statusColor)
  }

  private var statusText: String {
    switch store.status {
    case .idle, .loading:
      return L10n.string(.statusLoading, language: language)
    case .loaded:
      return L10n.string(.statusLoaded, language: language)
    case .notConfigured:
      return L10n.string(.commandCodeNotConfigured, language: language)
    case .authInvalid:
      return L10n.string(.commandCodeAuthInvalid, language: language)
    case .networkError, .serverError, .decodingError:
      return L10n.string(.statusRequestFailed, language: language)
    }
  }

  private var statusColor: Color {
    switch store.status {
    case .loaded:
      return AppVisualStyle.positive
    case .idle, .loading:
      return AppVisualStyle.accent
    case .notConfigured, .authInvalid:
      return AppVisualStyle.warning
    case .networkError, .serverError, .decodingError:
      return AppVisualStyle.danger
    }
  }

  private func usageCard(_ usage: CommandCodeUsageResponse) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(L10n.string(.commandCodePlan, language: language))
          .font(AppTypography.section)
        Spacer()
        if let remaining = usage.remainingPercent, remaining <= 0 {
          Text(L10n.string(.commandCodeLimitReached, language: language))
            .font(AppTypography.badge)
            .foregroundStyle(.red)
        } else {
          Text(L10n.string(.commandCodeLimitAllowed, language: language))
            .font(AppTypography.badge)
            .foregroundStyle(.green)
        }
      }

      if let start = usage.currentPeriodStartDate, let end = usage.currentPeriodEndDate {
        windowRow(
          periodStart: start,
          periodEnd: end,
          usedPercent: usage.usedPercent,
          remainingPercent: usage.remainingPercent,
          gap: usage.usageGapPercent
        )
      } else if let used = usage.usedPercent {
        // 无订阅周期时仍展示已用进度（无理想用量红线）。
        windowRow(
          periodStart: nil,
          periodEnd: nil,
          usedPercent: used,
          remainingPercent: usage.remainingPercent,
          gap: nil
        )
      }

      if usage.hasActiveWindowLimit {
        windowLimitsSection(usage)
      }

      if let summary = usage.summary {
        summarySection(summary)
      }

      if let last = store.lastUpdated {
        Label(
          L10n.string(
            .commandCodeLastUpdated,
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
    .appInsetCard()
  }

  /// 进度条文案：有差距（实际已用 − 理想已用）时显示“已用 X% · 剩余 Y%（±Z%）”，
  /// 与 Cursor 详情页保持一致；无差距信息时不带括号。
  private func windowProgressText(
    usedPercent: Int,
    remainingPercent: Int,
    gap: Int?
  ) -> String {
    guard let gap else {
      return L10n.string(
        .commandCodeWindowUsedRemaining,
        language: language,
        usedPercent,
        remainingPercent
      )
    }
    let signedGap = "\(gap >= 0 ? "+" : "")\(gap)%"
    return L10n.string(
      .commandCodeWindowUsedRemainingWithGap,
      language: language,
      usedPercent,
      remainingPercent,
      signedGap
    )
  }

  /// 计费周期窗口：已用/剩余进度条 + 理想用量红线 + 重置时间。
  private func windowRow(
    periodStart: Date?,
    periodEnd: Date?,
    usedPercent: Int?,
    remainingPercent: Int?,
    gap: Int?
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(L10n.string(.commandCodeWindowTitle, language: language))
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
        expected: expectedPercent(start: periodStart, end: periodEnd)
      )
      if let periodEnd {
        Text(L10n.string(
          .commandCodeResetAt,
          language: language,
          periodEnd.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened).locale(language.locale)
          )
        ))
        .font(AppTypography.caption)
        .foregroundStyle(.secondary)
      }
    }
    .padding(.bottom, 2)
  }

  /// 5 小时 / 每周窗口限制区块：命中时显示各窗口已用/上限进度。
  @ViewBuilder
  private func windowLimitsSection(_ usage: CommandCodeUsageResponse) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(L10n.string(.commandCodeWindowLimitsTitle, language: language))
        .font(AppTypography.section)
      if let fiveHour = usage.fiveHourLimit {
        windowLimitRow(
          title: L10n.string(.commandCodeWindowFiveHour, language: language),
          limit: fiveHour
        )
      }
      if let weekly = usage.weeklyLimit {
        windowLimitRow(
          title: L10n.string(.commandCodeWindowWeekly, language: language),
          limit: weekly
        )
      }
    }
  }

  private func windowLimitRow(title: String, limit: CommandCodeWindowLimit) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title)
          .font(AppTypography.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Text(windowLimitText(limit))
          .font(AppTypography.caption.monospacedDigit())
          .foregroundStyle(limit.isExceeded ? .red : amountForegroundStyle)
      }
      usageBar(
        usedPercent: limit.usedPercent ?? 0,
        expected: nil
      )
      if let resetAt = limit.resetAtDate {
        Text(L10n.string(
          .commandCodeWindowResetAt,
          language: language,
          resetAt.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened).locale(language.locale)
          )
        ))
        .font(AppTypography.caption)
        .foregroundStyle(.secondary)
      }
    }
  }

  private func windowLimitText(_ limit: CommandCodeWindowLimit) -> String {
    let used = CommandCodeUsageFormatter.formatUSD(limit.used, locale: language.locale) ?? "—"
    let cap = CommandCodeUsageFormatter.formatUSD(limit.cap, locale: language.locale) ?? "—"
    return L10n.string(.commandCodeWindowUsedOfCap, language: language, used, cap)
  }

  /// 本期用量汇总：请求数、花费、成功率、Token 数。
  @ViewBuilder
  private func summarySection(_ summary: CommandCodeUsageSummary) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(L10n.string(.commandCodeSummaryTitle, language: language))
        .font(AppTypography.section)
      if let count = summary.totalCount {
        summaryRow(
          title: L10n.string(.commandCodeSummaryCount, language: language),
          value: "\(count)"
        )
      }
      if let cost = summary.totalCost {
        summaryRow(
          title: L10n.string(.commandCodeSummaryCost, language: language),
          value: CommandCodeUsageFormatter.formatUSD(cost, locale: language.locale) ?? "—"
        )
      }
      if let tokens = summary.totalTokens {
        summaryRow(
          title: L10n.string(.commandCodeSummaryTokens, language: language),
          value: tokens.formatted(.number.locale(language.locale))
        )
      }
      if let rate = summary.successRate {
        summaryRow(
          title: L10n.string(.commandCodeSummarySuccessRate, language: language),
          value: "\(Int(rate.rounded()))%"
        )
      }
    }
  }

  private func summaryRow(title: String, value: String) -> some View {
    HStack {
      Text(title)
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .font(AppTypography.value)
        .foregroundStyle(amountForegroundStyle)
    }
  }

  private func expectedPercent(start: Date?, end: Date?) -> Double? {
    guard let start, let end else { return nil }
    return CommandCodeUsageFormatter.expectedUsedPercent(start: start, end: end)
  }

  /// 自绘进度条：轨道、填充与理想用量红线共用固定 6pt 高度坐标系，
  /// 红线严格与轨道等长、不超出；位置按期望百分比定位并夹在轨道内。
  private func usageBar(
    usedPercent: Int,
    expected: Double? = nil
  ) -> some View {
    AppUsageProgressBar(
      progress: Double(min(max(usedPercent, 0), 100)) / 100,
      color: barColor(usedPercent, idealPercent: expected),
      expected: expected,
      expectedAccessibilityLabel: L10n.string(.commandCodeExpectedMarker, language: language)
    )
  }

  private func barColor(_ usedPercent: Int, idealPercent: Double?) -> Color {
    let gap = idealPercent.map { Double(usedPercent) - $0 }
    return MenuBarUsageColor.detailProgressColor(forGap: gap).map(Color.init(nsColor:))
      ?? AppVisualStyle.progressBlue
  }

  @ViewBuilder
  private var emptyView: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(emptyTitle)
        .font(AppTypography.section)
      if store.status == .notConfigured {
        Text(L10n.string(.commandCodeNotConfiguredDetail, language: language))
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
    .appInsetCard()
  }

  private var emptyTitle: String {
    switch store.status {
    case .notConfigured:
      return L10n.string(.commandCodeNotConfigured, language: language)
    case .authInvalid:
      return L10n.string(.commandCodeAuthInvalid, language: language)
    default:
      return L10n.string(.commandCodeEmpty, language: language)
    }
  }
}
