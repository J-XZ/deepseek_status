import SwiftUI

/// 应用外观模式：浅色（白色背景）/ 深色（黑色背景）。
/// 只影响弹出窗口内的 SwiftUI 界面，不改变菜单栏 NSStatusItem 外观。
enum AppAppearance: String, CaseIterable, Sendable {
  case light
  case dark

  static let userDefaultsKey = "appAppearance"

  /// 默认浅色（白色背景、高对比度、无毛玻璃）。
  static func initial(defaults: UserDefaults = .standard) -> AppAppearance {
    guard let raw = defaults.string(forKey: userDefaultsKey),
      let saved = AppAppearance(rawValue: raw)
    else { return .light }
    return saved
  }

  var colorScheme: ColorScheme {
    switch self {
    case .light: return .light
    case .dark: return .dark
    }
  }

  func save(defaults: UserDefaults = .standard) {
    defaults.set(rawValue, forKey: Self.userDefaultsKey)
  }
}
