import Foundation

/// ChatGPT `/backend-api/wham/usage` 响应模型（Codex 订阅用量）。
/// 所有字段可选，缺失或为 null 时回退为空，避免整体解码失败。
struct CodexUsageResponse: Codable, Equatable, Sendable {
  let userID: String?
  let accountID: String?
  let email: String?
  let planType: String?
  let rateLimit: CodexRateLimit?
  let codeReviewRateLimit: CodexRateLimit?
  let additionalRateLimits: [CodexAdditionalRateLimit]?
  let credits: CodexCredits?
  let spendControl: CodexSpendControl?
  let rateLimitReachedType: String?
  let rateLimitResetCredits: CodexResetCredits?

  enum CodingKeys: String, CodingKey {
    case userID = "user_id"
    case accountID = "account_id"
    case email
    case planType = "plan_type"
    case rateLimit = "rate_limit"
    case codeReviewRateLimit = "code_review_rate_limit"
    case additionalRateLimits = "additional_rate_limits"
    case credits
    case spendControl = "spend_control"
    case rateLimitReachedType = "rate_limit_reached_type"
    case rateLimitResetCredits = "rate_limit_reset_credits"
  }

  /// 主用量窗口（菜单栏与概览使用）。
  var primaryWindow: CodexUsageWindow? {
    rateLimit?.primaryWindow
  }

  /// 5 小时用量窗口：官方目前只下发每周窗口，5 小时窗口字段为 null。
  /// 预留实现：将来 Codex 若增加 5 小时限制，此值会自动变为实际剩余；
  /// 查不到该限制时视为可用量始终 100%。
  var fiveHourRemainingPercent: Int {
    rateLimit?.secondaryWindow?.remainingPercent ?? 100
  }

  /// 主窗口剩余百分比：0...100。
  var remainingPercent: Int? {
    guard let used = primaryWindow?.usedPercent else { return nil }
    return max(0, min(100, 100 - used))
  }

  /// 整体剩余百分比：取 5 小时与每周窗口中更严格（更小）的值。
  /// 5 小时窗口未下发时按 100% 参与计算，不改变当前显示。
  var overallRemainingPercent: Int? {
    guard let weekly = remainingPercent else { return nil }
    return min(weekly, fiveHourRemainingPercent)
  }

  /// 基于信用额度的剩余百分比：`credits.balance / monthlyLimit`。
  /// 优先使用 `spendControl.individualLimit`（OpenAI 下发的月度上限），
  /// 回退到 `planType` 推断的默认 grant 金额（如 Pro 为 $25/mo）。
  /// 只在账户有信用额度（`hasCredits == true`）且非无限（`unlimited == false`）
  /// 时使用此值，否则返回 `nil` 让调用者回退 API 请求配额百分比。
  var creditBasedRemainingPercent: Int? {
    guard let credits, credits.hasCredits, !credits.unlimited,
      let balanceString = credits.balance
    else { return nil }
    // 优先 API 下发的上限，其次按套餐类型推断
    let limit: Double
    if let apiLimit = spendControl?.individualLimit, apiLimit > 0 {
      limit = apiLimit
    } else if let planType, let inferred = Self.monthlyLimit(for: planType) {
      limit = inferred
    } else {
      return nil
    }
    // "¥7.00" → "7.00", "$25.00" → "25.00"
    let numeric = balanceString.filter { $0.isASCII && ($0.isNumber || $0 == ".") }
    guard let balance = Double(numeric), balance >= 0 else { return nil }
    return max(0, min(100, Int((balance / limit * 100).rounded())))
  }

  /// 根据 Codex 套餐类型返回对应的月度 grant 金额（美元）。
  /// 套餐 grant 金额是已知公开信息；未知套餐返回 `nil`。
  /// 服务端可能返回 snake_case (`pro_lite`)、连写 (`prolite`)、
  /// 空格 (`Pro Lite`) 等变体，逐一尝试。
  static func monthlyLimit(for planType: String) -> Double? {
    let normalized = planType.lowercased()
      .replacingOccurrences(of: "_", with: "")
      .replacingOccurrences(of: "-", with: "")
      .replacingOccurrences(of: " ", with: "")
    switch normalized {
    case "pro":    return 25
    case "plus":   return 20
    case "free":   return 5
    case "prolite": return 15
    default:       return nil
    }
  }

  /// 与理想用量（刷新周期内线性消耗、重置时恰好用完）的差距：
  /// 实际已用 − 理想已用，正数表示消耗快于理想、负数表示慢于理想。
  /// 无主窗口信息或当前时间不在窗口内时为 nil（不显示差距）。
  var usageGapPercent: Int? {
    guard let window = primaryWindow else { return nil }
    guard let expected = CodexUsageFormatter.expectedUsedPercent(
      resetAt: window.resetAt,
      limitWindowSeconds: window.limitWindowSeconds
    ) else { return nil }
    return window.usedPercent - Int(expected.rounded())
  }
}

/// 单个限额（整体用量或附加模型限额）。
struct CodexRateLimit: Codable, Equatable, Sendable {
  let allowed: Bool
  let limitReached: Bool
  let primaryWindow: CodexUsageWindow?
  let secondaryWindow: CodexUsageWindow?

  enum CodingKeys: String, CodingKey {
    case allowed
    case limitReached = "limit_reached"
    case primaryWindow = "primary_window"
    case secondaryWindow = "secondary_window"
  }
}

/// 附加模型限额，例如 GPT-5.3-Codex-Spark。
struct CodexAdditionalRateLimit: Codable, Equatable, Sendable {
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
  let resetAfterSeconds: Int
  let resetAt: Int?

  enum CodingKeys: String, CodingKey {
    case usedPercent = "used_percent"
    case limitWindowSeconds = "limit_window_seconds"
    case resetAfterSeconds = "reset_after_seconds"
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
struct CodexSpendControl: Codable, Equatable, Sendable {
  let reached: Bool
  let individualLimit: Double?

  enum CodingKeys: String, CodingKey {
    case reached
    case individualLimit = "individual_limit"
  }
}

/// 限速重置点数（rate_limit_reset_credits）。
struct CodexResetCredits: Codable, Equatable, Sendable {
  let availableCount: Int
  let applicableAvailableCount: Int

  enum CodingKeys: String, CodingKey {
    case availableCount = "available_count"
    case applicableAvailableCount = "applicable_available_count"
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
