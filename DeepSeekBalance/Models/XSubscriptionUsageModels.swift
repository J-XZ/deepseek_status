import Foundation

struct XSubscriptionUsageSnapshot: Equatable, Sendable {
  let weekly: XSubscriptionWeeklyStatus
  let planDisplayName: String?
  let isMerged: Bool
  let grokPlanLabel: String?
  let unifiedBillingUrl: URL?
  let onDemand: XSubscriptionOnDemandSettings?
  let productBreakdown: XSubscriptionProductBreakdown?
  let prepaid: XSubscriptionPrepaidBilling?
  let hardLimit: XSubscriptionHardLimit?

  var meteredQuota: XSubscriptionWeeklyQuota? {
    if case .metered(let quota) = weekly { return quota }
    return nil
  }

  var billingURL: URL? {
    unifiedBillingUrl ?? onDemand?.dashboardUrl
  }
}

enum XSubscriptionWeeklyStatus: Equatable, Sendable {
  case metered(XSubscriptionWeeklyQuota)
  case enterprisePooled
  case noIncludedLimit
  case trial(XSubscriptionTrial)
}

struct XSubscriptionTrial: Equatable, Sendable {
  let expiresAt: Date
  let isCancelable: Bool
}

struct XSubscriptionWeeklyQuota: Equatable, Sendable {
  let usedPercent: Int
  let resetsAt: Date?
  let windowStart: Date?

  var remainingPercent: Int {
    max(0, min(100, 100 - usedPercent))
  }

  static let weekSeconds: TimeInterval = 604_800

  func usageGapPercent(now: Date) -> Int? {
    guard let resetsAt, let start = resolvedWindowStart,
      let expected = XSubscriptionUsageFormatter.expectedUsedPercent(
        start: start,
        end: resetsAt,
        now: now
      )
    else {
      return nil
    }
    return usedPercent - Int(expected.rounded())
  }

  var resolvedWindowStart: Date? {
    if let windowStart { return windowStart }
    return resetsAt?.addingTimeInterval(-Self.weekSeconds)
  }
}

struct XSubscriptionProductSpend: Equatable, Sendable {
  let tokens: Int64
  let spendCents: Int64?
  let sharePercent: Int?

  var hasData: Bool { tokens > 0 || spendCents != nil }

  static let zero = XSubscriptionProductSpend(tokens: 0, spendCents: nil, sharePercent: nil)
}

struct XSubscriptionProductBreakdown: Equatable, Sendable {
  let cursor: XSubscriptionProductSpend
  let grokBot: XSubscriptionProductSpend

  var isEmpty: Bool { !cursor.hasData && !grokBot.hasData }

  /// 饼图扇区：两个产品都有金额时按金额，否则按 token；值为 0 的产品不出扇区。
  var pieSlices: [XSubscriptionProductSlice] {
    let useCents = cursor.spendCents != nil && grokBot.spendCents != nil
    func value(_ spend: XSubscriptionProductSpend) -> Double {
      useCents ? Double(spend.spendCents ?? 0) : Double(spend.tokens)
    }
    return [
      XSubscriptionProductSlice(product: .cursor, value: value(cursor)),
      XSubscriptionProductSlice(product: .grokBot, value: value(grokBot)),
    ].filter { $0.value > 0 }
  }
}

enum XSubscriptionProduct: String, Equatable, Sendable {
  case cursor
  case grokBot
  case grokChat
}

struct XSubscriptionProductSlice: Equatable, Sendable, Identifiable {
  let product: XSubscriptionProduct
  let value: Double
  var id: String { product.rawValue }
}

struct XSubscriptionPrepaidBilling: Equatable, Sendable {
  let availableCents: Int64
  let spentThisMonthCents: Int64?
  let spentCents: Int64?
  let fundedCents: Int64?
  let eligible: Bool?
  let hasPaymentMethod: Bool?
  let billingMode: String?
}

struct XSubscriptionHardLimit: Equatable, Sendable {
  static let unlimitedSentinel: Int64 = 2_147_483_647

  let dollars: Int64

  var isUnlimited: Bool { dollars == Self.unlimitedSentinel }
}

struct XSubscriptionOnDemandSettings: Equatable, Sendable {
  let visible: Bool
  let eligible: Bool
  let dashboardUrl: URL?
}

enum XSubscriptionExhaustionForecast: Equatable, Sendable {
  case alreadyExhausted
  case depletesBeforeReset(TimeInterval)
  case survivesUntilReset(TimeInterval)
}

enum XSubscriptionExhaustion {
  static func forecast(
    samples: [XSubscriptionUsageSample],
    now: Date,
    resetsAt: Date?
  ) -> XSubscriptionExhaustionForecast? {
    let points = samples.map {
      UsageExhaustionPoint(date: $0.bucketStart, remaining: Double($0.remainingPercent))
    }
    guard let seconds = UsageExhaustionEstimator.estimate(points: points, now: now) else {
      return nil
    }
    if UsageExhaustionEstimator.isExhausted(seconds) {
      return .alreadyExhausted
    }
    return clampToReset(seconds: seconds, now: now, resetsAt: resetsAt)
  }

  static func clampToReset(
    seconds: TimeInterval,
    now: Date,
    resetsAt: Date?
  ) -> XSubscriptionExhaustionForecast {
    let timeUntilReset = resetsAt.map { $0.timeIntervalSince(now) }
    guard let timeUntilReset, timeUntilReset > 0, seconds > timeUntilReset else {
      return .depletesBeforeReset(seconds)
    }
    return .survivesUntilReset(timeUntilReset)
  }
}

enum XSubscriptionUsageFormatter {
  /// grok.com 官方用量页（Grok Chat 用量无法通过本登录读取，只能跳转查看）。
  static let grokUsageDashboardURL = URL(string: "https://grok.com/dashboard/usage")!

  static func expectedUsedPercent(start: Date, end: Date, now: Date) -> Double? {
    let startT = start.timeIntervalSince1970
    let endT = end.timeIntervalSince1970
    let nowT = now.timeIntervalSince1970
    guard startT < endT, nowT >= startT, nowT <= endT else { return nil }
    return min(100, max(0, (nowT - startT) / (endT - startT) * 100))
  }

  static func planDisplayName(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    switch raw.lowercased() {
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
      return raw
    }
  }

  static func formatCents(_ cents: Int64?, locale: Locale) -> String? {
    guard let cents else { return nil }
    return usdCurrencyString(cents: cents, locale: locale)
  }

  static func formatCents(_ cents: Int64, locale: Locale) -> String {
    usdCurrencyString(cents: cents, locale: locale)
  }

  static func formatDollars(_ dollars: Int64, locale: Locale) -> String {
    usdCurrencyString(cents: dollars * 100, locale: locale)
  }

  private static func usdCurrencyString(cents: Int64, locale: Locale) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.locale = locale
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    return formatter.string(from: NSNumber(value: Double(cents) / 100))
      ?? String(format: "$%.2f", Double(cents) / 100)
  }

  static func formatTokens(_ tokens: Int64, locale: Locale) -> String {
    let absTokens = abs(tokens)
    let (scaled, suffix): (Double, String?)
    if absTokens >= 1_000_000_000 {
      scaled = Double(tokens) / 1_000_000_000
      suffix = "B"
    } else if absTokens >= 1_000_000 {
      scaled = Double(tokens) / 1_000_000
      suffix = "M"
    } else if absTokens >= 1_000 {
      scaled = Double(tokens) / 1_000
      suffix = "K"
    } else {
      scaled = Double(tokens)
      suffix = nil
    }
    let formatter = NumberFormatter()
    formatter.locale = locale
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = suffix == nil ? 0 : 1
    let number = formatter.string(from: NSNumber(value: scaled)) ?? "\(scaled)"
    if let suffix {
      return number + suffix
    }
    return number
  }
}
