import CryptoKit
import Foundation

/// 由 API Key 生成不可逆的 credentialID（SHA-256 完整十六进制）。
/// LevelDB 与历史数据只保存 credentialID，绝不保存原始 API Key。
enum CredentialFingerprint {
  static func credentialID(for apiKey: String) -> String {
    let normalized = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let digest = SHA256.hash(data: Data(normalized.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}
