import SwiftUI

/// 菜单栏 label：单色 DeepSeek 图标 + 动态余额文字。
struct MenuBarLabel: View {
  @ObservedObject var store: BalanceStore

  var body: some View {
    HStack(spacing: 4) {
      Image("DeepSeekIcon")
        .renderingMode(.template)
        .resizable()
        .frame(width: 16, height: 16)
        .accessibilityLabel("DeepSeek 图标")
      Text(store.menuBarText)
        .font(.system(size: 13, weight: .medium))
        .monospacedDigit()
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("DeepSeek API 余额，\(store.menuBarText)")
  }
}
