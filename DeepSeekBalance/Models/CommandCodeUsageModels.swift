import Foundation

/// `api.commandcode.ai` 用量聚合响应（Command Code 订阅用量）。
/// 由三个 endpoint 归一化合并：`/alpha/billing/credits`、`/alpha/billing/subscriptions`、
/// `/alpha/usage/summary`，加上 `/alpha/whoami` 的账号信息。字段缺失或为 null 时回退为空。
struct CommandCodeUsageResponse: Codable, Equatable, Sendable {
  /// 月度/购买/免费剩余额度（credits 响应）。
  let credits: CommandCodeCredits?
  /// 5 小时与每周窗口限制（credits 响应附带）。
  let windowLimits: CommandCodeWindowLimits?
  /// 订阅信息（subscriptions 响应）。
  let subscription: CommandCodeSubscription?
  /// 本计费周期用量汇总（usage/summary 响应）。
  let summary: CommandCodeUsageSummary?
  /// 当前登录用户（whoami 响应）。
  let user: CommandCodeUser?

  /// 计划名称（如 Pro / Max），未知回退大写。
  var planDisplayName: String? {
    subscription?.planDisplayName
  }

  /// 订阅状态（active 等）。
  var subscriptionStatus: String? {
    subscription?.status
  }

  /// 是否订阅已激活。
  var isActive: Bool {
    subscription?.status == "active"
  }

  /// 计费周期结束时间（重置时间）。
  var currentPeriodEndDate: Date? {
    subscription?.currentPeriodEndDate
  }

  /// 计费周期开始时间。
  var currentPeriodStartDate: Date? {
    subscription?.currentPeriodStartDate
  }

  /// 月度剩余额度（美元）。
  var monthlyRemainingCredits: Double? {
    credits?.monthlyCredits
  }

  /// 购买的附加额度（美元）。
  var purchasedRemainingCredits: Double? {
    credits?.purchasedCredits
  }

  /// 免费额度（美元）。
  var freeRemainingCredits: Double? {
    credits?.freeCredits
  }

  /// 当前已用额度金额（美元）：`总池 - 剩余`。
  var usedCredits: Double? {
    guard let total = totalPool, let remaining = totalRemainingCredits else { return nil }
    return max(0, total - remaining)
  }

  /// 总可用额度（美元）：有订阅时 = 计划额度与月度剩余取大者 + 购买 + 免费；
  /// 无订阅时 = 本月已花 + 剩余。
  var totalPool: Double? {
    let monthly = monthlyRemainingCredits ?? 0
    let purchased = purchasedRemainingCredits ?? 0
    let free = freeRemainingCredits ?? 0
    let spent = summary?.totalCost ?? 0
    if isActive, let planMonthly = subscription?.planMonthlyCredits {
      return max(planMonthly, monthly) + purchased + free
    }
    guard hasAnyCredits else { return nil }
    return spent + monthly + purchased + free
  }

  /// 总剩余额度（美元）。
  var totalRemainingCredits: Double? {
    let monthly = monthlyRemainingCredits ?? 0
    let purchased = purchasedRemainingCredits ?? 0
    let free = freeRemainingCredits ?? 0
    guard monthly > 0 || purchased > 0 || free > 0 else {
      // 全部为 0 时仅在确实有计费数据时才算“剩余 0”，否则视为无数据。
      return hasAnyCredits ? 0 : nil
    }
    return monthly + purchased + free
  }

  /// 是否有任何计费数据（额度或订阅）。
  var hasAnyCredits: Bool {
    credits != nil || subscription != nil
  }

  /// 已用百分比（0...100）。
  var usedPercent: Int? {
    guard let total = totalPool, total > 0, let used = usedCredits else { return nil }
    return max(0, min(100, Int((used / total * 100).rounded())))
  }

  /// 剩余百分比（0...100）。
  var remainingPercent: Int? {
    guard let usedPercent else { return nil }
    return max(0, min(100, 100 - usedPercent))
  }

  /// 与理想用量（计费周期内线性消耗、重置时恰好用完）的差距：
  /// 实际已用 − 理想已用，正数表示消耗快于理想、负数表示慢于理想。
  var usageGapPercent: Int? {
    guard let currentPeriodEndDate, let currentPeriodStartDate,
      let expected = CommandCodeUsageFormatter.expectedUsedPercent(
        start: currentPeriodStartDate,
        end: currentPeriodEndDate
      ),
      let usedPercent
    else {
      return nil
    }
    return usedPercent - Int(expected.rounded())
  }

  /// 5 小时窗口限制（若命中）。
  var fiveHourLimit: CommandCodeWindowLimit? {
    windowLimits?.fiveHour
  }

  /// 每周窗口限制（若命中）。
  var weeklyLimit: CommandCodeWindowLimit? {
    windowLimits?.weekly
  }

  /// 是否有任何窗口限制命中（5 小时/每周）。
  var hasActiveWindowLimit: Bool {
    windowLimits?.limited == true
  }

  /// 计费周期剩余天数（向下取整）。
  var daysRemaining: Int? {
    guard let currentPeriodEndDate else { return nil }
    let days = currentPeriodEndDate.timeIntervalSinceNow / 86_400
    return max(0, Int(ceil(days)))
  }
}

/// 额度信息（`/alpha/billing/credits` 响应）。
struct CommandCodeCredits: Codable, Equatable, Sendable {
  let monthlyCredits: Double?
  let purchasedCredits: Double?
  let freeCredits: Double?
  let belowThreshold: Bool?
}

/// 窗口限制（5 小时 / 每周）。
struct CommandCodeWindowLimits: Codable, Equatable, Sendable {
  let limited: Bool?
  let fiveHour: CommandCodeWindowLimit?
  let weekly: CommandCodeWindowLimit?

  enum CodingKeys: String, CodingKey {
    case limited
    case fiveHour
    case weekly
  }
}

/// 单个窗口限制：已用/上限（美元）与重置时间（毫秒时间戳，可能是字符串或数字）。
struct CommandCodeWindowLimit: Codable, Equatable, Sendable {
  let used: Double?
  let cap: Double?
  let exceeded: Bool?
  let resetAt: Int64?

  enum CodingKeys: String, CodingKey {
    case used
    case cap
    case exceeded
    case resetAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    used = try container.decodeIfPresent(Double.self, forKey: .used)
    cap = try container.decodeIfPresent(Double.self, forKey: .cap)
    exceeded = try container.decodeIfPresent(Bool.self, forKey: .exceeded)
    resetAt = try Self.decodeEpochMs(container, key: .resetAt)
  }

  /// 重置时间（毫秒时间戳 → Date）。
  var resetAtDate: Date? {
    guard let resetAt, resetAt > 0 else { return nil }
    return Date(timeIntervalSince1970: Double(resetAt) / 1000)
  }

  /// 该窗口已用百分比（0...100）。
  var usedPercent: Int? {
    guard let used, let cap, cap > 0 else { return nil }
    return max(0, min(100, Int((used / cap * 100).rounded())))
  }

  /// 是否已超出上限。
  var isExceeded: Bool {
    exceeded == true
  }

  private static func decodeEpochMs(
    _ container: KeyedDecodingContainer<CodingKeys>,
    key: CodingKeys
  ) throws -> Int64? {
    guard container.contains(key) else { return nil }
    if let asString = try? container.decode(String.self, forKey: key) {
      return Int64(asString)
    }
    if let asNumber = try? container.decode(Int64.self, forKey: key) {
      return asNumber
    }
    return nil
  }
}

/// 订阅信息（`/alpha/billing/subscriptions` 响应）。
struct CommandCodeSubscription: Codable, Equatable, Sendable {
  let id: String?
  let status: String?
  let planId: String?
  let currentPeriodStart: String?
  let currentPeriodEnd: String?
  let cancelAtPeriodEnd: Bool?

  var currentPeriodStartDate: Date? {
    guard let currentPeriodStart else { return nil }
    return Self.parseDate(currentPeriodStart)
  }

  var currentPeriodEndDate: Date? {
    guard let currentPeriodEnd else { return nil }
    return Self.parseDate(currentPeriodEnd)
  }

  /// 解析 API 返回的 ISO8601 时间（可能带毫秒，如 `2026-08-06T02:10:47.000Z`）。
  private static func parseDate(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: string) {
      return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string)
  }

  /// 计划品牌名（如 Pro / Max / Ultra）。
  var planDisplayName: String? {
    CommandCodeUsageFormatter.planDisplayName(planId)
  }

  /// 计划每月额度（美元）；未知计划返回 nil。
  var planMonthlyCredits: Double? {
    CommandCodeUsageFormatter.monthlyCredits(for: planId)
  }
}

/// 用量汇总（`/alpha/usage/summary` 响应）。
struct CommandCodeUsageSummary: Codable, Equatable, Sendable {
  let totalCount: Int?
  let totalCost: Double?
  let averageCost: Double?
  let successRate: Double?
  let totalTokens: Int?
  let periodBasis: String?
}

/// 当前用户（`/alpha/whoami` 响应）。
struct CommandCodeUser: Codable, Equatable, Sendable {
  let id: String?
  let name: String?
  let email: String?
  let userName: String?
}

/// Command Code 用量展示格式化。
enum CommandCodeUsageFormatter {
  /// 计划 ID → 品牌名；未知计划回退为 planId 原样。
  static func planDisplayName(_ rawPlanID: String?) -> String? {
    guard let rawPlanID, !rawPlanID.isEmpty else { return nil }
    let normalized = rawPlanID.lowercased().replacingOccurrences(of: "_", with: "-")
    for key in planMonthlyCredits.keys.sorted(by: { $0.count > $1.count })
    where normalized.hasPrefix(key) {
      return planNames[key] ?? key.uppercased()
    }
    return rawPlanID.uppercased()
  }

  /// 计划 ID 前缀 → 每月额度（美元）。
  static func monthlyCredits(for rawPlanID: String?) -> Double? {
    guard let rawPlanID else { return nil }
    let normalized = rawPlanID.lowercased().replacingOccurrences(of: "_", with: "-")
    for (key, credits) in planMonthlyCredits.sorted(by: { $0.key.count > $1.key.count })
    where normalized.hasPrefix(key) {
      return credits
    }
    return nil
  }

  /// 计划 ID 前缀 → 每月额度（美元）。来自 Command Code CLI 源码常量。
  static let planMonthlyCredits: [String: Double] = [
    "individual-go": 10,
    "individual-goat": 70,
    "individual-pro": 30,
    "individual-pro-v1": 80,
    "individual-provider": 15,
    "individual-max": 150,
    "individual-ultra": 300,
    "teams-pro": 40,
  ]

  /// 计划 ID 前缀 → 品牌名。
  static let planNames: [String: String] = [
    "individual-go": "Go",
    "individual-goat": "GOAT",
    "individual-pro": "Pro",
    "individual-provider": "Provider",
    "individual-max": "Max",
    "individual-ultra": "Ultra",
    "teams-pro": "Teams Pro",
  ]

  /// 假设用量在计费周期内线性消耗，返回当前时间对应的“应消耗”百分比（0...100）。
  /// 周期信息缺失或当前时间不在周期内时返回 nil（不画标记线）。
  static func expectedUsedPercent(
    start: Date,
    end: Date,
    now: Date = Date()
  ) -> Double? {
    let startT = start.timeIntervalSince1970
    let endT = end.timeIntervalSince1970
    let nowT = now.timeIntervalSince1970
    guard startT < endT, nowT >= startT, nowT <= endT else { return nil }
    return min(100, max(0, (nowT - startT) / (endT - startT) * 100))
  }

  /// 美元金额格式化为美元字符串，例如 `$12.35`；无金额时返回 nil。
  static func formatUSD(_ value: Double?, locale: Locale) -> String? {
    guard let value else { return nil }
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.locale = Locale(identifier: "en_US")
    formatter.currencyCode = "USD"
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    return formatter.string(from: NSNumber(value: value))
  }
}
