import Charts
import SwiftUI

/// 最近 3 天余额趋势图（Apple Swift Charts）。
/// 存储按 UTC 排序，X 轴按本地时间显示；缺口超过 20 分钟会断开连线。
struct BalanceTrendChartView: View {
  let samples: [BalanceSample]
  let currency: String
  let summary: TrendSummary

  @State private var selectedSample: BalanceSample?

  private var symbol: String {
    BalanceFormatter.currencySymbol(for: currency) ?? currency
  }

  private var points: [TrendPoint] {
    BalanceTrendProcessor.points(for: samples, currency: currency)
  }

  private var segments: [[TrendPoint]] {
    BalanceTrendProcessor.segments(from: points)
  }

  private struct SegmentPoint: Identifiable {
    let segment: Int
    let point: TrendPoint

    var id: String { point.id }
  }

  private var segmentPoints: [SegmentPoint] {
    segments.enumerated().flatMap { index, segment in
      segment.map { SegmentPoint(segment: index, point: $0) }
    }
  }

  private func seriesName(for item: SegmentPoint) -> String {
    "\(item.point.metric.rawValue)-\(item.segment)"
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
      return StrokeStyle(lineWidth: 2)
    case .toppedUp:
      return StrokeStyle(lineWidth: 1.5, dash: [5, 4])
    case .granted:
      return StrokeStyle(lineWidth: 1.5, dash: [2, 3])
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(summary.displayText)
        .font(.subheadline.weight(.medium))
      chartView
      legend
      if let selectedSample {
        selectionDetail(selectedSample)
      }
    }
  }

  private var chartView: some View {
    Chart {
      ForEach(segmentPoints) { item in
        LineMark(
          x: .value("时间", item.point.date),
          y: .value("金额", item.point.value),
          series: .value("分段", seriesName(for: item))
        )
        .foregroundStyle(metricColor(item.point.metric))
        .lineStyle(metricLineStyle(item.point.metric))
      }

      ForEach(segmentPoints) { item in
        PointMark(
          x: .value("时间", item.point.date),
          y: .value("金额", item.point.value)
        )
        .foregroundStyle(metricColor(item.point.metric))
      }

      if let selectedSample {
        RuleMark(x: .value("选中时间", selectedSample.bucketStart))
          .foregroundStyle(.secondary)
          .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
      }
    }
    .chartXAxis {
      AxisMarks(values: .automatic(desiredCount: 6)) { _ in
        AxisGridLine().foregroundStyle(.quaternary)
        AxisValueLabel()
      }
    }
    .chartYAxis {
      AxisMarks(position: .leading) { _ in
        AxisGridLine().foregroundStyle(.quaternary)
        AxisValueLabel(format: BalanceAxisFormat(symbol: symbol))
      }
    }
    .chartLegend(.hidden)
    .frame(height: 180)
  }

  private func selectionGesture(proxy: ChartProxy, geometry: GeometryProxy) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        select(at: value.location, proxy: proxy, geometry: geometry)
      }
      .onEnded { _ in
        selectedSample = nil
      }
  }

  private var legend: some View {
    HStack(spacing: 14) {
      legendItem(label: "总余额", color: .blue, dash: [])
      legendItem(label: "充值余额", color: .green, dash: [5, 4])
      legendItem(label: "赠送余额", color: .orange, dash: [2, 3])
      Spacer()
    }
    .font(.caption)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("图例：总余额、充值余额、赠送余额")
  }

  private func legendItem(label: String, color: Color, dash: [CGFloat]) -> some View {
    HStack(spacing: 4) {
      Path { path in
        path.move(to: CGPoint(x: 0, y: 3))
        path.addLine(to: CGPoint(x: 16, y: 3))
      }
      .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dash))
      .frame(width: 16, height: 6)
      Text(label)
        .foregroundStyle(.secondary)
    }
  }

  private func select(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
    let frame = geometry[proxy.plotAreaFrame]
    let x = location.x - frame.origin.x
    guard x >= 0, x <= frame.width else {
      selectedSample = nil
      return
    }
    guard let date = proxy.value(atX: x, as: Date.self) else {
      selectedSample = nil
      return
    }
    let candidates = samples.filter { $0.currency == currency }
    selectedSample = candidates.min {
      abs($0.bucketStart.timeIntervalSince(date)) < abs($1.bucketStart.timeIntervalSince(date))
    }
  }

  @ViewBuilder
  private func selectionDetail(_ sample: BalanceSample) -> some View {
    let previous =
      samples
      .filter { $0.currency == currency && $0.bucketStart < sample.bucketStart }
      .sorted { $0.bucketStart < $1.bucketStart }
      .last
    VStack(alignment: .leading, spacing: 3) {
      Text(sample.bucketStart.formatted(date: .abbreviated, time: .shortened))
        .font(.caption.weight(.medium))
      HStack {
        Text("总余额 \(BalanceFormatter.format(total: sample.totalBalance, currency: currency))")
        Text("充值 \(BalanceFormatter.format(total: sample.toppedUpBalance, currency: currency))")
        Text("赠送 \(BalanceFormatter.format(total: sample.grantedBalance, currency: currency))")
        if let previous,
          let previousTotal = BalanceTrendProcessor.decimal(from: previous.totalBalance),
          let currentTotal = BalanceTrendProcessor.decimal(from: sample.totalBalance)
        {
          Text(
            "较前样本 \(BalanceTrendProcessor.deltaText(delta: currentTotal - previousTotal, currency: currency))"
          )
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .textSelection(.enabled)
  }
}

/// Y 轴金额格式：符号由接口 currency 决定。
struct BalanceAxisFormat: FormatStyle {
  typealias FormatInput = Double
  typealias FormatOutput = String

  let symbol: String

  func format(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.locale = .current
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    let text = formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    return symbol + text
  }
}
