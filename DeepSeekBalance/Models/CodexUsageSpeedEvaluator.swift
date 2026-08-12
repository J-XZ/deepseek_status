import Foundation

/// Codex 最近短周期（1 小时 / 3 小时）用量速度与理想速度对比的纯计算逻辑。
/// 只依赖 CodexUsageSample 与 CodexUsageWindow，便于单元测试。
enum CodexUsageSpeedEvaluator {
  static let weeklyLimitSeconds = 604800
  static let weeklyHours = 7.0 * 24.0
  /// 理想平均用量速度：每周额度按 7 天线性消耗。
  static let idealSpeedPPH = 100.0 / weeklyHours
  /// 实际速度与理想速度相差不超过该值时视为“与理想相当”。
  static let tolerancePPH = 0.5

  enum Comparison: Equatable, Sendable {
    case faster
    case slower
    case onPar
  }

  struct Result: Equatable, Sendable {
    let actualSpeedPPH: Double
    let idealSpeedPPH: Double
    let comparison: Comparison
    let idealLineStart: Date
    let idealLineEnd: Date
    let idealLineStartRemaining: Double
    let idealLineEndRemaining: Double
  }

  /// 最近窗口内真实样本的实际平均速度（每周额度百分比 / 小时）。
  /// 至少需要 2 个不同时间桶且时间间隔 > 0，否则返回 nil。
  static func actualSpeed(
    samples: [CodexUsageSample],
    now: Date,
    window: TimeInterval = 3 * 3600,
    firstSample: Date? = nil,
    lastSample: Date? = nil
  ) -> Double? {
    let ordered = windowSamples(samples: samples, now: now, window: window)
    let firstDate = firstSample ?? ordered.first?.bucketStart
    let lastDate = lastSample ?? ordered.last?.bucketStart
    guard let firstDate,
      let lastDate,
      firstDate != lastDate,
      let first = ordered.first(where: { $0.bucketStart == firstDate }),
      let last = ordered.last(where: { $0.bucketStart == lastDate })
    else { return nil }
    let intervalHours = lastDate.timeIntervalSince(firstDate) / 3600
    guard intervalHours > 0 else { return nil }
    let usedFirst = 100.0 - Double(first.remainingPercent)
    let usedLast = 100.0 - Double(last.remainingPercent)
    return (usedLast - usedFirst) / intervalHours
  }

  /// 过滤并去重窗口内样本，按 bucketStart 升序返回。
  static func windowSamples(
    samples: [CodexUsageSample],
    now: Date,
    window: TimeInterval = 3 * 3600
  ) -> [CodexUsageSample] {
    let lowerBound = now.addingTimeInterval(-window)
    var newestByBucket: [Int64: CodexUsageSample] = [:]
    for sample in samples where sample.bucketStart >= lowerBound && sample.bucketStart <= now {
      let key = Int64(sample.bucketStart.timeIntervalSince1970)
      if let existing = newestByBucket[key] {
        if sample.observedAt > existing.observedAt {
          newestByBucket[key] = sample
        }
      } else {
        newestByBucket[key] = sample
      }
    }
    return newestByBucket.values.sorted { $0.bucketStart < $1.bucketStart }
  }

  /// 理想速度：仅当周窗口有效且当前时间落在窗口内时可用。
  static func idealSpeed(
    window: CodexUsageWindow?,
    now: Date
  ) -> Double? {
    guard let window,
      window.limitWindowSeconds == weeklyLimitSeconds,
      let start = windowStart(window: window),
      let end = windowEnd(window: window),
      now >= start,
      now <= end
    else { return nil }
    return idealSpeedPPH
  }

  /// 对比结论：实际速度高于理想为快于理想，低于为慢于理想，差值在容差内为相当。
  static func comparison(
    actual: Double,
    ideal: Double,
    tolerance: Double = tolerancePPH
  ) -> Comparison {
    if abs(actual - ideal) <= tolerance {
      return .onPar
    }
    return actual > ideal ? .faster : .slower
  }

  /// 理想速度线：从蓝线首样本的实际剩余值出发，按理想速度推进到末样本时刻。
  /// 起点与蓝线完全重合（时间与剩余都一致），终点表示按理想速度应达到的剩余，
  /// 这样两条线的斜率差异就是实际速度与理想速度的对比。
  static func idealLine(
    window: CodexUsageWindow?,
    now: Date,
    firstSample: Date,
    lastSample: Date,
    firstSampleRemaining: Double
  ) -> (start: Date, end: Date, startRemaining: Double, endRemaining: Double)? {
    guard let window, window.limitWindowSeconds == weeklyLimitSeconds else { return nil }
    guard let weeklyStart = windowStart(window: window) else { return nil }
    guard let windowEnd = windowEnd(window: window), now >= weeklyStart, now <= windowEnd else {
      return nil
    }
    guard firstSample < lastSample else { return nil }
    let intervalHours = lastSample.timeIntervalSince(firstSample) / 3600
    let endRemaining = firstSampleRemaining - idealSpeedPPH * intervalHours
    return (
      firstSample,
      lastSample,
      firstSampleRemaining,
      endRemaining
    )
  }

  /// 组合评估：实际速度、理想速度、对比结论与理想线都可用时返回完整结果。
  static func evaluate(
    samples: [CodexUsageSample],
    window: CodexUsageWindow?,
    now: Date,
    windowSeconds: TimeInterval = 3 * 3600,
    firstSample: Date? = nil,
    lastSample: Date? = nil
  ) -> Result? {
    let windowed = windowSamples(samples: samples, now: now, window: windowSeconds)
    let firstDate = firstSample ?? windowed.first?.bucketStart
    let lastDate = lastSample ?? windowed.last?.bucketStart
    guard let firstDate,
      let lastDate,
      firstDate != lastDate,
      let firstRemaining = windowed.first(where: { $0.bucketStart == firstDate })?.remainingPercent,
      let actual = actualSpeed(
        samples: samples,
        now: now,
        window: windowSeconds,
        firstSample: firstDate,
        lastSample: lastDate
      ),
      let ideal = idealSpeed(window: window, now: now),
      let line = idealLine(
        window: window,
        now: now,
        firstSample: firstDate,
        lastSample: lastDate,
        firstSampleRemaining: Double(firstRemaining)
      )
    else { return nil }
    return Result(
      actualSpeedPPH: actual,
      idealSpeedPPH: ideal,
      comparison: comparison(actual: actual, ideal: ideal),
      idealLineStart: line.start,
      idealLineEnd: line.end,
      idealLineStartRemaining: line.startRemaining,
      idealLineEndRemaining: line.endRemaining
    )
  }

  private static func windowStart(window: CodexUsageWindow) -> Date? {
    guard window.limitWindowSeconds > 0, let resetAt = window.resetAt else { return nil }
    let end = Date(timeIntervalSince1970: TimeInterval(resetAt))
    return end.addingTimeInterval(-Double(window.limitWindowSeconds))
  }

  private static func windowEnd(window: CodexUsageWindow) -> Date? {
    guard let resetAt = window.resetAt else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(resetAt))
  }
}
