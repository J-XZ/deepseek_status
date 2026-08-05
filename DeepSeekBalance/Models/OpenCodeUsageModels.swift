import Foundation

/// OpenCode Go 的一个限额窗口。
/// usagePercent 表示已使用百分比，resetInSec 表示距离窗口重置的秒数。
struct OpenCodeUsageWindow: Codable, Equatable, Identifiable, Sendable {
  enum Kind: String, Codable, CaseIterable, Sendable {
    case rolling
    case weekly
    case monthly

    var defaultWindowSeconds: TimeInterval {
      switch self {
      case .rolling:
        return 5 * 60 * 60
      case .weekly:
        return 7 * 24 * 60 * 60
      case .monthly:
        return 30 * 24 * 60 * 60
      }
    }
  }

  let kind: Kind
  let usedPercent: Int
  let resetInSec: Int?

  var id: String { kind.rawValue }

  var remainingPercent: Int {
    max(0, min(100, 100 - usedPercent))
  }

  /// 根据服务端返回的“距离窗口重置的秒数”反推出当前窗口结束时间。
  /// now 显式传入，保证菜单栏和详情页使用同一个时间基准，也便于测试。
  func resetAt(now: Date) -> Date? {
    guard let resetInSec, resetInSec >= 0 else { return nil }
    return now.addingTimeInterval(TimeInterval(resetInSec))
  }

  var resetAt: Date? {
    resetAt(now: Date())
  }

  /// 当前窗口按时间线性消耗时应达到的已用百分比。
  func expectedUsedPercent(now: Date) -> Double? {
    expectedUsedPercent(now: now, windowEnd: resetAt(now: now))
  }

  /// 使用订阅续费时间作为窗口结束时间的理想用量计算。
  /// 某些 OpenCode 页面只返回 renewAt，不返回各窗口的 resetInSec，
  /// 此入口让菜单栏仍能显示理想进度差异。
  func expectedUsedPercent(now: Date, windowEnd: Date?) -> Double? {
    guard let windowEnd else { return nil }
    let windowEndSeconds = windowEnd.timeIntervalSince1970
    let current = now.timeIntervalSince1970
    let remainingWindowSeconds = windowEndSeconds - current
    // OpenCode 的月度窗口按服务端实际周期重置，某些月份会比固定的 30 天略长。
    // 如果剩余时间超过默认窗口长度，使用服务端返回的剩余周期作为有效窗口长度，
    // 避免把当前时刻误判为“窗口尚未开始”，从而丢失理想用量和 +0% 差异。
    let effectiveWindowSeconds = max(
      kind.defaultWindowSeconds,
      remainingWindowSeconds
    )
    let windowStart = windowEndSeconds - effectiveWindowSeconds
    guard current >= windowStart, current <= windowEndSeconds, windowStart < windowEndSeconds else {
      return nil
    }
    return min(100, max(0, (current - windowStart) / (windowEndSeconds - windowStart) * 100))
  }

  /// 实际已用百分比 − 理想已用百分比；正数表示实际用量超前。
  func usageGapPercent(now: Date) -> Int? {
    usageGapPercent(now: now, windowEnd: resetAt(now: now))
  }

  /// 使用指定窗口结束时间计算实际用量与理想用量的差异。
  func usageGapPercent(now: Date, windowEnd: Date?) -> Int? {
    guard let expected = expectedUsedPercent(now: now, windowEnd: windowEnd) else {
      return nil
    }
    return usedPercent - Int(expected.rounded())
  }
}

/// OpenCode Go 订阅状态。窗口字段可能因服务端版本变化而缺失。
struct OpenCodeGoSubscription: Codable, Equatable, Sendable {
  let rolling: OpenCodeUsageWindow?
  let weekly: OpenCodeUsageWindow?
  let monthly: OpenCodeUsageWindow?
  let renewsAt: Date?

  var windows: [OpenCodeUsageWindow] {
    [rolling, weekly, monthly].compactMap { $0 }
  }
}

/// 一次 OpenCode 查询的归一化结果。
struct OpenCodeUsageSnapshot: Equatable, Sendable {
  let workspaceID: String
  let accountEmail: String?
  let goSubscription: OpenCodeGoSubscription?
  let zenBalanceUSD: Double?
  let updatedAt: Date

  var isGoSubscribed: Bool {
    goSubscription != nil
  }

  /// 趋势历史使用 Go 的全部可用限额窗口。
  var goRollingUsedPercent: Int? {
    goSubscription?.rolling?.usedPercent
  }

  var goWeeklyUsedPercent: Int? {
    goSubscription?.weekly?.usedPercent
  }

  var goMonthlyUsedPercent: Int? {
    goSubscription?.monthly?.usedPercent
  }
}

/// 用户可粘贴的 Cookie 输入解析错误。
enum OpenCodeCookieInputError: Error, Equatable, Sendable {
  case empty
  case fileReadFailed
  case cookieNotFound
}

/// OpenCode Cookie 解析器。
///
/// 支持：
/// - 完整 Netscape Cookie 文件内容；
/// - 指向该文件的本机绝对路径（支持 `~` 开头）；
/// - 作为便捷兼容形式的 `auth=value` Cookie Header。
///
/// 请求只保留 OpenCode 登录所需的 `auth` / `__Host-auth`，不会把完整 Cookie
/// 文件或原始内容写入历史记录。
enum OpenCodeCookieParser {
  static let acceptedCookieNames = ["auth", "__Host-auth"]

  static func parse(_ rawInput: String, fileManager: FileManager = .default) throws -> String {
    let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !input.isEmpty else { throw OpenCodeCookieInputError.empty }

    let expandedPath = (input as NSString).expandingTildeInPath
    if expandedPath.hasPrefix("/"), fileManager.fileExists(atPath: expandedPath) {
      guard let contents = try? String(contentsOfFile: expandedPath, encoding: .utf8) else {
        throw OpenCodeCookieInputError.fileReadFailed
      }
      return try parseContents(contents)
    }

    return try parseContents(input)
  }

  static func parseContents(_ contents: String) throws -> String {
    let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw OpenCodeCookieInputError.empty }

    if let cookie = parseCookieHeader(trimmed) {
      return cookie
    }

    var candidates: [String: String] = [:]
    for rawLine in trimmed.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty, !line.hasPrefix("#") else { continue }

      let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
      guard fields.count >= 7 else { continue }

      let domain = String(fields[0]).lowercased().trimmingCharacters(in: .whitespaces)
      guard isOpenCodeDomain(domain) else { continue }
      let name = String(fields[5])
      guard acceptedCookieNames.contains(name) else { continue }
      let value = String(fields[6])
      guard !value.isEmpty, !value.contains("\n"), !value.contains("\r") else { continue }
      candidates[name] = value
    }

    for name in acceptedCookieNames {
      if let value = candidates[name] {
        return "\(name)=\(value)"
      }
    }
    throw OpenCodeCookieInputError.cookieNotFound
  }

  private static func parseCookieHeader(_ input: String) -> String? {
    let withoutPrefix: String
    if let colon = input.firstIndex(of: ":"),
      input[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "cookie"
    {
      withoutPrefix = String(input[input.index(after: colon)...])
    } else {
      withoutPrefix = input
    }

    for part in withoutPrefix.split(separator: ";", omittingEmptySubsequences: true) {
      let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard pair.count == 2 else { continue }
      let name = pair[0].trimmingCharacters(in: .whitespacesAndNewlines)
      guard acceptedCookieNames.contains(name) else { continue }
      let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty else { continue }
      return "\(name)=\(value)"
    }
    return nil
  }

  private static func isOpenCodeDomain(_ domain: String) -> Bool {
    let normalized = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
    return normalized == "opencode.ai" || normalized.hasSuffix(".opencode.ai")
  }
}
