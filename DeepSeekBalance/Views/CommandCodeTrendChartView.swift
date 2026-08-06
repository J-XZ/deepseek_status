import Charts
import SwiftUI

/// 折线图数据点：剩余百分比。
struct CommandCodeTrendPoint: Identifiable {
  let id: String
  let bucketStart: Date
  let percent: Int
  let segment: Int
}

/// Command Code 用量趋势折线图：最近 14 天剩余百分比（Apple Swift Charts）。
/// 缺口超过 20 分钟会断开连线。图表下方附带 5 小时/每周窗口限制状态。
struct CommandCodeTrendChartView: View {
  let samples: [CommandCodeUsageSample]
  let language: AppLanguage
  let now: Date
  var windowLimits: CommandCodeWindowLimits? = nil

  @State private var selectedDate: Date?

  private var selectedSample: CommandCodeUsageSample? {
    guard let selectedDate else { return nil }
    return CommandCodeTrendProcessor.nearestSample(to: selectedDate, samples: samples)
  }

  private var points: [CommandCodeTrendPoint] {
    CommandCodeTrendProcessor.points(samples)
  }

  private var xDomain: ClosedRange<Date> {
    now.addingTimeInterval(-CommandCodeTrendProcessor.chartWindowHours * 3600)...now
  }

  /// 统一趋势摘要所需的变化值；摘要前缀由供应商趋势卡片统一渲染。
  var usageChangeValue: String? {
    guard let first = points.first, let last = points.last, first.id != last.id else {
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
      windowLimitsSummary
      if let selectedSample {
        selectionDetail(selectedSample)
      }
    }
  }

  private var chartView: some View {
    let remainingTitle = L10n.string(.chartRemaining, language: language)
    return Chart {
      ForEach(points) { point in
        LineMark(
          x: .value(L10n.string(.chartTime, language: language), point.bucketStart),
          y: .value(L10n.string(.chartRemaining, language: language), point.percent),
          series: .value(L10n.string(.chartChannel, language: language), "\(remainingTitle)/\(point.segment)")
        )
        .foregroundStyle(by: .value(L10n.string(.chartChannel, language: language), remainingTitle))
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
    .chartForegroundStyleScale(
      domain: [remainingTitle],
      range: [.blue]
    )
    .chartLegend(position: .bottom, alignment: .leading, spacing: 12)
    .frame(height: 160)
    .trendChartSelection($selectedDate)
    .accessibilityLabel(L10n.string(.a11yCommandCodeLegend, language: language))
  }

  private func selectionDetail(_ sample: CommandCodeUsageSample) -> some View {
    TrendChartSelectionDetail(
      date: sample.bucketStart,
      language: language,
      values: [
        TrendChartSelectionDetail.valueText(
          label: L10n.string(.commandCodeTrendRemaining, language: language),
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

  // MARK: - 窗口限制状态

  /// 5 小时 / 每周窗口状态：已用金额、上限、进度与重置时间。
  /// 命中限制（exceeded）时整行红色高亮；API 未返回窗口数据时不显示。
  @ViewBuilder
  private var windowLimitsSummary: some View {
    let fiveHour = windowLimits?.fiveHour
    let weekly = windowLimits?.weekly
    if fiveHour != nil || weekly != nil {
      VStack(alignment: .leading, spacing: 4) {
        if let fiveHour {
          windowLimitRow(
            title: L10n.string(.commandCodeWindowFiveHour, language: language),
            limit: fiveHour
          )
        }
        if let weekly {
          windowLimitRow(
            title: L10n.string(.commandCodeWindowWeekly, language: language),
            limit: weekly
          )
        }
      }
      .padding(.top, 2)
    }
  }

  private func windowLimitRow(title: String, limit: CommandCodeWindowLimit) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        Text(title)
          .font(AppTypography.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        if limit.isExceeded {
          Text(L10n.string(.commandCodeTrendWindowExceeded, language: language))
            .font(AppTypography.badge)
            .foregroundStyle(.red)
        }
        Spacer()
        Text(windowLimitText(limit))
          .font(AppTypography.caption.monospacedDigit())
          .foregroundStyle(limit.isExceeded ? .red : .secondary)
      }
      windowLimitBar(limit)
      if let resetAt = limit.resetAtDate {
        Text(
          L10n.string(
            .commandCodeWindowResetAt,
            language: language,
            resetAt.formatted(
              Date.FormatStyle(date: .abbreviated, time: .shortened).locale(language.locale)
            )
          )
        )
        .font(AppTypography.caption)
        .foregroundStyle(.secondary)
      }
    }
  }

  private func windowLimitText(_ limit: CommandCodeWindowLimit) -> String {
    let used = CommandCodeUsageFormatter.formatUSD(limit.used, locale: language.locale) ?? "—"
    let cap = CommandCodeUsageFormatter.formatUSD(limit.cap, locale: language.locale) ?? "—"
    return L10n.string(.commandCodeTrendWindowUsed, language: language, used, cap)
  }

  /// 窗口已用进度条：低于 100% 蓝色，超出上限红色。
  private func windowLimitBar(_ limit: CommandCodeWindowLimit) -> some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule()
          .fill(Color.secondary.opacity(0.25))
        Capsule()
          .fill(limit.isExceeded ? Color.red : Color.blue)
          .frame(width: geo.size.width * CGFloat(min(max(limit.usedPercent ?? 0, 0), 100)) / 100)
      }
    }
    .frame(height: 5)
  }
}

/// 图表数据转换（纯函数，便于测试）。
enum CommandCodeTrendProcessor {
  /// 相邻样本间隔超过 20 分钟视为数据缺口。
  static let gapThreshold: TimeInterval = 20 * 60
  static let chartWindowHours: TimeInterval = TimeInterval(UsageHistoryWindow.hours)

  /// 把历史样本转为图数据点：按时间升序、同桶保留最新 observedAt、间隔超阈值断开分段。
  static func points(_ samples: [CommandCodeUsageSample]) -> [CommandCodeTrendPoint] {
    var newestByBucket: [Int64: CommandCodeUsageSample] = [:]
    for sample in samples {
      let bucketSeconds = Int64(sample.bucketStart.timeIntervalSince1970)
      if let existing = newestByBucket[bucketSeconds], existing.observedAt > sample.observedAt {
        continue
      }
      newestByBucket[bucketSeconds] = sample
    }

    let sorted = newestByBucket.values.sorted { $0.bucketStart < $1.bucketStart }
    var result: [CommandCodeTrendPoint] = []
    var segmentIndex = 0
    var currentSegment: [CommandCodeUsageSample] = []

    func flush(segment: Int) {
      result.append(contentsOf: currentSegment.map {
        CommandCodeTrendPoint(
          id: "\(Int64($0.bucketStart.timeIntervalSince1970))/\(segment)",
          bucketStart: $0.bucketStart,
          percent: $0.remainingPercent,
          segment: segment
        )
      })
      currentSegment = []
    }

    for sample in sorted {
      if let last = currentSegment.last,
        sample.bucketStart.timeIntervalSince(last.bucketStart) > gapThreshold
      {
        flush(segment: segmentIndex)
        segmentIndex += 1
      }
      currentSegment.append(sample)
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
