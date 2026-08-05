import Charts
import SwiftUI

/// Vultr 趋势图：同一张图用左轴显示剩余流量 GB，用右轴显示剩余额度 USD。
struct VPSTrendChartView: View {
  let samples: [VPSUsageSample]
  let language: AppLanguage
  let now: Date
  let currentRemainingGB: Double?
  let cycleStart: Date?
  let cycleEnd: Date?

  @State private var preparedModel: VPSUsageTrendProcessor.ChartModel?
  @State private var selectedDate: Date?

  init(
    samples: [VPSUsageSample],
    language: AppLanguage,
    now: Date,
    currentRemainingGB: Double? = nil,
    cycleStart: Date? = nil,
    cycleEnd: Date? = nil
  ) {
    self.samples = samples
    self.language = language
    self.now = now
    self.currentRemainingGB = currentRemainingGB
    self.cycleStart = cycleStart
    self.cycleEnd = cycleEnd
    // 样本集未变化时直接用缓存渲染，切回本页不会闪等待文案。
    _preparedModel = State(
      initialValue: VPSUsageTrendProcessor.cachedChartModel(
        for: VPSUsageTrendProcessor.chartModelCacheKey(samples: samples, now: now)
      )
    )
  }

  /// 图表数据与样本集不变时无需重新准备；不把当前分钟纳入 ID，
  /// 否则每次刷新/跨分钟都会把整张图重置为等待状态再重建，造成可见闪烁。
  private var preparationID: String {
    let latest = samples.last
    let observedAt = latest?.observedAt.timeIntervalSince1970 ?? -1
    return "\(samples.count)-\(latest?.id ?? "empty")-\(observedAt)"
  }

  private var selectedSample: VPSUsageSample? {
    guard let selectedDate else { return nil }
    return VPSUsageTrendProcessor.nearestSample(to: selectedDate, samples: samples)
  }

  private var trafficForecast: VPSTrafficForecast? {
    guard let cycleEnd else { return nil }
    return VPSTrafficForecastEstimator.estimate(
      samples: samples,
      currentRemainingGB: currentRemainingGB,
      cycleStart: cycleStart,
      cycleEnd: cycleEnd,
      now: now
    )
  }

  var usageChangeValue: String? {
    guard let summary = VPSUsageTrendProcessor.summary(samples: samples) else { return nil }
    return "\(trafficTitle): \(VPSUsageTrendProcessor.signedGB(summary.traffic)) · "
      + "\(creditTitle): \(VPSUsageTrendProcessor.signedUSD(summary.credit))"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let model = preparedModel {
        if model.canDraw {
          exhaustionEstimate
          chartView(model: model)
          if let selectedSample {
            selectionDetail(selectedSample)
          }
        } else {
          waitingText
        }
      } else {
        waitingText
      }
    }
    .task(id: preparationID) {
      preparedModel = nil
      let capturedSamples = samples
      let capturedNow = now
      let model = await Task.detached(priority: .userInitiated) {
        VPSUsageTrendProcessor.chartModel(samples: capturedSamples, now: capturedNow)
      }.value
      guard !Task.isCancelled else { return }
      preparedModel = model
      VPSUsageTrendProcessor.storeChartModel(
        model,
        for: VPSUsageTrendProcessor.chartModelCacheKey(samples: capturedSamples, now: capturedNow)
      )
    }
  }

  /// 等待期间与图表保持相同的高度（180pt 图表 + 图例），
  /// 避免页面高度在等待与就绪之间来回跳动。
  private var waitingText: some View {
    ZStack {
      Rectangle().fill(.clear)
      Text(L10n.string(.vpsTrendWaiting, language: language))
        .font(AppTypography.caption)
        .foregroundStyle(.secondary)
    }
    .frame(height: 180)
    .frame(maxWidth: .infinity)
  }

  private var exhaustionEstimate: some View {
    Text(exhaustionEstimateText)
      .font(AppTypography.caption)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.trailing)
      .lineLimit(2)
      .minimumScaleFactor(0.75)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .trailing)
  }

  private var exhaustionEstimateText: String {
    guard let forecast = trafficForecast else {
      return L10n.string(.vpsTrendEstimateUnavailable, language: language)
    }
    if let seconds = forecast.exhaustionInterval {
      return L10n.string(
        .vpsTrendEstimateTraffic,
        language: language,
        UsageExhaustionEstimator.formattedDuration(seconds, language: language)
      )
    }
    if let projected = forecast.projectedRemainingAtCycleEndGB {
      return L10n.string(
        .vpsTrendEstimateCycleEnd,
        language: language,
        formattedGB(max(projected, 0))
      )
    }
    return L10n.string(.vpsTrendEstimateUnavailable, language: language)
  }

  private var trafficTitle: String {
    L10n.string(.vpsTrendTraffic, language: language)
  }

  private var creditTitle: String {
    L10n.string(.vpsTrendCredit, language: language)
  }

  private func chartView(model: VPSUsageTrendProcessor.ChartModel) -> some View {
    let timeLabel = L10n.string(.chartTime, language: language)
    let trafficSeriesName = trafficTitle
    let creditSeriesName = creditTitle
    return Chart {
      ForEach(model.samples) { sample in
        LineMark(
          x: .value(timeLabel, sample.bucketStart),
          y: .value(
            trafficSeriesName,
            VPSUsageTrendProcessor.normalized(
              sample.remainingBandwidthGB,
              in: model.trafficDomain
            )
          ),
          series: .value("series", trafficSeriesName)
        )
        .foregroundStyle(by: .value("series", trafficSeriesName))
        .lineStyle(StrokeStyle(lineWidth: 2))

        LineMark(
          x: .value(timeLabel, sample.bucketStart),
          y: .value(
            creditSeriesName,
            VPSUsageTrendProcessor.normalized(
              sample.availableCreditUSD,
              in: model.creditDomain
            )
          ),
          series: .value("series", creditSeriesName)
        )
        .foregroundStyle(by: .value("series", creditSeriesName))
        .lineStyle(StrokeStyle(lineWidth: 2))
      }

      if let selectedSample {
        RuleMark(
          x: .value(
            L10n.string(.chartSelectedTime, language: language),
            selectedSample.bucketStart
          )
        )
        .foregroundStyle(.secondary)
        .lineStyle(TrendChartSelectionStyle.rule)
      }
    }
    .chartXScale(domain: model.xDomain)
    .chartYScale(domain: 0...1)
    .chartForegroundStyleScale(
      domain: [trafficTitle, creditTitle],
      range: [.blue, .purple]
    )
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
      AxisMarks(position: .leading, values: normalizedTicks) { value in
        AxisGridLine().foregroundStyle(.quaternary)
        AxisValueLabel {
          if let normalized = value.as(Double.self) {
            Text(formattedGB(denormalized(normalized, in: model.trafficDomain)))
              .font(AppTypography.caption)
          }
        }
      }
      AxisMarks(position: .trailing, values: normalizedTicks) { value in
        AxisValueLabel {
          if let normalized = value.as(Double.self) {
            Text(formattedUSD(denormalized(normalized, in: model.creditDomain)))
              .font(AppTypography.caption)
          }
        }
      }
    }
    .chartLegend(position: .bottom, alignment: .leading, spacing: 12)
    .frame(height: 180)
    .trendChartSelection($selectedDate)
    .accessibilityLabel(L10n.string(.a11yVPSTrend, language: language))
  }

  private var normalizedTicks: [Double] {
    [0, 0.25, 0.5, 0.75, 1]
  }

  private func denormalized(_ value: Double, in domain: ClosedRange<Double>) -> Double {
    domain.lowerBound + value * (domain.upperBound - domain.lowerBound)
  }

  private func formattedGB(_ value: Double) -> String {
    String(format: "%.0f GB", value)
  }

  private func formattedUSD(_ value: Double) -> String {
    String(format: "$%.2f", value)
  }

  private func axisLabel(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = language.locale
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = language == .simplifiedChinese ? "M/d HH:mm" : "MMM d HH:mm"
    return formatter.string(from: date)
  }

  private func selectionDetail(_ sample: VPSUsageSample) -> some View {
    TrendChartSelectionDetail(
      date: sample.bucketStart,
      language: language,
      values: [
        TrendChartSelectionDetail.valueText(
          label: trafficTitle,
          value: formattedGB(sample.remainingBandwidthGB),
          language: language
        ),
        TrendChartSelectionDetail.valueText(
          label: creditTitle,
          value: formattedUSD(sample.availableCreditUSD),
          language: language
        )
      ]
    )
  }
}
