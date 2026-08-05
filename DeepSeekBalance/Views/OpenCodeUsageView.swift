import AppKit
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
    HStack(spacing: 10) {
      Image("OpenCodeIcon")
        .renderingMode(.template)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 24, height: 24)
        .padding(8)
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
        serviceTitle(
          imageName: "OpenCodeZenIcon",
          title: L10n.string(.openCodeZenTitle, language: language)
        )
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
        serviceTitle(
          imageName: "OpenCodeGoIcon",
          title: L10n.string(.openCodeGoTitle, language: language)
        )
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

  private var loadingZenCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        serviceTitle(
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
    .padding(10)
    .background(cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private var loadingGoCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        serviceTitle(
          imageName: "OpenCodeGoIcon",
          title: L10n.string(.openCodeGoTitle, language: language)
        )
        Spacer()
        ProgressView()
          .controlSize(.small)
      }
      OpenCodeProgressBar(progress: 0.45, color: .blue)
      OpenCodeProgressBar(progress: 0.3, color: .blue)
      OpenCodeProgressBar(progress: 0.15, color: .blue)
    }
    .frame(minHeight: 150)
    .padding(10)
    .background(cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private func serviceTitle(imageName: String, title: String) -> some View {
    HStack(spacing: 6) {
      Image(imageName)
        .renderingMode(.template)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
      Text(title)
    }
    .font(AppTypography.section)
  }

  private func windowRow(_ window: OpenCodeUsageWindow) -> some View {
    let now = store.clock.now()
    let expected = window.expectedUsedPercent(now: now)
    let gap = window.usageGapPercent(now: now)

    return VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Text(windowTitle(window.kind))
          .font(AppTypography.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Text(
          windowProgressText(window, gap: gap)
        )
        .font(AppTypography.caption.monospacedDigit())
        .foregroundStyle(amountForegroundStyle)
      }
      OpenCodeProgressBar(
        progress: Double(window.usedPercent) / 100,
        color: progressColor(for: window, expected: expected),
        expected: expected,
        expectedAccessibilityLabel: L10n.string(
          .openCodeExpectedMarker,
          language: language
        )
      )
      if let reset = window.resetAt(now: now) {
        Text(
          L10n.string(
            .openCodeResetAt,
            language: language,
            reset.formatted(
              Date.FormatStyle(date: .abbreviated, time: .shortened).locale(language.locale)
            )
          )
        )
        .font(AppTypography.caption)
        .foregroundStyle(.secondary)
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
    let signedGap = "\(gap >= 0 ? "+" : "")\(gap)%"
    return L10n.string(
      .openCodeProgressWithGap,
      language: language,
      window.usedPercent,
      window.remainingPercent,
      signedGap
    )
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

  private func progressColor(
    for window: OpenCodeUsageWindow,
    expected: Double?
  ) -> Color {
    let gap = expected.map { Double(window.usedPercent) - $0 }
    return MenuBarUsageColor.progressColor(forGap: gap).map(Color.init(nsColor:)) ?? .blue
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
  let expected: Double?
  let expectedAccessibilityLabel: String

  init(
    progress: Double,
    color: Color,
    expected: Double? = nil,
    expectedAccessibilityLabel: String = "Ideal usage"
  ) {
    self.progress = progress
    self.color = color
    self.expected = expected
    self.expectedAccessibilityLabel = expectedAccessibilityLabel
  }

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule()
          .fill(Color.primary.opacity(0.12))
        Capsule()
          .fill(color)
          .frame(width: proxy.size.width * max(0, min(1, progress)))
        if let expected {
          Rectangle()
            .fill(.red)
            .frame(width: 3, height: 8)
            .position(x: markerX(width: proxy.size.width, expected: expected), y: 4)
            .accessibilityLabel(expectedAccessibilityLabel)
        }
      }
    }
    .frame(height: 8)
    .accessibilityValue("\(Int(max(0, min(1, progress)) * 100))%")
  }

  private func markerX(width: CGFloat, expected: Double) -> CGFloat {
    let fraction = CGFloat(min(max(expected / 100, 0), 1))
    return min(max(width * fraction, 2), max(width - 2, 2))
  }
}
