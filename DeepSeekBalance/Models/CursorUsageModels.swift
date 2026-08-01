import Foundation

/// `api2.cursor.sh` DashboardService.GetCurrentPeriodUsage 响应模型（Cursor 订阅用量）。
/// 字段来自 Cursor 客户端内部契约，非公开文档，缺失或为 null 时回退为空，避免整体解码失败。
struct CursorUsageResponse: Codable, Equatable, Sendable {
  let billingCycleStart: Int64?
  let billingCycleEnd: Int64?
  let planUsage: CursorPlanUsage?
  let spendLimitUsage: CursorSpendLimitUsage?
  let displayThreshold: Int?
  let enabled: Bool?

  enum CodingKeys: String, CodingKey {
    case billingCycleStart
    case billingCycleEnd
    case planUsage
    case spendLimitUsage
    case displayThreshold
    case enabled
  }

  init(
    billingCycleStart: Int64? = nil,
    billingCycleEnd: Int64? = nil,
    planUsage: CursorPlanUsage? = nil,
    spendLimitUsage: CursorSpendLimitUsage? = nil,
    displayThreshold: Int? = nil,
    enabled: Bool? = nil
  ) {
    self.billingCycleStart = billingCycleStart
    self.billingCycleEnd = billingCycleEnd
    self.planUsage = planUsage
    self.spendLimitUsage = spendLimitUsage
    self.displayThreshold = displayThreshold
    self.enabled = enabled
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    billingCycleStart = try Self.decodeEpochMs(container, key: .billingCycleStart)
    billingCycleEnd = try Self.decodeEpochMs(container, key: .billingCycleEnd)
    planUsage = try container.decodeIfPresent(CursorPlanUsage.self, forKey: .planUsage)
    spendLimitUsage = try container.decodeIfPresent(
      CursorSpendLimitUsage.self,
      forKey: .spendLimitUsage
    )
    displayThreshold = try container.decodeIfPresent(Int.self, forKey: .displayThreshold)
    enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
  }

  /// 接口把毫秒时间戳编码为字符串（如 "1784813765000"），偶尔也可能是数字，
  /// 两种都接受。注意不能用 decodeIfPresent 依次探测：类型不匹配会抛错。
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

  /// 计费周期起始时间（毫秒时间戳转换）。
  var billingCycleStartDate: Date? {
    guard let billingCycleStart, billingCycleStart > 0 else { return nil }
    return Date(timeIntervalSince1970: Double(billingCycleStart) / 1000)
  }

  /// 计费周期结束时间（毫秒时间戳转换）。
  var billingCycleEndDate: Date? {
    guard let billingCycleEnd, billingCycleEnd > 0 else { return nil }
    return Date(timeIntervalSince1970: Double(billingCycleEnd) / 1000)
  }

  /// 计费周期总秒数（用于理想用量线性推算）。
  var windowSeconds: Int64? {
    guard let billingCycleStart, let billingCycleEnd,
      billingCycleEnd > billingCycleStart
    else {
      return nil
    }
    return (billingCycleEnd - billingCycleStart) / 1000
  }

  /// 整体已用百分比（自动模型桶，0...100）。
  var usedPercent: Int? {
    guard let percent = planUsage?.totalPercentUsed else { return nil }
    return max(0, min(100, Int(percent.rounded())))
  }

  /// API 通道已用百分比（0...100）。
  var apiUsedPercent: Int? {
    guard let percent = planUsage?.apiPercentUsed else { return nil }
    return max(0, min(100, Int(percent.rounded())))
  }

  /// 整体剩余百分比：0...100。
  var remainingPercent: Int? {
    guard let usedPercent else { return nil }
    return max(0, min(100, 100 - usedPercent))
  }

  /// API 通道剩余百分比：0...100。
  var apiRemainingPercent: Int? {
    guard let apiUsedPercent else { return nil }
    return max(0, min(100, 100 - apiUsedPercent))
  }

  /// 是否已触及用量上限。
  var limitReached: Bool {
    usedPercent ?? 0 >= 100
  }

  /// 与理想用量（计费周期内线性消耗、重置时恰好用完）的差距：
  /// 实际已用 − 理想已用，正数表示消耗快于理想、负数表示慢于理想。
  /// 无周期信息或当前时间不在周期内时为 nil（不显示差距）。
  var usageGapPercent: Int? {
    guard let billingCycleEndDate, let billingCycleStartDate,
      let expected = CursorUsageFormatter.expectedUsedPercent(
        start: billingCycleStartDate,
        end: billingCycleEndDate
      ),
      let usedPercent
    else {
      return nil
    }
    return usedPercent - Int(expected.rounded())
  }

  /// API 通道与理想用量（同一计费周期线性推算）的差距。
  /// 无周期信息或当前时间不在周期内时为 nil（不显示差距）。
  var apiUsageGapPercent: Int? {
    guard let billingCycleEndDate, let billingCycleStartDate,
      let expected = CursorUsageFormatter.expectedUsedPercent(
        start: billingCycleStartDate,
        end: billingCycleEndDate
      ),
      let apiUsedPercent
    else {
      return nil
    }
    return apiUsedPercent - Int(expected.rounded())
  }

  /// 是否缺少订阅用量数据（免费计划或接口未返回 planUsage）。
  var hasNoPlanUsage: Bool {
    planUsage == nil
  }
}

/// 计费周期内的金额与百分比（金额单位为美分）。
struct CursorPlanUsage: Codable, Equatable, Sendable {
  let totalSpend: Double?
  let includedSpend: Double?
  let bonusSpend: Double?
  let limit: Double?
  let autoPercentUsed: Double?
  let apiPercentUsed: Double?
  let totalPercentUsed: Double?

  enum CodingKeys: String, CodingKey {
    case totalSpend
    case includedSpend
    case bonusSpend
    case limit
    case autoPercentUsed
    case apiPercentUsed
    case totalPercentUsed
  }
}

/// 费用上限类型（例如 "user"）。
struct CursorSpendLimitUsage: Codable, Equatable, Sendable {
  let limitType: String?

  enum CodingKeys: String, CodingKey {
    case limitType
  }
}

/// Cursor 用量展示格式化。
enum CursorUsageFormatter {
  /// 订阅方案的品牌名；未知值回退为原样大写。
  static func planDisplayName(_ rawTier: String?) -> String? {
    guard let rawTier, !rawTier.isEmpty else { return nil }
    switch rawTier.lowercased() {
    case "hobby":
      return "Hobby"
    case "pro":
      return "Pro"
    case "pro+":
      return "Pro+"
    case "ultra":
      return "Ultra"
    case "teams", "team":
      return "Teams"
    case "business":
      return "Business"
    case "enterprise":
      return "Enterprise"
    case "student":
      return "Student"
    default:
      return rawTier.uppercased()
    }
  }

  /// 重置时间展示；无重置时间时返回 nil。
  static func resetDate(billingCycleEnd: Date?) -> Date? {
    billingCycleEnd
  }

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

  /// 美分金额格式化为美元字符串，例如 `$643.12`；无金额时返回 nil。
  /// Cursor 费用按美元结算，固定使用 USD 符号，不受系统语言/区域影响。
  static func formatCents(_ cents: Double?, locale: Locale) -> String? {
    guard let cents else { return nil }
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.locale = Locale(identifier: "en_US")
    formatter.currencyCode = "USD"
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    return formatter.string(from: NSNumber(value: cents / 100))
  }
}
