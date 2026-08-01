import SwiftUI

/// 趋势空状态：首次使用或历史存储不可用。
struct BalanceTrendEmptyView: View {
  let historyUnavailable: Bool
  let language: AppLanguage

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(L10n.string(.trendEmptyTitle, language: language))
        .font(AppTypography.body.weight(.medium))
      Text(
        historyUnavailable
          ? L10n.string(.trendEmptyUnavailable, language: language)
          : L10n.string(.trendEmptyWaiting, language: language)
      )
      .font(AppTypography.caption)
      .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 8)
  }
}
