import SwiftUI

/// 通用设置独立小窗内容：语言、外观、开机自启、本地历史清理。
/// 由菜单栏图标右键菜单「设置」打开，不再占用 DeepSeek 额度页面空间。
struct SettingsView: View {
  @ObservedObject var store: BalanceStore
  @ObservedObject var loginItemStore: LoginItemStore

  @State private var showClearHistoryConfirmation = false
  @Environment(\.controlActiveState) private var controlActiveState

  private var language: AppLanguage {
    store.language
  }

  private var cardBackground: Color {
    store.appearance == .dark ? Color(white: 0.14) : Color(white: 0.96)
  }

  private var cardBorder: Color {
    store.appearance == .dark ? Color.primary.opacity(0.28) : Color.primary.opacity(0.16)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(L10n.string(.settingsTitle, language: language))
        .font(AppTypography.title)

      settingsGroup {
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Text(L10n.string(.settingsLanguage, language: language))
              Spacer()
              Button(L10n.string(.settingsLanguageSwitch, language: language)) {
                store.setLanguage(language == .simplifiedChinese ? .english : .simplifiedChinese)
              }
              .controlSize(.small)
              .help(L10n.string(.settingsLanguageSwitchHelp, language: language))
            }

            HStack {
              Text(L10n.string(.settingsAppearance, language: language))
              Spacer()
              Picker("", selection: appearanceBinding) {
                Text(L10n.string(.appearanceLight, language: language))
                  .tag(AppAppearance.light)
                Text(L10n.string(.appearanceDark, language: language))
                  .tag(AppAppearance.dark)
              }
              .pickerStyle(.segmented)
              .labelsHidden()
              .frame(width: 150)
            }

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
                .font(AppTypography.caption)
                .foregroundStyle(.secondary)
              if let error = loginItemStore.lastError {
                Text(error)
                  .font(AppTypography.caption)
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
      .font(AppTypography.body)

      Spacer()
    }
    .padding(20)
    .frame(width: 400, alignment: .leading)
    .background(store.appearance == .dark ? Color.black : Color.white)
    .preferredColorScheme(store.appearance.colorScheme)
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

  private func settingsGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    content()
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(12)
      .background(cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(cardBorder, lineWidth: 1)
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

  private var appearanceBinding: Binding<AppAppearance> {
    Binding(
      get: { store.appearance },
      set: { store.setAppearance($0) }
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
    case .unknownStatus:
      return L10n.string(.loginUnknownStatus, language: language)
    case .error(let message):
      return L10n.string(.loginErrorDetail, language: language, message)
    }
  }
}
