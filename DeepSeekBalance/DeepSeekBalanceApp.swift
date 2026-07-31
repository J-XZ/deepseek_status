import SwiftUI

@main
struct DeepSeekBalanceApp: App {
  @StateObject private var store = BalanceStore()

  var body: some Scene {
    MenuBarExtra {
      BalancePopoverView(store: store)
    } label: {
      MenuBarLabel(store: store)
    }
    .menuBarExtraStyle(.window)
  }
}
