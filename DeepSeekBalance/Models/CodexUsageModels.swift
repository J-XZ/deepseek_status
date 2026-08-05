import Foundation

/// ChatGPT `/backend-api/wham/usage` 响应模型（Codex 订阅用量）。
/// 所有字段可选，缺失或为 null 时回退为空，避免整体解码失败。
struct CodexUsageResponse: Decodable, Equatable, Sendable {
  let userID: String?
  let accountID: String?
  let email: String?
  let planType: String?
  let rateLimit: CodexRateLimit?
  let additionalRateLimits: [CodexAdditionalRateLimit]?
  let credits: CodexCredits?
  let spendControl: CodexSpendControl?
  let topLevelIndividualLimit: CodexSpendControlLimit?

  enum CodingKeys: String, CodingKey {
    case userID = "user_id"
    case accountID = "account_id"
    case email
    case planType = "plan_type"
    case rateLimit = "rate_limit"
    case additionalRateLimits = "additional_rate_limits"
    case credits
    case spendControl = "spend_control"
    case topLevelIndividualLimit = "individual_limit"
    case topLevelIndividualLimitCamel = "individualLimit"
  }

  init(
    userID: String? = nil,
    accountID: String? = nil,
    email: String? = nil,
    planType: String? = nil,
    rateLimit: CodexRateLimit? = nil,
    additionalRateLimits: [CodexAdditionalRateLimit]? = nil,
    credits: CodexCredits? = nil,
    spendControl: CodexSpendControl? = nil,
    topLevelIndividualLimit: CodexSpendControlLimit? = nil
  ) {
    self.userID = userID
    self.accountID = accountID
    self.email = email
    self.planType = planType
    self.rateLimit = rateLimit
    self.additionalRateLimits = additionalRateLimits
    self.credits = credits
    self.spendControl = spendControl
    self.topLevelIndividualLimit = topLevelIndividualLimit
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    userID = try? container.decodeIfPresent(String.self, forKey: .userID)
    accountID = try? container.decodeIfPresent(String.self, forKey: .accountID)
    email = try? container.decodeIfPresent(String.self, forKey: .email)
    planType = try? container.decodeIfPresent(String.self, forKey: .planType)
    rateLimit = try? container.decodeIfPresent(CodexRateLimit.self, forKey: .rateLimit)
    additionalRateLimits = try? container.decodeIfPresent(
      [CodexAdditionalRateLimit].self,
      forKey: .additionalRateLimits
    )
    credits = try? container.decodeIfPresent(CodexCredits.self, forKey: .credits)
    spendControl = try? container.decodeIfPresent(CodexSpendControl.self, forKey: .spendControl)
    topLevelIndividualLimit =
      (try? container.decodeIfPresent(CodexSpendControlLimit.self, forKey: .topLevelIndividualLimit))
      ?? (try? container.decodeIfPresent(CodexSpendControlLimit.self, forKey: .topLevelIndividualLimitCamel))
  }

  /// 每周用量窗口（604800 秒）。
  /// 服务端结构不稳定：历史版本把周窗口放在 primary_window，文档示例中
  /// 也可能放在 secondary_window。一律按 `limitWindowSeconds` 识别，
  /// 不依赖窗口位置，保证在两种结构下都能取到周用量。
  var weeklyWindow: CodexUsageWindow? {
    [rateLimit?.primaryWindow, rateLimit?.secondaryWindow]
      .compactMap { $0 }
      .first { $0.limitWindowSeconds == 604800 }
  }

  /// 5 小时用量窗口（18000 秒）；未下发时为 nil。
  var fiveHourWindow: CodexUsageWindow? {
    [rateLimit?.primaryWindow, rateLimit?.secondaryWindow]
      .compactMap { $0 }
      .first { $0.limitWindowSeconds == 18000 }
  }

  /// 官方下发的额度限制快照。参考 CodexBar：`individual_limit` 可能出现在
  /// 顶层、`rate_limit` 内部或 `spend_control` 内部，三处都尝试。
  var individualLimit: CodexSpendControlLimit? {
    spendControl?.individualLimit
      ?? rateLimit?.individualLimit
      ?? topLevelIndividualLimit
  }

  /// 官方口径的剩余百分比：优先使用 `individual_limit.remainingPercent`
  ///（OpenAI 直接下发，如 27）；缺失时用 `limit`/`used` 推算；再缺失时
  /// 回退到每周窗口的 `100 - usedPercent`。
  var creditRemainingPercent: Int? {
    if let official = individualLimit?.remainingPercent, official.isFinite {
      return max(0, min(100, Int(official.rounded())))
    }
    if let limit = individualLimit?.limit, limit > 0 {
      if let used = individualLimit?.used, used.isFinite {
        return max(0, min(100, Int((100 - used / limit * 100).rounded())))
      }
    }
    return remainingPercent
  }

  /// 每周窗口剩余百分比：0...100。周窗口缺失时为 nil。
  var remainingPercent: Int? {
    guard let used = weeklyWindow?.usedPercent else { return nil }
    return max(0, min(100, 100 - used))
  }

  /// 5 小时窗口剩余百分比：0...100。查不到该限制时视为可用量始终 100%。
  var fiveHourRemainingPercent: Int {
    fiveHourWindow?.remainingPercent ?? 100
  }

  /// 整体剩余百分比：取 5 小时与每周窗口中更严格（更小）的值。
  /// 5 小时窗口未下发时按 100% 参与计算，不改变当前显示。
  var overallRemainingPercent: Int? {
    guard let weekly = remainingPercent else { return nil }
    return min(weekly, fiveHourRemainingPercent)
  }

  /// 与理想用量（每周窗口内线性消耗、重置时恰好用完）的差距：
  /// 实际已用 − 理想已用，正数表示消耗快于理想、负数表示慢于理想。
  /// 无周窗口信息或当前时间不在窗口内时为 nil（不显示差距）。
  var usageGapPercent: Int? {
    guard let window = weeklyWindow else { return nil }
    guard let expected = CodexUsageFormatter.expectedUsedPercent(
      resetAt: window.resetAt,
      limitWindowSeconds: window.limitWindowSeconds
    ) else { return nil }
    return window.usedPercent - Int(expected.rounded())
  }
}

/// 单个限额（整体用量或附加模型限额）。
struct CodexRateLimit: Decodable, Equatable, Sendable {
  let allowed: Bool
  let limitReached: Bool
  let primaryWindow: CodexUsageWindow?
  let secondaryWindow: CodexUsageWindow?
  let individualLimit: CodexSpendControlLimit?

  enum CodingKeys: String, CodingKey {
    case allowed
    case limitReached = "limit_reached"
    case primaryWindow = "primary_window"
    case secondaryWindow = "secondary_window"
    case individualLimit = "individual_limit"
    case individualLimitCamel = "individualLimit"
  }

  init(
    allowed: Bool = true,
    limitReached: Bool = false,
    primaryWindow: CodexUsageWindow? = nil,
    secondaryWindow: CodexUsageWindow? = nil,
    individualLimit: CodexSpendControlLimit? = nil
  ) {
    self.allowed = allowed
    self.limitReached = limitReached
    self.primaryWindow = primaryWindow
    self.secondaryWindow = secondaryWindow
    self.individualLimit = individualLimit
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    allowed = try container.decodeIfPresent(Bool.self, forKey: .allowed) ?? true
    limitReached = try container.decodeIfPresent(Bool.self, forKey: .limitReached) ?? false
    primaryWindow = try? container.decodeIfPresent(CodexUsageWindow.self, forKey: .primaryWindow)
    secondaryWindow = try? container.decodeIfPresent(CodexUsageWindow.self, forKey: .secondaryWindow)
    individualLimit =
      (try? container.decodeIfPresent(CodexSpendControlLimit.self, forKey: .individualLimit))
      ?? (try? container.decodeIfPresent(CodexSpendControlLimit.self, forKey: .individualLimitCamel))
  }
}

/// 附加模型限额，例如 GPT-5.3-Codex-Spark。
struct CodexAdditionalRateLimit: Decodable, Equatable, Sendable {
  let limitName: String?
  let meteredFeature: String?
  let rateLimit: CodexRateLimit?

  enum CodingKeys: String, CodingKey {
    case limitName = "limit_name"
    case meteredFeature = "metered_feature"
    case rateLimit = "rate_limit"
  }
}

/// 用量窗口：已用百分比 + 重置时间（Unix 秒）。
struct CodexUsageWindow: Codable, Equatable, Sendable {
  let usedPercent: Int
  let limitWindowSeconds: Int
  let resetAt: Int?

  enum CodingKeys: String, CodingKey {
    case usedPercent = "used_percent"
    case limitWindowSeconds = "limit_window_seconds"
    case resetAt = "reset_at"
  }

  var remainingPercent: Int {
    max(0, min(100, 100 - usedPercent))
  }
}

/// 额外额度（credits）。
struct CodexCredits: Codable, Equatable, Sendable {
  let hasCredits: Bool
  let unlimited: Bool
  let overageLimitReached: Bool
  /// 当前信用额度余额。服务端可能返回字符串（`"7.00"`、`"$7.00"`）或
  /// 数字（`7.0`）；统统接受。
  let balance: String?

  enum CodingKeys: String, CodingKey {
    case hasCredits = "has_credits"
    case unlimited
    case overageLimitReached = "overage_limit_reached"
    case balance
  }

  init(hasCredits: Bool, unlimited: Bool, overageLimitReached: Bool, balance: String?) {
    self.hasCredits = hasCredits
    self.unlimited = unlimited
    self.overageLimitReached = overageLimitReached
    self.balance = balance
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    hasCredits = try container.decode(Bool.self, forKey: .hasCredits)
    unlimited = try container.decodeIfPresent(Bool.self, forKey: .unlimited) ?? false
    overageLimitReached = try container.decodeIfPresent(Bool.self, forKey: .overageLimitReached) ?? false
    // 兼容字符串和数字两种格式
    if let stringValue = try? container.decode(String.self, forKey: .balance) {
      balance = stringValue
    } else if let numberValue = try? container.decode(Double.self, forKey: .balance) {
      balance = String(numberValue)
    } else {
      balance = nil
    }
  }
}

/// 费用控制（spend control）。
/// 参考 CodexBar（steipete/CodexBar）的实现：`individual_limit` 是一个对象
/// （`SpendControlLimitSnapshot`），包含官方直接下发的 `remainingPercent`、
/// `used`、`limit`——这是 OpenAI 官方计算的剩余百分比口径，
/// 比从 used_percent 推算更准确。字段名有 snake_case 与 camelCase 两种，
/// 金额可能以数字或字符串下发，全部兼容。
struct CodexSpendControl: Decodable, Equatable, Sendable {
  let reached: Bool
  let individualLimit: CodexSpendControlLimit?

  enum CodingKeys: String, CodingKey {
    case reached
    case individualLimit = "individual_limit"
    case individualLimitCamel = "individualLimit"
  }

  init(reached: Bool, individualLimit: CodexSpendControlLimit?) {
    self.reached = reached
    self.individualLimit = individualLimit
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    reached = try container.decodeIfPresent(Bool.self, forKey: .reached) ?? false
    individualLimit = (try? container.decodeIfPresent(CodexSpendControlLimit.self, forKey: .individualLimit))
      ?? (try? container.decodeIfPresent(CodexSpendControlLimit.self, forKey: .individualLimitCamel))
  }
}

/// 官方下发的额度限制快照：`remainingPercent` 由 OpenAI 直接计算。
struct CodexSpendControlLimit: Decodable, Equatable, Sendable {
  let limit: Double?
  let used: Double?
  let remainingPercent: Double?

  enum CodingKeys: String, CodingKey {
    case limit
    case used
    case remainingPercent
    case remainingPercentSnake = "remaining_percent"
  }

  init(limit: Double?, used: Double?, remainingPercent: Double?) {
    self.limit = limit
    self.used = used
    self.remainingPercent = remainingPercent
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    limit = Self.decodeFlexibleDouble(container, forKey: .limit)
    used = Self.decodeFlexibleDouble(container, forKey: .used)
    remainingPercent = Self.decodeFlexibleDouble(container, forKey: .remainingPercent)
      ?? Self.decodeFlexibleDouble(container, forKey: .remainingPercentSnake)
  }

  private static func decodeFlexibleDouble(
    _ container: KeyedDecodingContainer<CodingKeys>,
    forKey key: CodingKeys
  ) -> Double? {
    if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
      return value
    }
    if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
      return Double(value)
    }
    if let value = try? container.decodeIfPresent(String.self, forKey: key) {
      return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return nil
  }

  private static func decodeFlexibleInt(
    _ container: KeyedDecodingContainer<CodingKeys>,
    forKey key: CodingKeys
  ) -> Int? {
    if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
      return value
    }
    if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
      return Int(value)
    }
    if let value = try? container.decodeIfPresent(String.self, forKey: key) {
      return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return nil
  }
}

/// Codex 用量展示格式化。
enum CodexUsageFormatter {
  /// 订阅方案的品牌名；未知值回退为原样大写。
  static func planDisplayName(_ rawPlanType: String?) -> String? {
    guard let rawPlanType, !rawPlanType.isEmpty else { return nil }
    switch rawPlanType.lowercased() {
    case "free":
      return "Free"
    case "plus":
      return "Plus"
    case "pro":
      return "Pro"
    case "prolite":
      return "Pro Lite"
    case "business":
      return "Business"
    case "team":
      return "Team"
    case "enterprise":
      return "Enterprise"
    default:
      return rawPlanType.uppercased()
    }
  }

  /// 窗口名称：按窗口秒数识别官方窗口，未知秒数回退通用名称。
  static func windowTitle(limitWindowSeconds: Int, language: AppLanguage) -> String {
    switch limitWindowSeconds {
    case 60 * 60 * 24 * 7:
      return L10n.string(.codexWindowWeekly, language: language)
    case 60 * 60 * 5:
      return L10n.string(.codexWindowFiveHour, language: language)
    case 60 * 60 * 24:
      return L10n.string(.codexWindowDaily, language: language)
    default:
      return L10n.string(.codexWindowGeneric, language: language)
    }
  }

  /// 重置时间展示；无重置时间时返回 nil。
  static func resetDate(resetAt: Int?, locale: Locale) -> Date? {
    guard let resetAt else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(resetAt))
  }

  /// 假设用量在刷新周期内线性消耗，返回当前时间对应的“应消耗”百分比（0...100）。
  /// 窗口信息缺失或当前时间不在窗口内时返回 nil（不画标记线）。
  static func expectedUsedPercent(
    resetAt: Int?,
    limitWindowSeconds: Int,
    now: Date = Date()
  ) -> Double? {
    guard let resetAt, limitWindowSeconds > 0 else { return nil }
    let windowEnd = TimeInterval(resetAt)
    let windowStart = windowEnd - Double(limitWindowSeconds)
    let nowT = now.timeIntervalSince1970
    guard nowT >= windowStart, nowT <= windowEnd, windowStart < windowEnd else { return nil }
    return min(100, max(0, (nowT - windowStart) / (windowEnd - windowStart) * 100))
  }
}
