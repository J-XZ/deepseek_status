import Foundation

/// 全部本地化 key。所有 key 必须同时存在于 Localizable.xcstrings 的 en 与 zh-Hans。
enum L10nKey: String, CaseIterable, Sendable {
  // 菜单栏与状态
  case menuBarLoading = "menuBar.loading"
  case menuBarNotConfigured = "menuBar.notConfigured"
  case menuBarError = "menuBar.error"
  case statusLoading = "status.loading"
  case statusLoaded = "status.loaded"
  case statusNotConfigured = "status.notConfigured"
  case statusKeychainError = "status.keychainError"
  case statusRequestFailed = "status.requestFailed"
  case statusInsufficientBalance = "status.insufficientBalance"

  // 余额区
  case balanceTitle = "balance.title"
  case balanceTotal = "balance.total"
  case balanceToppedUp = "balance.toppedUp"
  case balanceGranted = "balance.granted"
  case balanceLoading = "balance.loading"
  case balanceEmpty = "balance.empty"
  case balanceLastUpdated = "balance.lastUpdated"

  // 趋势区
  case trendTitle = "trend.title"
  case trendCurrencyPicker = "trend.currencyPicker"
  case trendClearHistory = "trend.clearHistory"
  case trendClearConfirmTitle = "trend.clearConfirmTitle"
  case trendClearConfirmMessage = "trend.clearConfirmMessage"
  case actionClear = "action.clear"
  case actionCancel = "action.cancel"
  case trendLocalNote = "trend.localNote"
  case trendEmptyTitle = "trend.emptyTitle"
  case trendEmptyUnavailable = "trend.emptyUnavailable"
  case trendEmptyWaiting = "trend.emptyWaiting"
  case trendSummaryInsufficient = "trend.summaryInsufficient"
  case trendSummaryChange = "trend.summaryChange"
  case trendSelectionChange = "trend.selectionChange"
  case trendHistoryErrorPrefix = "trend.historyErrorPrefix"

  // API Key 设置
  case apiKeyTitle = "apiKey.title"
  case apiKeyPlaceholder = "apiKey.placeholder"
  case apiKeySave = "apiKey.save"
  case apiKeyClear = "apiKey.clear"
  case apiKeySource = "apiKey.source"
  case apiKeySourceKeychain = "apiKey.source.keychain"
  case apiKeySourceEnvironment = "apiKey.source.environment"
  case apiKeySourceNotConfigured = "apiKey.source.notConfigured"
  case apiKeyEmptyInput = "apiKey.emptyInput"
  case apiKeySaveFailed = "apiKey.saveFailed"
  case apiKeyClearFailed = "apiKey.clearFailed"

  // 设置区
  case settingsTitle = "settings.title"
  case settingsLanguage = "settings.language"
  case languageSwitchButton = "settings.languageSwitch"
  case settingsAppearance = "settings.appearance"
  case appearanceLight = "appearance.light"
  case appearanceDark = "appearance.dark"
  case settingsLaunchAtLogin = "settings.launchAtLogin"
  case loginEnabled = "login.enabled"
  case loginNotRegistered = "login.notRegistered"
  case loginRequiresApproval = "login.requiresApproval"
  case loginNotFound = "login.notFound"
  case loginError = "login.error"
  case loginOpenSettings = "login.openSettings"
  case settingsLocalHistory = "settings.localHistory"

  // 服务状态
  case serviceTitle = "serviceStatus.title"
  case serviceTitleCodex = "serviceStatus.titleCodex"
  case serviceTitleCursor = "serviceStatus.titleCursor"
  case serviceLoading = "serviceStatus.loading"
  case serviceUnavailable = "serviceStatus.unavailable"
  case serviceLastUpdated = "serviceStatus.lastUpdated"
  case serviceStale = "serviceStatus.stale"
  case serviceOpenPage = "serviceStatus.openPage"
  case serviceOverall = "serviceStatus.overall"
  case serviceApi = "serviceStatus.api"
  case serviceWebChat = "serviceStatus.webChat"
  case serviceOtherComponents = "serviceStatus.otherComponents"
  case serviceIncidents = "serviceStatus.incidents"
  case serviceMaintenance = "serviceStatus.maintenance"
  case serviceIncidentPhase = "serviceStatus.incidentPhase"
  case serviceIncidentImpact = "serviceStatus.incidentImpact"
  case serviceIncidentUpdated = "serviceStatus.incidentUpdated"
  case serviceRefresh = "serviceStatus.refresh"

  // 状态值
  case indicatorNone = "indicator.none"
  case indicatorMinor = "indicator.minor"
  case indicatorMajor = "indicator.major"
  case indicatorCritical = "indicator.critical"
  case indicatorMaintenance = "indicator.maintenance"
  case indicatorUnknown = "indicator.unknown"
  case componentOperational = "component.operational"
  case componentDegraded = "component.degraded"
  case componentPartialOutage = "component.partialOutage"
  case componentMajorOutage = "component.majorOutage"
  case componentUnderMaintenance = "component.underMaintenance"
  case componentUnknown = "component.unknown"
  case incidentInvestigating = "incident.investigating"
  case incidentIdentified = "incident.identified"
  case incidentMonitoring = "incident.monitoring"
  case incidentResolved = "incident.resolved"
  case incidentPostmortem = "incident.postmortem"
  case incidentUnknown = "incident.unknown"
  case impactNone = "impact.none"
  case impactMinor = "impact.minor"
  case impactMajor = "impact.major"
  case impactCritical = "impact.critical"
  case impactUnknown = "impact.unknown"

  // 错误
  case errorUnauthorized = "error.unauthorized"
  case errorInsufficientBalance = "error.insufficientBalance"
  case errorRateLimited = "error.rateLimited"
  case errorHttp = "error.http"
  case errorServer = "error.server"
  case errorNoNetwork = "error.noNetwork"
  case errorTimeout = "error.timeout"
  case errorDecoding = "error.decoding"
  case errorKeychain = "error.keychain"
  case errorHistory = "error.history"
  case errorServiceStatus = "error.serviceStatus"
  case errorUnknown = "error.unknown"

  // 底部与辅助功能
  case footerRefresh = "footer.refresh"
  case footerQuit = "footer.quit"
  case menuOpenDashboard = "menu.openDashboard"
  case menuSettings = "menu.settings"
  case menuBarVisibility = "menu.barVisibility"
  case menuShowDeepSeek = "menu.showDeepSeek"
  case menuShowCodex = "menu.showCodex"
  case a11yStatus = "a11y.status"
  case a11yDeepSeekIcon = "a11y.deepseekIcon"
  case a11yMenuBar = "a11y.menuBar"
  case a11yLegend = "a11y.legend"
  case a11yCurrencyPicker = "a11y.currencyPicker"

  // 图例
  case legendTotal = "legend.total"
  case legendToppedUp = "legend.toppedUp"
  case legendGranted = "legend.granted"

  // 其他
  case appTitle = "app.title"
  case unknown = "common.unknown"

  // Codex 用量
  case tabDeepSeek = "tab.deepseek"
  case tabCodex = "tab.codex"
  case codexTitle = "codex.title"
  case codexPlan = "codex.plan"
  case codexPlanUnknown = "codex.planUnknown"
  case codexAccount = "codex.account"
  case codexWindowWeekly = "codex.windowWeekly"
  case codexWindowFiveHour = "codex.windowFiveHour"
  case codexWindowFiveHourNone = "codex.windowFiveHourNone"
  case codexWindowDaily = "codex.windowDaily"
  case codexWindowGeneric = "codex.windowGeneric"
  case codexWindowUsedRemaining = "codex.windowUsedRemaining"
  case codexResetAt = "codex.resetAt"
  case codexExpectedMarker = "codex.expectedMarker"
  case codexLimitAllowed = "codex.limitAllowed"
  case codexLimitReached = "codex.limitReached"
  case codexNoLimit = "codex.noLimit"
  case codexFreePlan = "codex.freePlan"
  case codexCreditsTitle = "codex.creditsTitle"
  case codexCreditsNone = "codex.creditsNone"
  case codexCreditsUnlimited = "codex.creditsUnlimited"
  case codexCreditsBalance = "codex.creditsBalance"
  case codexLoading = "codex.loading"
  case codexEmpty = "codex.empty"
  case codexNotConfigured = "codex.notConfigured"
  case codexNotConfiguredDetail = "codex.notConfiguredDetail"
  case codexAuthInvalid = "codex.authInvalid"
  case codexLastUpdated = "codex.lastUpdated"
  case codexTrendTitle = "codex.trendTitle"
  case codexTrendSummary = "codex.trendSummary"
  case codexTrendInsufficient = "codex.trendInsufficient"
  case a11yCodexIcon = "a11y.codexIcon"
  case a11yMenuBarCodex = "a11y.menuBarCodex"

  // Cursor 用量
  case tabCursor = "tab.cursor"
  case cursorTitle = "cursor.title"
  case cursorPlan = "cursor.plan"
  case cursorPlanUnknown = "cursor.planUnknown"
  case cursorAccount = "cursor.account"
  case cursorWindowTitle = "cursor.windowTitle"
  case cursorWindowUsedRemaining = "cursor.windowUsedRemaining"
  case cursorResetAt = "cursor.resetAt"
  case cursorExpectedMarker = "cursor.expectedMarker"
  case cursorLimitAllowed = "cursor.limitAllowed"
  case cursorLimitReached = "cursor.limitReached"
  case cursorNoLimit = "cursor.noLimit"
  case cursorFreePlan = "cursor.freePlan"
  case cursorApiChannel = "cursor.apiChannel"
  case cursorSpendTitle = "cursor.spendTitle"
  case cursorSpendTotal = "cursor.spendTotal"
  case cursorSpendIncluded = "cursor.spendIncluded"
  case cursorSpendBonus = "cursor.spendBonus"
  case cursorSpendLimit = "cursor.spendLimit"
  case cursorLoading = "cursor.loading"
  case cursorEmpty = "cursor.empty"
  case cursorNotConfigured = "cursor.notConfigured"
  case cursorNotConfiguredDetail = "cursor.notConfiguredDetail"
  case cursorAuthInvalid = "cursor.authInvalid"
  case cursorLastUpdated = "cursor.lastUpdated"
  case cursorTrendTitle = "cursor.trendTitle"
  case cursorTrendSummary = "cursor.trendSummary"
  case cursorTrendInsufficient = "cursor.trendInsufficient"
  case cursorTrendFirstParty = "cursor.trendFirstParty"
  case cursorTrendApi = "cursor.trendApi"
  case menuShowCursor = "menu.showCursor"
  case a11yCursorIcon = "a11y.cursorIcon"
  case a11yMenuBarCursor = "a11y.menuBarCursor"
}

/// 本地化入口：按当前选择语言读取 String Catalog，缺 key 时回退英文。
enum L10n {
  static func string(
    _ key: L10nKey,
    language: AppLanguage,
    _ arguments: CVarArg...
  ) -> String {
    var template = bundle(for: language).localizedString(
      forKey: key.rawValue,
      value: key.rawValue,
      table: nil
    )
    if template == key.rawValue, language != .english {
      template = bundle(for: .english).localizedString(
        forKey: key.rawValue,
        value: key.rawValue,
        table: nil
      )
    }
    if arguments.isEmpty {
      return template
    }
    return String(format: template, locale: language.locale, arguments: arguments)
  }

  static func bundle(for language: AppLanguage) -> Bundle {
    if let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
      let bundle = Bundle(path: path)
    {
      return bundle
    }
    return .main
  }
}
