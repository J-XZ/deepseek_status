import Charts
import SwiftUI

/// Codex 用量趋势折线图：最近 3 天剩余百分比（Apple Swift Charts）。
/// 缺口超过 20 分钟会断开连线。
struct CodexTrendChartView: View {
  let samples: [CodexUsageSample]
  let language: AppLanguage
  let now: Date

  private var segments: [[CodexUsageSample]] {
    CodexTrendProcessor.segments(samples)
  }

  private var xDomain: ClosedRange<Date> {
    now.addingTimeInterval(-CodexTrendProcessor.chartWindowHours * 3600)...now
  }

  private var summaryText: String {
    guard let first = samples.first, let last = samples.last else {
      return L10n.string(.codexTrendInsufficient, language: language)
    }
    let delta = last.remainingPercent - first.remainingPercent
    return L10n.string(
      .codexTrendSummary,
      language: language,
      "\(delta >= 0 ? "+" : "")\(delta)%"
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(summaryText)
        .font(AppTypography.body.weight(.medium))
      chartView
    }
  }

  private var chartView: some View {
    Chart {
      ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
        ForEach(segment) { sample in
          LineMark(
            x: .value(L10n.string(.chartTime, language: language), sample.bucketStart),
            y: .value(L10n.string(.chartRemaining, language: language), sample.remainingPercent),
            series: .value(L10n.string(.chartSegment, language: language), index)
          )
          .foregroundStyle(.blue)
          .lineStyle(StrokeStyle(lineWidth: 2))
        }
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
    .chartLegend(.hidden)
    .frame(height: 160)
    .accessibilityLabel(L10n.string(.a11yCodexLegend, language: language))
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
  static let chartWindowHours: TimeInterval = 72

  /// 把历史样本转为连续折线段：按时间升序、同桶保留最新 observedAt、
  /// 相邻间隔超过 gapThreshold 时断开。
  static func segments(_ samples: [CodexUsageSample]) -> [[CodexUsageSample]] {
    var newestByBucket: [Int64: CodexUsageSample] = [:]
    for sample in samples {
      let bucketSeconds = Int64(sample.bucketStart.timeIntervalSince1970)
      if let existing = newestByBucket[bucketSeconds], existing.observedAt > sample.observedAt {
        continue
      }
      newestByBucket[bucketSeconds] = sample
    }

    let sorted = newestByBucket.values.sorted { $0.bucketStart < $1.bucketStart }
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
}
