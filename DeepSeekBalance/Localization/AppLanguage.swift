import Foundation

/// 应用支持的语言。首次启动默认使用简体中文，用户选择后持久化。
enum AppLanguage: String, CaseIterable, Sendable {
  case simplifiedChinese = "zh-Hans"
  case english = "en"

  static let userDefaultsKey = "appLanguage"
  /// 旧版本没有记录“English”是否由用户主动选择；未标记的旧 English 值视为旧默认值，迁移为中文。
  static let explicitChoiceKey = "appLanguageExplicitChoice"
  static let defaultMigrationVersionKey = "appLanguageDefaultMigrationVersion"
  static let defaultMigrationVersion = 1

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
    let migrationNeeded = defaults.integer(forKey: defaultMigrationVersionKey) < defaultMigrationVersion
    if migrationNeeded {
      defaults.set(defaultMigrationVersion, forKey: defaultMigrationVersionKey)
    }

    if let raw = defaults.string(forKey: userDefaultsKey),
      let saved = AppLanguage(rawValue: raw)
    {
      if migrationNeeded, saved == .english {
        // 2.1.8 及更早版本可能把系统英文误存为用户语言选择，且无法区分
        // 系统默认值和用户主动选择；首次启动新版本时统一迁移为中文。
        defaults.set(simplifiedChinese.rawValue, forKey: userDefaultsKey)
        defaults.removeObject(forKey: explicitChoiceKey)
        return .simplifiedChinese
      }
      return saved
    }
    _ = systemLanguages
    return .simplifiedChinese
  }

  func save(defaults: UserDefaults = .standard) {
    defaults.set(rawValue, forKey: Self.userDefaultsKey)
    defaults.set(true, forKey: Self.explicitChoiceKey)
  }
}
