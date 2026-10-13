import AppKit
import SwiftUI

struct XSubscriptionUsageView: View {
  @ObservedObject var store: XSubscriptionUsageStore
  let language: AppLanguage

  @Environment(\.controlActiveState) private var controlActiveState

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      headerCard
      Divider()
        .overlay(AppVisualStyle.divider)
      if let usage = store.usage {
        weeklyCard(usage)
        productCard(usage)
        extraUsageCard(usage)
        if let error = store.lastDisplayError {
          AppErrorText(text: error.text(language: language))
        }
      } else if store.isRefreshing || store.status == .loading {
        AppLoadingCard(text: L10n.string(.xSubscriptionLoading, language: language))
      } else {
        emptyView
      }
    }
  }

  private var headerCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      AppProviderHeader(
        imageName: "XSubscriptionIcon",
        title: L10n.string(.xSubscriptionTitle, language: language),
        subtitle: store.menuBarText,
        accessibilityLabel: L10n.string(.a11yXSubscriptionIcon, language: language)
      ) {
        HStack(spacing: 6) {
          if let plan = store.usage?.planDisplayName, !plan.isEmpty {
            AppStatusBadge(text: plan, tint: AppVisualStyle.accent, showsDot: false)
          }
          if let usage = store.usage {
            AppStatusBadge(
              text: L10n.string(
                usage.isMerged ? .xSubscriptionMerged : .xSubscriptionLegacy,
                language: language
              ),
              tint: usage.isMerged ? AppVisualStyle.positive : AppVisualStyle.warning,
              showsDot: false
            )
          }
          statusBadge
        }
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
      return L10n.string(.xSubscriptionNotConfigured, language: language)
    case .authInvalid:
      return L10n.string(.xSubscriptionAuthInvalid, language: language)
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

  @ViewBuilder
  private func weeklyCard(_ usage: XSubscriptionUsageSnapshot) -> some View {
    switch usage.weekly {
    case .metered(let quota):
      meteredCard(quota)
    case .enterprisePooled:
      copyOnlyCard(L10n.string(.xSubscriptionEnterprisePooled, language: language))
    case .noIncludedLimit:
      copyOnlyCard(L10n.string(.xSubscriptionNoIncludedLimit, language: language))
    case .trial(let trial):
      trialCard(trial)
    }
  }

  private func meteredCard(_ quota: XSubscriptionWeeklyQuota) -> some View {
    let gap = quota.usageGapPercent(now: store.clock.now())
    return VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(L10n.string(.xSubscriptionWindowTitle, language: language))
          .font(AppTypography.section)
        Spacer()
        AppLimitBadge(
          text: L10n.string(
            quota.remainingPercent <= 0
              ? .xSubscriptionLimitReached
              : .xSubscriptionLimitAllowed,
            language: language
          ),
          isReached: quota.remainingPercent <= 0
        )
      }

      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Spacer()
          Text(windowProgressText(used: quota.usedPercent, remaining: quota.remainingPercent, gap: gap))
            .font(AppTypography.caption.monospacedDigit())
            .foregroundStyle(AppVisualStyle.amountForeground(controlActiveState))
        }
        AppUsageProgressBar(
          usedPercent: quota.usedPercent,
          expected: expectedPercent(start: quota.resolvedWindowStart, end: quota.resetsAt),
          expectedAccessibilityLabel: L10n.string(.xSubscriptionExpectedMarker, language: language)
        )
        if let resetsAt = quota.resetsAt {
          ResetAtCaption(
            label: L10n.string(
              .xSubscriptionResetAt,
              language: language,
              UsageFormatting.abbreviatedDateTime(resetsAt, locale: language.locale)
            ),
            until: resetsAt
          )
        }
        if let forecast = XSubscriptionExhaustion.forecast(
          samples: store.historySamples,
          now: store.clock.now(),
          resetsAt: quota.resetsAt
        ) {
          Text(exhaustionEstimateText(forecast))
            .font(AppTypography.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      if let last = store.lastUpdated {
        lastUpdatedLabel(last)
      }
    }
    .appInsetCard()
  }

  private func trialCard(_ trial: XSubscriptionTrial) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(L10n.string(.xSubscriptionTrial, language: language))
        .font(AppTypography.section)
      Text(
        UsageFormatting.abbreviatedDateTime(trial.expiresAt, locale: language.locale)
      )
      .font(AppTypography.caption)
      .foregroundStyle(.secondary)
    }
    .appInsetCard()
  }

  private func productCard(_ usage: XSubscriptionUsageSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(L10n.string(.xSubscriptionBreakdownTitle, language: language))
        .font(AppTypography.section)
      if let breakdown = usage.productBreakdown, !breakdown.isEmpty {
        HStack(alignment: .center, spacing: 12) {
          productPie(breakdown.pieSlices)
          VStack(alignment: .leading, spacing: 6) {
            productRow(.cursor, spend: breakdown.cursor)
            productRow(.grokBot, spend: breakdown.grokBot)
            productRow(.grokChat, spend: nil, unavailable: true)
          }
        }
        Text(L10n.string(.xSubscriptionGrokChatNote, language: language))
          .font(AppTypography.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Button {
          NSWorkspace.shared.open(XSubscriptionUsageFormatter.grokUsageDashboardURL)
        } label: {
          Label(
            L10n.string(.xSubscriptionOpenGrokUsage, language: language),
            systemImage: "arrow.up.right.square"
          )
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      } else {
        Text(L10n.string(.xSubscriptionProductEmpty, language: language))
          .font(AppTypography.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .appInsetCard()
  }

  /// 环形饼图（自绘，兼容 macOS 13；Swift Charts 的 SectorMark 需要 macOS 14）。
  private func productPie(_ slices: [XSubscriptionProductSlice]) -> some View {
    let total = slices.reduce(0) { $0 + $1.value }
    return Canvas { context, size in
      guard total > 0 else { return }
      let side = min(size.width, size.height)
      let lineWidth = side * 0.22
      let rect = CGRect(
        x: (size.width - side) / 2 + lineWidth / 2,
        y: (size.height - side) / 2 + lineWidth / 2,
        width: side - lineWidth,
        height: side - lineWidth
      )
      let center = CGPoint(x: rect.midX, y: rect.midY)
      let radius = rect.width / 2
      var start = -90.0
      for slice in slices {
        let sweep = slice.value / total * 360
        var path = Path()
        path.addArc(
          center: center,
          radius: radius,
          startAngle: .degrees(start),
          endAngle: .degrees(start + sweep),
          clockwise: false
        )
        context.stroke(
          path,
          with: .color(ProductKind(slice.product).color),
          style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt)
        )
        start += sweep
      }
    }
    .frame(width: 64, height: 64)
    .accessibilityHidden(true)
  }

  private enum ProductKind {
    case cursor
    case grokBot
    case grokChat

    init(_ product: XSubscriptionProduct) {
      switch product {
      case .cursor: self = .cursor
      case .grokBot: self = .grokBot
      case .grokChat: self = .grokChat
      }
    }

    var color: Color {
      switch self {
      case .cursor:
        return .blue
      case .grokBot:
        return .green
      case .grokChat:
        return .orange
      }
    }
  }

  private func productRow(
    _ kind: ProductKind,
    spend: XSubscriptionProductSpend?,
    unavailable: Bool = false
  ) -> some View {
    HStack {
      HStack(spacing: 6) {
        Circle()
          .fill(kind.color)
          .frame(width: 6, height: 6)
        Text(productTitle(kind))
          .foregroundStyle(.secondary)
      }
      Spacer()
      Text(productValue(spend: spend, unavailable: unavailable))
        .font(AppTypography.value)
        .foregroundStyle(AppVisualStyle.amountForeground(controlActiveState))
    }
  }

  private func productTitle(_ kind: ProductKind) -> String {
    switch kind {
    case .cursor:
      return L10n.string(.xSubscriptionProductCursor, language: language)
    case .grokBot:
      return L10n.string(.xSubscriptionProductGrokBot, language: language)
    case .grokChat:
      return L10n.string(.xSubscriptionProductGrokChat, language: language)
    }
  }

  private func productValue(spend: XSubscriptionProductSpend?, unavailable: Bool) -> String {
    if unavailable {
      return "—"
    }
    guard let spend else { return "—" }
    var parts: [String] = [
      XSubscriptionUsageFormatter.formatTokens(spend.tokens, locale: language.locale)
    ]
    if let share = spend.sharePercent {
      parts.append("\(share)%")
    }
    if let cents = XSubscriptionUsageFormatter.formatCents(
      spend.spendCents,
      locale: language.locale
    ) {
      parts.append(cents)
    }
    return parts.joined(separator: " · ")
  }

  @ViewBuilder
  private func extraUsageCard(_ usage: XSubscriptionUsageSnapshot) -> some View {
    let shouldShow =
      usage.prepaid != nil
      || usage.hardLimit != nil
      || usage.billingURL != nil
    if shouldShow {
      VStack(alignment: .leading, spacing: 8) {
        ServiceCardAmountHeader(
          imageName: "XSubscriptionIcon",
          title: L10n.string(.xSubscriptionExtraTitle, language: language),
          value: usage.prepaid.map {
            UsageFormatting.formattedUSD(
              Double($0.availableCents) / 100,
              locale: language.locale
            )
          },
          emptyText: L10n.string(.openCodeNoData, language: language)
        )
        Text(L10n.string(.xSubscriptionExtraDescription, language: language))
          .font(AppTypography.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if let detail = extraUsageDetailText(usage) {
          Text(detail)
            .font(AppTypography.caption)
            .foregroundStyle(.secondary)
        }
        if let last = store.lastUpdated {
          lastUpdatedLabel(last)
        }
        if let url = usage.billingURL {
          Button {
            NSWorkspace.shared.open(url)
          } label: {
            Text(L10n.string(.xSubscriptionOpenBilling, language: language))
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
      }
      .appInsetCard()
    }
  }

  /// "本月已花 $X · 上限 不限" 合并为一行说明，缺失的部分省略。
  private func extraUsageDetailText(_ usage: XSubscriptionUsageSnapshot) -> String? {
    var parts: [String] = []
    if let spent = usage.prepaid?.spentThisMonthCents {
      parts.append(
        L10n.string(
          .xSubscriptionSpentThisMonth,
          language: language,
          XSubscriptionUsageFormatter.formatCents(spent, locale: language.locale)
        )
      )
    }
    if let hardLimit = usage.hardLimit {
      parts.append(hardLimitText(hardLimit))
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private func hardLimitText(_ hardLimit: XSubscriptionHardLimit) -> String {
    let limit: String
    if hardLimit.isUnlimited {
      limit = L10n.string(.xSubscriptionOnDemandUnlimited, language: language)
    } else {
      limit = XSubscriptionUsageFormatter.formatDollars(hardLimit.dollars, locale: language.locale)
    }
    return L10n.string(.xSubscriptionOnDemandLimit, language: language, limit)
  }

  private func exhaustionEstimateText(_ forecast: XSubscriptionExhaustionForecast) -> String {
    switch forecast {
    case .alreadyExhausted:
      return L10n.string(.trendEstimateExhausted, language: language)
    case .depletesBeforeReset(let seconds), .survivesUntilReset(let seconds):
      return L10n.string(
        .trendEstimateWeekly,
        language: language,
        UsageExhaustionEstimator.formattedDuration(seconds, language: language)
      )
    }
  }

  private func copyOnlyCard(_ message: String) -> some View {
    Text(message)
      .font(AppTypography.caption)
      .foregroundStyle(.secondary)
      .appInsetCard()
  }

  private func windowProgressText(used: Int, remaining: Int, gap: Int?) -> String {
    guard let gap else {
      return L10n.string(.xSubscriptionWindowUsedRemaining, language: language, used, remaining)
    }
    return L10n.string(
      .xSubscriptionWindowUsedRemainingWithGap,
      language: language,
      used,
      remaining,
      UsageFormatting.signedPercent(gap)
    )
  }

  private func expectedPercent(start: Date?, end: Date?) -> Double? {
    guard let start, let end else { return nil }
    return XSubscriptionUsageFormatter.expectedUsedPercent(
      start: start,
      end: end,
      now: store.clock.now()
    )
  }

  private func lastUpdatedLabel(_ date: Date) -> some View {
    AppLastUpdatedLabel(
      text: L10n.string(
        .xSubscriptionLastUpdated,
        language: language,
        UsageFormatting.abbreviatedDateTime(date, locale: language.locale)
      )
    )
  }

  private var emptyView: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(L10n.string(.xSubscriptionEmpty, language: language))
        .foregroundStyle(.secondary)
      Text(L10n.string(.xSubscriptionNotConfiguredDetail, language: language))
        .font(AppTypography.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .appInsetCard()
  }
}
