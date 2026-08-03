import Foundation

protocol OpenCodeCookieStoring: Sendable {
  func save(cookieHeader: String) throws
  func readCookieHeader() throws -> String?
  func deleteCookieHeader() throws
}

/// OpenCode Cookie 使用独立 Keychain account，和 DeepSeek API Key 分开保存。
struct KeychainOpenCodeCookieStore: OpenCodeCookieStoring {
  private let keychain: KeychainStore

  init(
    service: String = Bundle.main.bundleIdentifier ?? "com.jxz.deepseekbalance",
    account: String = "opencode-cookie"
  ) {
    self.keychain = KeychainStore(service: service, account: account, legacyService: nil)
  }

  func save(cookieHeader: String) throws {
    try keychain.save(apiKey: cookieHeader)
  }

  func readCookieHeader() throws -> String? {
    try keychain.readAPIKey()
  }

  func deleteCookieHeader() throws {
    try keychain.deleteAPIKey()
  }
}

enum OpenCodeDisplayError: Equatable, Sendable {
  case invalidCookie
  case unauthorized
  case noNetwork
  case timeout
  case http(Int)
  case server(Int)
  case decoding
  case keychain(String)

  func text(language: AppLanguage) -> String {
    switch self {
    case .invalidCookie:
      return L10n.string(.openCodeErrorInvalidCookie, language: language)
    case .unauthorized:
      return L10n.string(.openCodeErrorUnauthorized, language: language)
    case .noNetwork:
      return L10n.string(.openCodeErrorNoNetwork, language: language)
    case .timeout:
      return L10n.string(.openCodeErrorTimeout, language: language)
    case .http(let code):
      return L10n.string(.openCodeErrorHttp, language: language, code)
    case .server(let code):
      return L10n.string(.openCodeErrorServer, language: language, code)
    case .decoding:
      return L10n.string(.openCodeErrorDecoding, language: language)
    case .keychain(let detail):
      return L10n.string(
        .openCodeErrorKeychain,
        language: language,
        AppDisplayError.sanitized(detail)
      )
    }
  }
}

/// OpenCode 页面状态与 14 天本地趋势协调器。
@MainActor
final class OpenCodeUsageStore: ObservableObject {
  enum Status: Equatable {
    case idle
    case loading
    case loaded
    case notConfigured
    case keychainError
    case authInvalid
    case networkError
    case serverError
    case decodingError
  }

  enum SaveResult: Equatable {
    case success
    case emptyInput
    case invalidCookie
    case fileReadFailed
    case cookieNotFound
    case keychainFailed(String)
  }

  @Published private(set) var status: Status = .idle
  @Published private(set) var snapshot: OpenCodeUsageSnapshot?
  @Published private(set) var lastUpdated: Date?
  @Published private(set) var isRefreshing = false
  @Published private(set) var lastDisplayError: OpenCodeDisplayError?
  @Published private(set) var historySamples: [OpenCodeUsageSample] = []
  @Published private(set) var hasSavedCookie = false

  let client: any OpenCodeUsageFetching
  let cookieStore: any OpenCodeCookieStoring
  let clock: any DateProviding
  let historyService: OpenCodeHistoryService
  let refreshInterval: TimeInterval

  private var isFetching = false
  private var refreshTask: Task<Void, Never>?
  private var autoRefreshTask: Task<Void, Never>?
  private var startupPruneTask: Task<Void, Never>?
  private var autoRefreshInterval: TimeInterval?

  init(
    client: any OpenCodeUsageFetching = OpenCodeUsageClient(),
    cookieStore: any OpenCodeCookieStoring = KeychainOpenCodeCookieStore(),
    clock: any DateProviding = SystemClock(),
    refreshInterval: TimeInterval = DataRefreshPolicy.autoRefreshInterval,
    startupRefresh: Bool = true,
    startupPrune: Bool = true,
    autoRefreshInterval: TimeInterval? = DataRefreshPolicy.autoRefreshInterval,
    historyService: OpenCodeHistoryService? = nil
  ) {
    self.client = client
    self.cookieStore = cookieStore
    self.clock = clock
    self.refreshInterval = refreshInterval
    self.historyService = historyService ?? Self.makeDefaultHistoryService(clock: clock)
    self.autoRefreshInterval = autoRefreshInterval
    self.hasSavedCookie = (try? cookieStore.readCookieHeader()) != nil

    startAutoRefreshIfNeeded()
    if startupRefresh {
      refreshTask = Task { [weak self] in
        await self?.refresh()
      }
    }
    if startupPrune {
      let history = self.historyService
      let clock = self.clock
      startupPruneTask = Task(priority: .utility) { [weak self] in
        try? await history.pruneAll(before: clock.now().addingTimeInterval(-UsageHistoryWindow.seconds))
        try? await self?.historyService.pruneThrottled()
      }
    }
  }

  deinit {
    refreshTask?.cancel()
    autoRefreshTask?.cancel()
    startupPruneTask?.cancel()
  }

  private(set) var isEnabled = true

  func setEnabled(_ enabled: Bool) {
    guard isEnabled != enabled else { return }
    isEnabled = enabled
    if enabled {
      refreshTask = Task { [weak self] in
        await self?.refresh()
      }
      startAutoRefreshIfNeeded()
    } else {
      refreshTask?.cancel()
      refreshTask = nil
      autoRefreshTask?.cancel()
      autoRefreshTask = nil
    }
  }

  private func startAutoRefreshIfNeeded() {
    autoRefreshTask?.cancel()
    guard isEnabled, let interval = autoRefreshInterval else { return }
    autoRefreshTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(interval))
        guard !Task.isCancelled else { break }
        await self?.refreshIfNeeded(maximumAge: interval)
      }
    }
  }

  func refreshIfNeeded(maximumAge: TimeInterval = 60) async {
    guard isEnabled else { return }
    let age: TimeInterval
    if let lastUpdated {
      age = clock.now().timeIntervalSince(lastUpdated)
    } else {
      age = .infinity
    }
    guard age >= maximumAge else { return }
    await refresh()
  }

  func refresh() async {
    guard isEnabled, !isFetching else { return }
    isFetching = true
    isRefreshing = true
    defer {
      isFetching = false
      isRefreshing = false
    }

    let previousStatus = status
    if snapshot == nil {
      status = .loading
    }

    let cookieHeader: String
    do {
      guard let saved = try cookieStore.readCookieHeader(), !saved.isEmpty else {
        hasSavedCookie = false
        status = .notConfigured
        lastDisplayError = nil
        historySamples = []
        return
      }
      cookieHeader = saved
      hasSavedCookie = true
    } catch {
      status = .keychainError
      lastDisplayError = .keychain(error.localizedDescription)
      return
    }

    let credentialID = Self.credentialID(for: cookieHeader)
    historySamples = (try? await historyService.recentSamples(credentialID: credentialID)) ?? []

    do {
      let response = try await client.fetchUsage(cookieHeader: cookieHeader, now: clock.now())
      snapshot = response
      lastUpdated = response.updatedAt
      status = .loaded
      lastDisplayError = nil
      await persistHistory(response, credentialID: credentialID)
    } catch OpenCodeUsageClient.APIError.cancelled {
      status = previousStatus
    } catch is CancellationError {
      status = previousStatus
    } catch let error as OpenCodeUsageClient.APIError {
      apply(error: error, previousStatus: previousStatus)
    } catch {
      status = .networkError
      lastDisplayError = .noNetwork
    }
  }

  @discardableResult
  func saveCookieInput(_ rawInput: String) -> SaveResult {
    do {
      let cookieHeader = try OpenCodeCookieParser.parse(rawInput)
      try cookieStore.save(cookieHeader: cookieHeader)
      hasSavedCookie = true
      return .success
    } catch OpenCodeCookieInputError.empty {
      return .emptyInput
    } catch OpenCodeCookieInputError.fileReadFailed {
      return .fileReadFailed
    } catch OpenCodeCookieInputError.cookieNotFound {
      return .cookieNotFound
    } catch {
      return .keychainFailed(error.localizedDescription)
    }
  }

  func clearSavedCookie() {
    do {
      try cookieStore.deleteCookieHeader()
      hasSavedCookie = false
      snapshot = nil
      lastUpdated = nil
      historySamples = []
      status = .notConfigured
      lastDisplayError = nil
    } catch {
      lastDisplayError = .keychain(error.localizedDescription)
      status = .keychainError
    }
  }

  var menuBarText: String {
    if let balance = snapshot?.zenBalanceUSD {
      return String(format: "$%.2f", balance)
    }
    switch status {
    case .loading:
      return "…"
    case .notConfigured:
      return "—"
    default:
      return "—"
    }
  }

  /// 菜单栏 OpenCode 使用两行紧凑布局：第一行是 Go 月度剩余额度，第二行是 Zen 余额。
  /// 未订阅或月度窗口不可用时，Go 行固定显示 `--`，避免误把未知状态当成可用额度。
  var menuBarLines: [String] {
    [menuBarGoMonthlyText, menuBarZenText]
  }

  private var menuBarGoMonthlyText: String {
    if let monthly = snapshot?.goSubscription?.monthly {
      return "\(monthly.remainingPercent)%"
    }
    return "--"
  }

  private var menuBarZenText: String {
    if let balance = snapshot?.zenBalanceUSD {
      return String(format: "$%.2f", balance)
    }
    return status == .loading ? "…" : "—"
  }

  private func persistHistory(_ snapshot: OpenCodeUsageSnapshot, credentialID: String) async {
    guard let sample = historyService.makeSample(
      from: snapshot,
      credentialID: credentialID,
      at: snapshot.updatedAt
    ) else {
      return
    }
    do {
      try await historyService.save(sample: sample)
      historySamples = try await historyService.recentSamples(credentialID: credentialID)
    } catch {
      return
    }
    try? await historyService.pruneThrottled()
  }

  private func apply(error: OpenCodeUsageClient.APIError, previousStatus: Status) {
    switch error {
    case .cancelled:
      status = previousStatus
    case .invalidCookie:
      status = .authInvalid
      lastDisplayError = .invalidCookie
    case .unauthorized:
      status = .authInvalid
      lastDisplayError = .unauthorized
    case .noNetwork:
      status = .networkError
      lastDisplayError = .noNetwork
    case .timedOut:
      status = .networkError
      lastDisplayError = .timeout
    case .httpError(let code):
      status = .serverError
      lastDisplayError = .http(code)
    case .server(let code):
      status = .serverError
      lastDisplayError = .server(code)
    case .decodingFailed:
      status = .decodingError
      lastDisplayError = .decoding
    }
  }

  private static func credentialID(for cookieHeader: String) -> String {
    CredentialFingerprint.credentialID(for: cookieHeader)
  }

  private static func makeDefaultHistoryService(clock: any DateProviding) -> OpenCodeHistoryService {
    let base = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first
    let root = base ?? FileManager.default.temporaryDirectory
    let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.jxz.deepseekbalance"
    let fileURL = root
      .appendingPathComponent(bundleIdentifier, isDirectory: true)
      .appendingPathComponent("OpenCodeHistory.json", isDirectory: false)
    return OpenCodeHistoryService(
      store: OpenCodeHistoryFileStore(fileURL: fileURL),
      clock: clock
    )
  }
}
