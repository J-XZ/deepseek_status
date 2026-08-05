import Foundation

/// Vultr 查询所需的最小配置。Token 只保存到 Keychain，Instance ID 保存到 UserDefaults。
struct VPSUsageConfig: Equatable, Sendable {
  let apiToken: String
  let instanceID: String

  static let empty = VPSUsageConfig(apiToken: "", instanceID: "")

  var isComplete: Bool {
    !apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !instanceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

/// 一次 Vultr 查询的归一化结果。
///
/// 带宽口径与独立的 vps_usage 项目保持一致：
/// `account/bandwidth.current_month_to_date.instance_bandwidth_credits`
/// 减去 `gb_out` 得到剩余 GB；美元余额来自 `GET /v2/account` 的 `balance`。
struct VPSUsageSnapshot: Equatable, Sendable {
  let instanceID: String
  let instanceLabel: String?
  let instanceStatus: String?
  let instanceRegion: String?
  let accountEmail: String?
  let cycleStart: Date
  let cycleEnd: Date
  let totalBandwidthGB: Double
  let usedBandwidthGB: Double
  let remainingCreditUSD: Double
  let refreshedAt: Date

  var remainingBandwidthGB: Double {
    max(totalBandwidthGB - usedBandwidthGB, 0)
  }

  /// Vultr 的 account.balance 可能以负号返回可用余额；界面统一显示其额度绝对值。
  var availableCreditUSD: Double {
    abs(remainingCreditUSD)
  }
}

/// Vultr 流量在当前计费周期结束时的续航预测。
///
/// 这里拟合的是“剩余流量”的净趋势，而不是只统计下降量：Vultr 每小时分配的带宽和
/// 当天实际消耗都会反映在剩余值中，因此一阶导数代表净日变化，二阶导数代表净变化
/// 的加速度。这样不会把每天发放的流量误判成一次性充值或重置。
///
/// 为避免把几小时内的阶梯噪声外推成抛物线，估算要求至少 24 小时数据，并且优先
/// 使用可用的最长窗口；只有窗口跨度至少 3 天时才启用二次项。
struct VPSTrafficForecast: Equatable, Sendable {
  let currentRemainingGB: Double
  let projectedRemainingAtCycleEndGB: Double?
  let dailyNetChangeGB: Double?
  let dailyAccelerationGB: Double?
  let exhaustionInterval: TimeInterval?
  /// 0 表示安全（白色），0.5 表示刚好接近周期末（黄色），1 表示明显撑不到周期末（红色）。
  let riskScore: Double?
}

/// 按最近趋势估算 Vultr 流量能否撑到当前计费周期结束。
enum VPSTrafficForecastEstimator {
  private static let day: TimeInterval = 86_400
  private static let meaningfulChangeThreshold = 0.0001
  private static let windows: [TimeInterval] = [
    24 * 3600,
    72 * 3600,
    UsageHistoryWindow.seconds,
  ]
  /// 数据跨度不足时不给出耗尽估算，避免把几小时的变化拟合成抛物线。
  private static let minimumDataSpan: TimeInterval = 24 * 3600
  /// 二次项只在至少 3 天的数据上启用；短窗口一律使用线性拟合。
  private static let quadraticMinimumSpan: TimeInterval = 3 * day

  private struct Point {
    let date: Date
    let value: Double
  }

  private struct Coefficients {
    let slope: Double
    let acceleration: Double
  }

  static func estimate(
    samples: [VPSUsageSample],
    currentRemainingGB: Double? = nil,
    cycleStart: Date? = nil,
    cycleEnd: Date,
    now: Date
  ) -> VPSTrafficForecast? {
    var points = VPSUsageTrendProcessor
      .deduplicatedSamples(samples)
      .filter { sample in
        guard sample.bucketStart <= now, sample.remainingBandwidthGB.isFinite else {
          return false
        }
        if let cycleStart {
          return sample.bucketStart >= cycleStart
        }
        return true
      }
      .map {
        Point(date: $0.bucketStart, value: max($0.remainingBandwidthGB, 0))
      }

    guard let latestValue = currentRemainingGB.map({ max($0, 0) }) ?? points.last?.value else {
      return nil
    }

    // The current API response may be newer than the most recent 10-minute history bucket.
    // Include it so the derivative is calculated at the value the user is actually seeing.
    if let last = points.last,
      abs(last.date.timeIntervalSince(now)) < 1,
      abs(last.value - latestValue) < meaningfulChangeThreshold
    {
      points[points.count - 1] = Point(date: now, value: latestValue)
    } else {
      points.append(Point(date: now, value: latestValue))
    }
    points.sort { $0.date < $1.date }

    guard points.count >= 2,
      let firstDate = points.first?.date,
      let lastDate = points.last?.date,
      lastDate.timeIntervalSince(firstDate) >= minimumDataSpan
    else {
      return nil
    }

    // 优先使用尽可能长的窗口：Vultr 带宽按小时分配，最近 24 小时内的阶梯
    // 噪声会被更长的趋势平均掉；数据越多，外推越稳定。
    let selectedPoints = windows
      .reversed()
      .map { window in
        points.filter { $0.date >= now.addingTimeInterval(-window) }
      }
      .first { windowPoints in
        windowPoints.count >= 2 && hasMeaningfulChange(windowPoints)
      }
      ?? points

    guard selectedPoints.count >= 2 else { return nil }

    guard let firstSelected = selectedPoints.first?.date,
      let lastSelected = selectedPoints.last?.date
    else { return nil }
    let selectedSpan = lastSelected.timeIntervalSince(firstSelected)
    guard
      let coefficients = fit(
        selectedPoints,
        relativeTo: now,
        allowQuadratic: selectedSpan >= quadraticMinimumSpan
      ),
      coefficients.slope.isFinite,
      coefficients.acceleration.isFinite
    else {
      return nil
    }

    let cycleSeconds = cycleEnd.timeIntervalSince(now)
    let cycleDays = max(cycleSeconds / day, 0)
    let projected = cycleDays > 0
      ? projectedRemaining(
        current: latestValue,
        slope: coefficients.slope,
        acceleration: coefficients.acceleration,
        afterDays: cycleDays
      )
      : nil
    let exhaustionInterval = exhaustionInterval(
      current: latestValue,
      slope: coefficients.slope,
      acceleration: coefficients.acceleration
    )
    let riskScore = riskScore(
      current: latestValue,
      exhaustionInterval: exhaustionInterval,
      cycleSeconds: cycleSeconds
    )

    return VPSTrafficForecast(
      currentRemainingGB: latestValue,
      projectedRemainingAtCycleEndGB: projected,
      dailyNetChangeGB: coefficients.slope,
      dailyAccelerationGB: coefficients.acceleration,
      exhaustionInterval: exhaustionInterval,
      riskScore: riskScore
    )
  }

  private static func hasMeaningfulChange(_ points: [Point]) -> Bool {
    guard let minimum = points.map(\.value).min(), let maximum = points.map(\.value).max() else {
      return false
    }
    return maximum - minimum > meaningfulChangeThreshold
  }

  /// Fit `remaining = a + b * days + c * days²` with `days = 0` at the current response.
  /// The current slope is `b`; the second derivative is `2c`.
  /// 短窗口禁用二次项：抛物线对几小时内的阶梯数据过于敏感，外推会失真。
  private static func fit(
    _ points: [Point],
    relativeTo now: Date,
    allowQuadratic: Bool
  ) -> Coefficients? {
    let values = points.map { point in
      (
        x: point.date.timeIntervalSince(now) / day,
        y: point.value
      )
    }

    guard let first = values.first, let last = values.last else { return nil }
    let elapsed = last.x - first.x
    guard elapsed > 0 else { return nil }

    guard values.count >= 3, allowQuadratic else {
      let slope = (last.y - first.y) / elapsed
      return slope.isFinite ? Coefficients(slope: slope, acceleration: 0) : nil
    }

    // Normal equations for a quadratic least-squares fit. The x range is at most 14 days,
    // so this small 3x3 solve is stable and avoids adding a numerical dependency.
    let s0 = Double(values.count)
    let s1 = values.reduce(0) { $0 + $1.x }
    let s2 = values.reduce(0) { $0 + $1.x * $1.x }
    let s3 = values.reduce(0) { $0 + $1.x * $1.x * $1.x }
    let s4 = values.reduce(0) { $0 + $1.x * $1.x * $1.x * $1.x }
    let t0 = values.reduce(0) { $0 + $1.y }
    let t1 = values.reduce(0) { $0 + $1.x * $1.y }
    let t2 = values.reduce(0) { $0 + $1.x * $1.x * $1.y }

    var matrix = [
      [s0, s1, s2, t0],
      [s1, s2, s3, t1],
      [s2, s3, s4, t2],
    ]

    for column in 0..<3 {
      guard let pivot = (column..<3).max(by: {
        abs(matrix[$0][column]) < abs(matrix[$1][column])
      }), abs(matrix[pivot][column]) > 1e-9 else {
        return linearFit(values)
      }
      if pivot != column {
        matrix.swapAt(pivot, column)
      }

      let divisor = matrix[column][column]
      for index in column..<4 {
        matrix[column][index] /= divisor
      }

      for row in 0..<3 where row != column {
        let factor = matrix[row][column]
        for index in column..<4 {
          matrix[row][index] -= factor * matrix[column][index]
        }
      }
    }

    let slope = matrix[1][3]
    let acceleration = 2 * matrix[2][3]
    guard slope.isFinite, acceleration.isFinite else { return linearFit(values) }
    return Coefficients(slope: slope, acceleration: acceleration)
  }

  private static func linearFit(
    _ values: [(x: Double, y: Double)]
  ) -> Coefficients? {
    guard let first = values.first, let last = values.last else { return nil }
    let elapsed = last.x - first.x
    guard elapsed > 0 else { return nil }
    let slope = (last.y - first.y) / elapsed
    return slope.isFinite ? Coefficients(slope: slope, acceleration: 0) : nil
  }

  private static func projectedRemaining(
    current: Double,
    slope: Double,
    acceleration: Double,
    afterDays: Double
  ) -> Double {
    current + slope * afterDays + 0.5 * acceleration * afterDays * afterDays
  }

  private static func exhaustionInterval(
    current: Double,
    slope: Double,
    acceleration: Double
  ) -> TimeInterval? {
    guard current.isFinite, slope.isFinite, acceleration.isFinite else { return nil }
    guard current > 0 else { return 0 }

    let quadratic = 0.5 * acceleration
    if abs(quadratic) < 1e-9 {
      guard slope < -1e-9 else { return nil }
      return current / -slope * day
    }

    let discriminant = slope * slope - 4 * quadratic * current
    guard discriminant >= 0 else { return nil }
    let discriminantRoot = sqrt(discriminant)
    let roots = [
      (-slope - discriminantRoot) / (2 * quadratic),
      (-slope + discriminantRoot) / (2 * quadratic),
    ]
      .filter { $0 >= 0 && $0.isFinite }
      .min()
    guard let selectedRoot = roots else { return nil }
    return selectedRoot * day
  }

  private static func riskScore(
    current: Double,
    exhaustionInterval: TimeInterval?,
    cycleSeconds: TimeInterval
  ) -> Double? {
    guard cycleSeconds > 0 else { return nil }
    guard current > 0 else { return 1 }
    guard let exhaustionInterval, exhaustionInterval.isFinite else {
      return 0
    }

    let runwayRatio = exhaustionInterval / cycleSeconds
    if runwayRatio >= 2 {
      return 0
    }
    if runwayRatio >= 1 {
      // Enough to reach the cycle end, but with less than one extra cycle of buffer:
      // continuously fade from white to yellow as the buffer disappears.
      return 0.5 * (2 - runwayRatio)
    }
    // Exhaustion before the cycle end continuously fades from yellow to red.
    return min(max(0.5 + 0.5 * (1 - runwayRatio), 0), 1)
  }
}

/// VPS 余额趋势的纯数据处理，避免 SwiftUI 视图直接处理原始历史。
enum VPSUsageTrendProcessor {

  struct ChartModel: Equatable, Sendable {
    let samples: [VPSUsageSample]
    let xDomain: ClosedRange<Date>
    let trafficDomain: ClosedRange<Double>
    let creditDomain: ClosedRange<Double>

    var canDraw: Bool {
      samples.count >= 2
    }
  }

  /// 图表模型缓存：样本集不变时切回该页面可以立即渲染，避免每次
  /// 访问都先闪一下等待文案、再等后台任务重建图表。
  /// key 覆盖样本数量、最新样本和小时级时间戳；读写都在主线程。
  nonisolated(unsafe) private static var chartModelCache: [String: ChartModel] = [:]

  static func chartModelCacheKey(
    samples: [VPSUsageSample],
    now: Date
  ) -> String {
    let latest = samples.last
    let observedAt = latest?.observedAt.timeIntervalSince1970 ?? -1
    let hour = Int(now.timeIntervalSince1970 / 3_600)
    return "\(samples.count)-\(latest?.id ?? "empty")-\(observedAt)-\(hour)"
  }

  static func cachedChartModel(for key: String) -> ChartModel? {
    chartModelCache[key]
  }

  static func storeChartModel(_ model: ChartModel, for key: String) {
    chartModelCache[key] = model
  }

  static func chartModel(
    samples: [VPSUsageSample],
    now: Date
  ) -> ChartModel {
    let deduplicated = deduplicatedSamples(samples)
    return ChartModel(
      samples: deduplicated,
      xDomain: UsageHistoryWindow.chartDomain(now: now),
      trafficDomain: axisDomain(deduplicated.map(\.remainingBandwidthGB)),
      creditDomain: axisDomain(deduplicated.map(\.availableCreditUSD))
    )
  }

  static func deduplicatedSamples(_ samples: [VPSUsageSample]) -> [VPSUsageSample] {
    var newestByBucket: [Int64: VPSUsageSample] = [:]
    for sample in samples {
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

  static func nearestSample(
    to date: Date,
    samples: [VPSUsageSample]
  ) -> VPSUsageSample? {
    deduplicatedSamples(samples).min {
      abs($0.bucketStart.timeIntervalSince(date))
        < abs($1.bucketStart.timeIntervalSince(date))
    }
  }

  static func normalized(_ value: Double, in domain: ClosedRange<Double>) -> Double {
    let span = domain.upperBound - domain.lowerBound
    guard span > 0 else { return 0.5 }
    return min(max((value - domain.lowerBound) / span, 0), 1)
  }

  static func signedGB(_ value: Double) -> String {
    let sign = value >= 0 ? "+" : "-"
    return "\(sign)\(String(format: "%.0f", abs(value))) GB"
  }

  static func signedUSD(_ value: Double) -> String {
    let sign = value >= 0 ? "+" : "-"
    return "\(sign)$\(String(format: "%.2f", abs(value)))"
  }

  static func summary(samples: [VPSUsageSample]) -> (traffic: Double, credit: Double)? {
    let ordered = deduplicatedSamples(samples)
    guard let first = ordered.first, let last = ordered.last, first.id != last.id else {
      return nil
    }
    return (
      last.remainingBandwidthGB - first.remainingBandwidthGB,
      last.availableCreditUSD - first.availableCreditUSD
    )
  }

  private static func axisDomain(_ values: [Double]) -> ClosedRange<Double> {
    // Y 轴从 0 开始画；上限在最大值之上留 8% 余量。
    let finite = values.filter { $0.isFinite }
    guard let maximum = finite.max() else {
      return 0...1
    }
    let padding = max(abs(maximum) * 0.08, 0.01)
    return 0...(maximum + padding)
  }
}
