import Foundation

/// DeepSeek `/user/balance` 响应模型。
struct BalanceResponse: Codable, Equatable, Sendable {
  let isAvailable: Bool
  let balanceInfos: [BalanceInfo]

  enum CodingKeys: String, CodingKey {
    case isAvailable = "is_available"
    case balanceInfos = "balance_infos"
  }
}

/// 单种货币的余额明细。金额字段在 JSON 中是字符串。
struct BalanceInfo: Codable, Equatable, Identifiable, Sendable {
  let currency: String
  let totalBalance: String
  let grantedBalance: String
  let toppedUpBalance: String

  var id: String { currency }

  enum CodingKeys: String, CodingKey {
    case currency
    case totalBalance = "total_balance"
    case grantedBalance = "granted_balance"
    case toppedUpBalance = "topped_up_balance"
  }
}

/// 金额格式化：优先使用 `Decimal`，避免浮点精度问题。
enum BalanceFormatter {
  /// 菜单栏紧凑格式，例如 `¥110.00` 或 `¥110.00 · $2.50`。
  static func summary(for infos: [BalanceInfo], locale: Locale = .current) -> String? {
    let parts = infos.map {
      format(total: $0.totalBalance, currency: $0.currency, locale: locale)
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  /// 单个金额：CNY 显示 `¥110.00`，USD 显示 `$10.25`，未知货币显示 `EUR 10.00`。
  static func format(total: String, currency: String, locale: Locale = .current) -> String {
    if let symbol = currencySymbol(for: currency) {
      return withSymbol(symbol, amount: total, locale: locale)
    }
    return "\(currency) \(numberString(from: total, locale: locale))"
  }

  static func currencySymbol(for currency: String) -> String? {
    switch currency.uppercased() {
    case "CNY":
      return "¥"
    case "USD":
      return "$"
    default:
      return nil
    }
  }

  /// 默认两位小数，按用户 Locale 分组；无法解析时保留原始字符串。
  static func numberString(from raw: String, locale: Locale = .current) -> String {
    guard let decimal = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) else {
      return raw
    }
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.locale = locale
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    formatter.usesGroupingSeparator = true
    return formatter.string(from: NSDecimalNumber(decimal: decimal)) ?? raw
  }

  private static func withSymbol(_ symbol: String, amount: String, locale: Locale) -> String {
    let formatted = numberString(from: amount, locale: locale)
    if formatted.hasPrefix("-") {
      return "-" + symbol + formatted.dropFirst()
    }
    return symbol + formatted
  }
}
