import SwiftUI

enum CompactRemaining {
  /// Floored remaining seconds as `1D2H3S`. Zero units omitted. Non-finite or ≤ 0 → `0S`.
  /// Days are 86400 seconds, not Calendar days.
  static func ascii(_ remaining: TimeInterval) -> String {
    guard remaining.isFinite else { return "0S" }
    let total = max(0, Int(remaining.rounded(.down)))
    if total == 0 { return "0S" }

    var rest = total
    let days = rest / 86_400
    rest %= 86_400
    let hours = rest / 3_600
    rest %= 3_600
    let minutes = rest / 60
    let seconds = rest % 60

    var result = ""
    if days > 0 { result += "\(days)D" }
    if hours > 0 { result += "\(hours)H" }
    if minutes > 0 { result += "\(minutes)M" }
    if seconds > 0 { result += "\(seconds)S" }
    return result
  }
}

struct ResetAtCaption: View {
  let label: String
  let until: Date

  var body: some View {
    HStack(spacing: 6) {
      Text(label)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Rectangle()
        .fill(AppVisualStyle.divider)
        .frame(width: AppVisualStyle.hairlineWidth, height: 9)
        .accessibilityHidden(true)
      // TimelineView pauses off-screen; no stored Timer.
      TimelineView(.periodic(from: .now, by: 1)) { context in
        Text(CompactRemaining.ascii(until.timeIntervalSince(context.date)))
          .foregroundStyle(AppVisualStyle.remainingBlueGray)
          .monospacedDigit()
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
      }
    }
    .font(AppTypography.caption)
    .accessibilityElement(children: .combine)
  }
}
