import Charts
import SwiftUI

/// Command Code 趋势折线图中的一条数据线。
struct CommandCodeTrendPoint: Identifiable {
  enum Kind: Hashable {
    case overall
    case fiveHour
    case weekly
  }

  let id: String
  let bucketStart: Date
  /// 剩余百分比（0...100）。
  let percent: Int
  let kind: Kind
  let segment: Int
  /// 已本地化的系列名（图例文案），构建数据点时预先算好。
  let seriesName: String
  /// 折线 series 标识：系列名 + 分段号，预计算避免图表内字符串插值。
  let seriesID: String
}

/// Command Code 用量趋势折线图：最近 14 天剩余百分比（Apple Swift Charts）。
/// 整体剩余额度、5 小时窗口、每周窗口各一条折线；窗口数据缺失时不画该线。
/// 缺口超过 20 分钟会断开连线。
struct CommandCodeTrendChartView: View {
  let samples: [CommandCodeUsageSample]
  let language: AppLanguage
  let now: Date

  @State private var selectedDate: Date?

  private var selectedSample: CommandCodeUsageSample? {
    guard let selectedDate else { return nil }
    return CommandCodeTrendProcessor.nearestSample(to: selectedDate, samples: samples)
  }

  private var points: [CommandCodeTrendPoint] {
    CommandCodeTrendProcessor.points(samples, language: language)
  }

  private var xDomain: ClosedRange<Date> {
    now.addingTimeInterval(-CommandCodeTrendProcessor.chartWindowHours * 3600)...now
  }

  /// 统一趋势摘要所需的变化值；摘要前缀由供应商趋势卡片统一渲染。
  var usageChangeValue: String? {
    let overall = points.filter { $0.kind == .overall }
    guard let first = overall.first, let last = overall.last, first.id != last.id else {
      return nil
    }
    let delta = last.percent - first.percent
    return "\(delta >= 0 ? "+" : "")\(delta)%"
  }

  @ViewBuilder
  private var exhaustionEstimate: some View {
    if let seconds = UsageExhaustionEstimator.estimate(
      points: samples.map {
        UsageExhaustionPoint(date: $0.bucketStart, remaining: Double($0.remainingPercent))
      },
      now: now
    ) {
      Text(
        L10n.string(
          .trendEstimateMonthly,
          language: language,
          UsageExhaustionEstimator.formattedDuration(seconds, language: language)
        )
      )
      .font(AppTypography.caption)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.trailing)
      .lineLimit(2)
      .minimumScaleFactor(0.75)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .trailing)
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
    let chart = Chart {
      ForEach(points) { point in
        LineMark(
          x: .value(L10n.string(.chartTime, language: language), point.bucketStart),
          y: .value(L10n.string(.chartRemaining, language: language), point.percent),
          series: .value(L10n.string(.chartChannel, language: language), point.seriesID)
        )
        .foregroundStyle(by: .value(L10n.string(.chartChannel, language: language), point.seriesName))
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
    let chartWithAxes = chart
      .chartXScale(domain: xDomain)
      .chartYScale(domain: 0...100)
    return chartWithAxes
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
        L10n.string(.chartRemaining, language: language),
        L10n.string(.commandCodeTrendFiveHour, language: language),
        L10n.string(.commandCodeTrendWeekly, language: language),
      ]) { name -> Color in
        switch name {
        case L10n.string(.chartRemaining, language: language):
          return .blue
        case L10n.string(.commandCodeTrendFiveHour, language: language):
          return .green
        default:
          return .orange
        }
      }
      .chartLegend(position: .bottom, alignment: .leading, spacing: 12)
      .frame(height: 160)
      .trendChartSelection($selectedDate)
      .accessibilityLabel(L10n.string(.a11yCommandCodeLegend, language: language))
  }

  private func selectionDetail(_ sample: CommandCodeUsageSample) -> some View {
    var values = [
      TrendChartSelectionDetail.valueText(
        label: L10n.string(.chartRemaining, language: language),
        value: "\(sample.remainingPercent)%",
        language: language
      ),
    ]
    if let fiveHourUsed = sample.fiveHourUsedPercent {
      values.append(
        TrendChartSelectionDetail.valueText(
          label: L10n.string(.commandCodeTrendFiveHour, language: language),
          value: "\(max(0, min(100, 100 - fiveHourUsed)))%",
          language: language
        )
      )
    }
    if let weeklyUsed = sample.weeklyUsedPercent {
      values.append(
        TrendChartSelectionDetail.valueText(
          label: L10n.string(.commandCodeTrendWeekly, language: language),
          value: "\(max(0, min(100, 100 - weeklyUsed)))%",
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
enum CommandCodeTrendProcessor {
  /// 相邻样本间隔超过 20 分钟视为数据缺口。
  static let gapThreshold: TimeInterval = 20 * 60
  static let chartWindowHours: TimeInterval = TimeInterval(UsageHistoryWindow.hours)

  /// 把历史样本转为图数据点：每条线按时间升序、同桶保留最新 observedAt、
  /// 间隔超阈值断开分段。窗口字段缺失的样本不进入对应线。
  static func points(
    _ samples: [CommandCodeUsageSample],
    language: AppLanguage
  ) -> [CommandCodeTrendPoint] {
    let overall = makeSeries(
      samples.compactMap { sample in
        (sample.bucketStart, sample.observedAt, sample.remainingPercent)
      },
      kind: .overall,
      language: language
    )
    let fiveHour = makeSeries(
      samples.compactMap { sample -> (Date, Date, Int)? in
        guard let used = sample.fiveHourUsedPercent else { return nil }
        return (sample.bucketStart, sample.observedAt, max(0, min(100, 100 - used)))
      },
      kind: .fiveHour,
      language: language
    )
    let weekly = makeSeries(
      samples.compactMap { sample -> (Date, Date, Int)? in
        guard let used = sample.weeklyUsedPercent else { return nil }
        return (sample.bucketStart, sample.observedAt, max(0, min(100, 100 - used)))
      },
      kind: .weekly,
      language: language
    )
    return (overall + fiveHour + weekly).sorted { $0.bucketStart < $1.bucketStart }
  }

  private static func makeSeries(
    _ entries: [(bucketStart: Date, observedAt: Date, percent: Int)],
    kind: CommandCodeTrendPoint.Kind,
    language: AppLanguage
  ) -> [CommandCodeTrendPoint] {
    var newestByBucket: [Int64: (Date, Date, Int)] = [:]
    for entry in entries {
      let bucketSeconds = Int64(entry.bucketStart.timeIntervalSince1970)
      if let existing = newestByBucket[bucketSeconds], existing.1 > entry.observedAt {
        continue
      }
      newestByBucket[bucketSeconds] = (entry.bucketStart, entry.observedAt, entry.percent)
    }

    let sorted = newestByBucket.values.sorted { $0.0 < $1.0 }
    var result: [CommandCodeTrendPoint] = []
    var segmentIndex = 0
    var currentSegment: [(Date, Int)] = []

    func flush(segment: Int) {
      let seriesName: String
      switch kind {
      case .overall:
        seriesName = L10n.string(.chartRemaining, language: language)
      case .fiveHour:
        seriesName = L10n.string(.commandCodeTrendFiveHour, language: language)
      case .weekly:
        seriesName = L10n.string(.commandCodeTrendWeekly, language: language)
      }
      result.append(contentsOf: currentSegment.map {
        CommandCodeTrendPoint(
          id: "\(Int64($0.0.timeIntervalSince1970))/\(kind)/\(segment)",
          bucketStart: $0.0,
          percent: $0.1,
          kind: kind,
          segment: segment,
          seriesName: seriesName,
          seriesID: "\(seriesName)/\(segment)"
        )
      })
      currentSegment = []
    }

    for entry in sorted {
      if let last = currentSegment.last, entry.0.timeIntervalSince(last.0) > gapThreshold {
        flush(segment: segmentIndex)
        segmentIndex += 1
      }
      currentSegment.append((entry.0, entry.2))
    }
    flush(segment: segmentIndex)
    return result
  }

  /// 选择距离给定时间最近的、与图表相同去重规则处理后的样本。
  static func nearestSample(
    to date: Date,
    samples: [CommandCodeUsageSample]
  ) -> CommandCodeUsageSample? {
    newestSamples(samples).min {
      abs($0.bucketStart.timeIntervalSince(date)) < abs($1.bucketStart.timeIntervalSince(date))
    }
  }

  private static func newestSamples(_ samples: [CommandCodeUsageSample]) -> [CommandCodeUsageSample] {
    var newestByBucket: [Int64: CommandCodeUsageSample] = [:]
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
