import Charts
import SwiftUI

struct GrokBotTrendPoint: Identifiable {
  let id: String
  let bucketStart: Date
  let percent: Int
  let segment: Int
}

struct GrokBotTrendChartView: View {
  let samples: [GrokBotUsageSample]
  let language: AppLanguage
  let now: Date
  let period: TrendPeriod
  let resetsAt: Date?

  @State private var selectedDate: Date?

  init(
    samples: [GrokBotUsageSample],
    language: AppLanguage,
    now: Date,
    period: TrendPeriod = .fourteenDays,
    resetsAt: Date? = nil
  ) {
    self.samples = samples
    self.language = language
    self.now = now
    self.period = period
    self.resetsAt = resetsAt
  }

  private var periodSamples: [GrokBotUsageSample] {
    TrendPeriod.filtered(samples, period: period, now: now) { $0.bucketStart }
  }

  private var selectedSample: GrokBotUsageSample? {
    guard let selectedDate else { return nil }
    return GrokBotTrendProcessor.nearestSample(to: selectedDate, samples: periodSamples)
  }

  private var segments: [[GrokBotTrendPoint]] {
    GrokBotTrendProcessor.segments(periodSamples)
  }

  private var xDomain: ClosedRange<Date> {
    period.chartDomain(now: now)
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
    if let forecast = GrokBotExhaustion.forecast(
      samples: periodSamples,
      now: now,
      resetsAt: resetsAt
    ) {
      Text(exhaustionEstimateText(forecast))
        .font(AppTypography.caption)
        .foregroundStyle(TrendChartPalette.secondaryText)
        .multilineTextAlignment(.trailing)
        .lineLimit(2)
        .minimumScaleFactor(0.75)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
  }

  private func exhaustionEstimateText(_ forecast: GrokBotExhaustionForecast) -> String {
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
      exhaustionEstimate
      chartView
      if let selectedSample {
        selectionDetail(selectedSample)
      }
    }
  }

  private var chartView: some View {
    let remainingTitle = L10n.string(.chartRemaining, language: language)
    return Chart {
      ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
        ForEach(segment) { point in
          LineMark(
            x: .value(L10n.string(.chartTime, language: language), point.bucketStart),
            y: .value(L10n.string(.chartRemaining, language: language), point.percent),
            series: .value(L10n.string(.chartSegment, language: language), "\(remainingTitle)/\(index)")
          )
          .foregroundStyle(by: .value(L10n.string(.chartSegment, language: language), remainingTitle))
          .lineStyle(StrokeStyle(lineWidth: 2))
        }
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
    .chartXAxis {
      AxisMarks(values: .automatic(desiredCount: 4)) { value in
        AxisGridLine().foregroundStyle(TrendChartPalette.grid)
        AxisValueLabel {
          if let date = value.as(Date.self) {
            Text(axisLabel(for: date))
              .font(AppTypography.caption)
              .foregroundStyle(TrendChartPalette.axisText)
              .lineLimit(1)
          }
        }
      }
    }
    .chartYAxis {
      AxisMarks(position: .leading) { value in
        AxisGridLine().foregroundStyle(TrendChartPalette.grid)
        AxisValueLabel {
          if let percent = value.as(Double.self) {
            Text("\(Int(percent))%")
              .font(AppTypography.caption)
              .foregroundStyle(TrendChartPalette.axisText)
          }
        }
      }
    }
    .chartLegend(.hidden)
    .frame(height: 160)
    .trendChartSelection($selectedDate)
    .accessibilityLabel(L10n.string(.a11yGrokBotLegend, language: language))
  }

  private func selectionDetail(_ sample: GrokBotUsageSample) -> some View {
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

  private func axisLabel(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = language.locale
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = language == .simplifiedChinese ? "M/d HH:mm" : "MMM d HH:mm"
    return formatter.string(from: date)
  }
}

enum GrokBotTrendProcessor {
  static let gapThreshold: TimeInterval = 20 * 60

  static func segments(_ samples: [GrokBotUsageSample]) -> [[GrokBotTrendPoint]] {
    let sorted = newestSamples(samples).sorted { $0.bucketStart < $1.bucketStart }
    var result: [[GrokBotTrendPoint]] = []
    var current: [GrokBotTrendPoint] = []
    var segmentIndex = 0

    func flush() {
      guard !current.isEmpty else { return }
      result.append(current)
      current = []
    }

    for sample in sorted {
      if let last = current.last,
        sample.bucketStart.timeIntervalSince(last.bucketStart) > gapThreshold
      {
        flush()
        segmentIndex += 1
      }
      current.append(
        GrokBotTrendPoint(
          id: "\(Int64(sample.bucketStart.timeIntervalSince1970))/\(segmentIndex)",
          bucketStart: sample.bucketStart,
          percent: sample.remainingPercent,
          segment: segmentIndex
        )
      )
    }
    flush()
    return result
  }

  static func nearestSample(
    to date: Date,
    samples: [GrokBotUsageSample]
  ) -> GrokBotUsageSample? {
    newestSamples(samples).min {
      abs($0.bucketStart.timeIntervalSince(date)) < abs($1.bucketStart.timeIntervalSince(date))
    }
  }

  private static func newestSamples(_ samples: [GrokBotUsageSample]) -> [GrokBotUsageSample] {
    var newestByBucket: [Int64: GrokBotUsageSample] = [:]
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
