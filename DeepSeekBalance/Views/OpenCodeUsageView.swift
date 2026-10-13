import SwiftUI

/// OpenCode 标签页：同时展示 Go 订阅窗口和 Zen 余额。
struct OpenCodeUsageView: View {
  @ObservedObject var store: OpenCodeUsageStore
  let language: AppLanguage

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      headerCard
      if let email = store.snapshot?.accountEmail, !email.isEmpty {
        Label(
          L10n.string(.openCodeAccount, language: language, email),
          systemImage: "person.crop.circle"
        )
        .font(AppTypography.caption)
        .foregroundStyle(.secondary)
      }
      Divider()
        .overlay(AppVisualStyle.divider)
      if let snapshot = store.snapshot {
        zenCard(snapshot)
        goCard(snapshot)
        if let error = store.lastDisplayError {
          AppErrorText(text: error.text(language: language))
        }
      } else if store.isRefreshing || store.status == .loading {
        // 加载占位卡与真实卡等高：加载期间页面高度不塌缩，窗口不会先缩后涨、
        // 也不会在卡片下方留下一大块空白。
        loadingZenCard
        loadingGoCard
      } else {
        emptyView
      }
    }
  }

  private var headerCard: some View {
    AppProviderHeader(
      imageName: "OpenCodeIcon",
      title: L10n.string(.openCodeTitle, language: language),
      subtitle: store.menuBarText,
      accessibilityLabel: L10n.string(.a11yOpenCodeIcon, language: language)
    ) {
      statusBadge
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
      if store.snapshot?.goSubscription == nil {
        return L10n.string(.openCodeNoSubscription, language: language)
      }
      return L10n.string(.statusLoaded, language: language)
    case .notConfigured:
      return L10n.string(.openCodeNotConfigured, language: language)
    case .keychainError, .networkError, .serverError, .decodingError:
      return L10n.string(.statusRequestFailed, language: language)
    case .authInvalid:
      return L10n.string(.openCodeAuthInvalid, language: language)
    }
  }

  private var statusColor: Color {
    switch store.status {
    case .loaded:
      return store.snapshot?.goSubscription == nil
        ? AppVisualStyle.danger : AppVisualStyle.positive
    case .idle, .loading:
      return AppVisualStyle.accent
    case .notConfigured:
      return .secondary
    case .authInvalid:
      return AppVisualStyle.warning
    case .keychainError, .networkError, .serverError, .decodingError:
      return AppVisualStyle.danger
    }
  }

  private func zenCard(_ snapshot: OpenCodeUsageSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      ServiceCardAmountHeader(
        imageName: "OpenCodeZenIcon",
        title: L10n.string(.openCodeZenTitle, language: language),
        value: snapshot.zenBalanceUSD.map {
          UsageFormatting.formattedUSD($0, locale: language.locale)
        },
        emptyText: L10n.string(.openCodeNoData, language: language)
      )
      Text(L10n.string(.openCodeZenDescription, language: language))
        .font(AppTypography.caption)
        .foregroundStyle(.secondary)
      if let last = store.lastUpdated {
        AppLastUpdatedLabel(
          text: L10n.string(
            .openCodeLastUpdated,
            language: language,
            UsageFormatting.abbreviatedDateTime(last, locale: language.locale)
          )
        )
      }
    }
    .appInsetCard()
  }

  private func goCard(_ snapshot: OpenCodeUsageSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        ServiceCardTitle(
          imageName: "OpenCodeGoIcon",
          title: L10n.string(.openCodeGoTitle, language: language)
        )
        Spacer()
        AppLimitBadge(
          text: L10n.string(
            snapshot.goSubscription == nil ? .openCodeNoSubscription : .openCodeSubscribed,
            language: language
          ),
          isReached: snapshot.goSubscription == nil
        )
      }

      if let subscription = snapshot.goSubscription, !subscription.windows.isEmpty {
        ForEach(subscription.windows) { window in
          windowRow(window)
        }
      } else if snapshot.goSubscription == nil {
        AppUsageProgressBar(progress: 0, color: .red)
        Text(L10n.string(.openCodeNoSubscriptionDetail, language: language))
          .font(AppTypography.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        Text(L10n.string(.openCodeUsageUnavailable, language: language))
          .font(AppTypography.caption)
          .foregroundStyle(.secondary)
      }
    }
    .appInsetCard()
  }

  private var loadingZenCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        ServiceCardTitle(
          imageName: "OpenCodeZenIcon",
          title: L10n.string(.openCodeZenTitle, language: language)
        )
        Spacer()
        ProgressView()
          .controlSize(.small)
      }
      Text(L10n.string(.openCodeLoading, language: language))
        .font(AppTypography.caption)
        .foregroundStyle(.secondary)
    }
    .frame(minHeight: 84)
    .appInsetCard()
  }

  private var loadingGoCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        ServiceCardTitle(
          imageName: "OpenCodeGoIcon",
          title: L10n.string(.openCodeGoTitle, language: language)
        )
        Spacer()
        ProgressView()
          .controlSize(.small)
      }
      AppUsageProgressBar(
        progress: 0.45,
        color: AppVisualStyle.progressBlue
      )
      AppUsageProgressBar(
        progress: 0.3,
        color: AppVisualStyle.progressBlue
      )
      AppUsageProgressBar(
        progress: 0.15,
        color: AppVisualStyle.progressBlue
      )
    }
    .frame(minHeight: 150)
    .appInsetCard()
  }

  private func windowRow(_ window: OpenCodeUsageWindow) -> some View {
    let now = store.clock.now()
    let expected = window.expectedUsedPercent(now: now)
    let gap = window.usageGapPercent(now: now)

    return VStack(alignment: .leading, spacing: 4) {
      AppUsageProgressHeader(
        title: windowTitle(window.kind),
        progressText: windowProgressText(window, gap: gap)
      )
      AppUsageProgressBar(
        usedPercent: window.usedPercent,
        expected: expected,
        expectedAccessibilityLabel: L10n.string(
          .openCodeExpectedMarker,
          language: language
        )
      )
      // resetAt is now + resetInSec; capture from store.clock, not TimelineView's context.date.
      if let reset = window.resetAt(now: now) {
        ResetAtCaption(
          label: L10n.string(
            .openCodeResetAt,
            language: language,
            UsageFormatting.abbreviatedDateTime(reset, locale: language.locale)
          ),
          until: reset
        )
      }
    }
  }

  private func windowProgressText(
    _ window: OpenCodeUsageWindow,
    gap: Int?
  ) -> String {
    guard let gap else {
      return L10n.string(
        .openCodeProgress,
        language: language,
        window.usedPercent,
        window.remainingPercent
      )
    }
    return L10n.string(
      .openCodeProgressWithGap,
      language: language,
      window.usedPercent,
      window.remainingPercent,
      UsageFormatting.signedPercent(gap)
    )
  }

  private var emptyView: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(L10n.string(.openCodeEmpty, language: language))
        .foregroundStyle(.secondary)
      if let error = store.lastDisplayError {
        AppErrorText(text: error.text(language: language))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .appInsetCard()
  }

  private func windowTitle(_ kind: OpenCodeUsageWindow.Kind) -> String {
    switch kind {
    case .rolling:
      return L10n.string(.openCodeWindowRolling, language: language)
    case .weekly:
      return L10n.string(.openCodeWindowWeekly, language: language)
    case .monthly:
      return L10n.string(.openCodeWindowMonthly, language: language)
    }
  }

}
