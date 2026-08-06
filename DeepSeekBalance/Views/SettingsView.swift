import SwiftUI

/// 通用设置独立小窗内容：语言、外观、开机自启、本地历史清理。
/// 由菜单栏图标右键菜单「设置」打开，不再占用 DeepSeek 额度页面空间。
struct SettingsView: View {
  @ObservedObject var store: BalanceStore
  @ObservedObject var loginItemStore: LoginItemStore
  @ObservedObject var visibility: MenuBarVendorVisibility
  /// 可见性切换后的副作用：启停对应 Store 并刷新菜单栏标题。
  var onVisibilityChange: ((MenuBarVendor) -> Void)?

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
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              Text(L10n.string(.settingsMenuBar, language: language))
              Spacer()
              Text(L10n.string(.settingsMenuBarOrderHint, language: language))
                .font(AppTypography.caption)
                .foregroundStyle(.secondary)
            }

            ForEach(orderedVendors, id: \.rawValue) { vendor in
              HStack(spacing: 8) {
                Button {
                  moveVendor(vendor, offset: -1)
                } label: {
                  Image(systemName: "arrow.up")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(!canMove(vendor, offset: -1))
                .help(L10n.string(.settingsMoveUp, language: language))

                Button {
                  moveVendor(vendor, offset: 1)
                } label: {
                  Image(systemName: "arrow.down")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(!canMove(vendor, offset: 1))
                .help(L10n.string(.settingsMoveDown, language: language))

                Text(L10n.string(vendorTitleKey(vendor), language: language))
                Spacer()
                Toggle("", isOn: visibilityBinding(for: vendor))
                  .labelsHidden()
                  .toggleStyle(.switch)
                  .controlSize(.small)
              }
            }
          }
      }
      .font(AppTypography.body)

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

  /// 菜单栏顺序中的可见供应商（含全部供应商，按已保存顺序排列）。
  private var orderedVendors: [MenuBarVendor] {
    visibility.orderedVendors
  }

  /// 判断供应商能否在可见列表内上移/下移：仅可见供应商参与排序。
  private func canMove(_ vendor: MenuBarVendor, offset: Int) -> Bool {
    let list = visibility.orderedVisibleVendors
    guard let index = list.firstIndex(of: vendor) else {
      return false
    }
    let target = index + offset
    return target >= 0 && target < list.count
  }

  /// 在可见列表内移动供应商并通知控制器刷新菜单栏。
  private func moveVendor(_ vendor: MenuBarVendor, offset: Int) {
    var reordered = visibility.orderedVisibleVendors
    guard let index = reordered.firstIndex(of: vendor) else { return }
    let target = index + offset
    guard target >= 0 && target < reordered.count else { return }
    reordered.remove(at: index)
    reordered.insert(vendor, at: target)
    visibility.move(reordered)
    onVisibilityChange?(vendor)
  }

  private func visibilityBinding(for vendor: MenuBarVendor) -> Binding<Bool> {
    Binding(
      get: { visibility.isVisible(vendor) },
      set: { newValue in
        guard newValue != visibility.isVisible(vendor) else { return }
        visibility.toggle(vendor)
        onVisibilityChange?(vendor)
      }
    )
  }

  private func vendorTitleKey(_ vendor: MenuBarVendor) -> L10nKey {
    vendor.titleKey
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
