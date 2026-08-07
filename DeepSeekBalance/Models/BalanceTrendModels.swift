import CoreGraphics
import Foundation
import SwiftUI

/// Shared cadence for background provider and service-status requests.
enum DataRefreshPolicy {
  static let autoRefreshInterval: TimeInterval = 30
}

/// All provider histories and trend charts share the same local retention window.
enum UsageHistoryWindow {
  static let days = 14
  static let hours = days * 24
  static let seconds = TimeInterval(hours * 3600)

  static func chartDomain(now: Date) -> ClosedRange<Date> {
    now.addingTimeInterval(-seconds)...now
  }

  /// 过去 24 小时内数值变化量。正值=上涨，负值=下跌；数据不足时 nil。
  static func change24h<Sample>(
    samples: [Sample],
    value: (Sample) -> Double?,
    date: (Sample) -> Date
  ) -> Double? {
    let sorted = samples
      .compactMap { s -> (Date, Double)? in
        guard let v = value(s) else { return nil }
        return (date(s), v)
      }
      .sorted { $0.0 < $1.0 }
    guard let current = sorted.last else { return nil }
    let threshold = Date().addingTimeInterval(-86400)
    guard let earliest = sorted.first else { return nil }
    let previous = sorted.last(where: { $0.0 <= threshold }) ?? earliest
    return current.1 - previous.1
  }

  /// 根据 24 小时余额下跌量返回渐变颜色（连续插值，白 → 黄 → 红）：
  /// $0（无下跌）→ nil（默认色），$2 → 完全黄色，$5 → 完全红色。
  static func dropColor(changeUSD: Double?) -> Color? {
    guard let changeUSD, changeUSD < -0.5 else { return nil }
    let t = max(0, min(1, (-changeUSD - 0.5) / 4.5))
    return .orange.opacity(t * 0.85)
  }

}

/// 用于估算额度耗尽时间的剩余量样本。
/// `remaining` 可以是金额，也可以是剩余百分比；估算器只依赖它的下降速度。
struct UsageExhaustionPoint: Equatable, Sendable {
  let date: Date
  let remaining: Double
}

/// 根据历史消耗速度估算剩余额度耗尽时间。
/// 优先使用最近 1 小时，若该窗口没有实际消耗，则依次扩大到 24 小时、72 小时和全部历史。
enum UsageExhaustionEstimator {
  static let recentWindows: [TimeInterval] = [
    60 * 60,
    24 * 60 * 60,
    72 * 60 * 60,
  ]

  static func estimate(
    points: [UsageExhaustionPoint],
    now: Date
  ) -> TimeInterval? {
    let validPoints = points
      .filter { $0.date <= now && $0.remaining.isFinite && $0.remaining >= 0 }
      .sorted { $0.date < $1.date }
    guard let current = validPoints.last else { return nil }
    // 余额已经耗尽（≤ 0）：返回 0 表示「已耗尽」，而不是无法估算。
    guard current.remaining > 0 else { return 0 }

    for window in recentWindows {
      let lowerBound = now.addingTimeInterval(-window)
      let windowPoints = validPoints.filter { $0.date >= lowerBound }
      if let rate = consumptionRate(points: windowPoints) {
        return current.remaining / rate
      }
    }

    guard let rate = consumptionRate(points: validPoints) else { return nil }
    return current.remaining / rate
  }

  /// 判断估算结果是否表示「额度已耗尽」。
  static func isExhausted(_ seconds: TimeInterval?) -> Bool {
    seconds == 0
  }

  /// 用正向下降量之和计算平均消耗速度，避免充值或窗口重置被误认为用量。
  private static func consumptionRate(points: [UsageExhaustionPoint]) -> Double? {
    guard points.count >= 2, let first = points.first, let last = points.last else {
      return nil
    }
    let elapsed = last.date.timeIntervalSince(first.date)
    guard elapsed > 0 else { return nil }

    let consumed = zip(points, points.dropFirst()).reduce(0.0) { total, pair in
      total + max(0, pair.0.remaining - pair.1.remaining)
    }
    guard consumed > 0 else { return nil }
    return consumed / elapsed
  }

  /// 将秒数格式化为简洁的本地化天、小时或分钟文本。
  static func formattedDuration(_ seconds: TimeInterval, language: AppLanguage) -> String {
    let minutes = max(1, Int(ceil(seconds / 60)))
    if minutes >= 24 * 60 {
      let days = minutes / (24 * 60)
      return language == .simplifiedChinese ? "\(days)天" : "\(days) days"
    }
    if minutes >= 60 {
      let hours = minutes / 60
      return language == .simplifiedChinese ? "\(hours)小时" : "\(hours) hours"
    }
    return language == .simplifiedChinese ? "\(minutes)分钟" : "\(minutes) minutes"
  }
}

/// 图表坐标点。仅在此处允许把 `Decimal` 转换为 `Double`。
struct TrendPoint: Identifiable, Equatable, Sendable {
  enum Metric: String, CaseIterable, Sendable {
    case total
    case toppedUp
    case granted

    func label(language: AppLanguage) -> String {
      switch self {
      case .total: return L10n.string(.legendTotal, language: language)
      case .toppedUp: return L10n.string(.legendToppedUp, language: language)
      case .granted: return L10n.string(.legendGranted, language: language)
      }
    }
  }

  let id: String
  let date: Date
  let metric: Metric
  let value: Double
}

/// 最近 14 天趋势摘要。
struct TrendSummary: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case insufficientSamples
    case available(delta: Decimal, percent: Decimal?)
  }

  let kind: Kind
  let currency: String

  /// 只返回摘要中的变化值，统一的“近 14 天用量变化”前缀由趋势卡片渲染。
  func usageChangeValue(language: AppLanguage) -> String? {
    switch kind {
    case .insufficientSamples:
      return nil
    case .available(let delta, let percent):
      var value = BalanceTrendProcessor.deltaText(
        delta: delta,
        currency: currency,
        locale: language.locale
      )
      if let percent {
        let percentText = Self.percentText(percent, language: language)
        value += language == .simplifiedChinese ? "（" + percentText + "）" : " (" + percentText + ")"
      }
      return value
    }
  }

  func text(language: AppLanguage) -> String {
    guard let value = usageChangeValue(language: language) else {
      return L10n.string(.trendSummaryInsufficient, language: language)
    }
    return L10n.string(.trendSummaryChange, language: language, value)
  }

  static func percentText(_ percent: Decimal, language: AppLanguage) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.locale = language.locale
    formatter.minimumFractionDigits = 1
    formatter.maximumFractionDigits = 1
    let absolute = percent < 0 ? -percent : percent
    let text = formatter.string(from: NSDecimalNumber(decimal: absolute)) ?? "\(absolute)"
    return (percent < 0 ? "-" : "+") + text + "%"
  }
}

/// 图表数据转换与趋势计算（纯函数，便于测试）。
enum BalanceTrendProcessor {
  /// 图表数据模型：只保留至少包含两个样本的连续折线段。
  struct ChartModel: Equatable, Sendable {
    struct Segment: Identifiable, Equatable, Sendable {
      let id: String
      let metric: TrendPoint.Metric
      let points: [TrendPoint]
    }

    let segments: [Segment]
    let xDomain: ClosedRange<Date>
  }

  /// 相邻样本间隔超过 20 分钟视为数据缺口。
  static let gapThreshold: TimeInterval = 20 * 60
  static let chartWindowHours: TimeInterval = TimeInterval(UsageHistoryWindow.hours)

  /// 图表模型缓存：样本集不变时切回该页面可以立即渲染，避免每次
  /// 访问都先闪一下加载占位、再等后台任务重建图表。
  /// key 覆盖样本数量、币种、最新样本和小时级时间戳；读写都在主线程。
  nonisolated(unsafe) private static var chartModelCache: [String: ChartModel] = [:]

  static func chartModelCacheKey(
    samples: [BalanceSample],
    currency: String,
    now: Date
  ) -> String {
    let latest = samples.last
    let observedAt = latest?.observedAt.timeIntervalSince1970 ?? -1
    let hour = Int(now.timeIntervalSince1970 / 3_600)
    return "\(samples.count)-\(currency)-\(latest?.id ?? "empty")-\(observedAt)-\(hour)"
  }

  static func cachedChartModel(for key: String) -> ChartModel? {
    chartModelCache[key]
  }

  static func storeChartModel(_ model: ChartModel, for key: String) {
    chartModelCache[key] = model
  }

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
      .flatMap { sample -> [TrendPoint] in
        guard
          let total = decimal(from: sample.totalBalance),
          let toppedUp = decimal(from: sample.toppedUpBalance),
          let granted = decimal(from: sample.grantedBalance)
        else { return [] }
        let bucket = sample.bucketStart
        return [
          TrendPoint(
            id: sample.id + "-total",
            date: bucket,
            metric: .total,
            value: double(from: total)
          ),
          TrendPoint(
            id: sample.id + "-toppedUp",
            date: bucket,
            metric: .toppedUp,
            value: double(from: toppedUp)
          ),
          TrendPoint(
            id: sample.id + "-granted",
            date: bucket,
            metric: .granted,
            value: double(from: granted)
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
      guard let lastDate = current.last?.date else { return [] }
      let gap = point.date.timeIntervalSince(lastDate)
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

  /// 明确 X 轴 domain：`now - 14 天 ... now`。
  static func chartDomain(now: Date) -> ClosedRange<Date> {
    now.addingTimeInterval(-chartWindowHours * 3600)...now
  }

  /// 0 起点 Y 轴上限：把数据最大值向上取整到 1/2/5×10ⁿ 的“漂亮”刻度，
  /// 金额折线图从 0 开始画，避免仅显示数据区间的放大错觉。
  static func yCeiling(for maxValue: Double) -> Double {
    guard maxValue.isFinite, maxValue > 0 else { return 1 }
    let exponent = floor(log10(maxValue))
    let base = pow(10, exponent)
    let mantissa = maxValue / base
    let nice: Double
    switch mantissa {
    case ...2:
      nice = 2
    case ...5:
      nice = 5
    default:
      nice = 10
    }
    return nice * base
  }

  /// 按 metric 独立分段；只有连续段（>=2 点）进入折线。
  static func chartModel(
    samples: [BalanceSample],
    currency: String,
    now: Date
  ) -> ChartModel {
    let points = points(for: samples, currency: currency)
    var lineSegments: [ChartModel.Segment] = []

    for metric in TrendPoint.Metric.allCases {
      let metricPoints = points.filter { $0.metric == metric }
      let metricSegments = segments(from: metricPoints)
      for (index, segment) in metricSegments.enumerated() {
        if segment.count >= 2 {
          lineSegments.append(
            ChartModel.Segment(
              id: "\(metric.rawValue)-\(index)",
              metric: metric,
              points: segment
            )
          )
        }
      }
    }

    return ChartModel(
      segments: lineSegments,
      xDomain: chartDomain(now: now)
    )
  }

  /// 选择距离给定时间最近的同币种样本（纯函数，供图表选择与测试使用）。
  static func nearestSample(
    to date: Date,
    samples: [BalanceSample],
    currency: String
  ) -> BalanceSample? {
    let candidates = samples.filter { $0.currency == currency }
    return candidates.min {
      abs($0.bucketStart.timeIntervalSince(date)) < abs($1.bucketStart.timeIntervalSince(date))
    }
  }

  /// plot area 坐标边界检查：位置必须落在图表绘制区域内。
  static func containsPlotCoordinate(_ location: CGPoint, in frame: CGRect) -> Bool {
    location.x >= frame.minX
      && location.x <= frame.maxX
      && location.y >= frame.minY
      && location.y <= frame.maxY
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
