import Foundation

struct GrokBotUsageSnapshot: Equatable, Sendable {
  let weekly: GrokBotWeeklyStatus
  let planDisplayName: String?
}

enum GrokBotWeeklyStatus: Equatable, Sendable {
  case metered(GrokBotWeeklyQuota)
  case enterprisePooled
  case noIncludedLimit
  case trial(GrokBotTrial)
}

struct GrokBotTrial: Equatable, Sendable {
  let expiresAt: Date
  let isCancelable: Bool
}

struct GrokBotWeeklyQuota: Equatable, Sendable {
  let usedPercent: Int
  let resetsAt: Date?

  var remainingPercent: Int {
    max(0, min(100, 100 - usedPercent))
  }

  var windowStart: Date? {
    resetsAt?.addingTimeInterval(-Self.weekSeconds)
  }

  static let weekSeconds: TimeInterval = 604_800

  func usageGapPercent(now: Date) -> Int? {
    guard let resetsAt, let windowStart,
      let expected = GrokBotUsageFormatter.expectedUsedPercent(
        start: windowStart,
        end: resetsAt,
        now: now
      )
    else {
      return nil
    }
    return usedPercent - Int(expected.rounded())
  }
}

extension GrokBotUsageSnapshot {
  var meteredQuota: GrokBotWeeklyQuota? {
    if case .metered(let quota) = weekly { return quota }
    return nil
  }
}

enum GrokBotExhaustionForecast: Equatable, Sendable {
  case alreadyExhausted
  case depletesBeforeReset(TimeInterval)
  case survivesUntilReset(TimeInterval)
}

enum GrokBotExhaustion {
  static func forecast(
    samples: [GrokBotUsageSample],
    now: Date,
    resetsAt: Date?
  ) -> GrokBotExhaustionForecast? {
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
  ) -> GrokBotExhaustionForecast {
    let timeUntilReset = resetsAt.map { $0.timeIntervalSince(now) }
    guard let timeUntilReset, timeUntilReset > 0, seconds > timeUntilReset else {
      return .depletesBeforeReset(seconds)
    }
    return .survivesUntilReset(timeUntilReset)
  }
}

enum GrokBotUsageFormatter {
  static func expectedUsedPercent(start: Date, end: Date, now: Date) -> Double? {
    let startT = start.timeIntervalSince1970
    let endT = end.timeIntervalSince1970
    let nowT = now.timeIntervalSince1970
    guard startT < endT, nowT >= startT, nowT <= endT else { return nil }
    return min(100, max(0, (nowT - startT) / (endT - startT) * 100))
  }
}
