import Foundation

/// Cursor 登录信息：访问令牌来自 macOS Keychain（`cursor agent login` 写入）。
struct CursorAuthInfo: Sendable {
  let accessToken: String
}

/// Cursor 账号资料（从 `cursor-agent about` 输出解析）。
struct CursorProfileInfo: Sendable {
  let planTier: String?
  let email: String?
}

/// Cursor 登录信息读取抽象，便于测试注入。
protocol CursorAuthProviding: Sendable {
  /// 读取 Keychain 中的访问令牌；未登录时抛出错误。
  func loadAuthInfo() throws -> CursorAuthInfo

  /// 读取账号资料（订阅方案、邮箱）；失败时返回 nil。
  func loadProfile() -> CursorProfileInfo?
}

enum CursorAuthError: Error, Equatable, Sendable {
  case noToken
  case securityCommandFailed
  case missingAccessToken
}

/// 读取 Cursor 的本地登录凭据：
/// - 访问令牌：macOS Keychain 服务 `cursor-access-token`（由 `cursor agent login` 写入）
/// - 账号资料：解析 `cursor-agent about` 输出中的订阅方案与邮箱
struct CursorAuthProvider: CursorAuthProviding {
  /// ai-limits 项目逆向得到的 Cursor CLI 令牌服务名。
  static let keychainService = "cursor-access-token"

  let keychainServiceName: String
  let executableURL: URL?
  let environment: [String: String]

  init(
    keychainServiceName: String = CursorAuthProvider.keychainService,
    executableURL: URL? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.keychainServiceName = keychainServiceName
    self.executableURL = executableURL
    self.environment = environment
  }

  func loadAuthInfo() throws -> CursorAuthInfo {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = [
      "find-generic-password", "-s", keychainServiceName, "-w",
    ]
    process.environment = environment

    let output = try runSync(process, timeout: 5)
    guard output.exitStatus == 0 else {
      throw CursorAuthError.securityCommandFailed
    }
    let token = String(decoding: output.stdout, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else {
      throw CursorAuthError.missingAccessToken
    }
    return CursorAuthInfo(accessToken: token)
  }

  func loadProfile() -> CursorProfileInfo? {
    let executable = executableURL ?? Self.resolveCursorAgentURL(environment: environment)
    guard let executable else { return nil }
    let process = Process()
    process.executableURL = executable
    process.arguments = ["about"]
    process.environment = environment
    guard let output = try? runSync(process, timeout: 10), output.exitStatus == 0 else {
      return nil
    }
    return Self.parseAbout(String(decoding: output.stdout, as: UTF8.self))
  }

  /// 解析 `cursor-agent about` 输出，例如：
  /// `Subscription Tier   Pro+` / `User Email   user@example.com`
  /// （键与值之间用多个空格分隔，没有冒号）。无法识别时对应字段为 nil。
  static func parseAbout(_ output: String) -> CursorProfileInfo? {
    var tier: String?
    var email: String?
    for line in output.components(separatedBy: .newlines) {
      let words = line
        .trimmingCharacters(in: .whitespaces)
        .split(whereSeparator: { $0 == " " || $0 == ":" })
        .map(String.init)
      guard words.count >= 3 else { continue }
      switch (words[0].lowercased(), words[1].lowercased()) {
      case ("subscription", "tier"):
        tier = words[2...].joined(separator: " ")
      case ("user", "email"):
        email = words[2...].joined(separator: " ")
      default:
        continue
      }
    }
    guard tier != nil || email != nil else { return nil }
    return CursorProfileInfo(planTier: tier, email: email)
  }

  /// 解析 `cursor-agent` 路径：`$PATH` 中查找，找不到则尝试 `~/.local/bin/cursor-agent`。
  static func resolveCursorAgentURL(environment: [String: String]) -> URL? {
    let candidates: [String]
    if let path = environment["PATH"], !path.isEmpty {
      candidates = path.split(separator: ":").map(String.init)
    } else {
      candidates = []
    }
    let fileManager = FileManager.default
    for directory in candidates where !directory.isEmpty {
      let url = URL(fileURLWithPath: directory).appendingPathComponent("cursor-agent")
      if fileManager.isExecutableFile(atPath: url.path) {
        return url
      }
    }
    if let home = environment["HOME"], !home.isEmpty {
      let fallback = URL(fileURLWithPath: home)
        .appendingPathComponent(".local/bin/cursor-agent")
      if fileManager.isExecutableFile(atPath: fallback.path) {
        return fallback
      }
    }
    return nil
  }

  // MARK: - 子进程

  struct SyncOutput {
    let exitStatus: Int32
    let stdout: Data
  }

  /// 同步执行子进程并捕获 stdout（stderr 丢弃）；超时或启动失败时抛出。
  private func runSync(_ process: Process, timeout: TimeInterval) throws -> SyncOutput {
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()

    try process.run()

    let end = Date().addingTimeInterval(timeout)
    while process.isRunning {
      if Date() > end {
        process.terminate()
        throw CursorAuthError.securityCommandFailed
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.availableData
    return SyncOutput(exitStatus: process.terminationStatus, stdout: data)
  }
}
