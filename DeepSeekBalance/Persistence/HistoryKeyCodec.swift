import Foundation

/// LevelDB key 编解码。
/// 格式：`balance/v1/<credentialID>/<currency>/<10位UTC桶秒>`，
/// 时间戳使用固定宽度十进制，保证字典序与时间序一致。
enum HistoryKeyCodec {
  static let schemaPrefix = "balance/v1/"
  private static let width = 10

  /// 币种标准化：大写并拒绝可能破坏 key schema 的字符。
  static func normalizedCurrency(_ currency: String) -> String? {
    let normalized = currency
      .uppercased()
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty,
      !normalized.contains("/"),
      !normalized.contains("\0"),
      !normalized.contains("\\"),
      !normalized.contains(":")
    else {
      return nil
    }
    return normalized
  }

  static func validCredentialID(_ credentialID: String) -> Bool {
    !credentialID.isEmpty
      && !credentialID.contains("/")
      && !credentialID.contains("\0")
      && !credentialID.contains("\\")
      && !credentialID.contains(":")
  }

  static func key(credentialID: String, currency: String, bucketStart: Date) -> String {
    let seconds = Int64(bucketStart.timeIntervalSince1970)
    return "\(schemaPrefix)\(credentialID)/\(currency)/\(padded(seconds))"
  }

  static func credentialPrefix(credentialID: String) -> String {
    "\(schemaPrefix)\(credentialID)/"
  }

  static func schemaPrefixKey() -> String {
    schemaPrefix
  }

  static func padded(_ seconds: Int64) -> String {
    String(format: "%0\(width)lld", seconds)
  }

  static func parse(key: String) -> (credentialID: String, currency: String, bucketSeconds: Int64)?
  {
    guard key.hasPrefix(schemaPrefix) else { return nil }
    let rest = key.dropFirst(schemaPrefix.count)
    let parts = rest.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 3, let seconds = Int64(parts[2]) else { return nil }
    return (String(parts[0]), String(parts[1]), seconds)
  }
}
