import Foundation

/// 应用支持的语言。首次启动根据系统首选语言选择，用户选择后持久化。
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

  /// 首次启动：仅看系统首选语言（列表第一项）；中文系用简体，其余默认 English。
  static func initial(
    defaults: UserDefaults = .standard,
    systemLanguages: [String] = Locale.preferredLanguages
  ) -> AppLanguage {
    if let raw = defaults.string(forKey: userDefaultsKey),
      let saved = AppLanguage(rawValue: raw)
    {
      return saved
    }
    if let primary = systemLanguages.first {
      let prefix = primary.prefix(2).lowercased()
      if prefix == "zh" {
        return .simplifiedChinese
      }
    }
    return .english
  }

  func save(defaults: UserDefaults = .standard) {
    defaults.set(rawValue, forKey: Self.userDefaultsKey)
  }
}
