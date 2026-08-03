import Foundation

/// 应用支持的语言。首次启动默认使用简体中文，用户选择后持久化。
enum AppLanguage: String, CaseIterable, Sendable {
  case simplifiedChinese = "zh-Hans"
  case english = "en"

  static let userDefaultsKey = "appLanguage"

  var locale: Locale {
    Locale(identifier: rawValue)
  }

  var displayName: String {
    switch self {
    case .simplifiedChinese:
      return "中文"
    case .english:
      return "English"
    }
  }

  /// 首次启动默认使用简体中文；已有用户选择始终优先。
  static func initial(
    defaults: UserDefaults = .standard,
    systemLanguages: [String] = Locale.preferredLanguages
  ) -> AppLanguage {
    if let raw = defaults.string(forKey: userDefaultsKey),
      let saved = AppLanguage(rawValue: raw)
    {
      return saved
    }
    _ = systemLanguages
    return .simplifiedChinese
  }

  func save(defaults: UserDefaults = .standard) {
    defaults.set(rawValue, forKey: Self.userDefaultsKey)
  }
}
