import Foundation

struct GrokBotUsageSample: Codable, Equatable, Identifiable, Sendable {
  let credentialID: String
  let bucketStart: Date
  let observedAt: Date
  let remainingPercent: Int

  var id: String {
    "\(credentialID)/\(Int64(bucketStart.timeIntervalSince1970))"
  }
}
