import Foundation

/// 一次成功 Cursor 用量响应在单个 10 分钟时间桶内的历史样本。
/// 记录整体剩余百分比与 API 通道剩余百分比（0...100），供趋势折线图使用。
/// apiRemainingPercent 为可选：旧记录无该字段时为 nil，图表只画第一方模型线。
struct CursorUsageSample: Codable, Equatable, Identifiable, Sendable {
  let credentialID: String
  let bucketStart: Date
  let observedAt: Date
  let remainingPercent: Int
  let apiRemainingPercent: Int?

  init(
    credentialID: String,
    bucketStart: Date,
    observedAt: Date,
    remainingPercent: Int,
    apiRemainingPercent: Int? = nil
  ) {
    self.credentialID = credentialID
    self.bucketStart = bucketStart
    self.observedAt = observedAt
    self.remainingPercent = remainingPercent
    self.apiRemainingPercent = apiRemainingPercent
  }

  var id: String {
    "\(credentialID)/\(Int64(bucketStart.timeIntervalSince1970))"
  }
}
