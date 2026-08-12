import Charts
import SwiftUI

/// Codex 用量趋势折线图：最近 14 天剩余百分比（Apple Swift Charts）。
/// 缺口超过 20 分钟会断开连线。
struct CodexTrendChartView: View {
  let samples: [CodexUsageSample]
  let language: AppLanguage
  let now: Date
  let period: TrendPeriod
  let weeklyWindow: CodexUsageWindow?

  @State private var selectedDate: Date?
  @Environment(\.trendChartHighContrast) private var highContrast

  init(
    samples: [CodexUsageSample],
    language: AppLanguage,
    now: Date,
    period: TrendPeriod = .fourteenDays,
    weeklyWindow: CodexUsageWindow? = nil
  ) {
    self.samples = samples
    self.language = language
    self.now = now
    self.period = period
    self.weeklyWindow = weeklyWindow
  }

  private var periodSamples: [CodexUsageSample] {
    TrendPeriod.filtered(samples, period: period, now: now) { $0.bucketStart }
  }

  private var selectedSample: CodexUsageSample? {
    guard let selectedDate else { return nil }
    return CodexTrendProcessor.nearestSample(to: selectedDate, samples: periodSamples)
  }

  private var segments: [[CodexUsageSample]] {
    CodexTrendProcessor.segments(periodSamples)
  }

  private var xDomain: ClosedRange<Date> {
    period.chartDomain(now: now)
  }

  /// 1 小时 / 3 小时周期展示最近用量速度对比；数据或周窗口不足时返回 nil。
  private var speedResult: CodexUsageSpeedEvaluator.Result? {
    guard period == .threeHours || period == .oneHour else { return nil }
    // 绿线对齐蓝线实际可见分段的首末点：segments 会丢弃孤立点，
    // 若直接取窗口内全局首末样本，可能落在蓝线未绘制的点上。
    guard let visibleFirst = segments.first?.first?.bucketStart,
      let visibleLast = segments.last?.last?.bucketStart
    else { return nil }
    return CodexUsageSpeedEvaluator.evaluate(
      samples: periodSamples,
      window: weeklyWindow,
      now: now,
      windowSeconds: period.duration,
      firstSample: visibleFirst,
      lastSample: visibleLast
    )
  }

  /// 统一趋势摘要所需的变化值；摘要前缀由供应商趋势卡片统一渲染。
  var usageChangeValue: String? {
    let ordered = samples.sorted { $0.bucketStart < $1.bucketStart }
    guard let first = ordered.first, let last = ordered.last, first.id != last.id else {
      return nil
    }
    let delta = last.remainingPercent - first.remainingPercent
    return "\(delta >= 0 ? "+" : "")\(delta)%"
  }

  @ViewBuilder
  private var exhaustionEstimate: some View {
    if let seconds = UsageExhaustionEstimator.estimate(
      points: periodSamples.map {
        UsageExhaustionPoint(date: $0.bucketStart, remaining: Double($0.remainingPercent))
      },
      now: now
    ) {
      Text(exhaustionEstimateText(seconds))
        .font(AppTypography.caption)
        .foregroundStyle(TrendChartPalette.secondaryText(highContrast: highContrast))
        .multilineTextAlignment(.trailing)
        .lineLimit(2)
        .minimumScaleFactor(0.75)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
  }

  private func exhaustionEstimateText(_ seconds: TimeInterval) -> String {
    if UsageExhaustionEstimator.isExhausted(seconds) {
      return L10n.string(.trendEstimateExhausted, language: language)
    }
    return L10n.string(
      .trendEstimateWeekly,
      language: language,
      UsageExhaustionEstimator.formattedDuration(seconds, language: language)
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      exhaustionEstimate
      chartView
      if let speedResult {
        HStack(spacing: 12) {
          legendLine(label: speedConclusionText(speedResult.comparison), color: .blue, dash: [])
          legendLine(
            label: L10n.string(.codexIdealSpeedLegend, language: language),
            color: Color.green.opacity(0.9),
            dash: [6, 4]
          )
          Spacer()
        }
        .font(AppTypography.caption)
      }
      if let selectedSample {
        selectionDetail(selectedSample)
      }
    }
  }

  private var chartView: some View {
    let remainingTitle = L10n.string(.chartRemaining, language: language)
    return Chart {
      ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
        ForEach(segment) { sample in
          LineMark(
            x: .value(L10n.string(.chartTime, language: language), sample.bucketStart),
            y: .value(L10n.string(.chartRemaining, language: language), sample.remainingPercent),
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
        .foregroundStyle(TrendChartPalette.selection(highContrast: highContrast))
        .lineStyle(TrendChartSelectionStyle.rule)
      }

      if let speedResult {
        LineMark(
          x: .value(L10n.string(.chartTime, language: language), speedResult.idealLineStart),
          y: .value(
            L10n.string(.chartRemaining, language: language),
            speedResult.idealLineStartRemaining
          ),
          series: .value(L10n.string(.chartSegment, language: language), "ideal-speed")
        )
        .foregroundStyle(Color.green.opacity(0.9))
        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 4]))

        LineMark(
          x: .value(L10n.string(.chartTime, language: language), speedResult.idealLineEnd),
          y: .value(
            L10n.string(.chartRemaining, language: language),
            speedResult.idealLineEndRemaining
          ),
          series: .value(L10n.string(.chartSegment, language: language), "ideal-speed")
        )
        .foregroundStyle(Color.green.opacity(0.9))
        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
      }
    }
    .chartXScale(domain: xDomain)
    .chartYScale(domain: 0...100)
    .chartXAxis {
      AxisMarks(values: .automatic(desiredCount: 4)) { value in
        AxisGridLine().foregroundStyle(TrendChartPalette.grid(highContrast: highContrast))
        AxisValueLabel {
          if let date = value.as(Date.self) {
            Text(axisLabel(for: date))
              .font(AppTypography.caption)
              .foregroundStyle(TrendChartPalette.axisText(highContrast: highContrast))
              .lineLimit(1)
          }
        }
      }
    }
    .chartYAxis {
      AxisMarks(position: .leading) { value in
        AxisGridLine().foregroundStyle(TrendChartPalette.grid(highContrast: highContrast))
        AxisValueLabel {
          if let percent = value.as(Double.self) {
            Text("\(Int(percent))%")
              .font(AppTypography.caption)
              .foregroundStyle(TrendChartPalette.axisText(highContrast: highContrast))
          }
        }
      }
    }
    .chartForegroundStyleScale(
      domain: [remainingTitle],
      range: [.blue]
    )
    // 3 小时对比图使用下方自定义双线图例；其他周期沿用系统图例。
    .chartLegend(speedResult == nil ? .visible : .hidden)
    .frame(height: 160)
    .trendChartSelection($selectedDate)
    .accessibilityLabel(L10n.string(.a11yCodexLegend, language: language))
  }

  private func selectionDetail(_ sample: CodexUsageSample) -> some View {
    TrendChartSelectionDetail(
      date: sample.bucketStart,
      language: language,
      values: [
        TrendChartSelectionDetail.valueText(
          label: L10n.string(.codexWindowWeekly, language: language),
          value: L10n.string(
            .codexWindowUsedRemaining,
            language: language,
            max(0, min(100, 100 - sample.remainingPercent)),
            sample.remainingPercent
          ),
          language: language
        ),
      ]
    )
  }

  private func speedConclusionText(_ comparison: CodexUsageSpeedEvaluator.Comparison) -> String {
    switch comparison {
    case .faster:
      return L10n.string(.codexSpeedFaster, language: language)
    case .slower:
      return L10n.string(.codexSpeedSlower, language: language)
    case .onPar:
      return L10n.string(.codexSpeedOnPar, language: language)
    }
  }

  private func legendLine(label: String, color: Color, dash: [CGFloat]) -> some View {
    HStack(spacing: 4) {
      Path { path in
        path.move(to: CGPoint(x: 0, y: 3))
        path.addLine(to: CGPoint(x: 20, y: 3))
      }
      .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dash))
      .frame(width: 20, height: 6)
      Text(label)
        .foregroundStyle(TrendChartPalette.secondaryText(highContrast: highContrast))
    }
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
enum CodexTrendProcessor {
  /// 相邻样本间隔超过 20 分钟视为数据缺口。
  static let gapThreshold: TimeInterval = 20 * 60
  static let chartWindowHours: TimeInterval = TimeInterval(UsageHistoryWindow.hours)

  /// 把历史样本转为连续折线段：按时间升序、同桶保留最新 observedAt、
  /// 相邻间隔超过 gapThreshold 时断开。
  static func segments(_ samples: [CodexUsageSample]) -> [[CodexUsageSample]] {
    let sorted = newestSamples(samples)
    guard sorted.count >= 2 else { return [] }

    var result: [[CodexUsageSample]] = []
    var current: [CodexUsageSample] = [sorted[0]]
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
    samples: [CodexUsageSample]
  ) -> CodexUsageSample? {
    newestSamples(samples).min {
      abs($0.bucketStart.timeIntervalSince(date)) < abs($1.bucketStart.timeIntervalSince(date))
    }
  }

  private static func newestSamples(_ samples: [CodexUsageSample]) -> [CodexUsageSample] {
    var newestByBucket: [Int64: CodexUsageSample] = [:]
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
