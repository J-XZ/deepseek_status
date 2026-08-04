import Combine
import Foundation

enum VPSDisplayError: Equatable, Sendable {
  case unauthorized
  case rateLimited
  case http(Int)
  case server(Int)
  case noNetwork
  case timeout
  case decoding
  case keychain(String)
  case invalidConfiguration

  func text(language: AppLanguage) -> String {
    switch self {
    case .unauthorized:
      return L10n.string(.vpsErrorUnauthorized, language: language)
    case .rateLimited:
      return L10n.string(.vpsErrorRateLimited, language: language)
    case .http(let code):
      return L10n.string(.vpsErrorHTTP, language: language, code)
    case .server(let code):
      return L10n.string(.vpsErrorServer, language: language, code)
    case .noNetwork:
      return L10n.string(.vpsErrorNoNetwork, language: language)
    case .timeout:
      return L10n.string(.vpsErrorTimeout, language: language)
    case .decoding:
      return L10n.string(.vpsErrorDecoding, language: language)
    case .keychain(let detail):
      return L10n.string(
        .vpsErrorKeychain,
        language: language,
        AppDisplayError.sanitized(detail)
      )
    case .invalidConfiguration:
      return L10n.string(.vpsConfigEmpty, language: language)
    }
  }
}

/// Vultr 页面状态与 14 天本地趋势协调器。
@MainActor
final class VPSUsageStore: ObservableObject {
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
    case emptyToken
    case emptyInstanceID
    case keychainFailed(String)
  }

  @Published private(set) var status: Status
  @Published private(set) var snapshot: VPSUsageSnapshot?
  @Published private(set) var lastUpdated: Date?
  @Published private(set) var isRefreshing = false
  @Published private(set) var lastDisplayError: VPSDisplayError?
  @Published private(set) var historySamples: [VPSUsageSample] = []
  @Published private(set) var configuration: VPSUsageConfig

  let client: any VPSUsageFetching
  let configStore: any VPSConfigStoring
  let clock: any DateProviding
  let historyService: VPSHistoryService

  private(set) var isEnabled = true
  private var isFetching = false
  private var refreshTask: Task<Void, Never>?
  private var autoRefreshTask: Task<Void, Never>?
  private var startupPruneTask: Task<Void, Never>?
  private let autoRefreshInterval: TimeInterval?

  init(
    client: any VPSUsageFetching = VultrUsageClient(),
    configStore: any VPSConfigStoring = KeychainVPSConfigStore(),
    clock: any DateProviding = SystemClock(),
    historyService: VPSHistoryService? = nil,
    startupRefresh: Bool = true,
    startupPrune: Bool = true,
    autoRefreshInterval: TimeInterval? = DataRefreshPolicy.autoRefreshInterval
  ) {
    self.client = client
    self.configStore = configStore
    self.clock = clock
    self.historyService = historyService ?? Self.makeDefaultHistoryService(clock: clock)
    self.autoRefreshInterval = autoRefreshInterval
    self.lastDisplayError = nil

    do {
      let loadedConfiguration = try configStore.load()
      self.configuration = loadedConfiguration
      self.status = loadedConfiguration.isComplete ? .idle : .notConfigured
    } catch {
      self.configuration = .empty
      self.status = .keychainError
      self.lastDisplayError = .keychain(error.localizedDescription)
    }

    startAutoRefreshIfNeeded()
    if startupRefresh, configuration.isComplete {
      refreshTask = Task { [weak self] in
        await self?.refresh()
      }
    }
    if startupPrune {
      let history = self.historyService
      let clock = self.clock
      startupPruneTask = Task(priority: .utility) {
        try? await history.store.prune(before: clock.now().addingTimeInterval(-UsageHistoryWindow.seconds))
        try? await history.pruneThrottled()
      }
    }
  }

  deinit {
    refreshTask?.cancel()
    autoRefreshTask?.cancel()
    startupPruneTask?.cancel()
  }

  var hasSavedConfiguration: Bool {
    configuration.isComplete
  }

  var currentCycleRemainingDays: Int? {
    guard let snapshot else { return nil }
    return Self.remainingCycleDays(until: snapshot.cycleEnd, now: clock.now())
  }

  var trafficForecast: VPSTrafficForecast? {
    guard let snapshot else { return nil }
    return VPSTrafficForecastEstimator.estimate(
      samples: historySamples,
      currentRemainingGB: snapshot.remainingBandwidthGB,
      cycleStart: snapshot.cycleStart,
      cycleEnd: snapshot.cycleEnd,
      now: clock.now()
    )
  }

  func currentCycleRemainingText(language: AppLanguage) -> String? {
    guard let days = currentCycleRemainingDays else { return nil }
    return L10n.string(.vpsCycleRemaining, language: language, days)
  }

  func menuBarLines(language: AppLanguage) -> [String] {
    guard let snapshot else {
      switch status {
      case .loading:
        return ["…", "…"]
      case .notConfigured:
        return ["--", "--"]
      default:
        return ["—", "—"]
      }
    }
    let cycleRemaining = currentCycleRemainingText(language: language) ?? "—"
    return [
      "\(String(format: "%.0f GB", snapshot.remainingBandwidthGB)) (\(cycleRemaining))",
      String(format: "$%.2f", snapshot.availableCreditUSD)
    ]
  }

  func menuBarText(language: AppLanguage) -> String {
    menuBarLines(language: language).joined(separator: " / ")
  }

  nonisolated static func remainingCycleDays(until end: Date, now: Date) -> Int {
    let secondsRemaining = end.timeIntervalSince(now)
    guard secondsRemaining > 0 else { return 0 }
    return Int(ceil(secondsRemaining / 86_400))
  }

  func statusTitle(language: AppLanguage) -> String {
    switch status {
    case .idle, .loading:
      return L10n.string(.statusLoading, language: language)
    case .loaded:
      return L10n.string(.statusLoaded, language: language)
    case .notConfigured:
      return L10n.string(.vpsNotConfigured, language: language)
    case .keychainError, .networkError, .serverError, .decodingError:
      return L10n.string(.statusRequestFailed, language: language)
    case .authInvalid:
      return L10n.string(.vpsAuthInvalid, language: language)
    }
  }

  func setEnabled(_ enabled: Bool) {
    guard isEnabled != enabled else { return }
    isEnabled = enabled
    if enabled {
      if configuration.isComplete {
        refreshTask = Task { [weak self] in
          await self?.refresh()
        }
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

  func refreshIfNeeded(maximumAge: TimeInterval = DataRefreshPolicy.autoRefreshInterval) async {
    guard isEnabled, configuration.isComplete else { return }
    let age = lastUpdated.map { clock.now().timeIntervalSince($0) } ?? .infinity
    guard age >= maximumAge else { return }
    await refresh()
  }

  func refresh() async {
    guard isEnabled, configuration.isComplete, !isFetching else { return }
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

    let credentialID = Self.credentialID(for: configuration)
    historySamples = (try? await historyService.recentSamples(credentialID: credentialID)) ?? []

    do {
      let response = try await client.fetchUsage(config: configuration, now: clock.now())
      snapshot = response
      lastUpdated = response.refreshedAt
      status = .loaded
      lastDisplayError = nil
      let sample = historyService.makeSample(
        from: response,
        credentialID: credentialID,
        at: response.refreshedAt
      )
      do {
        try await historyService.save(sample: sample)
        historySamples = try await historyService.recentSamples(credentialID: credentialID)
      } catch {
        // 网络数据已经成功，不让历史文件问题覆盖当前显示。
      }
      try? await historyService.pruneThrottled()
    } catch let error as VultrUsageClient.APIError {
      if error == .cancelled {
        status = previousStatus
      } else {
        apply(error: error, previousStatus: previousStatus)
      }
    } catch is CancellationError {
      status = previousStatus
    } catch {
      status = .networkError
      lastDisplayError = .noNetwork
    }
  }

  @discardableResult
  func saveConfiguration(token: String, instanceID: String) -> SaveResult {
    let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedInstanceID = instanceID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedToken.isEmpty else { return .emptyToken }
    guard !trimmedInstanceID.isEmpty else { return .emptyInstanceID }

    let newConfiguration = VPSUsageConfig(
      apiToken: trimmedToken,
      instanceID: trimmedInstanceID
    )
    do {
      try configStore.save(newConfiguration)
      configuration = newConfiguration
      status = .idle
      lastDisplayError = nil
      startAutoRefreshIfNeeded()
      return .success
    } catch {
      return .keychainFailed(error.localizedDescription)
    }
  }

  func clearConfiguration() {
    do {
      try configStore.clear()
      configuration = .empty
      snapshot = nil
      lastUpdated = nil
      historySamples = []
      status = .notConfigured
      lastDisplayError = nil
    } catch {
      status = .keychainError
      lastDisplayError = .keychain(error.localizedDescription)
    }
  }

  private func apply(error: VultrUsageClient.APIError, previousStatus: Status) {
    switch error {
    case .missingConfig:
      status = .notConfigured
      lastDisplayError = .invalidConfiguration
    case .unauthorized:
      status = .authInvalid
      lastDisplayError = .unauthorized
    case .rateLimited:
      status = .serverError
      lastDisplayError = .rateLimited
    case .httpError(let code):
      status = .serverError
      lastDisplayError = .http(code)
    case .server(let code):
      status = .serverError
      lastDisplayError = .server(code)
    case .noNetwork:
      status = .networkError
      lastDisplayError = .noNetwork
    case .timedOut:
      status = .networkError
      lastDisplayError = .timeout
    case .decodingFailed, .invalidResponse, .cycleUnavailable:
      status = .decodingError
      lastDisplayError = .decoding
    case .cancelled:
      status = previousStatus
    }
  }

  private static func credentialID(for configuration: VPSUsageConfig) -> String {
    CredentialFingerprint.credentialID(
      for: "\(configuration.apiToken)|\(configuration.instanceID)"
    )
  }

  private static func makeDefaultHistoryService(clock: any DateProviding) -> VPSHistoryService {
    let base = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first
    let root = base ?? FileManager.default.temporaryDirectory
    let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.jxz.deepseekbalance"
    let fileURL = root
      .appendingPathComponent(bundleIdentifier, isDirectory: true)
      .appendingPathComponent("VPSUsageHistory.json", isDirectory: false)
    return VPSHistoryService(
      store: VPSHistoryFileStore(fileURL: fileURL),
      clock: clock
    )
  }
}
