import SwiftUI

/// Vultr 标签页：显示实例剩余流量和账户剩余额度，不显示百分比。
struct VPSUsageView: View {
  @ObservedObject var store: VPSUsageStore
  let language: AppLanguage

  /// 过去 24 小时信用额度下跌颜色：‑5 红、‑2 黄，否则默认。
  private var creditDropColor: Color? {
    guard let change = UsageHistoryWindow.change24h(
      samples: store.historySamples,
      value: { $0.availableCreditUSD },
      date: \.bucketStart
    ) else { return nil }
    return UsageHistoryWindow.dropColor(changeUSD: change)
  }


  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      headerCard
      if let email = store.snapshot?.accountEmail, !email.isEmpty {
        Label(
          L10n.string(.vpsAccount, language: language, email),
          systemImage: "person.crop.circle"
        )
        .font(AppTypography.caption)
        .foregroundStyle(.secondary)
      }
      Divider()
        .overlay(AppVisualStyle.divider)
      if let snapshot = store.snapshot {
        usageCard(snapshot)
        cycleCard()
        if let error = store.lastDisplayError {
          AppErrorText(text: error.text(language: language))
        }
      } else if store.isRefreshing || store.status == .loading {
        AppLoadingCard(text: L10n.string(.vpsLoading, language: language))
      } else {
        emptyView
      }
    }
  }

  private var headerCard: some View {
    AppProviderHeader(
      imageName: "VultrIcon",
      title: L10n.string(.vpsTitle, language: language),
      subtitle: store.menuBarText(language: language),
      accessibilityLabel: L10n.string(.a11yVPSIcon, language: language)
    ) {
      AppStatusBadge(text: store.statusTitle(language: language), tint: statusColor)
    }
  }

  private func usageCard(_ snapshot: VPSUsageSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(L10n.string(.vpsInstance, language: language))
          .font(AppTypography.section)
        Spacer()
        Text(snapshot.instanceLabel ?? snapshot.instanceID)
          .font(AppTypography.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }

      AppAmountRow(
        title: L10n.string(.vpsRemainingTraffic, language: language),
        value: UsageFormatting.formattedGB(snapshot.remainingBandwidthGB)
      )
      AppAmountRow(
        title: L10n.string(.vpsRemainingCredit, language: language),
        value: UsageFormatting.formattedUSD(snapshot.availableCreditUSD, locale: language.locale),
        valueColor: creditDropColor
      )
    }
    .appInsetCard()
  }

  private func cycleCard() -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(L10n.string(.vpsBillingCycle, language: language))
        .font(AppTypography.section)
      if let remainingText = store.currentCycleRemainingText(language: language) {
        Text(remainingText)
          .font(AppTypography.caption)
          .foregroundStyle(.secondary)
      }

      if let lastUpdated = store.lastUpdated {
        AppLastUpdatedLabel(
          text: L10n.string(
            .vpsLastUpdated,
            language: language,
            UsageFormatting.abbreviatedDateTime(lastUpdated, locale: language.locale)
          )
        )
      }
    }
    .appInsetCard()
  }

  private var emptyView: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(L10n.string(.vpsEmpty, language: language))
        .foregroundStyle(.secondary)
      if let error = store.lastDisplayError {
        AppErrorText(text: error.text(language: language))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .appInsetCard()
  }

  private var statusColor: Color {
    switch store.status {
    case .loaded:
      return AppVisualStyle.positive
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


}
