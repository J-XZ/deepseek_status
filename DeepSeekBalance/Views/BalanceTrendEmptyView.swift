import SwiftUI

/// 趋势空状态：首次使用或历史存储不可用。
struct BalanceTrendEmptyView: View {
  let historyUnavailable: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("尚无足够历史数据")
        .font(.subheadline.weight(.medium))
      Text(
        historyUnavailable
          ? "当前余额可正常使用，但本地历史记录暂时不可用。"
          : "应用会从首次成功获取余额后开始记录，每 10 分钟保留一个时间桶。"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 8)
  }
}
