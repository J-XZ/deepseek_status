import Foundation

@MainActor
final class XSubscriptionUsageStore: ObservableObject {
  enum Status: Equatable {
    case idle
    case loading
    case loaded
    case notConfigured
    case authInvalid
    case networkError
    case serverError
    case decodingError
  }

  @Published private(set) var status: Status = .idle
  @Published private(set) var usage: XSubscriptionUsageSnapshot?
  @Published private(set) var lastUpdated: Date?
  @Published private(set) var isRefreshing = false
  @Published private(set) var lastDisplayError: AppDisplayError?
  @Published private(set) var historySamples: [XSubscriptionUsageSample] = []

  let client: any XSubscriptionUsageFetching
  let authProvider: any XSubscriptionAuthProviding
  let clock: any DateProviding
  let refreshInterval: TimeInterval
  let historyService: XSubscriptionHistoryService

  static let credentialID = "xsubscription"

  private var isFetching = false
  private var refreshTask: Task<Void, Never>?
  private var autoRefreshTask: Task<Void, Never>?
  private var startupPruneTask: Task<Void, Never>?
  private var autoRefreshInterval: TimeInterval?

  init(
    client: any XSubscriptionUsageFetching = XSubscriptionUsageClient(),
    authProvider: any XSubscriptionAuthProviding = XSubscriptionAuthProvider(),
    clock: any DateProviding = SystemClock(),
    refreshInterval: TimeInterval = DataRefreshPolicy.autoRefreshInterval,
    startupRefresh: Bool = true,
    startupPrune: Bool = true,
    autoRefreshInterval: TimeInterval? = DataRefreshPolicy.autoRefreshInterval,
    historyService: XSubscriptionHistoryService? = nil
  ) {
    self.client = client
    self.authProvider = authProvider
    self.clock = clock
    self.refreshInterval = refreshInterval
    self.historyService = historyService ?? Self.makeDefaultHistoryService(clock: clock)

    self.autoRefreshInterval = autoRefreshInterval
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
    guard isEnabled else { return }
    guard !isFetching else { return }
    isFetching = true
    isRefreshing = true
    defer {
      isFetching = false
      isRefreshing = false
    }

    let previousStatus = status
    if usage == nil {
      status = .loading
    }

    let authInfo: XSubscriptionAuthInfo
    do {
      authInfo = try authProvider.loadAuthInfo()
    } catch {
      applyAuthFailure(previousStatus: previousStatus)
      return
    }

    historySamples = (try? await historyService.recentSamples(
      credentialID: Self.credentialID
    )) ?? historySamples

    do {
      let snapshot = try await client.fetchUsage(accessToken: authInfo.accessToken)
      usage = snapshot
      lastUpdated = clock.now()
      lastDisplayError = nil
      status = .loaded
      if case .metered(let quota) = snapshot.weekly {
        await persistHistory(quota: quota)
      } else {
        historySamples = (try? await historyService.recentSamples(
          credentialID: Self.credentialID
        )) ?? historySamples
      }
    } catch XSubscriptionUsageClient.APIError.cancelled {
      status = previousStatus
      return
    } catch let error as XSubscriptionUsageClient.APIError {
      applyClientError(error)
    } catch {
      status = .networkError
      lastDisplayError = .noNetwork
    }
  }

  private func persistHistory(quota: XSubscriptionWeeklyQuota) async {
    let history = historyService
    let sample = history.makeSample(
      remainingPercent: quota.remainingPercent,
      credentialID: Self.credentialID,
      at: clock.now()
    )
    do {
      try await history.save(sample: sample)
      historySamples = try await history.recentSamples(credentialID: Self.credentialID)
    } catch {
      return
    }
    try? await history.pruneThrottled()
  }

  private static func makeDefaultHistoryService(clock: any DateProviding) -> XSubscriptionHistoryService {
    let base = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first
    guard let base else {
      return XSubscriptionHistoryService(store: UnavailableXSubscriptionHistoryStore(), clock: clock)
    }
    let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.jxz.deepseekbalance"
    let appSupport = base.appendingPathComponent(bundleIdentifier, isDirectory: true)
    let directory = appSupport.appendingPathComponent(
      "XSubscriptionHistory.leveldb",
      isDirectory: true
    )
    if let store = try? LevelDBXSubscriptionHistoryStore.open(directory: directory) {
      Task(priority: .utility) {
        await XSubscriptionHistoryMigrator.migrateIfNeeded(
          grokBotDirectory: appSupport.appendingPathComponent(
            XSubscriptionHistoryMigrator.grokBotDirectoryName,
            isDirectory: true
          ),
          cursorDirectory: appSupport.appendingPathComponent(
            XSubscriptionHistoryMigrator.cursorDirectoryName,
            isDirectory: true
          ),
          destination: store,
          credentialID: credentialID,
          defaults: .standard
        )
      }
      return XSubscriptionHistoryService(store: store, clock: clock)
    }
    return XSubscriptionHistoryService(store: UnavailableXSubscriptionHistoryStore(), clock: clock)
  }

  private func applyAuthFailure(previousStatus: Status) {
    if usage != nil {
      status = .authInvalid
    } else {
      usage = nil
      status = .notConfigured
    }
    lastDisplayError = previousStatus == .loaded
      ? .xSubscriptionAuthInvalid
      : .xSubscriptionNotConfigured
  }

  private func applyClientError(_ error: XSubscriptionUsageClient.APIError) {
    switch error {
    case .cancelled:
      return
    case .unauthorized:
      if usage != nil {
        status = .authInvalid
      } else {
        status = .notConfigured
      }
      lastDisplayError = .xSubscriptionAuthInvalid
    case .server(let code):
      status = .serverError
      lastDisplayError = .server(code)
    case .httpError(let code):
      status = .serverError
      lastDisplayError = .http(code)
    case .noNetwork:
      status = .networkError
      lastDisplayError = .noNetwork
    case .timedOut:
      status = .networkError
      lastDisplayError = .timeout
    case .decodingFailed:
      status = .decodingError
      lastDisplayError = .decoding
    }
  }

  var menuBarText: String {
    if case .metered(let quota)? = usage?.weekly {
      var text = "\(quota.remainingPercent)%"
      if let gap = quota.usageGapPercent(now: clock.now()) {
        text += " (\(gap >= 0 ? "+" : "")\(gap)%)"
      }
      return text
    }
    switch status {
    case .idle, .loading:
      return "…"
    case .loaded:
      return "—"
    case .notConfigured, .authInvalid, .networkError, .serverError, .decodingError:
      return "—"
    }
  }
}
