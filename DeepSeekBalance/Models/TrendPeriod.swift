import Foundation

/// 悬浮窗悬停折线图可切换的时间周期。
/// 运行时状态，不写入 UserDefaults；App 重启后恢复 `.fourteenDays`。
enum TrendPeriod: String, CaseIterable, Sendable {
  /// 图表聚合策略。当前所有历史都按 10 分钟桶采样，
  /// 短周期（1 小时 / 3 小时）必须保留原始 10 分钟点，禁止按天聚合。
  enum Aggregation: String, Sendable {
    case rawTenMinutePoints
  }

  case fourteenDays
  case sevenDays
  case oneDay
  case threeHours
  case oneHour

  /// 单击循环顺序：14 天 → 7 天 → 1 天 → 3 小时 → 1 小时 → 14 天。
  static let cycle: [TrendPeriod] = [
    .fourteenDays,
    .sevenDays,
    .oneDay,
    .threeHours,
    .oneHour,
  ]

  var duration: TimeInterval {
    switch self {
    case .fourteenDays:
      return 14 * 24 * 3600
    case .sevenDays:
      return 7 * 24 * 3600
    case .oneDay:
      return 24 * 3600
    case .threeHours:
      return 3 * 3600
    case .oneHour:
      return 3600
    }
  }

  var displayKey: L10nKey {
    switch self {
    case .fourteenDays:
      return .trendPeriod14Days
    case .sevenDays:
      return .trendPeriod7Days
    case .oneDay:
      return .trendPeriod1Day
    case .threeHours:
      return .trendPeriod3Hours
    case .oneHour:
      return .trendPeriod1Hour
    }
  }

  func displayName(language: AppLanguage) -> String {
    L10n.string(displayKey, language: language)
  }

  func next() -> TrendPeriod {
    guard let index = Self.cycle.firstIndex(of: self),
      Self.cycle.indices.contains(index + 1)
    else {
      return .fourteenDays
    }
    return Self.cycle[index + 1]
  }

  func chartDomain(now: Date) -> ClosedRange<Date> {
    now.addingTimeInterval(-duration)...now
  }

  /// 1 小时 / 3 小时等亚日窗口。历史数据按 10 分钟桶采样，
  /// 短窗口直接用原始 10 分钟点展示，不做按天聚合，也不伪造缺失数据。
  var isSubDaily: Bool {
    duration <= 24 * 3600
  }

  var aggregation: Aggregation {
    .rawTenMinutePoints
  }

  /// 只保留当前周期内的样本。短周期最多显示 6（1 小时）或 18（3 小时）个
  /// 真实 10 分钟采样点；样本不足时图表沿用现有等待/空状态。
  static func filtered<S>(
    _ samples: [S],
    period: TrendPeriod,
    now: Date,
    date: (S) -> Date
  ) -> [S] {
    let lowerBound = now.addingTimeInterval(-period.duration)
    return samples.filter {
      let sampleDate = date($0)
      return sampleDate >= lowerBound && sampleDate <= now
    }
  }
}
