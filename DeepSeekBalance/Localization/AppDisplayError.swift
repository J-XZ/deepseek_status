import Foundation

/// 语义化错误：状态层只保存错误种类，翻译由 UI/L10n 按当前语言即时生成。
enum AppDisplayError: Equatable, Sendable {
  case unauthorized
  case insufficientBalance
  case rateLimited
  case http(Int)
  case server(Int)
  case noNetwork
  case timeout
  case decoding
  case keychain(String)
  case history(String)
  case serviceStatusUnavailable
  case codexNotConfigured
  case codexAuthInvalid
  case cursorNotConfigured
  case cursorAuthInvalid
  case commandCodeNotConfigured
  case commandCodeAuthInvalid
  case unknown

  func text(language: AppLanguage) -> String {
    switch self {
    case .unauthorized:
      return L10n.string(.errorUnauthorized, language: language)
    case .insufficientBalance:
      return L10n.string(.errorInsufficientBalance, language: language)
    case .rateLimited:
      return L10n.string(.errorRateLimited, language: language)
    case .http(let code):
      return L10n.string(.errorHttp, language: language, code)
    case .server(let code):
      return L10n.string(.errorServer, language: language, code)
    case .noNetwork:
      return L10n.string(.errorNoNetwork, language: language)
    case .timeout:
      return L10n.string(.errorTimeout, language: language)
    case .decoding:
      return L10n.string(.errorDecoding, language: language)
    case .keychain(let detail):
      return L10n.string(
        .errorKeychain,
        language: language,
        Self.sanitized(detail)
      )
    case .history(let detail):
      return L10n.string(.errorHistory, language: language, Self.sanitized(detail))
    case .serviceStatusUnavailable:
      return L10n.string(.errorServiceStatus, language: language)
    case .codexNotConfigured:
      return L10n.string(.codexNotConfigured, language: language)
    case .codexAuthInvalid:
      return L10n.string(.codexAuthInvalid, language: language)
    case .cursorNotConfigured:
      return L10n.string(.cursorNotConfigured, language: language)
    case .cursorAuthInvalid:
      return L10n.string(.cursorAuthInvalid, language: language)
    case .commandCodeNotConfigured:
      return L10n.string(.commandCodeNotConfigured, language: language)
    case .commandCodeAuthInvalid:
      return L10n.string(.commandCodeAuthInvalid, language: language)
    case .unknown:
      return L10n.string(.errorUnknown, language: language)
    }
  }

  /// 清理无法翻译的底层系统文本：去掉控制字符，避免换行注入。
  static func sanitized(_ raw: String) -> String {
    let cleaned = raw.components(separatedBy: CharacterSet.controlCharacters).joined()
    return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
