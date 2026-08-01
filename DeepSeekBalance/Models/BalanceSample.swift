import Foundation

/// 一次成功余额响应在单个 10 分钟时间桶内的历史样本。
/// 金额字段始终保存接口返回的十进制字符串，业务计算使用 `Decimal`。
struct BalanceSample: Codable, Equatable, Identifiable, Sendable {
  let credentialID: String
  let bucketStart: Date
  let observedAt: Date
  let currency: String
  let totalBalance: String
  let grantedBalance: String
  let toppedUpBalance: String
  let isAvailable: Bool

  var id: String {
    "\(credentialID)/\(currency)/\(Int64(bucketStart.timeIntervalSince1970))"
  }
}

/// 10 分钟 UTC 时间桶。
enum TimeBucket {
  static let bucketSeconds: Int64 = 600

  /// 返回给定时刻所在时间桶的开始时间。
  /// 对负 Unix 时间使用严格 floor：`floor(seconds / 600) * 600`。
  static func bucketStart(for date: Date) -> Date {
    let seconds = Int64(date.timeIntervalSince1970.rounded(.down))
    let quotient = seconds / bucketSeconds
    let remainder = seconds % bucketSeconds
    let flooredQuotient = remainder < 0 ? quotient - 1 : quotient
    return Date(timeIntervalSince1970: TimeInterval(flooredQuotient * bucketSeconds))
  }
}

/// 可注入的时间来源，便于测试。
protocol DateProviding: Sendable {
  func now() -> Date
}

struct SystemClock: DateProviding {
  func now() -> Date { Date() }
}
