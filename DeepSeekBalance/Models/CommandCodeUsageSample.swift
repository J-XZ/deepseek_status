import Foundation

/// 一次成功 Command Code 用量响应在单个 10 分钟时间桶内的历史样本。
/// 记录整体剩余百分比、计费周期剩余天数与 5 小时/每周窗口已用百分比，
/// 供趋势折线图使用。窗口字段可能因服务端未返回而缺失。
struct CommandCodeUsageSample: Codable, Equatable, Identifiable, Sendable {
  let credentialID: String
  let bucketStart: Date
  let observedAt: Date
  let remainingPercent: Int
  let daysRemaining: Int?
  let fiveHourUsedPercent: Int?
  let weeklyUsedPercent: Int?

  init(
    credentialID: String,
    bucketStart: Date,
    observedAt: Date,
    remainingPercent: Int,
    daysRemaining: Int? = nil,
    fiveHourUsedPercent: Int? = nil,
    weeklyUsedPercent: Int? = nil
  ) {
    self.credentialID = credentialID
    self.bucketStart = bucketStart
    self.observedAt = observedAt
    self.remainingPercent = remainingPercent
    self.daysRemaining = daysRemaining
    self.fiveHourUsedPercent = fiveHourUsedPercent
    self.weeklyUsedPercent = weeklyUsedPercent
  }

  var id: String {
    "\(credentialID)/\(Int64(bucketStart.timeIntervalSince1970))"
  }
}
