import Foundation

protocol OpenCodeUsageFetching: Sendable {
  func fetchUsage(cookieHeader: String, now: Date) async throws -> OpenCodeUsageSnapshot
}

/// 读取 OpenCode Web 页面使用的内部 Server Function 数据。
///
/// OpenCode 的 Go 页面是 Solid 生成的 HTML/JavaScript，不保证返回 JSON；因此客户端
/// 同时支持 JSON、序列化对象和页面内的字段文本三种形式。请求只使用 Cookie，不保存
/// 页面或 Cookie 内容。
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

  private static let baseURL = URL(string: "https://opencode.ai")!
  private static let serverURL = URL(string: "https://opencode.ai/_server")!
  private static let workspaceServerID =
    "def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f"
  private static let billingServerID =
    "c83b78a614689c38ebee981f9b39a8b377716db85c1fd7dbab604adc02d3313d"
  private static let userAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
      + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

  let session: URLSession
  let timeoutInterval: TimeInterval

  init(
    session: URLSession = OpenCodeUsageClient.makeDefaultSession(),
    timeoutInterval: TimeInterval = 20
  ) {
    self.session = session
    self.timeoutInterval = timeoutInterval
  }

  func fetchUsage(cookieHeader: String, now: Date = Date()) async throws -> OpenCodeUsageSnapshot {
    let normalizedCookie: String
    do {
      normalizedCookie = try OpenCodeCookieParser.parse(cookieHeader)
    } catch {
      throw APIError.invalidCookie
    }

    let workspaceID = try await fetchWorkspaceID(cookieHeader: normalizedCookie)
    let goPage = try await fetchGoPage(
      workspaceID: workspaceID,
      cookieHeader: normalizedCookie
    )
    let goSubscription = try Self.parseGoSubscription(text: goPage, now: now)
    let zenText = try await fetchZenBilling(
      workspaceID: workspaceID,
      cookieHeader: normalizedCookie
    )
    guard let zenBalanceUSD = Self.parseZenBalance(text: zenText) else {
      throw APIError.decodingFailed
    }

    return OpenCodeUsageSnapshot(
      workspaceID: workspaceID,
      goSubscription: goSubscription,
      zenBalanceUSD: zenBalanceUSD,
      updatedAt: now
    )
  }

  // MARK: - HTTP

  private struct ServerRequest {
    let serverID: String
    let args: String?
    let method: String
    let referer: URL
  }

  private func fetchWorkspaceID(cookieHeader: String) async throws -> String {
    let request = ServerRequest(
      serverID: Self.workspaceServerID,
      args: nil,
      method: "GET",
      referer: Self.baseURL
    )
    let initial = try await fetchServerText(request: request, cookieHeader: cookieHeader)
    if Self.looksSignedOut(text: initial) {
      throw APIError.unauthorized
    }

    if let workspaceID = Self.parseWorkspaceIDs(text: initial).first {
      return workspaceID
    }

    // 某些服务端版本只响应 POST；这是同一个只读函数的兼容回退。
    let fallback = ServerRequest(
      serverID: Self.workspaceServerID,
      args: "[]",
      method: "POST",
      referer: Self.baseURL
    )
    let fallbackText = try await fetchServerText(request: fallback, cookieHeader: cookieHeader)
    if Self.looksSignedOut(text: fallbackText) {
      throw APIError.unauthorized
    }
    guard let workspaceID = Self.parseWorkspaceIDs(text: fallbackText).first else {
      throw APIError.decodingFailed
    }
    return workspaceID
  }

  private func fetchGoPage(workspaceID: String, cookieHeader: String) async throws -> String {
    let url = Self.baseURL.appendingPathComponent("workspace")
      .appendingPathComponent(workspaceID)
      .appendingPathComponent("go")
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = timeoutInterval
    request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue(
      "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
      forHTTPHeaderField: "Accept"
    )
    return try await fetchText(request: request)
  }

  private func fetchZenBilling(workspaceID: String, cookieHeader: String) async throws -> String {
    let argsData = try JSONSerialization.data(withJSONObject: [workspaceID])
    guard let args = String(data: argsData, encoding: .utf8) else {
      throw APIError.decodingFailed
    }
    let referer = Self.baseURL.appendingPathComponent("workspace")
      .appendingPathComponent(workspaceID)
      .appendingPathComponent("zen")
    let request = ServerRequest(
      serverID: Self.billingServerID,
      args: args,
      method: "GET",
      referer: referer
    )
    return try await fetchServerText(request: request, cookieHeader: cookieHeader)
  }

  private func fetchServerText(
    request serverRequest: ServerRequest,
    cookieHeader: String
  ) async throws -> String {
    var components = URLComponents(
      url: Self.serverURL,
      resolvingAgainstBaseURL: false
    )
    var queryItems = [URLQueryItem(name: "id", value: serverRequest.serverID)]
    if serverRequest.method.uppercased() == "GET", let args = serverRequest.args {
      queryItems.append(URLQueryItem(name: "args", value: args))
    }
    components?.queryItems = queryItems
    guard let url = components?.url else { throw APIError.decodingFailed }

    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = serverRequest.method
    urlRequest.timeoutInterval = timeoutInterval
    urlRequest.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
    urlRequest.setValue(serverRequest.serverID, forHTTPHeaderField: "X-Server-Id")
    urlRequest.setValue(
      "server-fn:\(UUID().uuidString)",
      forHTTPHeaderField: "X-Server-Instance"
    )
    urlRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    urlRequest.setValue(Self.baseURL.absoluteString, forHTTPHeaderField: "Origin")
    urlRequest.setValue(serverRequest.referer.absoluteString, forHTTPHeaderField: "Referer")
    urlRequest.setValue(
      "text/javascript, application/json;q=0.9, */*;q=0.8",
      forHTTPHeaderField: "Accept"
    )

    if serverRequest.method.uppercased() != "GET", let args = serverRequest.args {
      urlRequest.httpBody = args.data(using: .utf8)
      urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    return try await fetchText(request: urlRequest)
  }

  private func fetchText(request: URLRequest) async throws -> String {
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

    guard let httpResponse = response as? HTTPURLResponse else {
      throw APIError.noNetwork
    }
    switch httpResponse.statusCode {
    case 200...299:
      guard let text = String(data: data, encoding: .utf8) else {
        throw APIError.decodingFailed
      }
      return text
    case 401, 403:
      throw APIError.unauthorized
    case 500...599:
      throw APIError.server(statusCode: httpResponse.statusCode)
    default:
      throw APIError.httpError(statusCode: httpResponse.statusCode)
    }
  }

  // MARK: - 页面解析

  static func parseGoSubscription(text: String, now: Date) throws -> OpenCodeGoSubscription? {
    if looksSignedOut(text: text) {
      throw APIError.unauthorized
    }

    // OpenCode 的无订阅页面仍然会输出一组 subscription/lite 字段，并且可能
    // 带有 monthlyUsage 等页面元数据。订阅字段是权威状态，必须先判断它，
    // 不能因为页面中出现一个数字字段就把用户显示成已订阅。
    let subscriptionMarker = subscriptionMarker(in: text)
    if subscriptionMarker == .none {
      return nil
    }

    if let parsed = parseSubscriptionJSON(text: text, now: now) {
      return parsed
    }

    let rolling = parseTextWindow(named: "rollingUsage", kind: .rolling, text: text)
    let weekly = parseTextWindow(named: "weeklyUsage", kind: .weekly, text: text)
    let monthly = parseTextWindow(named: "monthlyUsage", kind: .monthly, text: text)
    if rolling != nil || weekly != nil || monthly != nil {
      return OpenCodeGoSubscription(
        rolling: rolling,
        weekly: weekly,
        monthly: monthly,
        renewsAt: parseTextDate(named: "renewAt", text: text)
          ?? parseTextDate(named: "renew_at", text: text)
      )
    }

    if subscriptionMarker == .active {
      return OpenCodeGoSubscription(
        rolling: nil,
        weekly: nil,
        monthly: nil,
        renewsAt: nil
      )
    }
    throw APIError.decodingFailed
  }

  static func parseZenBalance(text: String) -> Double? {
    if let data = text.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data),
      let raw = findBalance(in: object)
    {
      return normalizedZenBalance(raw)
    }

    let pattern = #"(?:[\"']?balance[\"']?)\s*:\s*([+-]?[0-9]+(?:\.[0-9]+)?)"#
    guard let raw = extractDouble(pattern: pattern, text: text) else { return nil }
    return normalizedZenBalance(raw)
  }

  private static func parseSubscriptionJSON(
    text: String,
    now: Date
  ) -> OpenCodeGoSubscription? {
    guard let data = text.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data)
    else {
      return nil
    }
    return findSubscription(in: object, now: now)
  }

  private static func findSubscription(in object: Any, now: Date) -> OpenCodeGoSubscription? {
    if let dictionary = object as? [String: Any] {
      let rolling = firstDictionary(
        in: dictionary,
        keys: ["rollingUsage", "rolling", "rolling_usage", "rollingWindow", "rolling_window"]
      ).flatMap { parseWindow(dictionary: $0, kind: .rolling, now: now) }
      let weekly = firstDictionary(
        in: dictionary,
        keys: ["weeklyUsage", "weekly", "weekly_usage", "weeklyWindow", "weekly_window"]
      ).flatMap { parseWindow(dictionary: $0, kind: .weekly, now: now) }
      let monthly = firstDictionary(
        in: dictionary,
        keys: ["monthlyUsage", "monthly", "monthly_usage", "monthlyWindow", "monthly_window"]
      ).flatMap { parseWindow(dictionary: $0, kind: .monthly, now: now) }

      if rolling != nil || weekly != nil || monthly != nil {
        return OpenCodeGoSubscription(
          rolling: rolling,
          weekly: weekly,
          monthly: monthly,
          renewsAt: dateValue(from: firstValue(in: dictionary, keys: ["renewAt", "renew_at"]))
        )
      }

      if let usage = dictionary["usage"] {
        if let nested = findSubscription(in: usage, now: now) {
          return nested
        }
      }
      for value in dictionary.values {
        if let nested = findSubscription(in: value, now: now) {
          return nested
        }
      }
      return nil
    }

    if let array = object as? [Any] {
      for value in array {
        if let nested = findSubscription(in: value, now: now) {
          return nested
        }
      }
    }
    return nil
  }

  private static func parseWindow(
    dictionary: [String: Any],
    kind: OpenCodeUsageWindow.Kind,
    now: Date
  ) -> OpenCodeUsageWindow? {
    let percentKeys = [
      "usagePercent", "usedPercent", "percentUsed", "percent", "usage_percent",
      "used_percent", "utilization", "utilizationPercent", "utilization_percent", "usage"
    ]
    var percent: Double?
    for key in percentKeys {
      if let value = doubleValue(dictionary[key]) {
        percent = value
        break
      }
    }
    let directPercent = percent != nil
    if percent == nil {
      let used = ["used", "usage", "consumed", "count", "usedTokens"].compactMap {
        doubleValue(dictionary[$0])
      }.first
      let limit = ["limit", "total", "quota", "max", "cap", "tokenLimit"].compactMap {
        doubleValue(dictionary[$0])
      }.first
      if let used, let limit, limit > 0 {
        percent = used / limit * 100
      }
    }
    guard var resolvedPercent = percent, resolvedPercent.isFinite else { return nil }
    if directPercent {
      resolvedPercent = normalizedUsagePercent(resolvedPercent)
    }
    let boundedPercent = max(0, min(100, Int(resolvedPercent.rounded())))

    let resetKeys = [
      "resetInSec", "resetInSeconds", "resetSeconds", "reset_sec", "reset_in_sec",
      "resetsInSec", "resetsInSeconds", "resetIn", "resetSec"
    ]
    var resetInSec = resetKeys.compactMap { intValue(dictionary[$0]) }.first
    if resetInSec == nil {
      let resetAtKeys = [
        "resetAt", "resetsAt", "reset_at", "resets_at", "nextReset", "next_reset"
      ]
      if let resetAt = resetAtKeys.compactMap({ dateValue(from: dictionary[$0]) }).first {
        resetInSec = max(0, Int(resetAt.timeIntervalSince(now)))
      }
    }
    return OpenCodeUsageWindow(
      kind: kind,
      usedPercent: boundedPercent,
      resetInSec: resetInSec
    )
  }

  private static func parseTextWindow(
    named name: String,
    kind: OpenCodeUsageWindow.Kind,
    text: String
  ) -> OpenCodeUsageWindow? {
    let escapedName = NSRegularExpression.escapedPattern(for: name)
    // SolidStart 当前页面会把窗口对象写成
    // `rollingUsage:$R[36]={...}`，而不是直接写成 `rollingUsage:{...}`。
    // `$R[n]=` 是页面序列化引用，不是用量数据本身。
    let pattern = #"(?is)(?:[\"']?"# + escapedName
      + #"[\"']?)\s*:\s*(?:\$R\[\d+\]\s*=\s*)?\{([^{}]*)\}"#
    guard let body = extractString(pattern: pattern, capture: 1, text: text) else {
      return nil
    }
    let percentPattern = #"(?i)(?:[\"']?(?:usagePercent|usedPercent|percentUsed|percent|usage_percent|used_percent|utilization|utilizationPercent|utilization_percent)[\"']?)\s*:\s*([+-]?[0-9]+(?:\.[0-9]+)?)"#
    guard var percent = extractDouble(pattern: percentPattern, text: body), percent.isFinite else {
      return nil
    }
    percent = normalizedUsagePercent(percent)
    let resetPattern = #"(?i)(?:[\"']?(?:resetInSec|resetInSeconds|resetSeconds|reset_sec|reset_in_sec|resetsInSec|resetsInSeconds|resetIn|resetSec)[\"']?)\s*:\s*([0-9]+)"#
    let resetInSec = extractInt(pattern: resetPattern, text: body)
    return OpenCodeUsageWindow(
      kind: kind,
      usedPercent: max(0, min(100, Int(percent.rounded()))),
      resetInSec: resetInSec
    )
  }

  /// OpenCode 当前接口返回整数百分比（例如 `1` 就是 1%），旧版本/兼容
  /// 数据也可能返回 0~1 的小数比例（例如 `0.25` 表示 25%）。只有严格
  /// 小于 1 的正数才按小数比例转换，避免把真实的 1% 误显示成 100%。
  private static func normalizedUsagePercent(_ value: Double) -> Double {
    guard value > 0, value < 1 else { return value }
    return value * 100
  }

  private enum SubscriptionMarker: Equatable {
    case unknown
    case none
    case active
  }

  private static func subscriptionMarker(in text: String) -> SubscriptionMarker {
    let names = ["subscription", "subscriptionID", "subscriptionPlan", "lite", "liteSubscriptionID"]
    var found = false

    for name in names {
      let escaped = NSRegularExpression.escapedPattern(for: name)
      let pattern = #"(?:[\"']?"# + escaped
        + #"[\"']?)\s*:\s*([^\s,}\]]+)"#
      guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
        continue
      }
      let range = NSRange(text.startIndex..<text.endIndex, in: text)
      for match in regex.matches(in: text, options: [], range: range) {
        guard let valueRange = Range(match.range(at: 1), in: text) else { continue }
        found = true
        let normalized = String(text[valueRange])
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
          .lowercased()
        if !["", "null", "nil", "undefined", "false"].contains(normalized) {
          return .active
        }
      }
    }

    return found ? .none : .unknown
  }

  private static func parseTextDate(named name: String, text: String) -> Date? {
    let escaped = NSRegularExpression.escapedPattern(for: name)
    let pattern = #"(?:[\"']?"# + escaped
      + #"[\"']?)\s*:\s*(?:new\s+Date\(\s*)?([0-9]{10,13})"#
    guard let value = extractDouble(pattern: pattern, text: text) else { return nil }
    return dateValue(from: value)
  }

  // MARK: - 通用解析工具

  private static func firstDictionary(
    in dictionary: [String: Any],
    keys: [String]
  ) -> [String: Any]? {
    for key in keys {
      if let value = dictionary[key] as? [String: Any] {
        return value
      }
    }
    return nil
  }

  private static func firstValue(in dictionary: [String: Any], keys: [String]) -> Any? {
    for key in keys {
      if let value = dictionary[key] {
        return value
      }
    }
    return nil
  }

  private static func doubleValue(_ value: Any?) -> Double? {
    let number: Double?
    switch value {
    case let value as Double:
      number = value
    case let value as NSNumber:
      number = value.doubleValue
    case let value as String:
      number = Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
    default:
      number = nil
    }
    guard let number, number.isFinite else { return nil }
    return number
  }

  private static func intValue(_ value: Any?) -> Int? {
    switch value {
    case let value as Int:
      return value
    case let value as NSNumber:
      return value.intValue
    case let value as String:
      return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    default:
      return nil
    }
  }

  private static func dateValue(from value: Any?) -> Date? {
    if let number = doubleValue(value) {
      if number > 1_000_000_000_000 {
        return Date(timeIntervalSince1970: number / 1000)
      }
      if number > 1_000_000_000 {
        return Date(timeIntervalSince1970: number)
      }
    }
    if let string = value as? String {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
    return nil
  }

  private static func extractString(
    pattern: String,
    capture: Int,
    text: String
  ) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
      return nil
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, options: [], range: range),
      let captureRange = Range(match.range(at: capture), in: text)
    else {
      return nil
    }
    return String(text[captureRange])
  }

  private static func extractDouble(pattern: String, text: String) -> Double? {
    guard let string = extractString(pattern: pattern, capture: 1, text: text) else {
      return nil
    }
    return Double(string)
  }

  private static func extractInt(pattern: String, text: String) -> Int? {
    guard let string = extractString(pattern: pattern, capture: 1, text: text) else {
      return nil
    }
    return Int(string)
  }

  private static func findBalance(in object: Any) -> Double? {
    if let dictionary = object as? [String: Any] {
      for (key, value) in dictionary where key.lowercased() == "balance" {
        if let value = doubleValue(value) {
          return value
        }
      }
      for value in dictionary.values {
        if let nested = findBalance(in: value) {
          return nested
        }
      }
    } else if let array = object as? [Any] {
      for value in array {
        if let nested = findBalance(in: value) {
          return nested
        }
      }
    }
    return nil
  }

  /// Zen billing 接口返回以 1e-8 美元为单位的整数；兼容已经是美元的小数响应。
  private static func normalizedZenBalance(_ raw: Double) -> Double? {
    guard raw.isFinite else { return nil }
    let value = abs(raw) >= 1_000 ? raw / 100_000_000 : raw
    return value.isFinite ? value : nil
  }

  static func parseWorkspaceIDs(text: String) -> [String] {
    let pattern = #"wrk_[A-Za-z0-9]+"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
      return []
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    var result: [String] = []
    for match in regex.matches(in: text, options: [], range: range) {
      guard let matchRange = Range(match.range, in: text) else { continue }
      let id = String(text[matchRange])
      if !result.contains(id) {
        result.append(id)
      }
    }
    return result
  }

  static func looksSignedOut(text: String) -> Bool {
    let lower = text.lowercased()
    return lower.contains("auth/authorize")
      || lower.contains("not associated with an account")
      || lower.contains("actor of type \"public\"")
      || lower.contains("<title>login")
      || lower.contains("<title>sign in")
  }

  private static func makeDefaultSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    return URLSession(
      configuration: configuration,
      delegate: RedirectGuardDelegate(),
      delegateQueue: nil
    )
  }

  private final class RedirectGuardDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
      _ session: URLSession,
      task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse,
      newRequest request: URLRequest,
      completionHandler: @escaping (URLRequest?) -> Void
    ) {
      let sourceHost = task.originalRequest?.url?.host?.lowercased()
      let destinationHost = request.url?.host?.lowercased()
      guard sourceHost == destinationHost,
        request.url?.scheme?.lowercased() == "https"
      else {
        completionHandler(nil)
        return
      }
      completionHandler(request)
    }
  }
}
