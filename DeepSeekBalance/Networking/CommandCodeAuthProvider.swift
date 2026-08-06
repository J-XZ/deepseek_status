import Foundation

/// Command Code 登录信息：API Key 来自 `~/.commandcode/auth.json`（`cmd login` 写入）。
struct CommandCodeAuthInfo: Sendable {
  let apiKey: String
}

/// Command Code 登录信息读取抽象，便于测试注入。
protocol CommandCodeAuthProviding: Sendable {
  /// 读取 auth.json 中的 API Key；未登录时抛出错误。
  func loadAuthInfo() throws -> CommandCodeAuthInfo
}

enum CommandCodeAuthError: Error, Equatable, Sendable {
  case noToken
  case authFileUnreadable
  case missingAPIKey
}

/// 读取 Command Code 的本地登录凭据：`~/.commandcode/auth.json` 的 `apiKey` 字段。
struct CommandCodeAuthProvider: CommandCodeAuthProviding {
  /// auth.json 路径（可注入测试）。
  let authFileURL: URL

  init(authFileURL: URL? = nil) {
    if let authFileURL {
      self.authFileURL = authFileURL
    } else {
      let home = FileManager.default.homeDirectoryForCurrentUser
      self.authFileURL = home.appendingPathComponent(".commandcode/auth.json")
    }
  }

  func loadAuthInfo() throws -> CommandCodeAuthInfo {
    guard let data = try? Data(contentsOf: authFileURL) else {
      throw CommandCodeAuthError.authFileUnreadable
    }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let apiKey = object["apiKey"] as? String, !apiKey.isEmpty
    else {
      throw CommandCodeAuthError.missingAPIKey
    }
    return CommandCodeAuthInfo(apiKey: apiKey)
  }
}
