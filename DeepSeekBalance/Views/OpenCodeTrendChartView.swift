import Charts
import SwiftUI

/// OpenCode 趋势：订阅 Go 时使用同一张双 Y 轴图展示 Go 窗口和 Zen 余额；
/// 未订阅 Go 时只展示独立的 Zen 余额图。
struct OpenCodeTrendChartView: View {
  let samples: [OpenCodeUsageSample]
  let showGoTrend: Bool
  let language: AppLanguage
  let now: Date

  private var zenPoints: [Point] {
    deduplicated { $0.zenBalanceUSD }.compactMap { sample in
      guard let value = sample.zenBalanceUSD, value.isFinite else { return nil }
      return Point(id: sample.id + "/zen", date: sample.bucketStart, value: value)
    }
  }

  private var xDomain: ClosedRange<Date> {
    now.addingTimeInterval(-72 * 3600)...now
  }

  private var goSeries: [LineSeries] {
    [
      makeGoSeries(
        kind: .rolling,
        value: \OpenCodeUsageSample.goRollingUsedPercent,
        color: .blue
      ),
      makeGoSeries(
        kind: .weekly,
        value: \OpenCodeUsageSample.goWeeklyUsedPercent,
        color: .green
      ),
      makeGoSeries(
        kind: .monthly,
        value: \OpenCodeUsageSample.goMonthlyUsedPercent,
        color: .orange
      ),
    ].filter { !$0.points.isEmpty }
  }

  private var canDrawGoChart: Bool {
    goSeries.contains { $0.points.count >= 2 }
  }

  private var canDrawZenChart: Bool {
    zenPoints.count >= 2
  }

  private var combinedPoints: [CombinedPoint] {
    var points: [CombinedPoint] = []
    for series in goSeries {
      for point in series.points {
        points.append(
          CombinedPoint(
            id: point.id,
            date: point.date,
            value: point.value,
            seriesTitle: series.title
          )
        )
      }
    }
    for point in zenPoints {
      points.append(
        CombinedPoint(
          id: point.id + "/zen",
          date: point.date,
          value: zenNormalized(point.value),
          seriesTitle: zenSeriesTitle
        )
      )
    }
    return points
  }

  /// 统一趋势摘要所需的变化值；Go 只使用月度额度，Zen 使用余额变化。
  /// 摘要前缀由供应商趋势卡片统一渲染。
  var usageChangeValue: String? {
    var values: [String] = []
    if showGoTrend, let goChange = goMonthlyChangeValue {
      values.append("\(L10n.string(.openCodeTrendGo, language: language)): \(goChange)")
    }
    if let zenChange = zenBalanceChangeValue {
      values.append("\(L10n.string(.openCodeTrendZen, language: language)): \(zenChange)")
    }
    return values.isEmpty ? nil : values.joined(separator: " · ")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      if showGoTrend {
        goAndZenSection
      } else {
        zenSection
      }
    }
  }

  private var goAndZenSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      if canDrawGoChart || canDrawZenChart {
        combinedChart
      } else {
        waitingView
      }
    }
  }

  private var zenSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      if canDrawZenChart {
        zenChart
      } else {
        waitingView
      }
    }
  }

  private var waitingView: some View {
    Text(L10n.string(.openCodeTrendWaiting, language: language))
      .font(AppTypography.caption)
      .foregroundStyle(.secondary)
  }

  private var combinedChart: some View {
    Chart {
      ForEach(combinedPoints) { point in
        combinedLineMark(for: point)
      }
    }
    .chartXScale(domain: xDomain)
    .chartYScale(domain: 0...1)
    .chartForegroundStyleScale(
      domain: goSeries.map(\.title) + [zenSeriesTitle],
      range: goSeries.map(\.color) + [.purple]
    )
    .chartXAxis { xAxis }
    .chartYAxis {
      AxisMarks(position: .leading, values: normalizedAxisTicks) { value in
        AxisGridLine().foregroundStyle(.quaternary)
        AxisTick()
        AxisValueLabel {
          if let number = value.as(Double.self) {
            Text("\(Int(number * 100))%")
              .font(AppTypography.caption)
          }
        }
      }
      if !zenPoints.isEmpty {
        AxisMarks(position: .trailing, values: normalizedAxisTicks) { value in
          AxisTick()
          AxisValueLabel {
            if let number = value.as(Double.self) {
              Text(formattedAxisUSD(zenValue(fromNormalized: number)))
                .font(AppTypography.caption)
            }
          }
        }
      }
    }
    .chartLegend(position: .bottom, alignment: .leading, spacing: 12)
    .frame(height: 170)
    .accessibilityLabel(L10n.string(.a11yOpenCodeGoLegend, language: language))
  }

  private func combinedLineMark(for point: CombinedPoint) -> some ChartContent {
    LineMark(
      x: .value(chartTimeTitle, point.date),
      y: .value(combinedAxisTitle, point.value)
    )
    .foregroundStyle(by: .value(seriesDimensionTitle, point.seriesTitle))
    .lineStyle(StrokeStyle(lineWidth: 2))
  }

  private var zenChart: some View {
    Chart {
      ForEach(zenPoints) { point in
        LineMark(
          x: .value(chartTimeTitle, point.date),
          y: .value(zenAxisTitle, point.value)
        )
        .foregroundStyle(.purple)
        .lineStyle(StrokeStyle(lineWidth: 2))
      }
    }
    .chartXScale(domain: xDomain)
    .chartYScale(domain: zenYDomain)
    .chartXAxis { xAxis }
    .chartYAxis {
      AxisMarks(position: .leading) { value in
        AxisGridLine().foregroundStyle(.quaternary)
        AxisValueLabel {
          if let number = value.as(Double.self) {
            Text(formattedAxisUSD(number))
              .font(AppTypography.caption)
          }
        }
      }
    }
    .chartLegend(.hidden)
    .frame(height: 150)
    .accessibilityLabel(L10n.string(.a11yOpenCodeZenLegend, language: language))
  }

  private var xAxis: some AxisContent {
    AxisMarks(values: .automatic(desiredCount: 4)) { value in
      AxisGridLine().foregroundStyle(.quaternary)
      AxisValueLabel {
        if let date = value.as(Date.self) {
          Text(axisLabel(for: date))
            .font(AppTypography.caption)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
      }
    }
  }

  private var goMonthlyChangeValue: String? {
    let monthlyPoints = makeGoSeries(
      kind: .monthly,
      value: \OpenCodeUsageSample.goMonthlyUsedPercent,
      color: .orange
    ).points
    guard let first = monthlyPoints.first, let last = monthlyPoints.last, first.id != last.id else {
      return nil
    }
    let delta = (last.value - first.value) * 100
    return String(format: "%+.0f%%", delta)
  }

  private var zenBalanceChangeValue: String? {
    guard let first = zenPoints.first, let last = zenPoints.last, first.id != last.id else {
      return nil
    }
    let delta = last.value - first.value
    return formattedUSD(delta)
  }

  private var zenYDomain: ClosedRange<Double> {
    let values = zenPoints.map(\.value)
    guard let minValue = values.min(), let maxValue = values.max() else {
      return 0...1
    }
    if abs(maxValue - minValue) < 0.000001 {
      let padding = max(0.5, abs(maxValue) * 0.1)
      return max(0, minValue - padding)...maxValue + padding
    }
    let padding = max(0.1, (maxValue - minValue) * 0.1)
    return max(0, minValue - padding)...maxValue + padding
  }

  private var normalizedAxisTicks: [Double] {
    [0, 0.25, 0.5, 0.75, 1]
  }

  private var zenSeriesTitle: String {
    L10n.string(.openCodeTrendZen, language: language)
  }

  private var chartTimeTitle: String {
    L10n.string(.chartTime, language: language)
  }

  private var zenAxisTitle: String {
    L10n.string(.openCodeTrendZen, language: language)
  }

  private var combinedAxisTitle: String {
    "OpenCode"
  }

  private var seriesDimensionTitle: String {
    "series"
  }

  private func makeGoSeries(
    kind: OpenCodeUsageWindow.Kind,
    value keyPath: KeyPath<OpenCodeUsageSample, Int?>,
    color: Color
  ) -> LineSeries {
    let matchingSamples: [OpenCodeUsageSample] = deduplicated { sample in
      sample[keyPath: keyPath]
    }
    let points: [Point] = matchingSamples.compactMap { sample in
      guard let value = sample[keyPath: keyPath] else { return nil }
      return Point(
        id: sample.id + "/" + kind.rawValue,
        date: sample.bucketStart,
        value: Double(value) / 100
      )
    }
    return LineSeries(
      id: kind.rawValue,
      title: windowTitle(kind),
      color: color,
      points: points
    )
  }

  private func windowTitle(_ kind: OpenCodeUsageWindow.Kind) -> String {
    switch kind {
    case .rolling:
      return L10n.string(.openCodeWindowRolling, language: language)
    case .weekly:
      return L10n.string(.openCodeWindowWeekly, language: language)
    case .monthly:
      return L10n.string(.openCodeWindowMonthly, language: language)
    }
  }

  private func zenNormalized(_ value: Double) -> Double {
    let span = zenYDomain.upperBound - zenYDomain.lowerBound
    guard span > 0 else { return 0.5 }
    return min(1, max(0, (value - zenYDomain.lowerBound) / span))
  }

  private func zenValue(fromNormalized value: Double) -> Double {
    zenYDomain.lowerBound + value * (zenYDomain.upperBound - zenYDomain.lowerBound)
  }

  private func deduplicated<Value>(_ value: (OpenCodeUsageSample) -> Value?) -> [OpenCodeUsageSample] {
    var newestByBucket: [Int64: OpenCodeUsageSample] = [:]
    for sample in samples where value(sample) != nil {
      let bucket = Int64(sample.bucketStart.timeIntervalSince1970)
      if let existing = newestByBucket[bucket], existing.observedAt >= sample.observedAt {
        continue
      }
      newestByBucket[bucket] = sample
    }
    return newestByBucket.values.sorted { $0.bucketStart < $1.bucketStart }
  }

  private func axisLabel(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = language.locale
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = language == .simplifiedChinese ? "M/d HH:mm" : "MMM d HH:mm"
    return formatter.string(from: date)
  }

  private func formattedAxisUSD(_ value: Double) -> String {
    String(format: "$%.2f", value)
  }

  private func formattedUSD(_ value: Double) -> String {
    String(format: "%+.2f", value)
  }

  private struct Point: Identifiable {
    let id: String
    let date: Date
    let value: Double
  }

  private struct LineSeries: Identifiable {
    let id: String
    let title: String
    let color: Color
    let points: [Point]
  }

  private struct CombinedPoint: Identifiable {
    let id: String
    let date: Date
    let value: Double
    let seriesTitle: String
  }
}
