import Foundation

struct XSubscriptionAuthInfo: Sendable {
  let accessToken: String
}

protocol XSubscriptionAuthProviding: Sendable {
  func loadAuthInfo() throws -> XSubscriptionAuthInfo
}

enum XSubscriptionAuthError: Error, Equatable, Sendable {
  case noToken
  case securityCommandFailed
  case missingAccessToken
}

/// 读取 X Subscription 访问令牌：macOS Keychain 服务 `cursor-access-token`。
struct XSubscriptionAuthProvider: XSubscriptionAuthProviding {
  static let keychainService = "cursor-access-token"

  let keychainServiceName: String
  let environment: [String: String]

  init(
    keychainServiceName: String = XSubscriptionAuthProvider.keychainService,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.keychainServiceName = keychainServiceName
    self.environment = environment
  }

  func loadAuthInfo() throws -> XSubscriptionAuthInfo {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = [
      "find-generic-password", "-s", keychainServiceName, "-w",
    ]
    process.environment = environment

    let output = try runSync(process, timeout: 5)
    guard output.exitStatus == 0 else {
      throw XSubscriptionAuthError.securityCommandFailed
    }
    let token = String(decoding: output.stdout, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else {
      throw XSubscriptionAuthError.missingAccessToken
    }
    return XSubscriptionAuthInfo(accessToken: token)
  }

  struct SyncOutput {
    let exitStatus: Int32
    let stdout: Data
  }

  private func runSync(_ process: Process, timeout: TimeInterval) throws -> SyncOutput {
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()

    try process.run()

    let end = Date().addingTimeInterval(timeout)
    while process.isRunning {
      if Date() > end {
        process.terminate()
        throw XSubscriptionAuthError.securityCommandFailed
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.availableData
    return SyncOutput(exitStatus: process.terminationStatus, stdout: data)
  }
}
