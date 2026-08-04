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

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      headerCard
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
        .background(Color.accentColor.opacity(0.12), in: Circle())
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
        Label(
          L10n.string(.vpsInstance, language: language),
          systemImage: "server.rack"
        )
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
        value: formattedGB(snapshot.remainingBandwidthGB)
      )
      valueRow(
        title: L10n.string(.vpsRemainingCredit, language: language),
        value: formattedUSD(snapshot.availableCreditUSD)
      )
    }
    .padding(10)
    .background(cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private func cycleCard() -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(L10n.string(.vpsBillingCycle, language: language), systemImage: "calendar")
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

  private func valueRow(title: String, value: String) -> some View {
    HStack {
      Text(title)
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .font(AppTypography.value)
        .foregroundStyle(amountForegroundStyle)
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

  private func formattedGB(_ value: Double) -> String {
    String(format: "%.0f GB", value)
  }

  private func formattedUSD(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.locale = language.locale
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    return formatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
  }

}
