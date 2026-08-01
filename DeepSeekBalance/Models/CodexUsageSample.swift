import Foundation

/// 一次成功 Codex 用量响应在单个 10 分钟时间桶内的历史样本。
/// 记录整体剩余百分比（0...100），供趋势折线图使用。
struct CodexUsageSample: Codable, Equatable, Identifiable, Sendable {
  let credentialID: String
  let bucketStart: Date
  let observedAt: Date
  let remainingPercent: Int

  var id: String {
    "\(credentialID)/\(Int64(bucketStart.timeIntervalSince1970))"
  }
}
