import CoreGraphics
import Foundation

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

/// 最近 72 小时趋势摘要。
struct TrendSummary: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case insufficientSamples
    case available(delta: Decimal, percent: Decimal?)
  }

  let kind: Kind
  let currency: String

  func text(language: AppLanguage) -> String {
    switch kind {
    case .insufficientSamples:
      return L10n.string(.trendSummaryInsufficient, language: language)
    case .available(let delta, let percent):
      let base = L10n.string(
        .trendSummaryChange,
        language: language,
        BalanceTrendProcessor.deltaText(delta: delta, currency: currency, locale: language.locale)
      )
      if let percent {
        let percentText = Self.percentText(percent, language: language)
        if language == .simplifiedChinese {
          return base + "（" + percentText + "）"
        }
        return base + " (" + percentText + ")"
      }
      return base
    }
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
  /// 图表数据模型：连续多样本使用折线，孤立单样本使用点。
  struct ChartModel: Equatable, Sendable {
    struct Segment: Identifiable, Equatable, Sendable {
      let id: String
      let metric: TrendPoint.Metric
      let points: [TrendPoint]
    }

    struct IsolatedPoint: Identifiable, Equatable, Sendable {
      let id: String
      let point: TrendPoint
    }

    let segments: [Segment]
    let isolatedPoints: [IsolatedPoint]
    let xDomain: ClosedRange<Date>
  }

  /// 相邻样本间隔超过 20 分钟视为数据缺口。
  static let gapThreshold: TimeInterval = 20 * 60
  static let chartWindowHours: TimeInterval = 72

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

  /// 明确 X 轴 domain：`now - 72 小时 ... now`。
  static func chartDomain(now: Date) -> ClosedRange<Date> {
    now.addingTimeInterval(-chartWindowHours * 3600)...now
  }

  /// 按 metric 独立分段；连续段（>=2 点）进入折线，孤立单点进入点标记。
  static func chartModel(
    samples: [BalanceSample],
    currency: String,
    now: Date
  ) -> ChartModel {
    let points = points(for: samples, currency: currency)
    var lineSegments: [ChartModel.Segment] = []
    var isolated: [ChartModel.IsolatedPoint] = []

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
        } else if let only = segment.first {
          isolated.append(ChartModel.IsolatedPoint(id: only.id, point: only))
        }
      }
    }

    return ChartModel(
      segments: lineSegments,
      isolatedPoints: isolated,
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
