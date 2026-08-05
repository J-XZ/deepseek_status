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

/// 弹出窗口顶部切换栏：DeepSeek / Codex / Cursor / OpenCode / Vultr 用量。
enum UsageTab: String, CaseIterable, Identifiable, Hashable {
  case deepseek
  case codex
  case cursor
  case openCode
  case vps

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
    case .vps:
      return .vps
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
  @ObservedObject var vpsStore: VPSUsageStore
  @ObservedObject var codexStatusStore: StatusPageStatusStore
  @ObservedObject var cursorStatusStore: StatusPageStatusStore
  let visibility: MenuBarVendorVisibility
  let onPageHeightsChange: ([UsageTab: CGFloat]) -> Void

  @State private var apiKeyInput = ""
  @State private var openCodeCookieInput = ""
  @State private var vpsTokenInput = ""
  @State private var vpsInstanceIDInput = ""
  @State private var validationMessage: String?
  @State private var openCodeCookieValidationMessage: String?
  @State private var vpsValidationMessage: String?
  @State private var selectedTab: UsageTab = .deepseek
  @State private var reportedPageHeights: [UsageTab: CGFloat] = [:]
  @Environment(\.controlActiveState) private var controlActiveState

  private var language: AppLanguage {
    store.language
  }

  /// 仅显示菜单栏可见的供应商页。
  private var visibleTabs: [UsageTab] {
    UsageTab.allCases.filter { visibility.isVisible($0.vendor) }
  }

  var body: some View {
    ScrollView(.vertical) {
      // ScrollView 的内容在横向没有天然的收缩约束。英文长文案会让内容层
      // 按理想宽度展开，随后被弹窗左右边缘裁掉；这里明确给内容层分配弹窗
      // 的可用内宽，让所有子视图都在同一宽度下换行和压缩。
      // fixedSize(vertical: true) 让内容按自然高度布局（而不是填满滚动视口），
      // 后台的 GeometryReader 因此能持续报告页面真实高度用于弹窗定高。
      contentStack(for: selectedTab)
        .frame(width: PopoverSizing.contentWidth, alignment: .leading)
        .padding(PopoverSizing.horizontalPadding)
        .fixedSize(horizontal: false, vertical: true)
        .background {
          GeometryReader { proxy in
            Color.clear.preference(
              key: VendorPageHeightPreferenceKey.self,
              value: [selectedTab: proxy.size.height.rounded(.up)]
            )
          }
        }
    }
    .frame(width: PopoverSizing.width)
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
      refreshStoresAfterFirstFrame()
    }
    .onPreferenceChange(VendorPageHeightPreferenceKey.self) { pageHeights in
      guard !pageHeights.isEmpty else { return }

      let visibleSet = Set(visibleTabs)
      var updatedHeights = reportedPageHeights.filter { visibleSet.contains($0.key) }
      var didChange = updatedHeights.count != reportedPageHeights.count
      for (tab, height) in pageHeights where visibleSet.contains(tab) && height.isFinite && height > 0 {
        // GeometryReader 可能在 SwiftUI 重排期间短暂报告一个较小值。
        // 只保留本次打开期间观察到的最大自然高度，避免内容刚出现就把窗口缩小。
        let stableHeight = max(updatedHeights[tab] ?? 0, height)
        if updatedHeights[tab] != stableHeight {
          updatedHeights[tab] = stableHeight
          didChange = true
        }
      }

      guard didChange else { return }
      reportedPageHeights = updatedHeights
      onPageHeightsChange(updatedHeights)
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
      case .vps:
        VPSUsageView(
          store: vpsStore,
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
        card { vpsTrendSection }
        card { vpsConfigurationSection }
      }
      card { footer }
    }
    .font(AppTypography.body)
  }

  /// 让首帧先完成布局，再启动各供应商的网络刷新；网络请求本身并行，
  /// 但统一由一个任务协调，减少菜单打开瞬间的任务与 SwiftUI 更新风暴。
  private func refreshStoresAfterFirstFrame() {
    Task { @MainActor in
      await Task.yield()
      async let balance = store.refreshIfNeeded()
      async let deepSeekStatus = statusStore.refreshIfNeeded()
      async let codex = codexStore.refreshIfNeeded()
      async let cursor = cursorStore.refreshIfNeeded()
      async let openCode = openCodeStore.refreshIfNeeded()
      async let vps = vpsStore.refreshIfNeeded()
      async let codexStatus = codexStatusStore.refreshIfNeeded()
      async let cursorStatus = cursorStatusStore.refreshIfNeeded()
      _ = await (balance, deepSeekStatus, codex, cursor, openCode, vps, codexStatus, cursorStatus)
    }
  }

  // MARK: - 顶部切换栏

  private var tabSwitcher: some View {
    Picker("", selection: $selectedTab) {
      ForEach(visibleTabs) { tab in
        Text(L10n.string(tabLabelKey(tab), language: language))
          .font(AppTypography.caption)
          .lineLimit(1)
          .minimumScaleFactor(0.7)
          .allowsTightening(true)
          .tag(tab)
      }
    }
    .pickerStyle(.segmented)
    .controlSize(.small)
    .frame(maxWidth: .infinity)
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
    case .vps:
      return .tabVPS
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

  private var deepSeekUsageChangeValue: String? {
    guard let currency = store.selectedCurrency else { return nil }
    return BalanceTrendProcessor.summary(
      samples: store.historySamples,
      currency: currency
    )
    .usageChangeValue(language: language)
  }

  private func usageTrendSummary(_ value: String?) -> some View {
    Text(
      value.map {
        L10n.string(.trendSummaryChange, language: language, $0)
      } ?? L10n.string(.trendSummaryInsufficient, language: language)
    )
    .font(AppTypography.body.weight(.medium))
    .fixedSize(horizontal: false, vertical: true)
  }

  private var trendSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(L10n.string(.trendTitle, language: language))
        .font(AppTypography.section)

      usageTrendSummary(deepSeekUsageChangeValue)

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
      Text(L10n.string(.trendTitle, language: language))
        .font(AppTypography.section)

      let chart = CodexTrendChartView(
        samples: codexStore.historySamples,
        language: language,
        now: codexStore.clock.now()
      )
      usageTrendSummary(chart.usageChangeValue)

      if codexStore.historySamples.count >= 2 {
        chart
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
      Text(L10n.string(.trendTitle, language: language))
        .font(AppTypography.section)

      let chart = CursorTrendChartView(
        samples: cursorStore.historySamples,
        language: language,
        now: cursorStore.clock.now()
      )
      usageTrendSummary(chart.usageChangeValue)

      if cursorStore.historySamples.count >= 2 {
        chart
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
      Text(L10n.string(.trendTitle, language: language))
        .font(AppTypography.section)

      let chart = OpenCodeTrendChartView(
        samples: openCodeStore.historySamples,
        showGoTrend: openCodeStore.snapshot?.isGoSubscribed == true,
        language: language,
        now: openCodeStore.clock.now()
      )
      usageTrendSummary(chart.usageChangeValue)

      if openCodeStore.historySamples.count >= 2 {
        chart
      } else {
        BalanceTrendEmptyView(historyUnavailable: false, language: language)
      }

      Text(L10n.string(.trendLocalNote, language: language))
        .font(AppTypography.caption)
        .foregroundStyle(.secondary)
    }
  }

  // MARK: - Vultr 趋势区

  private var vpsTrendSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(L10n.string(.trendTitle, language: language))
        .font(AppTypography.section)

      let chart = VPSTrendChartView(
        samples: vpsStore.historySamples,
        language: language,
        now: vpsStore.clock.now(),
        currentRemainingGB: vpsStore.snapshot?.remainingBandwidthGB,
        cycleStart: vpsStore.snapshot?.cycleStart,
        cycleEnd: vpsStore.snapshot?.cycleEnd
      )
      usageTrendSummary(chart.usageChangeValue)

      if vpsStore.historySamples.count >= 2 {
        chart
      } else {
        Text(L10n.string(.vpsTrendWaiting, language: language))
          .font(AppTypography.caption)
          .foregroundStyle(.secondary)
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

  // MARK: - Vultr 配置区

  private var vpsConfigurationSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(L10n.string(.vpsConfigTitle, language: language))
        .font(AppTypography.section)

      SecureField(
        L10n.string(.vpsTokenPlaceholder, language: language),
        text: $vpsTokenInput
      )
      .textFieldStyle(.roundedBorder)
      .onSubmit(saveVPSConfiguration)

      TextField(
        L10n.string(.vpsInstancePlaceholder, language: language),
        text: $vpsInstanceIDInput
      )
      .textFieldStyle(.roundedBorder)
      .onSubmit(saveVPSConfiguration)

      Text(L10n.string(.vpsConfigHelp, language: language))
        .font(AppTypography.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if let message = vpsValidationMessage {
        Text(message)
          .font(AppTypography.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack(spacing: 8) {
        Button(L10n.string(.vpsConfigSave, language: language)) {
          saveVPSConfiguration()
        }
        Button(L10n.string(.vpsConfigClear, language: language)) {
          vpsStore.clearConfiguration()
          vpsTokenInput = ""
          vpsInstanceIDInput = ""
          vpsValidationMessage = nil
        }
        Spacer()
      }
      .controlSize(.small)

      HStack(spacing: 4) {
        Text(L10n.string(.vpsConfigSource, language: language))
        Text(
          vpsStore.hasSavedConfiguration
            ? L10n.string(.vpsConfigKeychain, language: language)
            : L10n.string(.vpsConfigNotConfigured, language: language)
        )
        .fontWeight(.medium)
      }
      .font(AppTypography.caption)
      .foregroundStyle(.secondary)
    }
  }

  private func saveVPSConfiguration() {
    switch vpsStore.saveConfiguration(
      token: vpsTokenInput,
      instanceID: vpsInstanceIDInput
    ) {
    case .success:
      vpsValidationMessage = nil
      vpsTokenInput = ""
      vpsInstanceIDInput = ""
      Task { await vpsStore.refresh() }
    case .emptyToken, .emptyInstanceID:
      vpsValidationMessage = L10n.string(.vpsConfigEmpty, language: language)
    case .keychainFailed(let detail):
      vpsValidationMessage = L10n.string(
        .vpsSaveFailed,
        language: language,
        AppDisplayError.sanitized(detail)
      )
    }
  }

  // MARK: - 底部操作区

  private var footer: some View {
    HStack(spacing: 8) {
      if store.isRefreshing || statusStore.loadState == .loading || codexStore.isRefreshing
        || cursorStore.isRefreshing || openCodeStore.isRefreshing || vpsStore.isRefreshing
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
          await vpsStore.refreshIfNeeded(maximumAge: 0)
          await codexStatusStore.refreshIfNeeded(maximumAge: 0)
          await cursorStatusStore.refreshIfNeeded(maximumAge: 0)
        }
      }
      .disabled(
        store.isRefreshing || statusStore.loadState == .loading || codexStore.isRefreshing
        || cursorStore.isRefreshing || openCodeStore.isRefreshing || vpsStore.isRefreshing
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
