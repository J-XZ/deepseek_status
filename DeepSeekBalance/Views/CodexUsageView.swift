import SwiftUI

/// Codex 用量标签页：订阅方案、用量窗口、额外额度与账号信息。
struct CodexUsageView: View {
  @ObservedObject var store: CodexUsageStore
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
        creditsCard(usage)
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
          Text(L10n.string(.codexLoading, language: language))
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
        imageName: "CodexIcon",
        title: L10n.string(.codexTitle, language: language),
        subtitle: store.menuBarText,
        accessibilityLabel: L10n.string(.a11yCodexIcon, language: language)
      ) {
        HStack(spacing: 6) {
          if let plan = store.usage.flatMap({ CodexUsageFormatter.planDisplayName($0.planType) }) {
            AppStatusBadge(text: plan, tint: AppVisualStyle.accent, showsDot: false)
          }
          statusBadge
        }
      }
      if let email = store.usage?.email, !email.isEmpty {
        Label(
          L10n.string(.codexAccount, language: language, email),
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
      return L10n.string(.codexNotConfigured, language: language)
    case .authInvalid:
      return L10n.string(.codexAuthInvalid, language: language)
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

  private func usageCard(_ usage: CodexUsageResponse) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(L10n.string(.codexPlan, language: language))
          .font(AppTypography.section)
        Spacer()
        if let rateLimit = usage.rateLimit {
          Text(
            rateLimit.limitReached
              ? L10n.string(.codexLimitReached, language: language)
              : L10n.string(.codexLimitAllowed, language: language)
          )
          .font(AppTypography.badge)
          .foregroundStyle(rateLimit.limitReached ? .red : .green)
        } else {
          Text(freePlanText(for: usage))
            .font(AppTypography.badge)
            .foregroundStyle(.blue)
        }
      }

      if usage.rateLimit == nil {
        if usage.planType?.lowercased() == "free" {
          Text(L10n.string(.codexFreePlan, language: language))
            .font(AppTypography.caption)
            .foregroundStyle(.secondary)
        }
      } else {
        if let weekly = usage.weeklyWindow {
          windowRow(weekly)
        }
        fiveHourRow(for: usage)
      }

      ForEach(usage.additionalRateLimits ?? []) { limit in
        if let window = limit.rateLimit?.primaryWindow,
          let name = limit.limitName, !name.isEmpty
        {
          windowRow(window, title: name)
        }
      }

      if let last = store.lastUpdated {
        Label(
          L10n.string(
            .codexLastUpdated,
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

  /// 无用量限制信息时的徽章文案：免费计划明确标注，否则通用“无限制信息”。
  private func freePlanText(for usage: CodexUsageResponse) -> String {
    switch usage.planType?.lowercased() {
    case "free":
      return L10n.string(.codexFreePlan, language: language)
    default:
      return L10n.string(.codexNoLimit, language: language)
    }
  }

  /// 5 小时窗口：官方通常未下发该限制，预留展示——未下发时按
  /// “已用 0% · 剩余 100%”显示并标注当前无限制；将来下发后自动显示真实数据。
  @ViewBuilder
  private func fiveHourRow(for usage: CodexUsageResponse) -> some View {
    if let fiveHour = usage.fiveHourWindow {
      windowRow(fiveHour)
    } else {
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text(L10n.string(.codexWindowFiveHour, language: language))
            .font(AppTypography.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          Spacer()
          Text(L10n.string(
            .codexWindowUsedRemaining,
            language: language,
            0,
            100
          ))
          .font(AppTypography.caption.monospacedDigit())
          .foregroundStyle(amountForegroundStyle)
        }
        usageBar(usedPercent: 0)
        Text(L10n.string(.codexWindowFiveHourNone, language: language))
          .font(AppTypography.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.bottom, 2)
    }
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
      expectedAccessibilityLabel: L10n.string(.codexExpectedMarker, language: language)
    )
  }

  private func usageBar(_ window: CodexUsageWindow) -> some View {
    usageBar(
      usedPercent: window.usedPercent,
      expected: CodexUsageFormatter.expectedUsedPercent(
        resetAt: window.resetAt,
        limitWindowSeconds: window.limitWindowSeconds
      )
    )
  }

  private func barColor(_ usedPercent: Int, idealPercent: Double?) -> Color {
    let gap = idealPercent.map { Double(usedPercent) - $0 }
    return MenuBarUsageColor.detailProgressColor(forGap: gap).map(Color.init(nsColor:))
      ?? AppVisualStyle.progressBlue
  }


  /// 进度条文案：有差距（实际已用 − 理想已用）时显示“已用 X% · 剩余 Y%（±Z%）”，
  /// 与 OpenCode 详情页保持一致；无差距信息时不带括号。
  private func windowProgressText(
    usedPercent: Int,
    remainingPercent: Int,
    gap: Int?
  ) -> String {
    guard let gap else {
      return L10n.string(
        .codexWindowUsedRemaining,
        language: language,
        usedPercent,
        remainingPercent
      )
    }
    let signedGap = "\(gap >= 0 ? "+" : "")\(gap)%"
    return L10n.string(
      .codexWindowUsedRemainingWithGap,
      language: language,
      usedPercent,
      remainingPercent,
      signedGap
    )
  }

  private func windowRow(_ window: CodexUsageWindow, title: String? = nil) -> some View {
    let expected = CodexUsageFormatter.expectedUsedPercent(
      resetAt: window.resetAt,
      limitWindowSeconds: window.limitWindowSeconds
    )
    let gap = expected.map { window.usedPercent - Int($0.rounded()) }

    return VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title ?? CodexUsageFormatter.windowTitle(
          limitWindowSeconds: window.limitWindowSeconds,
          language: language
        ))
        .font(AppTypography.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        Spacer()
        Text(windowProgressText(
          usedPercent: window.usedPercent,
          remainingPercent: window.remainingPercent,
          gap: gap
        ))
        .font(AppTypography.caption.monospacedDigit())
        .foregroundStyle(amountForegroundStyle)
      }
      usageBar(window)
      if let reset = CodexUsageFormatter.resetDate(
        resetAt: window.resetAt,
        locale: language.locale
      ) {
        Text(L10n.string(
          .codexResetAt,
          language: language,
          reset.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened).locale(language.locale)
          )
        ))
        .font(AppTypography.caption)
        .foregroundStyle(.secondary)
      }
    }
    .padding(.bottom, 2)
  }

  @ViewBuilder
  private func creditsCard(_ usage: CodexUsageResponse) -> some View {
    if let credits = usage.credits {
      VStack(alignment: .leading, spacing: 6) {
        Text(L10n.string(.codexCreditsTitle, language: language))
          .font(AppTypography.section)
        HStack {
          Text(creditsText(credits))
            .foregroundStyle(.secondary)
          Spacer()
          Text(creditsValue(credits))
            .font(AppTypography.value)
            .foregroundStyle(amountForegroundStyle)
        }
        if credits.overageLimitReached {
          Text(L10n.string(.codexLimitReached, language: language))
            .font(AppTypography.caption)
            .foregroundStyle(.red)
        }
      }
      .appInsetCard()
    }
  }

  private func creditsText(_ credits: CodexCredits) -> String {
    if credits.unlimited {
      return L10n.string(.codexCreditsUnlimited, language: language)
    }
    if credits.hasCredits {
      return L10n.string(.codexCreditsBalance, language: language)
    }
    return L10n.string(.codexCreditsNone, language: language)
  }

  private func creditsValue(_ credits: CodexCredits) -> String {
    if credits.unlimited {
      return "∞"
    }
    if credits.hasCredits {
      return credits.balance ?? "—"
    }
    return "—"
  }

  @ViewBuilder
  private var emptyView: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(emptyTitle)
        .font(AppTypography.section)
      if store.status == .notConfigured {
        Text(L10n.string(.codexNotConfiguredDetail, language: language))
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
      return L10n.string(.codexNotConfigured, language: language)
    case .authInvalid:
      return L10n.string(.codexAuthInvalid, language: language)
    default:
      return L10n.string(.codexEmpty, language: language)
    }
  }
}

extension CodexAdditionalRateLimit: Identifiable {
  var id: String { limitName ?? UUID().uuidString }
}
