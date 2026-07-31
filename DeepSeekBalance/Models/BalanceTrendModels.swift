import Foundation

/// 图表坐标点。仅在此处允许把 `Decimal` 转换为 `Double`。
struct TrendPoint: Identifiable, Equatable, Sendable {
  enum Metric: String, CaseIterable, Sendable {
    case total
    case toppedUp
    case granted

    var label: String {
      switch self {
      case .total: return "总余额"
      case .toppedUp: return "充值余额"
      case .granted: return "赠送余额"
      }
    }
  }

  let id: String
  let date: Date
  let metric: Metric
  let value: Double
}

/// 最近 72 小时趋势摘要。
struct TrendSummary: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case insufficientSamples
    case available(delta: Decimal, percent: Decimal?)
  }

  let kind: Kind
  let currency: String

  var displayText: String {
    switch kind {
    case .insufficientSamples:
      return "72 小时变化：样本不足"
    case .available(let delta, let percent):
      let base = "72 小时变化：" + BalanceTrendProcessor.deltaText(delta: delta, currency: currency)
      if let percent {
        return base + "（" + Self.percentText(percent) + "）"
      }
      return base
    }
  }

  static func percentText(_ percent: Decimal) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.locale = .current
    formatter.minimumFractionDigits = 1
    formatter.maximumFractionDigits = 1
    let absolute = percent < 0 ? -percent : percent
    let text = formatter.string(from: NSDecimalNumber(decimal: absolute)) ?? "\(absolute)"
    return (percent < 0 ? "-" : "+") + text + "%"
  }
}

/// 图表数据转换与趋势计算（纯函数，便于测试）。
enum BalanceTrendProcessor {
  /// 相邻样本间隔超过 20 分钟视为数据缺口。
  static let gapThreshold: TimeInterval = 20 * 60

  static func decimal(from string: String) -> Decimal? {
    Decimal(string: string, locale: Locale(identifier: "en_US_POSIX"))
  }

  static func double(from decimal: Decimal) -> Double {
    NSDecimalNumber(decimal: decimal).doubleValue
  }

  /// 将指定币种的历史样本转为图表点：
  /// 按桶去重（同一桶保留最新 observedAt）、跳过非法金额、按时间升序。
  static func points(for samples: [BalanceSample], currency: String) -> [TrendPoint] {
    var newestByBucket: [Int64: BalanceSample] = [:]
    for sample in samples where sample.currency == currency {
      guard
        decimal(from: sample.totalBalance) != nil,
        decimal(from: sample.grantedBalance) != nil,
        decimal(from: sample.toppedUpBalance) != nil
      else { continue }
      let key = Int64(sample.bucketStart.timeIntervalSince1970)
      if let existing = newestByBucket[key] {
        if sample.observedAt > existing.observedAt {
          newestByBucket[key] = sample
        }
      } else {
        newestByBucket[key] = sample
      }
    }
    return newestByBucket.values
      .sorted { $0.bucketStart < $1.bucketStart }
      .flatMap { sample in
        let bucket = sample.bucketStart
        return [
          TrendPoint(
            id: sample.id + "-total",
            date: bucket,
            metric: .total,
            value: double(from: decimal(from: sample.totalBalance)!)
          ),
          TrendPoint(
            id: sample.id + "-toppedUp",
            date: bucket,
            metric: .toppedUp,
            value: double(from: decimal(from: sample.toppedUpBalance)!)
          ),
          TrendPoint(
            id: sample.id + "-granted",
            date: bucket,
            metric: .granted,
            value: double(from: decimal(from: sample.grantedBalance)!)
          ),
        ]
      }
  }

  /// 把图表点按数据缺口拆分为多个连续分段。
  static func segments(from points: [TrendPoint]) -> [[TrendPoint]] {
    guard let first = points.first else { return [] }
    var result: [[TrendPoint]] = []
    var current = [first]
    for point in points.dropFirst() {
      let gap = point.date.timeIntervalSince(current.last!.date)
      if gap > gapThreshold {
        result.append(current)
        current = [point]
      } else {
        current.append(point)
      }
    }
    result.append(current)
    return result
  }

  /// 取范围内第一条与最后一条有效总余额样本计算变化。
  static func summary(samples: [BalanceSample], currency: String) -> TrendSummary {
    let filtered =
      samples
      .filter { $0.currency == currency }
      .sorted { $0.bucketStart < $1.bucketStart }
    guard
      let first = filtered.first,
      let last = filtered.last,
      first.id != last.id,
      let firstValue = decimal(from: first.totalBalance),
      let lastValue = decimal(from: last.totalBalance)
    else {
      return TrendSummary(kind: .insufficientSamples, currency: currency)
    }
    let delta = lastValue - firstValue
    let percent: Decimal? = firstValue == 0 ? nil : (delta / firstValue) * 100
    return TrendSummary(kind: .available(delta: delta, percent: percent), currency: currency)
  }

  /// 带符号的金额变化文本，例如 `+¥12.35` / `-¥3.20` / `¥0.00`。
  static func deltaText(delta: Decimal, currency: String, locale: Locale = .current) -> String {
    if delta < 0 {
      return "-" + formattedAmount(-delta, currency: currency, locale: locale)
    }
    if delta > 0 {
      return "+" + formattedAmount(delta, currency: currency, locale: locale)
    }
    return formattedAmount(0, currency: currency, locale: locale)
  }

  static func formattedAmount(
    _ amount: Decimal,
    currency: String,
    locale: Locale = .current
  ) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.locale = locale
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    let absolute = amount < 0 ? -amount : amount
    let text = formatter.string(from: NSDecimalNumber(decimal: absolute)) ?? "\(absolute)"
    if let symbol = BalanceFormatter.currencySymbol(for: currency) {
      return symbol + text
    }
    return currency + " " + text
  }
}
