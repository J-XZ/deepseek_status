import SwiftUI

/// OpenCode 标签页：同时展示 Go 订阅窗口和 Zen 余额。
struct OpenCodeUsageView: View {
  @ObservedObject var store: OpenCodeUsageStore
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
        zenCard(snapshot)
        goCard(snapshot)
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
          Text(L10n.string(.openCodeLoading, language: language))
            .foregroundStyle(.secondary)
        }
      } else {
        emptyView
      }
    }
  }

  private var headerCard: some View {
    HStack(spacing: 10) {
      Image(systemName: "globe")
        .font(.system(size: 23, weight: .semibold))
        .foregroundStyle(Color.accentColor)
        .frame(width: 24, height: 24)
        .padding(8)
        .background(Color.accentColor.opacity(0.12), in: Circle())
        .accessibilityLabel(L10n.string(.a11yOpenCodeIcon, language: language))
      VStack(alignment: .leading, spacing: 2) {
        Text(L10n.string(.openCodeTitle, language: language))
          .font(AppTypography.title)
        Text(store.menuBarText)
          .font(AppTypography.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      Spacer()
      statusBadge
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
      return store.snapshot?.goSubscription == nil ? .red : .green
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

  private func zenCard(_ snapshot: OpenCodeUsageSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label(L10n.string(.openCodeZenTitle, language: language), systemImage: "sparkles")
          .font(AppTypography.section)
        Spacer()
        if let balance = snapshot.zenBalanceUSD {
          Text(formattedUSD(balance))
            .font(AppTypography.value)
            .foregroundStyle(amountForegroundStyle)
        } else {
          Text(L10n.string(.openCodeNoData, language: language))
            .font(AppTypography.caption)
            .foregroundStyle(.secondary)
        }
      }
      Text(L10n.string(.openCodeZenDescription, language: language))
        .font(AppTypography.caption)
        .foregroundStyle(.secondary)
      if let last = store.lastUpdated {
        Label(
          L10n.string(
            .openCodeLastUpdated,
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
    .padding(10)
    .background(cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private func goCard(_ snapshot: OpenCodeUsageSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label(L10n.string(.openCodeGoTitle, language: language), systemImage: "gauge.with.dots.needle.67percent")
          .font(AppTypography.section)
        Spacer()
        Text(
          snapshot.goSubscription == nil
            ? L10n.string(.openCodeNoSubscription, language: language)
            : L10n.string(.openCodeSubscribed, language: language)
        )
        .font(AppTypography.badge)
        .foregroundStyle(snapshot.goSubscription == nil ? .red : .green)
      }

      if let subscription = snapshot.goSubscription, !subscription.windows.isEmpty {
        ForEach(subscription.windows) { window in
          windowRow(window)
        }
      } else if snapshot.goSubscription == nil {
        OpenCodeProgressBar(progress: 0, color: .red)
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
    .padding(10)
    .background(cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private func windowRow(_ window: OpenCodeUsageWindow) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Text(windowTitle(window.kind))
          .font(AppTypography.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Text(
          L10n.string(
            .openCodeProgress,
            language: language,
            window.usedPercent,
            window.remainingPercent
          )
        )
        .font(AppTypography.caption.monospacedDigit())
        .foregroundStyle(amountForegroundStyle)
      }
      OpenCodeProgressBar(
        progress: Double(window.usedPercent) / 100,
        color: progressColor(for: window)
      )
    }
  }

  private var emptyView: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(L10n.string(.openCodeEmpty, language: language))
        .foregroundStyle(.secondary)
      if let error = store.lastDisplayError {
        Text(error.text(language: language))
          .font(AppTypography.caption)
          .foregroundStyle(.red)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var cardBackground: Color {
    appearance == .dark ? Color(white: 0.14) : Color(white: 0.96)
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

  private func progressColor(for window: OpenCodeUsageWindow) -> Color {
    let ideal: Double?
    if let resetInSec = window.resetInSec {
      let now = store.clock.now()
      let resetAt = now.addingTimeInterval(TimeInterval(resetInSec))
      ideal = CodexUsageFormatter.expectedUsedPercent(
        resetAt: Int(resetAt.timeIntervalSince1970),
        limitWindowSeconds: Int(window.kind.defaultWindowSeconds),
        now: now
      )
    } else {
      ideal = nil
    }

    switch UsageProgressEvaluator.status(usedPercent: window.usedPercent, idealPercent: ideal) {
    case .noIdeal, .onTrack:
      return .blue
    case .behindIdeal:
      return .green
    case .aheadOfIdeal:
      return .orange
    }
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

struct OpenCodeProgressBar: View {
  let progress: Double
  let color: Color

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule()
          .fill(Color.primary.opacity(0.12))
        Capsule()
          .fill(color)
          .frame(width: proxy.size.width * max(0, min(1, progress)))
      }
    }
    .frame(height: 8)
    .accessibilityValue("\(Int(max(0, min(1, progress)) * 100))%")
  }
}
