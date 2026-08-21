import SwiftUI

/// 通用设置独立小窗内容：语言、开机自启、本地历史清理。
/// 由菜单栏图标右键菜单「设置」打开，不再占用 DeepSeek 额度页面空间。
struct SettingsView: View {
  @ObservedObject var store: BalanceStore
  @ObservedObject var loginItemStore: LoginItemStore
  @ObservedObject var visibility: MenuBarVendorVisibility
  /// 可见性切换后的副作用：启停对应 Store 并刷新菜单栏标题。
  var onVisibilityChange: ((MenuBarVendor) -> Void)?

  @State private var showClearHistoryConfirmation = false
  private var language: AppLanguage {
    store.language
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 12) {
        Image(systemName: "slider.horizontal.3")
          .font(.system(size: 19, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(width: 32, height: 38)
        VStack(alignment: .leading, spacing: 2) {
          Text(L10n.string(.settingsTitle, language: language))
            .font(AppTypography.pageTitle)
          Text("DeepSeekBalance")
            .font(AppTypography.caption)
            .foregroundStyle(.secondary)
        }
      }

      settingsGroup {
        VStack(alignment: .leading, spacing: 10) {
          HStack(alignment: .firstTextBaseline) {
            AppSectionHeader(
              title: L10n.string(.settingsMenuBar, language: language),
              systemImage: "menubar.rectangle"
            )
            Spacer()
            Text(L10n.string(.settingsMenuBarOrderHint, language: language))
              .font(AppTypography.caption)
              .foregroundStyle(.secondary)
          }

          ForEach(orderedVendors, id: \.rawValue) { vendor in
            HStack(spacing: 10) {
              HStack(spacing: 0) {
                moveButton(vendor, offset: -1, systemImage: "chevron.up")
                Rectangle()
                  .fill(AppVisualStyle.divider)
                  .frame(width: AppVisualStyle.hairlineWidth, height: 16)
                moveButton(vendor, offset: 1, systemImage: "chevron.down")
              }
              .background(
                AppVisualStyle.insetSurface,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
              )
              .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                  .strokeBorder(
                    AppVisualStyle.border,
                    lineWidth: AppVisualStyle.hairlineWidth
                  )
              }

              Image(vendorIconName(vendor))
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .frame(width: 24, height: 28)

              Text(L10n.string(vendorTitleKey(vendor), language: language))
                .lineLimit(1)
              Spacer()
              Toggle("", isOn: visibilityBinding(for: vendor))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            .frame(height: 34)
          }
        }
      }
      .font(AppTypography.body)

      settingsGroup {
        VStack(alignment: .leading, spacing: 12) {
          AppSectionHeader(
            title: L10n.string(.settingsGeneral, language: language),
            systemImage: "gearshape"
          )
          HStack {
            Text(L10n.string(.settingsLanguage, language: language))
            Spacer()
            Button(L10n.string(.settingsLanguageSwitch, language: language)) {
              store.setLanguage(language == .simplifiedChinese ? .english : .simplifiedChinese)
            }
            .controlSize(.small)
            .help(L10n.string(.settingsLanguageSwitchHelp, language: language))
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

      settingsGroup {
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 12) {
            AppSectionHeader(
              title: L10n.string(.settingsFloatingWindow, language: language),
              systemImage: "macwindow.on.rectangle"
            )
            Spacer(minLength: 12)
            Toggle("", isOn: floatingWindowBinding)
              .labelsHidden()
              .toggleStyle(.switch)
              .controlSize(.small)
          }
          Divider()
          HStack {
            Text(L10n.string(.floatingWindowSnapToMenuBar, language: language))
            Spacer()
            Toggle("", isOn: floatingSnapBinding)
              .labelsHidden()
              .toggleStyle(.switch)
              .controlSize(.small)
          }
        }
      }
      .font(AppTypography.body)

    }
    .padding(22)
    .frame(width: 460, alignment: .leading)
    // 设置窗口按 NSHostingView 的 fittingSize 自适应高度；固定垂直理想尺寸，
    // 避免无界 Spacer 参与测量后把整组内容压到可视区域之外。
    .fixedSize(horizontal: false, vertical: true)
    .background(AppVisualStyle.windowTint)
    .preferredColorScheme(.light)
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
      .appCard(padding: 16)
  }

  private func moveButton(
    _ vendor: MenuBarVendor,
    offset: Int,
    systemImage: String
  ) -> some View {
    Button {
      moveVendor(vendor, offset: offset)
    } label: {
      Image(systemName: systemImage)
        .font(.system(size: 9, weight: .semibold))
        .frame(width: 25, height: 25)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(canMove(vendor, offset: offset) ? Color.secondary : Color.secondary.opacity(0.28))
    .disabled(!canMove(vendor, offset: offset))
    .help(
      L10n.string(offset < 0 ? .settingsMoveUp : .settingsMoveDown, language: language)
    )
  }

  private func vendorIconName(_ vendor: MenuBarVendor) -> String {
    switch vendor {
    case .deepseek: return "DeepSeekIcon"
    case .codex: return "CodexIcon"
    case .cursor: return "CursorIcon"
    case .openCode: return "OpenCodeIcon"
    case .vps: return "VultrIcon"
    case .commandCode: return "CommandCodeIcon"
    case .grokBot: return "GrokBotIcon"
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

  private var floatingWindowBinding: Binding<Bool> {
    Binding(
      get: { FloatingStatusWindow.isEnabled },
      set: { FloatingStatusWindow.setEnabled($0) }
    )
  }

  private var floatingSnapBinding: Binding<Bool> {
    Binding(
      get: { FloatingStatusWindow.snapsToMenuBar },
      set: { FloatingStatusWindow.setSnapsToMenuBar($0) }
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
