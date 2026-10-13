import Foundation

protocol OpenCodeUsageFetching: Sendable {
  func fetchUsage(
    cookieHeader: String?,
    apiKey: String?,
    now: Date
  ) async throws -> OpenCodeUsageSnapshot
}

/// 从本机 OpenCode CLI 的 `auth.json` 读取 Zen / Go API Key。
/// 优先 `opencode-go`，否则使用 `opencode`。
enum OpenCodeAPIKeyLoader {
  static func authFileURL(
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    if let dataHome = environment["XDG_DATA_HOME"], !dataHome.isEmpty {
      return URL(fileURLWithPath: dataHome, isDirectory: true)
        .appendingPathComponent("opencode/auth.json")
    }
    return fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent(".local/share/opencode/auth.json")
  }

  static func load(
    fileURL: URL? = nil,
    fileManager: FileManager = .default
  ) -> String? {
    let url = fileURL ?? authFileURL(fileManager: fileManager)
    guard fileManager.fileExists(atPath: url.path),
      let data = try? Data(contentsOf: url),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }
    for name in ["opencode-go", "opencode"] {
      guard let entry = object[name] as? [String: Any],
        let key = entry["key"] as? String
      else {
        continue
      }
      let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        return trimmed
      }
    }
    return nil
  }
}

/// 用官方接口读取 OpenCode Go 用量和 Zen 余额。
///
/// Go 用量：`GET https://opencode.ai/zen/go/v1/usage`，使用本机 API Key。
/// Zen 余额和账号：`https://opencode.ai/console/api/...`，使用控制台会话 Cookie。
struct OpenCodeUsageClient: OpenCodeUsageFetching {
  enum APIError: Error, Equatable, Sendable {
    case invalidCookie
    case unauthorized
    case httpError(statusCode: Int)
    case server(statusCode: Int)
    case noNetwork
    case timedOut
    case decodingFailed
    case cancelled
  }

  private static let goUsageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!
  private static let consoleAPI = URL(string: "https://opencode.ai/console/api")!
  private static let userAgent = "DeepSeekBalance"

  let session: URLSession
  let timeoutInterval: TimeInterval

  init(
    session: URLSession = OpenCodeUsageClient.makeDefaultSession(),
    timeoutInterval: TimeInterval = 20
  ) {
    self.session = session
    self.timeoutInterval = timeoutInterval
  }

  func fetchUsage(
    cookieHeader: String?,
    apiKey: String?,
    now: Date = Date()
  ) async throws -> OpenCodeUsageSnapshot {
    let normalizedCookie = cookieHeader.flatMap { header -> String? in
      let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      return try? OpenCodeCookieParser.parse(trimmed)
    }
    let trimmedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
    let key = (trimmedKey?.isEmpty == false) ? trimmedKey : nil
    guard normalizedCookie != nil || key != nil else {
      throw APIError.invalidCookie
    }

    async let goTask = fetchGo(apiKey: key, now: now)
    async let consoleTask = fetchConsole(cookieHeader: normalizedCookie)
    let go = await goTask
    let console = await consoleTask
    return try Self.snapshot(go: go, console: console, now: now)
  }

  // MARK: - Go usage

  private enum GoFetch: Sendable {
    case missing
    case notSubscribed
    case subscription(OpenCodeGoSubscription)
    case failure(APIError)
  }

  private func fetchGo(apiKey: String?, now: Date) async -> GoFetch {
    guard let apiKey else { return .missing }
    var request = URLRequest(url: Self.goUsageURL)
    request.httpMethod = "GET"
    request.timeoutInterval = timeoutInterval
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    do {
      let response = try await send(request)
      switch response.statusCode {
      case 200:
        guard let subscription = Self.parseGoUsage(data: response.body, now: now) else {
          return .failure(.decodingFailed)
        }
        return .subscription(subscription)
      case 401:
        return .failure(.unauthorized)
      case 403:
        return .notSubscribed
      case 500...599:
        return .failure(.server(statusCode: response.statusCode))
      default:
        return .failure(.httpError(statusCode: response.statusCode))
      }
    } catch let error as APIError {
      return .failure(error)
    } catch {
      return .failure(.noNetwork)
    }
  }

  static func parseGoUsage(data: Data, now: Date) -> OpenCodeGoSubscription? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let usage = object["usage"] as? [String: Any]
    else {
      return nil
    }
    let rolling = window(named: "rolling", kind: .rolling, usage: usage, now: now)
    let weekly = window(named: "weekly", kind: .weekly, usage: usage, now: now)
    let monthly = window(named: "monthly", kind: .monthly, usage: usage, now: now)
    guard rolling != nil || weekly != nil || monthly != nil else { return nil }
    return OpenCodeGoSubscription(
      rolling: rolling,
      weekly: weekly,
      monthly: monthly,
      renewsAt: nil
    )
  }

  private static func window(
    named name: String,
    kind: OpenCodeUsageWindow.Kind,
    usage: [String: Any],
    now: Date
  ) -> OpenCodeUsageWindow? {
    guard let entry = usage[name] as? [String: Any],
      let percent = doubleValue(entry["percent"]),
      percent.isFinite,
      let resetsAt = dateValue(entry["resetsAt"])
    else {
      return nil
    }
    let used = max(0, min(100, Int(percent.rounded())))
    let resetInSec = max(0, Int(resetsAt.timeIntervalSince(now)))
    return OpenCodeUsageWindow(kind: kind, usedPercent: used, resetInSec: resetInSec)
  }

  // MARK: - Console billing

  private struct ConsoleFetch: Sendable {
    var workspaceID: String?
    var email: String?
    var zenBalanceUSD: Double?
    var failure: APIError?
  }

  private func fetchConsole(cookieHeader: String?) async -> ConsoleFetch {
    guard let cookieHeader else { return ConsoleFetch() }
    do {
      let orgsResponse = try await send(
        consoleRequest(path: "orgs", cookieHeader: cookieHeader, orgID: nil)
      )
      if orgsResponse.statusCode == 401 || orgsResponse.statusCode == 403 {
        return ConsoleFetch(failure: .unauthorized)
      }
      guard (200...299).contains(orgsResponse.statusCode) else {
        return ConsoleFetch(failure: Self.httpFailure(orgsResponse.statusCode))
      }
      guard let workspaceID = Self.parseWorkspaceID(data: orgsResponse.body) else {
        return ConsoleFetch(failure: .decodingFailed)
      }

      async let userResponse = send(
        consoleRequest(path: "user", cookieHeader: cookieHeader, orgID: nil)
      )
      async let billingResponse = send(
        consoleRequest(path: "billing/status", cookieHeader: cookieHeader, orgID: workspaceID)
      )
      let user = try await userResponse
      let billing = try await billingResponse
      let email = (200...299).contains(user.statusCode)
        ? Self.parseEmail(data: user.body)
        : nil
      if billing.statusCode == 401 || billing.statusCode == 403 {
        return ConsoleFetch(workspaceID: workspaceID, email: email, failure: .unauthorized)
      }
      guard (200...299).contains(billing.statusCode) else {
        return ConsoleFetch(
          workspaceID: workspaceID,
          email: email,
          failure: Self.httpFailure(billing.statusCode)
        )
      }
      guard let balance = Self.parseZenBalanceUSD(data: billing.body) else {
        return ConsoleFetch(workspaceID: workspaceID, email: email, failure: .decodingFailed)
      }
      return ConsoleFetch(workspaceID: workspaceID, email: email, zenBalanceUSD: balance)
    } catch let error as APIError {
      return ConsoleFetch(failure: error)
    } catch {
      return ConsoleFetch(failure: .noNetwork)
    }
  }

  private func consoleRequest(
    path: String,
    cookieHeader: String,
    orgID: String?
  ) -> URLRequest {
    var url = Self.consoleAPI
    for part in path.split(separator: "/") where !part.isEmpty {
      url.appendPathComponent(String(part))
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = timeoutInterval
    request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    if let orgID {
      request.setValue(orgID, forHTTPHeaderField: "x-org-id")
    }
    return request
  }

  static func parseWorkspaceID(data: Data) -> String? {
    guard let orgs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      return nil
    }
    for org in orgs {
      if let id = org["id"] as? String, id.hasPrefix("wrk_") || id.hasPrefix("org_") {
        return id
      }
    }
    return nil
  }

  static func parseEmail(data: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let email = object["email"] as? String
    else {
      return nil
    }
    let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.contains("@") ? trimmed : nil
  }

  /// `balanceMicroCents` 是 10^-8 美元。字段可能是字符串或数字。
  static func parseZenBalanceUSD(data: Data) -> Double? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let raw = doubleValue(object["balanceMicroCents"]),
      raw.isFinite
    else {
      return nil
    }
    return raw / 100_000_000
  }

  // MARK: - Merge

  private static func snapshot(
    go: GoFetch,
    console: ConsoleFetch,
    now: Date
  ) throws -> OpenCodeUsageSnapshot {
    let subscription: OpenCodeGoSubscription?
    switch go {
    case .subscription(let value):
      subscription = value
    case .missing, .notSubscribed:
      subscription = nil
    case .failure:
      subscription = nil
    }

    let hasGo = {
      if case .subscription = go { return true }
      if case .notSubscribed = go { return true }
      return false
    }()
    let hasZen = console.zenBalanceUSD != nil
    if hasGo || hasZen {
      return OpenCodeUsageSnapshot(
        workspaceID: console.workspaceID ?? "opencode",
        accountEmail: console.email,
        goSubscription: subscription,
        zenBalanceUSD: console.zenBalanceUSD,
        updatedAt: now
      )
    }

    if let failure = preferredFailure(go: go, console: console) {
      throw failure
    }
    throw APIError.decodingFailed
  }

  private static func preferredFailure(go: GoFetch, console: ConsoleFetch) -> APIError? {
    let failures: [APIError] = [
      console.failure,
      { if case .failure(let error) = go { return error } else { return nil } }(),
    ].compactMap { $0 }
    if failures.contains(.unauthorized) {
      return .unauthorized
    }
    return failures.first
  }

  private static func httpFailure(_ statusCode: Int) -> APIError {
    if (500...599).contains(statusCode) {
      return .server(statusCode: statusCode)
    }
    return .httpError(statusCode: statusCode)
  }

  // MARK: - HTTP

  private struct HTTPBody {
    let statusCode: Int
    let body: Data
  }

  private func send(_ request: URLRequest) async throws -> HTTPBody {
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch let error as URLError {
      switch error.code {
      case .cancelled:
        throw APIError.cancelled
      case .timedOut:
        throw APIError.timedOut
      default:
        throw APIError.noNetwork
      }
    } catch is CancellationError {
      throw APIError.cancelled
    } catch {
      throw APIError.noNetwork
    }
    guard let http = response as? HTTPURLResponse else {
      throw APIError.noNetwork
    }
    return HTTPBody(statusCode: http.statusCode, body: data)
  }

  private static func doubleValue(_ value: Any?) -> Double? {
    switch value {
    case let value as Double:
      return value.isFinite ? value : nil
    case let value as NSNumber:
      let number = value.doubleValue
      return number.isFinite ? number : nil
    case let value as String:
      return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
    default:
      return nil
    }
  }

  private static func dateValue(_ value: Any?) -> Date? {
    guard let string = value as? String else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: string) {
      return date
    }
    return ISO8601DateFormatter().date(from: string)
  }

  private static func makeDefaultSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    return URLSession(configuration: configuration)
  }
}
