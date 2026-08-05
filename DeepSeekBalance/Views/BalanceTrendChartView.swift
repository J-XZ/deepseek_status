import Charts
import SwiftUI

/// 最近 14 天余额趋势图（Apple Swift Charts）。
/// 存储按 UTC 排序，X 轴按本地时间显示；缺口超过 20 分钟会断开连线。
struct BalanceTrendChartView: View {
  let samples: [BalanceSample]
  let currency: String
  let language: AppLanguage
  let now: Date

  @State private var preparedModel: BalanceTrendProcessor.ChartModel?
  @State private var selectedDate: Date?

  init(
    samples: [BalanceSample],
    currency: String,
    language: AppLanguage,
    now: Date
  ) {
    self.samples = samples
    self.currency = currency
    self.language = language
    self.now = now
    // 样本集未变化时直接用缓存渲染，切回本页不会闪加载占位。
    _preparedModel = State(
      initialValue: BalanceTrendProcessor.cachedChartModel(
        for: BalanceTrendProcessor.chartModelCacheKey(
          samples: samples,
          currency: currency,
          now: now
        )
      )
    )
  }

  /// 图表数据与样本集不变时无需重新准备；不把当前分钟纳入 ID，
  /// 否则每次刷新/跨分钟都会把整张图重置为等待状态再重建，造成可见闪烁。
  private var preparationID: String {
    let latest = samples.last
    let observedAt = latest?.observedAt.timeIntervalSince1970 ?? -1
    return "\(samples.count)-\(currency)-\(latest?.id ?? "empty")-\(observedAt)"
  }

  private var selectedSample: BalanceSample? {
    guard let selectedDate else { return nil }
    return BalanceTrendProcessor.nearestSample(
      to: selectedDate,
      samples: samples,
      currency: currency
    )
  }

  private func metricColor(_ metric: TrendPoint.Metric) -> Color {
    switch metric {
    case .total:
      return .blue
    case .toppedUp:
      return .green
    case .granted:
      return .orange
    }
  }

  private func metricLineStyle(_ metric: TrendPoint.Metric) -> StrokeStyle {
    switch metric {
    case .total:
      return StrokeStyle(lineWidth: 2.25)
    case .toppedUp, .granted:
      return StrokeStyle(lineWidth: 2)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      exhaustionEstimate
      if let model = preparedModel {
        chartView(model: model)
        legend
        if let selectedSample {
          selectionDetail(selectedSample)
        }
      } else {
        preparingPlaceholder
      }
    }
    .task(id: preparationID) {
      preparedModel = nil
      let capturedSamples = samples
      let capturedCurrency = currency
      let capturedNow = now
      let model = await Task.detached(priority: .userInitiated) {
        BalanceTrendProcessor.chartModel(
          samples: capturedSamples,
          currency: capturedCurrency,
          now: capturedNow
        )
      }.value
      guard !Task.isCancelled else { return }
      preparedModel = model
      BalanceTrendProcessor.storeChartModel(
        model,
        for: BalanceTrendProcessor.chartModelCacheKey(
          samples: capturedSamples,
          currency: capturedCurrency,
          now: capturedNow
        )
      )
    }
  }

  /// 首次准备期间保持与图表相同的高度，避免弹窗高度跳动。
  private var preparingPlaceholder: some View {
    ZStack {
      Rectangle().fill(.clear)
      ProgressView()
        .controlSize(.small)
    }
    .frame(height: 180)
    .frame(maxWidth: .infinity)
  }

  @ViewBuilder
  private var exhaustionEstimate: some View {
    if let seconds = UsageExhaustionEstimator.estimate(
      points: BalanceTrendProcessor.points(for: samples, currency: currency)
        .filter { $0.metric == .total }
        .map { UsageExhaustionPoint(date: $0.date, remaining: $0.value) },
      now: now
    ) {
      Text(
        L10n.string(
          .trendEstimateBalance,
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

  private func chartView(model: BalanceTrendProcessor.ChartModel) -> some View {
    let timeLabel = L10n.string(.chartTime, language: language)
    let amountLabel = L10n.string(.chartAmount, language: language)
    return Chart {
      ForEach(model.segments) { segment in
        ForEach(segment.points) { point in
          LineMark(
            x: .value(timeLabel, point.date),
            y: .value(amountLabel, point.value),
            series: .value(L10n.string(.chartSegment, language: language), segment.id)
          )
          .foregroundStyle(metricColor(segment.metric))
          .lineStyle(metricLineStyle(segment.metric))
        }
      }

      if let selectedSample {
        RuleMark(x: .value(L10n.string(.chartSelectedTime, language: language), selectedSample.bucketStart))
          .foregroundStyle(.secondary)
          .lineStyle(TrendChartSelectionStyle.rule)
      }
    }
    .chartXScale(domain: model.xDomain)
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
      AxisMarks(position: .leading) { _ in
        AxisGridLine().foregroundStyle(.quaternary)
        AxisValueLabel(format: BalanceAxisFormat(currency: currency))
      }
    }
    .chartLegend(.hidden)
    .frame(height: 180)
    .trendChartSelection($selectedDate)
    .accessibilityLabel(
      L10n.string(
        .a11yLegend,
        language: language
      )
    )
  }

  private var legend: some View {
    HStack(spacing: 14) {
      legendItem(label: L10n.string(.legendTotal, language: language), color: .blue, dash: [])
      legendItem(label: L10n.string(.legendToppedUp, language: language), color: .green, dash: [])
      legendItem(label: L10n.string(.legendGranted, language: language), color: .orange, dash: [])
      Spacer()
    }
    .font(AppTypography.caption)
  }

  private func legendItem(label: String, color: Color, dash: [CGFloat]) -> some View {
    HStack(spacing: 4) {
      Path { path in
        path.move(to: CGPoint(x: 0, y: 3))
        path.addLine(to: CGPoint(x: 20, y: 3))
      }
      .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dash))
      .frame(width: 20, height: 6)
      Text(label)
        .foregroundStyle(.secondary)
    }
  }

  private func axisLabel(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = language.locale
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = language == .simplifiedChinese ? "M/d HH:mm" : "MMM d HH:mm"
    return formatter.string(from: date)
  }

  private func selectionDetail(_ sample: BalanceSample) -> some View {
    let previous =
      samples
      .filter { $0.currency == currency && $0.bucketStart < sample.bucketStart }
      .sorted { $0.bucketStart < $1.bucketStart }
      .last
    var values = [
      TrendChartSelectionDetail.valueText(
        label: L10n.string(.balanceTotal, language: language),
        value: BalanceFormatter.format(
          total: sample.totalBalance, currency: currency, locale: language.locale
        ),
        language: language
      ),
      TrendChartSelectionDetail.valueText(
        label: L10n.string(.balanceToppedUp, language: language),
        value: BalanceFormatter.format(
          total: sample.toppedUpBalance, currency: currency, locale: language.locale
        ),
        language: language
      ),
      TrendChartSelectionDetail.valueText(
        label: L10n.string(.balanceGranted, language: language),
        value: BalanceFormatter.format(
          total: sample.grantedBalance, currency: currency, locale: language.locale
        ),
        language: language
      ),
    ]
    if let previous,
      let previousTotal = BalanceTrendProcessor.decimal(from: previous.totalBalance),
      let currentTotal = BalanceTrendProcessor.decimal(from: sample.totalBalance)
    {
      values.append(
        L10n.string(
          .trendSelectionChange,
          language: language,
          BalanceTrendProcessor.deltaText(
            delta: currentTotal - previousTotal,
            currency: currency,
            locale: language.locale
          )
        )
      )
    }
    return TrendChartSelectionDetail(
      date: sample.bucketStart,
      language: language,
      values: values
    )
  }
}

/// Shared click/drag selection behavior for every provider's trend chart.
/// The chart-specific view remains responsible for mapping the selected date
/// to its own nearest sample and rendering the corresponding values.
struct TrendChartSelectionModifier: ViewModifier {
  @Binding var selectedDate: Date?
  @State private var tapStartedDate: Date?

  func body(content: Content) -> some View {
    content.chartOverlay { proxy in
      GeometryReader { geometry in
        Rectangle()
          .fill(.clear)
          .contentShape(Rectangle())
          .gesture(
            DragGesture(minimumDistance: 0)
              .onChanged { value in
                if value.translation.width == 0, value.translation.height == 0 {
                  tapStartedDate = selectedDate
                }
                selectedDate = TrendChartInteraction.date(
                  at: value.location,
                  proxy: proxy,
                  geometry: geometry
                )
              }
              .onEnded { value in
                let isTap =
                  abs(value.translation.width) < 4 && abs(value.translation.height) < 4
                if isTap, let tapStartedDate, selectedDate == tapStartedDate {
                  // 再次点击相同位置取消选择；拖动则保留最后选中时间。
                  selectedDate = nil
                }
                tapStartedDate = nil
              }
          )
      }
    }
  }
}

enum TrendChartSelectionStyle {
  static let rule = StrokeStyle(lineWidth: 1, dash: [3, 3])
}

enum TrendChartInteraction {
  static func date(
    at location: CGPoint,
    proxy: ChartProxy,
    geometry: GeometryProxy
  ) -> Date? {
    let frame = geometry[proxy.plotAreaFrame]
    guard BalanceTrendProcessor.containsPlotCoordinate(location, in: frame) else {
      return nil
    }
    return proxy.value(atX: location.x - frame.origin.x, as: Date.self)
  }
}

extension View {
  func trendChartSelection(_ selectedDate: Binding<Date?>) -> some View {
    modifier(TrendChartSelectionModifier(selectedDate: selectedDate))
  }
}

/// Shared selected-point detail layout so all provider charts respond the same
/// way and keep their localized labels aligned.
struct TrendChartSelectionDetail: View {
  let date: Date
  let language: AppLanguage
  let values: [String]

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(
        date.formatted(
          Date.FormatStyle(date: .abbreviated, time: .shortened).locale(language.locale)
        )
      )
        .font(AppTypography.caption.weight(.medium))
      ForEach(Array(values.enumerated()), id: \.offset) { _, value in
        Text(value)
          .font(AppTypography.caption)
          .foregroundStyle(.secondary)
      }
    }
    .textSelection(.enabled)
  }

  static func valueText(label: String, value: String, language: AppLanguage) -> String {
    language == .simplifiedChinese ? "\(label)：\(value)" : "\(label): \(value)"
  }
}

/// Y 轴金额格式：符号由接口 currency 决定。
struct BalanceAxisFormat: FormatStyle {
  typealias FormatInput = Double
  typealias FormatOutput = String

  let currency: String

  func format(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.locale = .current
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    let text = formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    if let symbol = BalanceFormatter.currencySymbol(for: currency) {
      return symbol + text
    }
    return currency + " " + text
  }
}
