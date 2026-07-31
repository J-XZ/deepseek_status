import AppKit
import SwiftUI

/// 点击菜单栏项目后展示的弹出窗口内容。
struct BalancePopoverView: View {
  @ObservedObject var store: BalanceStore
  @State private var apiKeyInput = ""
  @State private var validationMessage: String?
  @State private var showClearHistoryConfirmation = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        header
        Divider()
        balanceSection
        Divider()
        trendSection
        errorMessageView
        Divider()
        keyConfigurationSection
        Divider()
        footer
      }
      .padding(16)
    }
    .frame(width: 500)
    .onAppear {
      Task { await store.refreshIfNeeded() }
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
      Text("DeepSeek API Balance")
        .font(.headline)
      Spacer()
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
      .accessibilityLabel("状态：\(store.statusTitle)")
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
              title: "总余额",
              value: BalanceFormatter.format(total: info.totalBalance, currency: info.currency)
            )
            row(
              title: "充值余额",
              value: BalanceFormatter.format(total: info.toppedUpBalance, currency: info.currency)
            )
            row(
              title: "赠送余额",
              value: BalanceFormatter.format(total: info.grantedBalance, currency: info.currency)
            )
          }
        }
      } else if store.isRefreshing {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("正在获取余额…")
            .foregroundStyle(.secondary)
        }
      } else {
        Text("暂无余额数据")
          .foregroundStyle(.secondary)
      }

      if let last = store.lastUpdated {
        Label(
          "最后更新：\(last.formatted(date: .abbreviated, time: .shortened))",
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
        Text("最近 3 天余额趋势")
          .font(.headline)
        Spacer()
        Button("清除本地历史") {
          showClearHistoryConfirmation = true
        }
        .controlSize(.small)
      }

      if !store.availableCurrencies.isEmpty {
        Picker("币种", selection: currencyBinding) {
          ForEach(store.availableCurrencies, id: \.self) { currency in
            Text(currency).tag(currency)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("选择趋势币种")
      }

      if store.historySamples.isEmpty, store.historyError != nil {
        BalanceTrendEmptyView(historyUnavailable: true)
      } else if let currency = store.selectedCurrency {
        let currencySamples = store.historySamples.filter { $0.currency == currency }
        if currencySamples.isEmpty {
          BalanceTrendEmptyView(historyUnavailable: false)
        } else {
          BalanceTrendChartView(
            samples: store.historySamples,
            currency: currency,
            summary: BalanceTrendProcessor.summary(
              samples: store.historySamples, currency: currency)
          )
        }
      } else {
        BalanceTrendEmptyView(historyUnavailable: false)
      }

      Text("历史仅保存在本机，最多保留 3 天。")
        .font(.caption2)
        .foregroundStyle(.secondary)

      if let historyError = store.historyError {
        Text(historyError)
          .font(.caption)
          .foregroundStyle(.red)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .confirmationDialog(
      "清除本地历史？",
      isPresented: $showClearHistoryConfirmation,
      titleVisibility: .visible
    ) {
      Button("清除", role: .destructive) {
        Task { await store.clearLocalHistory() }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("将删除本机保存的最近 3 天历史样本。不影响 API Key 与当前余额。")
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
    if let message = store.lastErrorMessage {
      Text(message)
        .font(.caption)
        .foregroundStyle(.red)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: - API Key 配置区

  private var keyConfigurationSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("API Key")
        .font(.headline)

      SecureField("输入 DeepSeek API Key", text: $apiKeyInput)
        .textFieldStyle(.roundedBorder)
        .onSubmit(saveAndRefresh)

      if let message = validationMessage {
        Text(message)
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack(spacing: 8) {
        Button("保存") { saveAndRefresh() }
        Button("清除已保存密钥") {
          Task { await store.clearSavedKey() }
        }
        Spacer()
      }
      .controlSize(.small)

      HStack(spacing: 4) {
        Text("密钥来源：")
        Text(store.keySource.displayName)
          .fontWeight(.medium)
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private func saveAndRefresh() {
    switch store.saveAPIKey(apiKeyInput) {
    case .success:
      validationMessage = nil
      apiKeyInput = ""
      Task { await store.refresh() }
    case .emptyInput:
      validationMessage = "请输入 API Key（不能为空）"
    case .failure(let message):
      validationMessage = message
    }
  }

  // MARK: - 底部操作区

  private var footer: some View {
    HStack(spacing: 8) {
      if store.isRefreshing {
        ProgressView()
          .controlSize(.small)
      }
      Button("刷新") {
        Task { await store.refresh() }
      }
      Spacer()
      Button("退出应用") {
        NSApplication.shared.terminate(nil)
      }
    }
    .controlSize(.small)
  }
}
