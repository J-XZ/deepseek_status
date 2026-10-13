import SwiftUI

/// Command Code 用量标签页：订阅方案、额度使用、窗口限制与账号信息。
/// 与其它订阅用量页使用相同的卡片结构。
struct CommandCodeUsageView: View {
  @ObservedObject var store: CommandCodeUsageStore
  let language: AppLanguage

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      headerCard
      Divider()
        .overlay(AppVisualStyle.divider)
      if let usage = store.usage {
        usageCard(usage)
        if let error = store.lastDisplayError {
          AppErrorText(text: error.text(language: language))
        }
      } else if store.isRefreshing || store.status == .loading {
        AppLoadingCard(text: L10n.string(.commandCodeLoading, language: language))
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
        AppLimitBadge(
          text: L10n.string(
            (usage.remainingPercent ?? 1) <= 0
              ? .commandCodeLimitReached
              : .commandCodeLimitAllowed,
            language: language
          ),
          isReached: (usage.remainingPercent ?? 1) <= 0
        )
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
        AppLastUpdatedLabel(
          text: L10n.string(
            .commandCodeLastUpdated,
            language: language,
            UsageFormatting.abbreviatedDateTime(last, locale: language.locale)
          )
        )
      }
    }
    .appInsetCard()
  }

  /// 进度条文案：有差距（实际已用 − 理想已用）时显示“已用 X% · 剩余 Y%（±Z%）”，
  /// 与其它订阅详情页保持一致；无差距信息时不带括号。
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
    return L10n.string(
      .commandCodeWindowUsedRemainingWithGap,
      language: language,
      usedPercent,
      remainingPercent,
      UsageFormatting.signedPercent(gap)
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
      AppUsageProgressHeader(
        title: L10n.string(.commandCodeWindowTitle, language: language),
        progressText: windowProgressText(
          usedPercent: usedPercent ?? 0,
          remainingPercent: remainingPercent ?? 0,
          gap: gap
        )
      )
      AppUsageProgressBar(
        usedPercent: usedPercent ?? 0,
        expected: expectedPercent(start: periodStart, end: periodEnd),
        expectedAccessibilityLabel: L10n.string(.commandCodeExpectedMarker, language: language)
      )
      if let periodEnd {
        ResetAtCaption(
          label: L10n.string(
            .commandCodeResetAt,
            language: language,
            UsageFormatting.abbreviatedDateTime(periodEnd, locale: language.locale)
          ),
          until: periodEnd
        )
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
      AppUsageProgressHeader(
        title: title,
        progressText: windowLimitText(limit),
        progressColor: limit.isExceeded ? .red : nil
      )
      AppUsageProgressBar(
        usedPercent: limit.usedPercent ?? 0,
        expectedAccessibilityLabel: L10n.string(.commandCodeExpectedMarker, language: language)
      )
      if let resetAt = limit.resetAtDate {
        ResetAtCaption(
          label: L10n.string(
            .commandCodeWindowResetAt,
            language: language,
            UsageFormatting.abbreviatedDateTime(resetAt, locale: language.locale)
          ),
          until: resetAt
        )
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
        AppAmountRow(
          title: L10n.string(.commandCodeSummaryCount, language: language),
          value: "\(count)"
        )
      }
      if let cost = summary.totalCost {
        AppAmountRow(
          title: L10n.string(.commandCodeSummaryCost, language: language),
          value: CommandCodeUsageFormatter.formatUSD(cost, locale: language.locale) ?? "—"
        )
      }
      if let tokens = summary.totalTokens {
        AppAmountRow(
          title: L10n.string(.commandCodeSummaryTokens, language: language),
          value: tokens.formatted(.number.locale(language.locale))
        )
      }
      if let rate = summary.successRate {
        AppAmountRow(
          title: L10n.string(.commandCodeSummarySuccessRate, language: language),
          value: "\(Int(rate.rounded()))%"
        )
      }
    }
  }

  private func expectedPercent(start: Date?, end: Date?) -> Double? {
    guard let start, let end else { return nil }
    return CommandCodeUsageFormatter.expectedUsedPercent(start: start, end: end)
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
        AppErrorText(text: error.text(language: language))
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
