import AppKit
import SwiftUI

/// 弹出面板统一字体层级：正文使用圆体提升可读性，金额使用等宽数字避免刷新时跳动。
enum AppTypography {
  static let title = Font.system(size: 17, weight: .semibold, design: .rounded)
  static let section = Font.system(size: 13, weight: .semibold, design: .rounded)
  static let body = Font.system(size: 13, weight: .regular, design: .rounded)
  static let value = Font.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit()
  static let caption = Font.system(size: 11, weight: .regular, design: .rounded)
  static let badge = Font.system(size: 11, weight: .semibold, design: .rounded)
}

/// 实际进度与理想进度的差异分类；阈值按百分比百分点计算。
enum UsageProgressStatus: Equatable {
  case noIdeal
  case onTrack
  case behindIdeal
  case aheadOfIdeal
}

enum UsageProgressEvaluator {
  static let tolerance: Double = 10

  static func status(usedPercent: Int, idealPercent: Double?) -> UsageProgressStatus {
    guard let idealPercent, idealPercent.isFinite else { return .noIdeal }

    let actual = Double(min(max(usedPercent, 0), 100))
    let ideal = min(max(idealPercent, 0), 100)
    let gap = actual - ideal
    if gap < -tolerance {
      return .behindIdeal
    }
    if gap > tolerance {
      return .aheadOfIdeal
    }
    return .onTrack
  }
}

/// 弹出窗口顶部切换栏：DeepSeek 用量 / Codex 用量 / Cursor 用量 / OpenCode 用量。
enum UsageTab: String, CaseIterable, Identifiable, Hashable {
  case deepseek
  case codex
  case cursor
  case openCode

  var id: String { rawValue }

  /// 与菜单栏供应商对应，用于可见性过滤。
  var vendor: MenuBarVendor {
    switch self {
    case .deepseek:
      return .deepseek
    case .codex:
      return .codex
    case .cursor:
      return .cursor
    case .openCode:
      return .openCode
    }
  }
}

private struct VendorPageHeightPreferenceKey: PreferenceKey {
  static var defaultValue: [UsageTab: CGFloat] = [:]

  static func reduce(
    value: inout [UsageTab: CGFloat],
    nextValue: () -> [UsageTab: CGFloat]
  ) {
    value.merge(nextValue(), uniquingKeysWith: { max($0, $1) })
  }
}

/// 点击菜单栏项目后展示的弹出窗口内容。
struct BalancePopoverView: View {
  @ObservedObject var store: BalanceStore
  @ObservedObject var statusStore: DeepSeekStatusStore
  @ObservedObject var loginItemStore: LoginItemStore
  @ObservedObject var codexStore: CodexUsageStore
  @ObservedObject var cursorStore: CursorUsageStore
  @ObservedObject var openCodeStore: OpenCodeUsageStore
  @ObservedObject var codexStatusStore: StatusPageStatusStore
  @ObservedObject var cursorStatusStore: StatusPageStatusStore
  let visibility: MenuBarVendorVisibility
  let onPageHeightsChange: ([UsageTab: CGFloat]) -> Void

  @State private var apiKeyInput = ""
  @State private var openCodeCookieInput = ""
  @State private var validationMessage: String?
  @State private var openCodeCookieValidationMessage: String?
  @State private var showClearHistoryConfirmation = false
  @State private var selectedTab: UsageTab = .deepseek
  @Environment(\.controlActiveState) private var controlActiveState

  private var language: AppLanguage {
    store.language
  }

  /// 仅显示菜单栏可见的供应商页。
  private var visibleTabs: [UsageTab] {
    UsageTab.allCases.filter { visibility.isVisible($0.vendor) }
  }

  var body: some View {
    ScrollView {
      contentStack(for: selectedTab)
      .padding(14)
    }
    // 在 ScrollView 外测量所有可见供应商页，避免当前页的滚动约束反过来
    // 把其它页面的自然高度压缩成固定值。
    .overlay(alignment: .topLeading) {
      pageHeightMeasurements
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
    // MenuBarExtra 窗口按视图的固有尺寸定高，ScrollView 没有固有高度，
    // 必须给出明确的高度，否则窗口会塌成一条窄条。
    .frame(
      minWidth: PopoverSizing.width,
      idealWidth: PopoverSizing.width,
      maxWidth: PopoverSizing.width,
      minHeight: 1,
      idealHeight: PopoverSizing.fallbackHeight,
      maxHeight: .infinity
    )
    // 纯色背景：浅色为白色、深色为黑色，不做毛玻璃/半透明。
    .background(windowBackground)
    .preferredColorScheme(store.appearance.colorScheme)
    .onAppear {
      Task { await store.refreshIfNeeded() }
      Task { await statusStore.refreshIfNeeded() }
      Task { await codexStore.refreshIfNeeded() }
      Task { await cursorStore.refreshIfNeeded() }
      Task { await openCodeStore.refreshIfNeeded() }
      Task { await codexStatusStore.refreshIfNeeded() }
      Task { await cursorStatusStore.refreshIfNeeded() }
    }
    .onPreferenceChange(VendorPageHeightPreferenceKey.self) { pageHeights in
      guard !pageHeights.isEmpty else { return }
      onPageHeightsChange(pageHeights)
    }
  }

  /// 每个供应商页都包含顶部切换栏、供应商内容和底部操作区，测量口径与实际页一致。
  @ViewBuilder
  private func contentStack(for tab: UsageTab) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      tabSwitcher
      switch tab {
      case .deepseek:
        deepSeekQuotaCard
        card { DeepSeekServiceStatusView(store: statusStore, language: language) }
        card { trendSection }
        card { keyConfigurationSection }
      case .codex:
        CodexUsageView(store: codexStore, language: language, appearance: store.appearance)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
          .background(cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .stroke(cardBorder, lineWidth: 1)
          }
        card {
          DeepSeekServiceStatusView(
            store: codexStatusStore,
            language: language,
            titleKey: .serviceTitleCodex
          )
        }
        card { codexTrendSection }
      case .cursor:
        CursorUsageView(store: cursorStore, language: language, appearance: store.appearance)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
          .background(cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .stroke(cardBorder, lineWidth: 1)
          }
        card {
          DeepSeekServiceStatusView(
            store: cursorStatusStore,
            language: language,
            titleKey: .serviceTitleCursor
          )
        }
        card { cursorTrendSection }
      case .openCode:
        OpenCodeUsageView(
          store: openCodeStore,
          language: language,
          appearance: store.appearance
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(cardBorder, lineWidth: 1)
        }
        card { openCodeTrendSection }
        card { openCodeCookieConfigurationSection }
      }
      card { footer }
    }
    .font(AppTypography.body)
  }

  /// 以实际弹窗宽度测量各页完整自然高度；隐藏供应商不参与高度计算。
  private var pageHeightMeasurements: some View {
    VStack(spacing: 0) {
      ForEach(visibleTabs) { tab in
        contentStack(for: tab)
          .padding(14)
          .frame(width: PopoverSizing.width)
          .fixedSize(horizontal: false, vertical: true)
          .background {
            GeometryReader { proxy in
              Color.clear.preference(
                key: VendorPageHeightPreferenceKey.self,
                value: [tab: proxy.size.height]
              )
            }
          }
      }
    }
    .fixedSize(horizontal: false, vertical: true)
  }

  // MARK: - 顶部切换栏

  private var tabSwitcher: some View {
    Picker("", selection: $selectedTab) {
      ForEach(visibleTabs) { tab in
        Text(L10n.string(tabLabelKey(tab), language: language))
          .tag(tab)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .accessibilityLabel(L10n.string(.a11yProviderPicker, language: language))
    .onAppear {
      if !visibleTabs.contains(selectedTab), let first = visibleTabs.first {
        selectedTab = first
      }
    }
  }

  private func tabLabelKey(_ tab: UsageTab) -> L10nKey {
    switch tab {
    case .deepseek:
      return .tabDeepSeek
    case .codex:
      return .tabCodex
    case .cursor:
      return .tabCursor
    case .openCode:
      return .tabOpenCode
    }
  }

  /// 弹出窗口底色：浅色白色、深色黑色，均为不透明纯色。
  private var windowBackground: Color {
    store.appearance == .dark ? .black : .white
  }

  /// DeepSeek 标题与额度内容必须属于同一张卡片。
  private var deepSeekQuotaCard: some View {
    card {
      VStack(alignment: .leading, spacing: 10) {
        header
        balanceSection
        errorMessageView
      }
    }
  }

  /// 卡片底色：浅色为极浅灰（与白色窗口对比），深色为深灰。
  private var cardBackground: Color {
    store.appearance == .dark ? Color(white: 0.14) : Color(white: 0.96)
  }

  /// 卡片描边：加深以提升对比度，替代毛玻璃分隔。
  private var cardBorder: Color {
    store.appearance == .dark ? Color.primary.opacity(0.28) : Color.primary.opacity(0.16)
  }

  @ViewBuilder
  private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    content()
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(12)
      .background(cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(cardBorder, lineWidth: 1)
      }
  }

  private func sectionTitle(_ key: L10nKey, systemImage: String) -> some View {
    Label(L10n.string(key, language: language), systemImage: systemImage)
      .font(AppTypography.section)
      .foregroundStyle(.primary)
  }

  // MARK: - 标题区

  private var header: some View {
    HStack(spacing: 10) {
      Image("DeepSeekIcon")
        .renderingMode(.template)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 24, height: 24)
        .padding(8)
        .background(Color.accentColor.opacity(0.12), in: Circle())
        .accessibilityLabel(L10n.string(.a11yDeepSeekIcon, language: language))
      VStack(alignment: .leading, spacing: 2) {
        Text(L10n.string(.tabDeepSeek, language: language))
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
    Text(store.statusTitle)
      .font(AppTypography.badge)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(statusColor.opacity(0.14), in: Capsule())
      .foregroundStyle(statusColor)
      .accessibilityLabel(L10n.string(.a11yStatus, language: language, store.statusTitle))
  }

  private var statusColor: Color {
    switch store.status {
    case .loaded:
      return .green
    case .insufficientBalance:
      return .orange
    case .notConfigured:
      return .secondary
    case .idle, .loading:
      return .blue
    case .keychainError, .authenticationFailed, .rateLimited, .httpError,
      .networkError, .serverError, .decodingError, .historyStorageError:
      return .red
    }
  }

  // MARK: - 余额区

  @ViewBuilder
  private var balanceSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let balance = store.balance {
        ForEach(balance.balanceInfos) { info in
          VStack(alignment: .leading, spacing: 4) {
            Text(info.currency)
              .font(AppTypography.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            row(
              title: L10n.string(.balanceTotal, language: language),
              value: BalanceFormatter.format(
                total: info.totalBalance,
                currency: info.currency,
                locale: language.locale
              )
            )
            row(
              title: L10n.string(.balanceToppedUp, language: language),
              value: BalanceFormatter.format(
                total: info.toppedUpBalance,
                currency: info.currency,
                locale: language.locale
              )
            )
            row(
              title: L10n.string(.balanceGranted, language: language),
              value: BalanceFormatter.format(
                total: info.grantedBalance,
                currency: info.currency,
                locale: language.locale
              )
            )
          }
        }
      } else if store.isRefreshing {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text(L10n.string(.balanceLoading, language: language))
            .foregroundStyle(.secondary)
        }
      } else {
        Text(L10n.string(.balanceEmpty, language: language))
          .foregroundStyle(.secondary)
      }

      if let last = store.lastUpdated {
        Label(
          L10n.string(
            .balanceLastUpdated,
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
  }

  private func row(title: String, value: String) -> some View {
    HStack {
      Text(title)
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .font(AppTypography.value)
        // SwiftUI's default primary color is not reliably updated for content
        // hosted inside an NSPopover. Follow the macOS control active state so
        // amounts become secondary when the popover loses focus.
        .foregroundStyle(amountForegroundStyle)
    }
  }

  private var amountForegroundStyle: Color {
    controlActiveState == .inactive ? .secondary : .primary
  }

  // MARK: - 趋势区

  private var trendSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(L10n.string(.trendTitle, language: language))
          .font(AppTypography.section)
        Spacer()
        Button(L10n.string(.trendClearHistory, language: language)) {
          showClearHistoryConfirmation = true
        }
        .controlSize(.small)
      }

      if !store.availableCurrencies.isEmpty {
        Picker(
          L10n.string(.trendCurrencyPicker, language: language),
          selection: currencyBinding
        ) {
          ForEach(store.availableCurrencies, id: \.self) { currency in
            Text(currency).tag(currency)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel(L10n.string(.a11yCurrencyPicker, language: language))
      }

      if store.historySamples.isEmpty, store.historyError != nil {
        BalanceTrendEmptyView(historyUnavailable: true, language: language)
      } else if let currency = store.selectedCurrency {
        let currencySamples = store.historySamples.filter { $0.currency == currency }
        if currencySamples.isEmpty {
          BalanceTrendEmptyView(historyUnavailable: false, language: language)
        } else {
          BalanceTrendChartView(
            samples: store.historySamples,
            currency: currency,
            summary: BalanceTrendProcessor.summary(
              samples: store.historySamples, currency: currency
            ),
            language: language,
            now: store.clock.now()
          )
        }
      } else {
        BalanceTrendEmptyView(historyUnavailable: false, language: language)
      }

      Text(L10n.string(.trendLocalNote, language: language))
        .font(AppTypography.caption)
        .foregroundStyle(.secondary)

      if let historyError = store.historyDisplayError {
        Text(historyError.text(language: language))
          .font(AppTypography.caption)
          .foregroundStyle(.red)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .confirmationDialog(
      L10n.string(.trendClearConfirmTitle, language: language),
      isPresented: $showClearHistoryConfirmation,
      titleVisibility: .visible
    ) {
      Button(L10n.string(.actionClear, language: language), role: .destructive) {
        Task { await store.clearLocalHistory() }
      }
      Button(L10n.string(.actionCancel, language: language), role: .cancel) {}
    } message: {
      Text(L10n.string(.trendClearConfirmMessage, language: language))
    }
  }

  private var currencyBinding: Binding<String> {
    Binding(
      get: { store.selectedCurrency ?? "" },
      set: { store.selectCurrency($0) }
    )
  }

  // MARK: - Codex 趋势区

  private var codexTrendSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(L10n.string(.codexTrendTitle, language: language))
        .font(AppTypography.section)

      if codexStore.historySamples.count >= 2 {
        CodexTrendChartView(
          samples: codexStore.historySamples,
          language: language,
          now: codexStore.clock.now()
        )
      } else {
        BalanceTrendEmptyView(historyUnavailable: false, language: language)
      }

      Text(L10n.string(.trendLocalNote, language: language))
        .font(AppTypography.caption)
        .foregroundStyle(.secondary)
    }
  }

  // MARK: - Cursor 趋势区

  private var cursorTrendSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(L10n.string(.cursorTrendTitle, language: language))
        .font(AppTypography.section)

      if cursorStore.historySamples.count >= 2 {
        CursorTrendChartView(
          samples: cursorStore.historySamples,
          language: language,
          now: cursorStore.clock.now()
        )
      } else {
        BalanceTrendEmptyView(historyUnavailable: false, language: language)
      }

      Text(L10n.string(.trendLocalNote, language: language))
        .font(AppTypography.caption)
        .foregroundStyle(.secondary)
    }
  }

  // MARK: - OpenCode 趋势区

  private var openCodeTrendSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(L10n.string(.openCodeTrendTitle, language: language))
        .font(AppTypography.section)

      if openCodeStore.historySamples.count >= 2 {
        OpenCodeTrendChartView(
          samples: openCodeStore.historySamples,
          showGoTrend: openCodeStore.snapshot?.isGoSubscribed == true,
          language: language,
          now: openCodeStore.clock.now()
        )
      } else {
        BalanceTrendEmptyView(historyUnavailable: false, language: language)
      }

      Text(L10n.string(.trendLocalNote, language: language))
        .font(AppTypography.caption)
        .foregroundStyle(.secondary)
    }
  }

  // MARK: - 错误提示

  @ViewBuilder
  private var errorMessageView: some View {
    if let message = store.lastDisplayError {
      Text(message.text(language: language))
        .font(AppTypography.caption)
        .foregroundStyle(.red)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: - API Key 配置区

  private var keyConfigurationSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(L10n.string(.apiKeyTitle, language: language))
        .font(AppTypography.section)

      SecureField(L10n.string(.apiKeyPlaceholder, language: language), text: $apiKeyInput)
        .textFieldStyle(.roundedBorder)
        .onSubmit(saveAndRefresh)

      if let message = validationMessage {
        Text(message)
          .font(AppTypography.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack(spacing: 8) {
        Button(L10n.string(.apiKeySave, language: language)) { saveAndRefresh() }
        Button(L10n.string(.apiKeyClear, language: language)) {
          Task { await store.clearSavedKey() }
        }
        Spacer()
      }
      .controlSize(.small)

      HStack(spacing: 4) {
        Text(L10n.string(.apiKeySource, language: language))
        Text(keySourceText)
          .fontWeight(.medium)
      }
      .font(AppTypography.caption)
      .foregroundStyle(.secondary)
    }
  }

  private var keySourceText: String {
    switch store.keySource {
    case .keychain:
      return L10n.string(.apiKeySourceKeychain, language: language)
    case .environment:
      return L10n.string(.apiKeySourceEnvironment, language: language)
    case .notConfigured:
      return L10n.string(.apiKeySourceNotConfigured, language: language)
    }
  }

  private func saveAndRefresh() {
    switch store.saveAPIKey(apiKeyInput) {
    case .success:
      validationMessage = nil
      apiKeyInput = ""
      Task { await store.refresh() }
    case .emptyInput:
      validationMessage = L10n.string(.apiKeyEmptyInput, language: language)
    case .failure(let error):
      validationMessage = error.text(language: language)
    }
  }

  // MARK: - OpenCode Cookie 配置区

  private var openCodeCookieConfigurationSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(L10n.string(.openCodeCookieTitle, language: language))
        .font(AppTypography.section)

      TextEditor(text: $openCodeCookieInput)
        .font(AppTypography.caption.monospaced())
        .frame(minHeight: 86, maxHeight: 120)
        .padding(4)
        .overlay {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(cardBorder, lineWidth: 1)
        }
        .accessibilityLabel(L10n.string(.openCodeCookiePlaceholder, language: language))

      Text(L10n.string(.openCodeCookieHelp, language: language))
        .font(AppTypography.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if let message = openCodeCookieValidationMessage {
        Text(message)
          .font(AppTypography.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack(spacing: 8) {
        Button(L10n.string(.openCodeCookieSave, language: language)) {
          saveOpenCodeCookie()
        }
        Button(L10n.string(.openCodeCookieClear, language: language)) {
          openCodeStore.clearSavedCookie()
          openCodeCookieInput = ""
          openCodeCookieValidationMessage = nil
        }
        Spacer()
      }
      .controlSize(.small)

      HStack(spacing: 4) {
        Text(L10n.string(.openCodeCookieSource, language: language))
        Text(
          openCodeStore.hasSavedCookie
            ? L10n.string(.openCodeCookieSourceKeychain, language: language)
            : L10n.string(.openCodeCookieSourceNotConfigured, language: language)
        )
        .fontWeight(.medium)
      }
      .font(AppTypography.caption)
      .foregroundStyle(.secondary)
    }
  }

  private func saveOpenCodeCookie() {
    switch openCodeStore.saveCookieInput(openCodeCookieInput) {
    case .success:
      openCodeCookieValidationMessage = nil
      openCodeCookieInput = ""
      Task { await openCodeStore.refresh() }
    case .emptyInput:
      openCodeCookieValidationMessage = L10n.string(.openCodeCookieEmpty, language: language)
    case .invalidCookie, .cookieNotFound:
      openCodeCookieValidationMessage = L10n.string(.openCodeCookieInvalid, language: language)
    case .fileReadFailed:
      openCodeCookieValidationMessage = L10n.string(.openCodeCookieFileReadFailed, language: language)
    case .keychainFailed(let detail):
      openCodeCookieValidationMessage = L10n.string(
        .openCodeCookieSaveFailed,
        language: language,
        AppDisplayError.sanitized(detail)
      )
    }
  }

  // MARK: - 底部操作区

  private var footer: some View {
    HStack(spacing: 8) {
      if store.isRefreshing || statusStore.loadState == .loading || codexStore.isRefreshing
        || cursorStore.isRefreshing || openCodeStore.isRefreshing
        || codexStatusStore.loadState == .loading
        || cursorStatusStore.loadState == .loading
      {
        ProgressView()
          .controlSize(.small)
      }
      Button(L10n.string(.footerRefresh, language: language)) {
        Task {
          await store.refreshAll()
          await codexStore.refreshIfNeeded(maximumAge: 0)
          await cursorStore.refreshIfNeeded(maximumAge: 0)
          await openCodeStore.refreshIfNeeded(maximumAge: 0)
          await codexStatusStore.refreshIfNeeded(maximumAge: 0)
          await cursorStatusStore.refreshIfNeeded(maximumAge: 0)
        }
      }
      .disabled(
        store.isRefreshing || statusStore.loadState == .loading || codexStore.isRefreshing
        || cursorStore.isRefreshing || openCodeStore.isRefreshing
        || codexStatusStore.loadState == .loading
          || cursorStatusStore.loadState == .loading
      )
      Spacer()
      Button(L10n.string(.footerQuit, language: language)) {
        NSApplication.shared.terminate(nil)
      }
    }
    .controlSize(.small)
  }
}
