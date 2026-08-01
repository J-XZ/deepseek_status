import SwiftUI

@main
struct DeepSeekBalanceApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    // 状态栏由 AppDelegate / StatusItemController 管理（原生 NSStatusItem）。
    Settings { EmptyView() }
  }
}
