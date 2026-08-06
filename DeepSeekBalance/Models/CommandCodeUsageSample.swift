import Foundation

/// 一次成功 Command Code 用量响应在单个 10 分钟时间桶内的历史样本。
/// 记录整体剩余百分比与计费周期剩余天数，供趋势折线图使用。
struct CommandCodeUsageSample: Codable, Equatable, Identifiable, Sendable {
  let credentialID: String
  let bucketStart: Date
  let observedAt: Date
  let remainingPercent: Int
  let daysRemaining: Int?

  init(
    credentialID: String,
    bucketStart: Date,
    observedAt: Date,
    remainingPercent: Int,
    daysRemaining: Int? = nil
  ) {
    self.credentialID = credentialID
    self.bucketStart = bucketStart
    self.observedAt = observedAt
    self.remainingPercent = remainingPercent
    self.daysRemaining = daysRemaining
  }

  var id: String {
    "\(credentialID)/\(Int64(bucketStart.timeIntervalSince1970))"
  }
}
