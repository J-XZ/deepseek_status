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

/// VPS 余额趋势的纯数据处理，避免 SwiftUI 视图直接处理原始历史。
enum VPSUsageTrendProcessor {
  enum Metric: String, CaseIterable, Sendable {
    case traffic
    case credit
  }

  struct ChartModel: Equatable, Sendable {
    let samples: [VPSUsageSample]
    let xDomain: ClosedRange<Date>
    let trafficDomain: ClosedRange<Double>
    let creditDomain: ClosedRange<Double>

    var canDraw: Bool {
      samples.count >= 2
    }
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
    let finite = values.filter { $0.isFinite }
    guard let minimum = finite.min(), let maximum = finite.max() else {
      return 0...1
    }

    let span = maximum - minimum
    let padding = max(span * 0.08, max(abs(maximum), abs(minimum)) * 0.02, 0.01)
    if span == 0 {
      let safePadding = max(abs(maximum) * 0.12, 1)
      return (minimum - safePadding)...(maximum + safePadding)
    }
    return (minimum - padding)...(maximum + padding)
  }
}
