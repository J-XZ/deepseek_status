import Charts
import SwiftUI

/// 折线图数据点：来自第一方模型或 API 通道。
struct CursorTrendPoint: Identifiable {
  enum Channel: Hashable {
    case firstParty
    case api

    var displayKey: L10nKey {
      switch self {
      case .firstParty:
        return .cursorTrendFirstParty
      case .api:
        return .cursorTrendApi
      }
    }
  }

  let id: String
  let bucketStart: Date
  let percent: Int
  let channel: Channel
  let segment: Int

  func seriesName(language: AppLanguage) -> String {
    L10n.string(channel.displayKey, language: language)
  }
}
/// Cursor 用量趋势折线图：最近 14 天剩余百分比，第一方模型与 API 通道各一条线
/// （Apple Swift Charts）。缺口超过 20 分钟会断开连线。
struct CursorTrendChartView: View {
  let samples: [CursorUsageSample]
  let language: AppLanguage
  let now: Date

  @State private var selectedDate: Date?

  private var selectedSample: CursorUsageSample? {
    guard let selectedDate else { return nil }
    return CursorTrendProcessor.nearestSample(to: selectedDate, samples: samples)
  }

  private var points: [CursorTrendPoint] {
    CursorTrendProcessor.points(samples)
  }

  private var xDomain: ClosedRange<Date> {
    now.addingTimeInterval(-CursorTrendProcessor.chartWindowHours * 3600)...now
  }

  /// 统一趋势摘要所需的变化值；摘要前缀由供应商趋势卡片统一渲染。
  var usageChangeValue: String? {
    let firstParty = points.filter { $0.channel == .firstParty }
    guard let first = firstParty.first, let last = firstParty.last, first.id != last.id else {
      return nil
    }
    let delta = last.percent - first.percent
    return "\(delta >= 0 ? "+" : "")\(delta)%"
  }

  private var exhaustionEstimate: some View {
    HStack {
      Spacer(minLength: 0)
      if let seconds = UsageExhaustionEstimator.estimate(
        points: samples.map {
          UsageExhaustionPoint(date: $0.bucketStart, remaining: Double($0.remainingPercent))
        },
        now: now
      ) {
        Text(
          L10n.string(
            .trendEstimateWeekly,
            language: language,
            UsageExhaustionEstimator.formattedDuration(seconds, language: language)
          )
        )
        .font(AppTypography.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.trailing)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
      }
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
    Chart {
      ForEach(points) { point in
        LineMark(
          x: .value(L10n.string(.chartTime, language: language), point.bucketStart),
          y: .value(L10n.string(.chartRemaining, language: language), point.percent),
          series: .value(
            L10n.string(.chartChannel, language: language),
            "\(point.seriesName(language: language))/\(point.segment)"
          )
        )
        .foregroundStyle(by: .value(
          L10n.string(.chartChannel, language: language),
          point.seriesName(language: language)
        ))
        .lineStyle(StrokeStyle(lineWidth: 2))
      }

      if let selectedSample {
        RuleMark(
          x: .value(L10n.string(.chartSelectedTime, language: language), selectedSample.bucketStart)
        )
        .foregroundStyle(.secondary)
        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
      }
    }
    .chartXScale(domain: xDomain)
    .chartYScale(domain: 0...100)
    .chartXAxis {
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
    .chartYAxis {
      AxisMarks(position: .leading) { value in
        AxisGridLine().foregroundStyle(.quaternary)
        AxisValueLabel {
          if let percent = value.as(Double.self) {
            Text("\(Int(percent))%")
              .font(AppTypography.caption)
          }
        }
      }
    }
    .chartForegroundStyleScale(domain: [
      L10n.string(.cursorTrendFirstParty, language: language),
      L10n.string(.cursorTrendApi, language: language),
    ]) { name in
      name == L10n.string(.cursorTrendFirstParty, language: language) ? .blue : .orange
    }
    .chartLegend(.visible)
    .frame(height: 160)
    .trendChartSelection($selectedDate)
    .accessibilityLabel(L10n.string(.a11yCursorLegend, language: language))
  }

  private func selectionDetail(_ sample: CursorUsageSample) -> some View {
    var values = [
      TrendChartSelectionDetail.valueText(
        label: L10n.string(.cursorTrendFirstParty, language: language),
        value: "\(sample.remainingPercent)%",
        language: language
      ),
    ]
    if let apiRemainingPercent = sample.apiRemainingPercent {
      values.append(
        TrendChartSelectionDetail.valueText(
          label: L10n.string(.cursorTrendApi, language: language),
          value: "\(apiRemainingPercent)%",
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

  private func axisLabel(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = language.locale
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = language == .simplifiedChinese ? "M/d HH:mm" : "MMM d HH:mm"
    return formatter.string(from: date)
  }
}

/// 图表数据转换（纯函数，便于测试）。
enum CursorTrendProcessor {
  /// 相邻样本间隔超过 20 分钟视为数据缺口。
  static let gapThreshold: TimeInterval = 20 * 60
  static let chartWindowHours: TimeInterval = TimeInterval(UsageHistoryWindow.hours)

  /// 把历史样本转为图数据点：第一方模型线来自 remainingPercent，
  /// API 通道线来自 apiRemainingPercent（旧记录无该字段则跳过）。
  /// 每个通道独立按时间升序、同桶保留最新 observedAt、间隔超阈值断开分段。
  static func points(_ samples: [CursorUsageSample]) -> [CursorTrendPoint] {
    let firstParty = makeSeries(
      samples.map { (percent: $0.remainingPercent, bucketStart: $0.bucketStart, observedAt: $0.observedAt) },
      channel: .firstParty
    )
    let apiSamples = samples.compactMap { sample -> (Int, Date, Date)? in
      guard let apiPercent = sample.apiRemainingPercent else { return nil }
      return (apiPercent, sample.bucketStart, sample.observedAt)
    }
    let api = makeSeries(
      apiSamples.map { (percent: $0.0, bucketStart: $0.1, observedAt: $0.2) },
      channel: .api
    )
    return (firstParty + api).sorted { $0.bucketStart < $1.bucketStart }
  }

  private static func makeSeries(
    _ entries: [(percent: Int, bucketStart: Date, observedAt: Date)],
    channel: CursorTrendPoint.Channel
  ) -> [CursorTrendPoint] {
    var newestByBucket: [Int64: (percent: Int, bucketStart: Date, observedAt: Date)] = [:]
    for entry in entries {
      let bucketSeconds = Int64(entry.bucketStart.timeIntervalSince1970)
      if let existing = newestByBucket[bucketSeconds], existing.observedAt > entry.observedAt {
        continue
      }
      newestByBucket[bucketSeconds] = entry
    }

    let sorted = newestByBucket.values.sorted { $0.bucketStart < $1.bucketStart }
    var result: [CursorTrendPoint] = []
    var segmentIndex = 0
    var currentSegment: [(percent: Int, bucketStart: Date)] = []

    func flush(segment: Int) {
      result.append(contentsOf: currentSegment.map {
        CursorTrendPoint(
          id: "\(Int64($0.bucketStart.timeIntervalSince1970))/\(channel)/\(segment)",
          bucketStart: $0.bucketStart,
          percent: $0.percent,
          channel: channel,
          segment: segment
        )
      })
      currentSegment = []
    }

    for entry in sorted {
      if let last = currentSegment.last, entry.bucketStart.timeIntervalSince(last.bucketStart) > gapThreshold {
        flush(segment: segmentIndex)
        segmentIndex += 1
      }
      currentSegment.append((entry.percent, entry.bucketStart))
    }
    flush(segment: segmentIndex)
    return result
  }

  /// 保留用于向后兼容的分段逻辑（测试沿用）。
  static func segments(_ samples: [CursorUsageSample]) -> [[CursorUsageSample]] {
    let sorted = newestSamples(samples)
    guard sorted.count >= 2 else { return [] }

    var result: [[CursorUsageSample]] = []
    var current: [CursorUsageSample] = [sorted[0]]
    for sample in sorted.dropFirst() {
      let gap = sample.bucketStart.timeIntervalSince(current.last!.bucketStart)
      if gap > gapThreshold {
        result.append(current)
        current = []
      }
      current.append(sample)
    }
    result.append(current)
    return result.filter { $0.count >= 2 }
  }

  /// 选择距离给定时间最近的、与图表相同去重规则处理后的样本。
  static func nearestSample(
    to date: Date,
    samples: [CursorUsageSample]
  ) -> CursorUsageSample? {
    newestSamples(samples).min {
      abs($0.bucketStart.timeIntervalSince(date)) < abs($1.bucketStart.timeIntervalSince(date))
    }
  }

  private static func newestSamples(_ samples: [CursorUsageSample]) -> [CursorUsageSample] {
    var newestByBucket: [Int64: CursorUsageSample] = [:]
    for sample in samples {
      let bucketSeconds = Int64(sample.bucketStart.timeIntervalSince1970)
      if let existing = newestByBucket[bucketSeconds], existing.observedAt > sample.observedAt {
        continue
      }
      newestByBucket[bucketSeconds] = sample
    }
    return newestByBucket.values.sorted { $0.bucketStart < $1.bucketStart }
  }
}
