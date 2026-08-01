import SwiftUI

@main
struct DeepSeekBalanceApp: App {
  @StateObject private var store: BalanceStore
  @StateObject private var statusStore: DeepSeekStatusStore
  @StateObject private var loginItemStore: LoginItemStore

  init() {
    let statusStore = DeepSeekStatusStore()
    let loginItemStore = LoginItemStore()
    _statusStore = StateObject(wrappedValue: statusStore)
    _loginItemStore = StateObject(wrappedValue: loginItemStore)
    _store = StateObject(
      wrappedValue: BalanceStore(statusStore: statusStore, loginItemStore: loginItemStore)
    )
  }

  var body: some Scene {
    MenuBarExtra {
      BalancePopoverView(
        store: store,
        statusStore: statusStore,
        loginItemStore: loginItemStore
      )
      .environment(\.locale, store.language.locale)
    } label: {
      MenuBarLabel(store: store)
    }
    .menuBarExtraStyle(.window)
  }
}
