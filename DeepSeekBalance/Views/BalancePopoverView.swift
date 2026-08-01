import AppKit
import SwiftUI

/// 点击菜单栏项目后展示的弹出窗口内容。
struct BalancePopoverView: View {
  @ObservedObject var store: BalanceStore
  @ObservedObject var statusStore: DeepSeekStatusStore
  @ObservedObject var loginItemStore: LoginItemStore

  @State private var apiKeyInput = ""
  @State private var validationMessage: String?
  @State private var showClearHistoryConfirmation = false

  private var language: AppLanguage {
    store.language
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        header
        Divider()
        DeepSeekServiceStatusView(store: statusStore, language: language)
        Divider()
        balanceSection
        Divider()
        trendSection
        errorMessageView
        Divider()
        settingsSection
        Divider()
        keyConfigurationSection
        Divider()
        footer
      }
      .padding(16)
    }
    // MenuBarExtra 窗口按视图的固有尺寸定高，ScrollView 没有固有高度，
    // 必须给出明确的高度，否则窗口会塌成一条窄条。
    .frame(
      minWidth: 500,
      idealWidth: 500,
      maxWidth: 500,
      minHeight: 400,
      idealHeight: 620,
      maxHeight: 820
    )
    .onAppear {
      Task { await store.refreshIfNeeded() }
      Task { await statusStore.refreshIfNeeded() }
    }
  }

  // MARK: - 标题区

  private var header: some View {
    HStack(spacing: 10) {
      Image("DeepSeekIcon")
        .renderingMode(.template)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 28, height: 28)
        .accessibilityLabel(L10n.string(.a11yDeepSeekIcon, language: language))
      Text(L10n.string(.appTitle, language: language))
        .font(.headline)
      Spacer()
      Button(language == .simplifiedChinese ? "English" : "中文") {
        store.setLanguage(language == .simplifiedChinese ? .english : .simplifiedChinese)
      }
      .controlSize(.small)
      .help("Switch language / 切换语言")
      statusBadge
    }
  }

  private var statusBadge: some View {
    Text(store.statusTitle)
      .font(.caption.weight(.medium))
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
              .font(.caption.weight(.semibold))
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
        .font(.caption)
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
        .font(.body.monospacedDigit())
    }
  }

  // MARK: - 趋势区

  private var trendSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(L10n.string(.trendTitle, language: language))
          .font(.headline)
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
        .font(.caption2)
        .foregroundStyle(.secondary)

      if let historyError = store.historyDisplayError {
        Text(historyError.text(language: language))
          .font(.caption)
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

  // MARK: - 错误提示

  @ViewBuilder
  private var errorMessageView: some View {
    if let message = store.lastDisplayError {
      Text(message.text(language: language))
        .font(.caption)
        .foregroundStyle(.red)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: - 设置区

  private var settingsSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(L10n.string(.settingsTitle, language: language))
        .font(.headline)

      HStack {
        Text(L10n.string(.settingsLanguage, language: language))
        Spacer()
        Button(language == .simplifiedChinese ? "English" : "中文") {
          store.setLanguage(
            language == .simplifiedChinese ? .english : .simplifiedChinese
          )
        }
        .controlSize(.small)
      }

      Divider()

      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text(L10n.string(.settingsLaunchAtLogin, language: language))
          Spacer()
          Toggle("", isOn: loginBinding)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(loginItemStore.isUpdating)
        }
        Text(loginStatusText)
          .font(.caption)
          .foregroundStyle(.secondary)
        if let error = loginItemStore.lastError {
          Text(error)
            .font(.caption)
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }
        if loginItemStore.status == .requiresApproval {
          Button(L10n.string(.loginOpenSettings, language: language)) {
            loginItemStore.openSystemSettings()
          }
          .controlSize(.small)
        }
      }

      Divider()

      HStack {
        Text(L10n.string(.settingsLocalHistory, language: language))
        Spacer()
        Button(L10n.string(.trendClearHistory, language: language)) {
          showClearHistoryConfirmation = true
        }
        .controlSize(.small)
      }
    }
  }

  private var loginBinding: Binding<Bool> {
    Binding(
      get: { loginItemStore.status == .enabled },
      set: { newValue in
        Task { await loginItemStore.setEnabled(newValue) }
      }
    )
  }

  private var loginStatusText: String {
    switch loginItemStore.status {
    case .enabled:
      return L10n.string(.loginEnabled, language: language)
    case .notRegistered:
      return L10n.string(.loginNotRegistered, language: language)
    case .requiresApproval:
      return L10n.string(.loginRequiresApproval, language: language)
    case .notFound:
      return L10n.string(.loginNotFound, language: language)
    case .error(let message):
      return L10n.string(.loginError, language: language) + "：" + message
    }
  }

  // MARK: - API Key 配置区

  private var keyConfigurationSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(L10n.string(.apiKeyTitle, language: language))
        .font(.headline)

      SecureField(L10n.string(.apiKeyPlaceholder, language: language), text: $apiKeyInput)
        .textFieldStyle(.roundedBorder)
        .onSubmit(saveAndRefresh)

      if let message = validationMessage {
        Text(message)
          .font(.caption)
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
      .font(.caption)
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

  // MARK: - 底部操作区

  private var footer: some View {
    HStack(spacing: 8) {
      if store.isRefreshing || statusStore.loadState == .loading {
        ProgressView()
          .controlSize(.small)
      }
      Button(L10n.string(.footerRefresh, language: language)) {
        Task { await store.refreshAll() }
      }
      Spacer()
      Button(L10n.string(.footerQuit, language: language)) {
        NSApplication.shared.terminate(nil)
      }
    }
    .controlSize(.small)
  }
}
