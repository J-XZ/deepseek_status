import SwiftUI

struct GrokBotUsageView: View {
  @ObservedObject var store: GrokBotUsageStore
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
        weeklyCard(usage)
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
          Text(L10n.string(.grokBotLoading, language: language))
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
        imageName: "GrokBotIcon",
        title: L10n.string(.grokBotTitle, language: language),
        subtitle: store.menuBarText,
        accessibilityLabel: L10n.string(.a11yGrokBotIcon, language: language)
      ) {
        HStack(spacing: 6) {
          if let plan = store.usage?.planDisplayName, !plan.isEmpty {
            AppStatusBadge(text: plan, tint: AppVisualStyle.accent, showsDot: false)
          } else if let plan = CursorUsageFormatter.planDisplayName(store.profile?.planTier) {
            AppStatusBadge(text: plan, tint: AppVisualStyle.accent, showsDot: false)
          }
          statusBadge
        }
      }
      if let email = store.profile?.email, !email.isEmpty {
        Label(
          L10n.string(.grokBotAccount, language: language, email),
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
      return L10n.string(.grokBotNotConfigured, language: language)
    case .authInvalid:
      return L10n.string(.grokBotAuthInvalid, language: language)
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
  private func weeklyCard(_ usage: GrokBotUsageSnapshot) -> some View {
    switch usage.weekly {
    case .metered(let quota):
      meteredCard(quota)
    case .enterprisePooled:
      copyOnlyCard(L10n.string(.grokBotEnterprisePooled, language: language))
    case .noIncludedLimit:
      copyOnlyCard(L10n.string(.grokBotNoIncludedLimit, language: language))
    case .trial(let trial):
      trialCard(trial)
    }
  }

  private func meteredCard(_ quota: GrokBotWeeklyQuota) -> some View {
    let gap = quota.usageGapPercent(now: store.clock.now())
    return VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(L10n.string(.grokBotWindowTitle, language: language))
          .font(AppTypography.section)
        Spacer()
        Text(
          quota.remainingPercent <= 0
            ? L10n.string(.grokBotLimitReached, language: language)
            : L10n.string(.grokBotLimitAllowed, language: language)
        )
        .font(AppTypography.badge)
        .foregroundStyle(quota.remainingPercent <= 0 ? .red : .green)
      }

      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Spacer()
          Text(windowProgressText(quota: quota, gap: gap))
            .font(AppTypography.caption.monospacedDigit())
            .foregroundStyle(amountForegroundStyle)
        }
        usageBar(quota: quota)
        if let resetsAt = quota.resetsAt {
          ResetAtCaption(
            label: L10n.string(
              .grokBotResetAt,
              language: language,
              resetsAt.formatted(
                Date.FormatStyle(date: .abbreviated, time: .shortened).locale(language.locale)
              )
            ),
            until: resetsAt
          )
        }
      }

      if let last = store.lastUpdated {
        Label(
          L10n.string(
            .grokBotLastUpdated,
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

  private func trialCard(_ trial: GrokBotTrial) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(L10n.string(.grokBotTrial, language: language))
        .font(AppTypography.section)
      Text(
        trial.expiresAt.formatted(
          Date.FormatStyle(date: .abbreviated, time: .shortened).locale(language.locale)
        )
      )
      .font(AppTypography.caption)
      .foregroundStyle(.secondary)
    }
    .appInsetCard()
  }

  private func copyOnlyCard(_ message: String) -> some View {
    Text(message)
      .font(AppTypography.caption)
      .foregroundStyle(.secondary)
      .appInsetCard()
  }

  private func windowProgressText(quota: GrokBotWeeklyQuota, gap: Int?) -> String {
    let used = quota.usedPercent
    let remaining = quota.remainingPercent
    guard let gap else {
      return L10n.string(.grokBotWindowUsedRemaining, language: language, used, remaining)
    }
    let signedGap = "\(gap >= 0 ? "+" : "")\(gap)%"
    return L10n.string(
      .grokBotWindowUsedRemainingWithGap,
      language: language,
      used,
      remaining,
      signedGap
    )
  }

  private func usageBar(quota: GrokBotWeeklyQuota) -> some View {
    let expected: Double? = {
      guard let start = quota.windowStart, let end = quota.resetsAt else { return nil }
      return GrokBotUsageFormatter.expectedUsedPercent(
        start: start,
        end: end,
        now: store.clock.now()
      )
    }()
    let gap = expected.map { Double(quota.usedPercent) - $0 }
    let color = MenuBarUsageColor.detailProgressColor(forGap: gap).map(Color.init(nsColor:))
      ?? AppVisualStyle.progressBlue
    return AppUsageProgressBar(
      progress: Double(min(max(quota.usedPercent, 0), 100)) / 100,
      color: color,
      expected: expected,
      expectedAccessibilityLabel: L10n.string(.grokBotExpectedMarker, language: language)
    )
  }

  private var emptyView: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(L10n.string(.grokBotEmpty, language: language))
        .foregroundStyle(.secondary)
      Text(L10n.string(.grokBotNotConfiguredDetail, language: language))
        .font(AppTypography.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .appInsetCard()
  }
}
