import Charts
import SwiftUI

/// OpenCode 趋势：订阅 Go 时使用同一张双 Y 轴图展示 Go 窗口和 Zen 余额；
/// 未订阅 Go 时只展示独立的 Zen 余额图。
///
/// 图表数据转换在后台任务中完成，菜单栏弹窗首次出现时先显示轻量的等待状态，
/// 避免 14 天历史样本在主线程上同步去重、归一化和组装大量 LineMark。
struct OpenCodeTrendChartView: View {
  let samples: [OpenCodeUsageSample]
  let showGoTrend: Bool
  let language: AppLanguage
  let now: Date

  @State private var preparedModel: OpenCodeTrendProcessor.ChartModel?
  @State private var selectedDate: Date?

  private var selectedSample: OpenCodeUsageSample? {
    guard let selectedDate else { return nil }
    return OpenCodeTrendProcessor.nearestSample(to: selectedDate, samples: samples)
  }

  private var preparationID: String {
    let latest = samples.last
    let observedAt = latest?.observedAt.timeIntervalSince1970 ?? -1
    let minute = Int(now.timeIntervalSince1970 / 60)
    return "\(showGoTrend)-\(samples.count)-\(latest?.id ?? "empty")-\(observedAt)-\(minute)"
  }

  private var xDomain: ClosedRange<Date> {
    now.addingTimeInterval(-UsageHistoryWindow.seconds)...now
  }

  /// 统一趋势摘要所需的变化值；Go 只使用月度额度，Zen 使用余额变化。
  /// 摘要前缀由供应商趋势卡片统一渲染。
  var usageChangeValue: String? {
    var values: [String] = []
    if showGoTrend,
      let goChange = OpenCodeTrendProcessor.monthlyRemainingChangePercent(samples: samples)
    {
      values.append(
        "\(L10n.string(.openCodeTrendGo, language: language)): \(goChange >= 0 ? "+" : "")\(goChange)%"
      )
    }
    if let zenChange = OpenCodeTrendProcessor.zenBalanceChange(samples: samples) {
      values.append(
        "\(L10n.string(.openCodeTrendZen, language: language)): \(formattedUSD(zenChange))"
      )
    }
    return values.isEmpty ? nil : values.joined(separator: " · ")
  }

  var body: some View {
    Group {
      if let preparedModel {
        VStack(alignment: .leading, spacing: 14) {
          exhaustionEstimate(preparedModel)
          if showGoTrend {
            goAndZenSection(preparedModel)
          } else {
            zenSection(preparedModel)
          }
          if let selectedSample {
            selectionDetail(selectedSample)
          }
        }
      } else {
        VStack(alignment: .leading, spacing: 8) {
          waitingView
        }
      }
    }
    .task(id: preparationID) {
      preparedModel = nil
      let capturedSamples = samples
      let capturedShowGoTrend = showGoTrend
      let capturedNow = now
      let model = await Task.detached(priority: .userInitiated) {
        OpenCodeTrendProcessor.chartModel(
          samples: capturedSamples,
          showGoTrend: capturedShowGoTrend,
          now: capturedNow
        )
      }.value
      guard !Task.isCancelled else { return }
      preparedModel = model
    }
  }

  @ViewBuilder
  private func exhaustionEstimate(_ model: OpenCodeTrendProcessor.ChartModel) -> some View {
    let estimates = exhaustionTexts(model)
    if !estimates.isEmpty {
      VStack(alignment: .trailing, spacing: 2) {
        ForEach(Array(estimates.enumerated()), id: \.offset) { _, estimate in
          Text(estimate)
            .font(AppTypography.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        }
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
  }

  private func exhaustionTexts(_ model: OpenCodeTrendProcessor.ChartModel) -> [String] {
    var result: [String] = []
    if showGoTrend, let seconds = model.exhaustion.goWeeklySeconds {
      result.append(
        L10n.string(
          .trendEstimateWeekly,
          language: language,
          UsageExhaustionEstimator.formattedDuration(seconds, language: language)
        )
      )
    }
    if let seconds = model.exhaustion.zenSeconds {
      result.append(
        L10n.string(
          .trendEstimateBalance,
          language: language,
          UsageExhaustionEstimator.formattedDuration(seconds, language: language)
        )
      )
    } else if model.exhaustion.zenHasData {
      result.append(L10n.string(.trendEstimateUnavailable, language: language))
    }
    return result
  }

  private func goAndZenSection(_ model: OpenCodeTrendProcessor.ChartModel) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      if model.canDrawGoChart || model.canDrawZenChart {
        combinedChart(model)
      } else {
        waitingView
      }
    }
  }

  private func zenSection(_ model: OpenCodeTrendProcessor.ChartModel) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      if model.canDrawZenChart {
        zenChart(model)
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

  private func combinedChart(_ model: OpenCodeTrendProcessor.ChartModel) -> some View {
    let series = seriesIDs(for: model)
    return Chart {
      ForEach(model.combinedPoints) { point in
        combinedLineMark(for: point)
      }

      if let selectedSample {
        RuleMark(
          x: .value(L10n.string(.chartSelectedTime, language: language), selectedSample.bucketStart)
        )
        .foregroundStyle(.secondary)
        .lineStyle(TrendChartSelectionStyle.rule)
      }
    }
    .chartXScale(domain: xDomain)
    .chartYScale(domain: 0...1)
    .chartForegroundStyleScale(
      domain: series.map(seriesTitle),
      range: series.map(seriesColor)
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
      if !model.zenPoints.isEmpty {
        AxisMarks(position: .trailing, values: normalizedAxisTicks) { value in
          AxisTick()
          AxisValueLabel {
            if let number = value.as(Double.self) {
              Text(formattedAxisUSD(zenValue(fromNormalized: number, model: model)))
                .font(AppTypography.caption)
            }
          }
        }
      }

    }
    .chartLegend(position: .bottom, alignment: .leading, spacing: 12)
    .frame(height: 170)
    .trendChartSelection($selectedDate)
    .accessibilityLabel(L10n.string(.a11yOpenCodeGoLegend, language: language))
  }

  private func combinedLineMark(
    for point: OpenCodeTrendProcessor.CombinedPoint
  ) -> some ChartContent {
    LineMark(
      x: .value(chartTimeTitle, point.date),
      y: .value(combinedAxisTitle, point.value)
    )
    .foregroundStyle(by: .value(seriesDimensionTitle, seriesTitle(point.series)))
    .lineStyle(StrokeStyle(lineWidth: 2))
  }

  private func zenChart(_ model: OpenCodeTrendProcessor.ChartModel) -> some View {
    Chart {
      ForEach(model.zenPoints) { point in
        LineMark(
          x: .value(chartTimeTitle, point.date),
          y: .value(zenAxisTitle, point.value)
        )
        .foregroundStyle(.purple)
        .lineStyle(StrokeStyle(lineWidth: 2))
      }

      if let selectedSample {
        RuleMark(
          x: .value(L10n.string(.chartSelectedTime, language: language), selectedSample.bucketStart)
        )
        .foregroundStyle(.secondary)
        .lineStyle(TrendChartSelectionStyle.rule)
      }
    }
    .chartXScale(domain: xDomain)
    .chartYScale(domain: model.zenLower...model.zenUpper)
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
    .trendChartSelection($selectedDate)
    .accessibilityLabel(L10n.string(.a11yOpenCodeZenLegend, language: language))
  }

  private func selectionDetail(_ sample: OpenCodeUsageSample) -> some View {
    var values: [String] = []
    if showGoTrend {
      for kind in OpenCodeUsageWindow.Kind.allCases {
        guard let used = OpenCodeTrendProcessor.usagePercent(sample, kind: kind) else {
          continue
        }
        values.append(
          TrendChartSelectionDetail.valueText(
            label: windowTitle(kind),
            value: L10n.string(
              .openCodeProgress,
              language: language,
              used,
              max(0, min(100, 100 - used))
            ),
            language: language
          )
        )
      }
    }
    if let balance = sample.zenBalanceUSD {
      values.append(
        TrendChartSelectionDetail.valueText(
          label: zenSeriesTitle,
          value: formattedAxisUSD(balance),
          language: language
        )
      )
    }
    return TrendChartSelectionDetail(
      date: sample.bucketStart,
      language: language,
      values: values
    )
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

  private var normalizedAxisTicks: [Double] {
    [0, 0.25, 0.5, 0.75, 1]
  }

  private func seriesIDs(
    for model: OpenCodeTrendProcessor.ChartModel
  ) -> [OpenCodeTrendProcessor.SeriesID] {
    model.goSeries.map { OpenCodeTrendProcessor.SeriesID(kind: $0.kind) }
      + (model.zenPoints.isEmpty ? [] : [.zen])
  }

  private func seriesTitle(_ series: OpenCodeTrendProcessor.SeriesID) -> String {
    switch series {
    case .rolling:
      return windowTitle(.rolling)
    case .weekly:
      return windowTitle(.weekly)
    case .monthly:
      return windowTitle(.monthly)
    case .zen:
      return zenSeriesTitle
    }
  }

  private func seriesColor(_ series: OpenCodeTrendProcessor.SeriesID) -> Color {
    switch series {
    case .rolling:
      return .blue
    case .weekly:
      return .green
    case .monthly:
      return .orange
    case .zen:
      return .purple
    }
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
    L10n.string(.chartRemaining, language: language)
  }

  private var seriesDimensionTitle: String {
    "series"
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

  private func zenValue(
    fromNormalized value: Double,
    model: OpenCodeTrendProcessor.ChartModel
  ) -> Double {
    model.zenLower + value * (model.zenUpper - model.zenLower)
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
}

/// OpenCode 趋势的纯数据计算，确保去重、双轴归一化和耗尽估算在后台任务中完成。
enum OpenCodeTrendProcessor {
  enum SeriesID: String, Sendable {
    case rolling
    case weekly
    case monthly
    case zen

    init(kind: OpenCodeUsageWindow.Kind) {
      switch kind {
      case .rolling: self = .rolling
      case .weekly: self = .weekly
      case .monthly: self = .monthly
      }
    }
  }

  struct Point: Identifiable, Sendable {
    let id: String
    let date: Date
    let value: Double
  }

  struct GoSeries: Identifiable, Sendable {
    let kind: OpenCodeUsageWindow.Kind
    let points: [Point]

    var id: String { kind.rawValue }
  }

  struct CombinedPoint: Identifiable, Sendable {
    let id: String
    let date: Date
    let value: Double
    let series: SeriesID
  }

  struct ExhaustionEstimates: Sendable {
    let goWeeklySeconds: TimeInterval?
    let zenSeconds: TimeInterval?
    let zenHasData: Bool
  }

  struct ChartModel: Sendable {
    let goSeries: [GoSeries]
    let zenPoints: [Point]
    let combinedPoints: [CombinedPoint]
    let zenLower: Double
    let zenUpper: Double
    let exhaustion: ExhaustionEstimates

    var canDrawGoChart: Bool {
      goSeries.contains { $0.points.count >= 2 }
    }

    var canDrawZenChart: Bool {
      zenPoints.count >= 2
    }
  }

  static func chartModel(
    samples: [OpenCodeUsageSample],
    showGoTrend: Bool,
    now: Date
  ) -> ChartModel {
    let zenPoints = makeZenPoints(samples)
    let goSeries: [GoSeries]
    if showGoTrend {
      goSeries = [
        makeGoSeries(samples, kind: .rolling),
        makeGoSeries(samples, kind: .weekly),
        makeGoSeries(samples, kind: .monthly),
      ].filter { !$0.points.isEmpty }
    } else {
      goSeries = []
    }

    let (zenLower, zenUpper) = zenDomain(for: zenPoints)
    var combinedPoints: [CombinedPoint] = []
    for series in goSeries {
      let seriesID = SeriesID(kind: series.kind)
      combinedPoints.append(contentsOf: series.points.map {
        CombinedPoint(id: $0.id, date: $0.date, value: $0.value, series: seriesID)
      })
    }
    combinedPoints.append(contentsOf: zenPoints.map {
      CombinedPoint(
        id: $0.id,
        date: $0.date,
        value: zenNormalized($0.value, lower: zenLower, upper: zenUpper),
        series: .zen
      )
    })

    return ChartModel(
      goSeries: goSeries,
      zenPoints: zenPoints,
      combinedPoints: combinedPoints,
      zenLower: zenLower,
      zenUpper: zenUpper,
      exhaustion: exhaustionEstimates(samples: samples, showGoTrend: showGoTrend, now: now)
    )
  }

  static func monthlyRemainingChangePercent(samples: [OpenCodeUsageSample]) -> Int? {
    let ordered = newestSamples(samples) { remainingPercent($0, kind: .monthly) != nil }
    guard let first = ordered.first.flatMap({ remainingPercent($0, kind: .monthly) }),
      let last = ordered.last.flatMap({ remainingPercent($0, kind: .monthly) }),
      ordered.count >= 2
    else {
      return nil
    }
    return last - first
  }

  static func zenBalanceChange(samples: [OpenCodeUsageSample]) -> Double? {
    let ordered = newestSamples(samples) { $0.zenBalanceUSD?.isFinite == true }
    guard let first = ordered.first?.zenBalanceUSD,
      let last = ordered.last?.zenBalanceUSD,
      ordered.count >= 2
    else {
      return nil
    }
    return last - first
  }

  /// 选择距离给定时间最近的历史样本，详情页和所有 OpenCode 图表共用。
  static func nearestSample(
    to date: Date,
    samples: [OpenCodeUsageSample]
  ) -> OpenCodeUsageSample? {
    newestSamples(samples) {
      $0.goRollingUsedPercent != nil
        || $0.goWeeklyUsedPercent != nil
        || $0.goMonthlyUsedPercent != nil
        || $0.zenBalanceUSD?.isFinite == true
    }
    .min {
      abs($0.bucketStart.timeIntervalSince(date)) < abs($1.bucketStart.timeIntervalSince(date))
    }
  }

  static func exhaustionEstimates(
    samples: [OpenCodeUsageSample],
    showGoTrend: Bool,
    now: Date
  ) -> ExhaustionEstimates {
    let goWeekly: TimeInterval?
    if showGoTrend {
      let points = makeQuotaExhaustionPoints(samples, kind: .weekly)
      goWeekly = UsageExhaustionEstimator.estimate(points: points, now: now)
    } else {
      goWeekly = nil
    }

    let zenPoints = makeZenExhaustionPoints(samples)
    return ExhaustionEstimates(
      goWeeklySeconds: goWeekly,
      zenSeconds: UsageExhaustionEstimator.estimate(points: zenPoints, now: now),
      zenHasData: !zenPoints.isEmpty
    )
  }

  /// 保留给现有测试和调用方的 Zen 估算便捷入口。
  static func zenExhaustionEstimate(
    samples: [OpenCodeUsageSample],
    now: Date
  ) -> TimeInterval? {
    exhaustionEstimates(samples: samples, showGoTrend: false, now: now).zenSeconds
  }

  private static func makeGoSeries(
    _ samples: [OpenCodeUsageSample],
    kind: OpenCodeUsageWindow.Kind
  ) -> GoSeries {
    let matching = newestSamples(samples) { remainingPercent($0, kind: kind) != nil }
    let points = matching.compactMap { sample -> Point? in
      guard let value = remainingPercent(sample, kind: kind) else { return nil }
      return Point(
        id: sample.id + "/" + kind.rawValue,
        date: sample.bucketStart,
        value: Double(value) / 100
      )
    }
    return GoSeries(kind: kind, points: points)
  }

  private static func makeZenPoints(_ samples: [OpenCodeUsageSample]) -> [Point] {
    newestSamples(samples) { $0.zenBalanceUSD?.isFinite == true }.compactMap { sample in
      guard let value = sample.zenBalanceUSD, value.isFinite else { return nil }
      return Point(id: sample.id + "/zen", date: sample.bucketStart, value: value)
    }
  }

  private static func makeQuotaExhaustionPoints(
    _ samples: [OpenCodeUsageSample],
    kind: OpenCodeUsageWindow.Kind
  ) -> [UsageExhaustionPoint] {
    newestSamples(samples) { remainingPercent($0, kind: kind) != nil }.compactMap { sample in
      guard let remaining = remainingPercent(sample, kind: kind) else { return nil }
      return UsageExhaustionPoint(
        date: sample.bucketStart,
        remaining: Double(remaining)
      )
    }
  }

  private static func makeZenExhaustionPoints(
    _ samples: [OpenCodeUsageSample]
  ) -> [UsageExhaustionPoint] {
    newestSamples(samples) { $0.zenBalanceUSD?.isFinite == true }.compactMap { sample in
      guard let balance = sample.zenBalanceUSD, balance.isFinite else { return nil }
      return UsageExhaustionPoint(date: sample.bucketStart, remaining: balance)
    }
  }

  static func usagePercent(
    _ sample: OpenCodeUsageSample,
    kind: OpenCodeUsageWindow.Kind
  ) -> Int? {
    switch kind {
    case .rolling:
      return sample.goRollingUsedPercent
    case .weekly:
      return sample.goWeeklyUsedPercent
    case .monthly:
      return sample.goMonthlyUsedPercent
    }
  }

  static func remainingPercent(
    _ sample: OpenCodeUsageSample,
    kind: OpenCodeUsageWindow.Kind
  ) -> Int? {
    guard let used = usagePercent(sample, kind: kind) else { return nil }
    return max(0, min(100, 100 - used))
  }

  private static func zenDomain(for points: [Point]) -> (Double, Double) {
    let values = points.map(\.value)
    guard let minValue = values.min(), let maxValue = values.max() else {
      return (0, 1)
    }
    if abs(maxValue - minValue) < 0.000001 {
      let padding = max(0.5, abs(maxValue) * 0.1)
      return (max(0, minValue - padding), maxValue + padding)
    }
    let padding = max(0.1, (maxValue - minValue) * 0.1)
    return (max(0, minValue - padding), maxValue + padding)
  }

  private static func zenNormalized(
    _ value: Double,
    lower: Double,
    upper: Double
  ) -> Double {
    let span = upper - lower
    guard span > 0 else { return 0.5 }
    return min(1, max(0, (value - lower) / span))
  }

  private static func newestSamples(
    _ samples: [OpenCodeUsageSample],
    where predicate: (OpenCodeUsageSample) -> Bool
  ) -> [OpenCodeUsageSample] {
    var newestByBucket: [Int64: OpenCodeUsageSample] = [:]
    for sample in samples where predicate(sample) {
      let bucket = Int64(sample.bucketStart.timeIntervalSince1970)
      if let existing = newestByBucket[bucket], existing.observedAt >= sample.observedAt {
        continue
      }
      newestByBucket[bucket] = sample
    }
    return newestByBucket.values.sorted { $0.bucketStart < $1.bucketStart }
  }
}
