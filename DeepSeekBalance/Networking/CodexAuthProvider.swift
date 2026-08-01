import Foundation

/// Codex 登录信息（从 `~/.codex/auth.json` 读取）。
struct CodexAuthInfo: Sendable {
  let accessToken: String
  let refreshToken: String?
  let accountID: String?
}

/// Codex 登录信息读取/刷新抽象，便于测试注入。
protocol CodexAuthProviding: Sendable {
  /// 读取本地登录信息；未登录时抛出错误。
  func loadAuthInfo() throws -> CodexAuthInfo

  /// 用 refresh_token 换取新令牌，成功后尽力写回本地 auth.json。
  func refreshAccessToken(refreshToken: String) async throws -> String
}

enum CodexAuthError: Error, Equatable, Sendable {
  case noAuthFile
  case malformedAuthFile
  case missingAccessToken
  case refreshFailed
  case noNetwork
}

/// 读取 codex CLI 的本地登录凭据：
/// - 优先 `$CODEX_HOME/auth.json`，缺省 `~/.codex/auth.json`
/// - 仅支持 ChatGPT 订阅登录（tokens.access_token）
/// - 令牌刷新走 `https://auth.openai.com/oauth/token`，成功后写回 auth.json
struct CodexAuthProvider: CodexAuthProviding {
  /// Codex CLI 默认 OAuth client id（与官方 codex CLI 一致）。
  static let defaultOAuthClientID = "DRivsnm2Mu42T3KOpqdtwB3NYviHYzwD"
  static let defaultOAuthTokenURL = URL(string: "https://auth.openai.com/oauth/token")!

  let authFileURL: URL?
  let oauthTokenURL: URL
  let session: URLSession
  let fileManager: FileManager

  init(
    authFileURL: URL? = nil,
    oauthTokenURL: URL = CodexAuthProvider.defaultOAuthTokenURL,
    session: URLSession = .shared,
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.authFileURL = authFileURL ?? Self.resolveDefaultAuthFileURL(
      fileManager: fileManager,
      environment: environment
    )
    self.oauthTokenURL = oauthTokenURL
    self.session = session
    self.fileManager = fileManager
  }

  /// 解析默认 auth.json 路径：`$CODEX_HOME/auth.json` 或 `~/.codex/auth.json`。
  static func resolveDefaultAuthFileURL(
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL? {
    if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
      return URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json")
    }
    guard let home = fileManager.homeDirectoryForCurrentUser.path as String? else {
      return nil
    }
    return URL(fileURLWithPath: home).appendingPathComponent(".codex/auth.json")
  }

  func loadAuthInfo() throws -> CodexAuthInfo {
    guard let authFileURL, fileManager.fileExists(atPath: authFileURL.path) else {
      throw CodexAuthError.noAuthFile
    }
    guard let data = fileManager.contents(atPath: authFileURL.path) else {
      throw CodexAuthError.malformedAuthFile
    }
    guard let file = try? JSONDecoder().decode(CodexAuthFile.self, from: data) else {
      throw CodexAuthError.malformedAuthFile
    }
    guard let accessToken = file.tokens?.accessToken, !accessToken.isEmpty else {
      throw CodexAuthError.missingAccessToken
    }
    return CodexAuthInfo(
      accessToken: accessToken,
      refreshToken: file.tokens?.refreshToken,
      accountID: file.tokens?.accountID
    )
  }

  func refreshAccessToken(refreshToken: String) async throws -> String {
    var request = URLRequest(url: oauthTokenURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.timeoutInterval = 15
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "client_id": Self.defaultOAuthClientID,
      "grant_type": "refresh_token",
      "refresh_token": refreshToken,
    ])

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch let error as URLError {
      if error.code == .cancelled {
        throw CodexAuthError.refreshFailed
      }
      throw CodexAuthError.noNetwork
    } catch {
      throw CodexAuthError.noNetwork
    }

    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw CodexAuthError.refreshFailed
    }
    struct TokenResponse: Decodable {
      let accessToken: String?
      let refreshToken: String?
      enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
      }
    }
    guard
      let token = try? JSONDecoder().decode(TokenResponse.self, from: data),
      let accessToken = token.accessToken, !accessToken.isEmpty
    else {
      throw CodexAuthError.refreshFailed
    }
    // 尽力写回本地 auth.json，失败不影响本次使用。
    if let refreshToken = token.refreshToken {
      try? saveTokens(accessToken: accessToken, refreshToken: refreshToken)
    }
    return accessToken
  }

  /// 更新本地 auth.json 中的 tokens（尽力而为，不覆盖其他字段）。
  private func saveTokens(accessToken: String, refreshToken: String) {
    guard let authFileURL,
      let data = fileManager.contents(atPath: authFileURL.path),
      var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else {
      return
    }
    var tokens = (json["tokens"] as? [String: Any]) ?? [:]
    tokens["access_token"] = accessToken
    tokens["refresh_token"] = refreshToken
    json["tokens"] = tokens
    if let updated = try? JSONSerialization.data(withJSONObject: json) {
      try? updated.write(to: authFileURL, options: .atomic)
    }
  }
}

/// auth.json 结构（仅解析需要的字段）。
private struct CodexAuthFile: Decodable {
  struct Tokens: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let accountID: String?
    enum CodingKeys: String, CodingKey {
      case accessToken = "access_token"
      case refreshToken = "refresh_token"
      case accountID = "account_id"
    }
  }

  let tokens: Tokens?

  enum CodingKeys: String, CodingKey {
    case tokens
  }
}
