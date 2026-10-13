import Charts
import SwiftUI

struct XSubscriptionTrendPoint: Identifiable, Equatable, Sendable {
  let id: String
  let bucketStart: Date
  let percent: Int
  let segment: Int
}

struct XSubscriptionTrendChartView: View {
  let samples: [XSubscriptionUsageSample]
  let language: AppLanguage
  let now: Date
  let period: TrendPeriod
  let resetsAt: Date?
  let currentRemainingPercent: Int?

  @State private var selectedDate: Date?

  init(
    samples: [XSubscriptionUsageSample],
    language: AppLanguage,
    now: Date,
    period: TrendPeriod = .fourteenDays,
    resetsAt: Date? = nil,
    currentRemainingPercent: Int? = nil
  ) {
    self.samples = samples
    self.language = language
    self.now = now
    self.period = period
    self.resetsAt = resetsAt
    self.currentRemainingPercent = currentRemainingPercent
  }

  private var model: XSubscriptionTrendProcessor.ChartModel {
    XSubscriptionTrendProcessor.chartModel(samples: samples, now: now, period: period)
  }

  private var periodSamples: [XSubscriptionUsageSample] {
    TrendPeriod.filtered(samples, period: period, now: now) { $0.bucketStart }
  }

  private var selectedSample: XSubscriptionUsageSample? {
    guard let selectedDate else { return nil }
    return XSubscriptionTrendProcessor.nearestSample(to: selectedDate, samples: periodSamples)
  }

  private var xDomain: ClosedRange<Date> {
    model.xDomain
  }

  var usageChangeValue: String? {
    let ordered = periodSamples.sorted { $0.bucketStart < $1.bucketStart }
    guard let first = ordered.first, let last = ordered.last, first.id != last.id else {
      return nil
    }
    let delta = last.remainingPercent - first.remainingPercent
    return "\(delta >= 0 ? "+" : "")\(delta)%"
  }

  @ViewBuilder
  private var exhaustionEstimate: some View {
    if let forecast = XSubscriptionExhaustion.forecast(
      samples: periodSamples,
      now: now,
      resetsAt: resetsAt
    ) {
      TrendExhaustionCaption(text: exhaustionEstimateText(forecast))
    }
  }

  private func exhaustionEstimateText(_ forecast: XSubscriptionExhaustionForecast) -> String {
    switch forecast {
    case .alreadyExhausted:
      return L10n.string(.trendEstimateExhausted, language: language)
    case .depletesBeforeReset(let seconds), .survivesUntilReset(let seconds):
      return L10n.string(
        .trendEstimateWeekly,
        language: language,
        UsageExhaustionEstimator.formattedDuration(seconds, language: language)
      )
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if model.canDraw {
        exhaustionEstimate
        chartView
        if let selectedSample {
          selectionDetail(selectedSample)
        }
      } else {
        insufficientSamplesView
      }
    }
  }

  private var displayedRemainingPercent: Int? {
    currentRemainingPercent ?? model.latestRemainingPercent
  }

  private var insufficientSamplesView: some View {
    TrendChartInsufficientSamplesView(
      remainingPercent: displayedRemainingPercent,
      language: language
    )
  }

  private var chartView: some View {
    let remainingTitle = L10n.string(.chartRemaining, language: language)
    return Chart {
      ForEach(model.points) { point in
        LineMark(
          x: .value(L10n.string(.chartTime, language: language), point.bucketStart),
          y: .value(L10n.string(.chartRemaining, language: language), point.percent),
          series: .value(L10n.string(.chartSegment, language: language), remainingTitle)
        )
        .foregroundStyle(by: .value(L10n.string(.chartSegment, language: language), remainingTitle))
        .interpolationMethod(.linear)
        .lineStyle(StrokeStyle(lineWidth: 2))
      }

      if let selectedSample {
        RuleMark(
          x: .value(L10n.string(.chartSelectedTime, language: language), selectedSample.bucketStart)
        )
        .foregroundStyle(TrendChartPalette.selection)
        .lineStyle(TrendChartSelectionStyle.rule)
      }
    }
    .chartXScale(domain: xDomain)
    .chartYScale(domain: 0...100)
    .chartXAxis { TrendChartAxis.dateMarks(language: language) }
    .chartYAxis { TrendChartAxis.percentMarks() }
    .chartLegend(.hidden)
    .frame(height: 160)
    .trendChartSelection($selectedDate)
    .accessibilityLabel(L10n.string(.a11yXSubscriptionLegend, language: language))
  }

  private func selectionDetail(_ sample: XSubscriptionUsageSample) -> some View {
    TrendChartSelectionDetail(
      date: sample.bucketStart,
      language: language,
      values: [
        TrendChartSelectionDetail.valueText(
          label: L10n.string(.chartRemaining, language: language),
          value: "\(sample.remainingPercent)%",
          language: language
        ),
      ]
    )
  }

}

enum XSubscriptionTrendProcessor {
  struct ChartModel: Equatable, Sendable {
    let points: [XSubscriptionTrendPoint]
    let xDomain: ClosedRange<Date>
    let latestRemainingPercent: Int?

    var canDraw: Bool { points.count >= 2 }
  }

  static func chartModel(
    samples: [XSubscriptionUsageSample],
    now: Date,
    period: TrendPeriod = .fourteenDays
  ) -> ChartModel {
    let periodSamples = TrendPeriod.filtered(samples, period: period, now: now) { $0.bucketStart }
    let points = segments(periodSamples).first ?? []
    let latest = newestSamples(periodSamples)
      .max { $0.bucketStart < $1.bucketStart }?
      .remainingPercent
    return ChartModel(
      points: points,
      xDomain: period.chartDomain(now: now),
      latestRemainingPercent: latest
    )
  }

  /// 全部样本组成一条折线。时间缺口由图表在相邻真实样本之间线性插值。
  static func segments(_ samples: [XSubscriptionUsageSample]) -> [[XSubscriptionTrendPoint]] {
    let sorted = newestSamples(samples).sorted { $0.bucketStart < $1.bucketStart }
    guard !sorted.isEmpty else { return [] }
    let points = sorted.map { sample in
      XSubscriptionTrendPoint(
        id: "\(Int64(sample.bucketStart.timeIntervalSince1970))/0",
        bucketStart: sample.bucketStart,
        percent: sample.remainingPercent,
        segment: 0
      )
    }
    return [points]
  }

  static func nearestSample(
    to date: Date,
    samples: [XSubscriptionUsageSample]
  ) -> XSubscriptionUsageSample? {
    newestSamples(samples).min {
      abs($0.bucketStart.timeIntervalSince(date)) < abs($1.bucketStart.timeIntervalSince(date))
    }
  }

  private static func newestSamples(
    _ samples: [XSubscriptionUsageSample]
  ) -> [XSubscriptionUsageSample] {
    var newestByBucket: [Int64: XSubscriptionUsageSample] = [:]
    for sample in samples {
      let bucketSeconds = Int64(sample.bucketStart.timeIntervalSince1970)
      if let existing = newestByBucket[bucketSeconds], existing.observedAt > sample.observedAt {
        continue
      }
      newestByBucket[bucketSeconds] = sample
    }
    return Array(newestByBucket.values)
  }
}
