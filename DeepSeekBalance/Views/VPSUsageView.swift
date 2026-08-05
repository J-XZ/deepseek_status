import SwiftUI

/// Vultr 标签页：显示实例剩余流量和账户剩余额度，不显示百分比。
struct VPSUsageView: View {
  @ObservedObject var store: VPSUsageStore
  let language: AppLanguage
  let appearance: AppAppearance

  @Environment(\.controlActiveState) private var controlActiveState

  private var amountForegroundStyle: Color {
    controlActiveState == .inactive ? .secondary : .primary
  }

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
        .padding(.leading, 10)
      }
      if let snapshot = store.snapshot {
        usageCard(snapshot)
        cycleCard()
        if let error = store.lastDisplayError {
          errorText(error.text(language: language))
        }
      } else if store.isRefreshing || store.status == .loading {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text(L10n.string(.vpsLoading, language: language))
            .foregroundStyle(.secondary)
        }
      } else {
        emptyView
      }
    }
  }

  private var headerCard: some View {
    HStack(spacing: 10) {
      Image("VultrIcon")
        .renderingMode(.template)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 24, height: 24)
        .padding(8)
        .accessibilityLabel(L10n.string(.a11yVPSIcon, language: language))

      VStack(alignment: .leading, spacing: 2) {
        Text(L10n.string(.vpsTitle, language: language))
          .font(AppTypography.title)
        Text(store.menuBarText(language: language))
          .font(AppTypography.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      Spacer()
      Text(store.statusTitle(language: language))
        .font(AppTypography.badge)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(statusColor.opacity(0.14), in: Capsule())
        .foregroundStyle(statusColor)
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

      valueRow(
        title: L10n.string(.vpsRemainingTraffic, language: language),
        value: UsageFormatting.formattedGB(snapshot.remainingBandwidthGB)
      )
      valueRow(
        title: L10n.string(.vpsRemainingCredit, language: language),
        value: UsageFormatting.formattedUSD(snapshot.availableCreditUSD, locale: language.locale),
        foregroundStyle: creditDropColor
      )
    }
    .padding(10)
    .background(cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
        Label(
          L10n.string(
            .vpsLastUpdated,
            language: language,
            lastUpdated.formatted(
              Date.FormatStyle(date: .abbreviated, time: .shortened).locale(language.locale)
            )
          ),
          systemImage: "clock"
        )
        .font(AppTypography.caption)
        .foregroundStyle(.secondary)
      }
    }
    .padding(10)
    .background(cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private var emptyView: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(L10n.string(.vpsEmpty, language: language))
        .foregroundStyle(.secondary)
      if let error = store.lastDisplayError {
        errorText(error.text(language: language))
      }
    }
  }

  private func valueRow(
    title: String,
    value: String,
    foregroundStyle: Color? = nil
  ) -> some View {
    HStack {
      Text(title)
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .font(AppTypography.value)
        .foregroundStyle(foregroundStyle ?? amountForegroundStyle)
    }
  }

  private func errorText(_ text: String) -> some View {
    Text(text)
      .font(AppTypography.caption)
      .foregroundStyle(.red)
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var cardBackground: Color {
    appearance == .dark ? Color(white: 0.14) : Color(white: 0.96)
  }

  private var statusColor: Color {
    switch store.status {
    case .loaded:
      return .green
    case .idle, .loading:
      return .blue
    case .notConfigured:
      return .secondary
    case .authInvalid:
      return .orange
    case .keychainError, .networkError, .serverError, .decodingError:
      return .red
    }
  }


}

