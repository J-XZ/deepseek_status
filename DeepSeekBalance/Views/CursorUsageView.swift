import SwiftUI

/// Cursor 用量标签页：订阅方案、计费周期用量、费用明细与账号信息。
struct CursorUsageView: View {
  @ObservedObject var store: CursorUsageStore
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
        spendCard(usage)
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
          Text(L10n.string(.cursorLoading, language: language))
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
        imageName: "CursorIcon",
        title: L10n.string(.cursorTitle, language: language),
        subtitle: store.menuBarText,
        accessibilityLabel: L10n.string(.a11yCursorIcon, language: language)
      ) {
        HStack(spacing: 6) {
          if let plan = CursorUsageFormatter.planDisplayName(store.profile?.planTier) {
            AppStatusBadge(text: plan, tint: AppVisualStyle.accent, showsDot: false)
          }
          statusBadge
        }
      }
      if let email = store.profile?.email, !email.isEmpty {
        Label(
          L10n.string(.cursorAccount, language: language, email),
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
      return L10n.string(.cursorNotConfigured, language: language)
    case .authInvalid:
      return L10n.string(.cursorAuthInvalid, language: language)
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

  private func usageCard(_ usage: CursorUsageResponse) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(L10n.string(.cursorPlan, language: language))
          .font(AppTypography.section)
        Spacer()
        if usage.hasNoPlanUsage {
          Text(L10n.string(.cursorNoLimit, language: language))
            .font(AppTypography.badge)
            .foregroundStyle(.secondary)
        } else {
          Text(
            usage.limitReached
              ? L10n.string(.cursorLimitReached, language: language)
              : L10n.string(.cursorLimitAllowed, language: language)
          )
          .font(AppTypography.badge)
          .foregroundStyle(usage.limitReached ? .red : .green)
        }
      }

      if usage.hasNoPlanUsage {
        Text(L10n.string(.cursorNoLimit, language: language))
          .font(AppTypography.caption)
          .foregroundStyle(.secondary)
      } else if let billingCycleStart = usage.billingCycleStartDate,
        let billingCycleEnd = usage.billingCycleEndDate
      {
        windowRow(
          billingCycleStart: billingCycleStart,
          billingCycleEnd: billingCycleEnd,
          usedPercent: usage.usedPercent,
          remainingPercent: usage.remainingPercent,
          gap: usage.usageGapPercent
        )
      }

      if let apiUsed = usage.apiUsedPercent {
        HStack {
          Text(L10n.string(.cursorApiChannel, language: language))
            .font(AppTypography.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          Spacer()
          Text(windowProgressText(
            usedPercent: apiUsed,
            remainingPercent: max(0, min(100, 100 - apiUsed)),
            gap: usage.apiUsageGapPercent
          ))
          .font(AppTypography.caption.monospacedDigit())
          .foregroundStyle(amountForegroundStyle)
        }
        usageBar(
          usedPercent: apiUsed,
          expected: apiExpected(usage)
        )
      }

      if let last = store.lastUpdated {
        Label(
          L10n.string(
            .cursorLastUpdated,
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

  /// 进度条文案：有差距（实际已用 − 理想已用）时显示“已用 X% · 剩余 Y%（±Z%）”，
  /// 与 OpenCode 详情页保持一致；无差距信息时不带括号。
  private func windowProgressText(
    usedPercent: Int,
    remainingPercent: Int,
    gap: Int?
  ) -> String {
    guard let gap else {
      return L10n.string(
        .cursorWindowUsedRemaining,
        language: language,
        usedPercent,
        remainingPercent
      )
    }
    let signedGap = "\(gap >= 0 ? "+" : "")\(gap)%"
    return L10n.string(
      .cursorWindowUsedRemainingWithGap,
      language: language,
      usedPercent,
      remainingPercent,
      signedGap
    )
  }

  /// 计费周期窗口：已用/剩余进度条 + 理想用量红线 + 重置时间。
  private func windowRow(
    billingCycleStart: Date,
    billingCycleEnd: Date,
    usedPercent: Int?,
    remainingPercent: Int?,
    gap: Int?
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(L10n.string(.cursorWindowTitle, language: language))
          .font(AppTypography.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Text(windowProgressText(
          usedPercent: usedPercent ?? 0,
          remainingPercent: remainingPercent ?? 0,
          gap: gap
        ))
        .font(AppTypography.caption.monospacedDigit())
        .foregroundStyle(amountForegroundStyle)
      }
      usageBar(
        usedPercent: usedPercent ?? 0,
        expected: CursorUsageFormatter.expectedUsedPercent(
          start: billingCycleStart,
          end: billingCycleEnd
        )
      )
      ResetAtCaption(
        label: L10n.string(
          .cursorResetAt,
          language: language,
          billingCycleEnd.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened).locale(language.locale)
          )
        ),
        until: billingCycleEnd
      )
    }
    .padding(.bottom, 2)
  }

  /// API 通道的理想用量红线：与第一方模型共用同一计费周期推算。
  private func apiExpected(_ usage: CursorUsageResponse) -> Double? {
    guard let start = usage.billingCycleStartDate, let end = usage.billingCycleEndDate else {
      return nil
    }
    return CursorUsageFormatter.expectedUsedPercent(start: start, end: end)
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
      expectedAccessibilityLabel: L10n.string(.cursorExpectedMarker, language: language)
    )
  }

  private func barColor(_ usedPercent: Int, idealPercent: Double?) -> Color {
    let gap = idealPercent.map { Double(usedPercent) - $0 }
    return MenuBarUsageColor.detailProgressColor(forGap: gap).map(Color.init(nsColor:))
      ?? AppVisualStyle.progressBlue
  }


  private func spendCard(_ usage: CursorUsageResponse) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(L10n.string(.cursorSpendTitle, language: language))
        .font(AppTypography.section)
      if let planUsage = usage.planUsage {
        spendRow(
          title: L10n.string(.cursorSpendTotal, language: language),
          cents: planUsage.totalSpend
        )
        spendRow(
          title: L10n.string(.cursorSpendIncluded, language: language),
          cents: planUsage.includedSpend
        )
        spendRow(
          title: L10n.string(.cursorSpendBonus, language: language),
          cents: planUsage.bonusSpend
        )
        if let limit = planUsage.limit {
          HStack {
            Text(L10n.string(.cursorSpendLimit, language: language))
              .foregroundStyle(.secondary)
            Spacer()
            Text(
              CursorUsageFormatter.formatCents(limit, locale: language.locale) ?? "—"
            )
            .font(AppTypography.value)
            .foregroundStyle(amountForegroundStyle)
          }
        }
      }
      if usage.limitReached {
        Text(L10n.string(.cursorLimitReached, language: language))
          .font(AppTypography.caption)
          .foregroundStyle(.red)
      }
    }
    .appInsetCard()
  }

  private func spendRow(title: String, cents: Double?) -> some View {
    HStack {
      Text(title)
        .foregroundStyle(.secondary)
      Spacer()
      Text(CursorUsageFormatter.formatCents(cents, locale: language.locale) ?? "—")
        .font(AppTypography.value)
        .foregroundStyle(amountForegroundStyle)
    }
  }

  @ViewBuilder
  private var emptyView: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(emptyTitle)
        .font(AppTypography.section)
      if store.status == .notConfigured {
        Text(L10n.string(.cursorNotConfiguredDetail, language: language))
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
      return L10n.string(.cursorNotConfigured, language: language)
    case .authInvalid:
      return L10n.string(.cursorAuthInvalid, language: language)
    default:
      return L10n.string(.cursorEmpty, language: language)
    }
  }
}
