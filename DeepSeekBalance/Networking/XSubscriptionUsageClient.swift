import Foundation

protocol XSubscriptionUsageFetching: Sendable {
  func fetchUsage(accessToken: String) async throws -> XSubscriptionUsageSnapshot
}

struct XSubscriptionUsageClient: XSubscriptionUsageFetching {
  enum APIError: Error, Equatable {
    case unauthorized
    case httpError(statusCode: Int)
    case server(statusCode: Int)
    case noNetwork
    case timedOut
    case decodingFailed
    case cancelled
  }

  let session: URLSession
  let timeoutInterval: TimeInterval
  let sandURL: URL
  let planURL: URL
  let meURL: URL
  let prepaidURL: URL
  let dailySpendURL: URL
  let hardLimitURL: URL

  private static let prepaidBody = Data(#"{"limit":1}"#.utf8)

  init(
    session: URLSession = .shared,
    timeoutInterval: TimeInterval = 15,
    sandURL: URL = URL(
      string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus"
    )!,
    planURL: URL = URL(
      string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetPlanInfo"
    )!,
    meURL: URL = URL(
      string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetMe"
    )!,
    prepaidURL: URL = URL(
      string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetUserPrepaidBilling"
    )!,
    dailySpendURL: URL = URL(
      string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetDailySpendByCategory"
    )!,
    hardLimitURL: URL = URL(
      string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetHardLimit"
    )!
  ) {
    self.session = session
    self.timeoutInterval = timeoutInterval
    self.sandURL = sandURL
    self.planURL = planURL
    self.meURL = meURL
    self.prepaidURL = prepaidURL
    self.dailySpendURL = dailySpendURL
    self.hardLimitURL = hardLimitURL
  }

  func fetchUsage(accessToken: String) async throws -> XSubscriptionUsageSnapshot {
    async let sand = fetchRequired(url: sandURL, accessToken: accessToken) {
      try XSubscriptionSandParser.parse($0)
    }
    async let plan = fetchOptional(url: planURL, accessToken: accessToken) {
      try XSubscriptionPlanParser.parse($0)
    }
    async let me = fetchOptional(url: meURL, accessToken: accessToken) {
      try XSubscriptionMeParser.parse($0)
    }
    async let prepaid = fetchOptional(
      url: prepaidURL,
      accessToken: accessToken,
      body: Self.prepaidBody
    ) {
      try XSubscriptionPrepaidParser.parse($0)
    }
    async let hardLimit = fetchOptional(url: hardLimitURL, accessToken: accessToken) {
      try XSubscriptionHardLimitParser.parse($0)
    }

    let sandResult = try await sand
    let planResult = await plan
    let userId = await me
    let prepaidResult = await prepaid
    let hardLimitResult = await hardLimit

    let planName = XSubscriptionUsageFormatter.planDisplayName(planResult?.planName)
      ?? XSubscriptionUsageFormatter.planDisplayName(sandResult.cursorPlanName)
    let isMerged = (planResult?.isMerged == true) || (sandResult.isUnified == true)

    let productBreakdown = await fetchProductBreakdown(
      accessToken: accessToken,
      userId: userId,
      periodStart: sandResult.currentPeriodStart,
      periodEnd: sandResult.nextResetTimestampUtc
    )

    return XSubscriptionUsageSnapshot(
      weekly: sandResult.weekly,
      planDisplayName: planName,
      isMerged: isMerged,
      grokPlanLabel: sandResult.grokPlanLabel,
      unifiedBillingUrl: sandResult.unifiedBillingUrl,
      onDemand: sandResult.onDemand,
      productBreakdown: productBreakdown,
      prepaid: prepaidResult,
      hardLimit: hardLimitResult
    )
  }

  private func fetchProductBreakdown(
    accessToken: String,
    userId: Int64?,
    periodStart: Date?,
    periodEnd: Date?
  ) async -> XSubscriptionProductBreakdown? {
    guard let userId, let periodStart, let periodEnd,
      let body = try? XSubscriptionDailySpendRequest.body(
        userId: userId,
        periodStart: periodStart,
        periodEnd: periodEnd
      )
    else {
      return nil
    }
    return await fetchOptional(url: dailySpendURL, accessToken: accessToken, body: body) {
      try XSubscriptionDailySpendParser.parse($0)
    }
  }

  private func fetchRequired<T>(
    url: URL,
    accessToken: String,
    body: Data = XSubscriptionConnectRPC.emptyJSONBody,
    parse: (Data) throws -> T
  ) async throws -> T {
    let (data, statusCode) = try await perform(url: url, accessToken: accessToken, body: body)
    switch statusCode {
    case 200...299:
      do {
        return try parse(data)
      } catch {
        throw APIError.decodingFailed
      }
    case 401:
      throw APIError.unauthorized
    case 500...599:
      throw APIError.server(statusCode: statusCode)
    default:
      throw APIError.httpError(statusCode: statusCode)
    }
  }

  private func fetchOptional<T>(
    url: URL,
    accessToken: String,
    body: Data = XSubscriptionConnectRPC.emptyJSONBody,
    parse: (Data) throws -> T
  ) async -> T? {
    do {
      let (data, statusCode) = try await perform(url: url, accessToken: accessToken, body: body)
      guard (200...299).contains(statusCode) else { return nil }
      return try parse(data)
    } catch {
      return nil
    }
  }

  private func perform(
    url: URL,
    accessToken: String,
    body: Data
  ) async throws -> (Data, Int) {
    let request = XSubscriptionConnectRPC.postRequest(
      url: url,
      accessToken: accessToken,
      timeoutInterval: timeoutInterval,
      body: body
    )
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
    } catch {
      throw APIError.noNetwork
    }
    guard let http = response as? HTTPURLResponse else {
      throw APIError.noNetwork
    }
    return (data, http.statusCode)
  }
}

struct XSubscriptionSandParseResult: Equatable, Sendable {
  let weekly: XSubscriptionWeeklyStatus
  let cursorPlanName: String?
  let grokPlanLabel: String?
  let isUnified: Bool?
  let unifiedBillingUrl: URL?
  let onDemand: XSubscriptionOnDemandSettings?
  let currentPeriodStart: Date?
  let nextResetTimestampUtc: Date?
}

enum XSubscriptionSandParser {
  static func parse(_ data: Data) throws -> XSubscriptionSandParseResult {
    let wire = try JSONDecoder().decode(SandWireResponse.self, from: data)
    return classify(wire)
  }

  private static func classify(_ wire: SandWireResponse) -> XSubscriptionSandParseResult {
    let planLabel = wire.grokPlanLabel?.nonEmpty ?? wire.includedUsageSuperGrokPlan?.nonEmpty
    let weekly: XSubscriptionWeeklyStatus
    if wire.usesPooledEnterpriseAllowance == true {
      weekly = .enterprisePooled
    } else if let trialExpiresAt = wire.sandTrialExpiresAt {
      weekly = .trial(
        XSubscriptionTrial(
          expiresAt: trialExpiresAt,
          isCancelable: wire.sandTrialCancelable ?? false
        )
      )
    } else if wire.hasNonZeroIncludedLimit == false || wire.usagePercent == nil {
      weekly = .noIncludedLimit
    } else {
      let usedPercent = XSubscriptionPercent.usedPercent(from: wire.usagePercent) ?? 0
      weekly = .metered(
        XSubscriptionWeeklyQuota(
          usedPercent: usedPercent,
          resetsAt: wire.nextResetTimestampUtc,
          windowStart: wire.currentPeriodStart
        )
      )
    }
    return XSubscriptionSandParseResult(
      weekly: weekly,
      cursorPlanName: wire.cursorPlanName?.nonEmpty,
      grokPlanLabel: planLabel,
      isUnified: wire.isUnified,
      unifiedBillingUrl: wire.unifiedBillingUrl.flatMap(URL.init(string:)),
      onDemand: wire.onDemandSettings.map {
        XSubscriptionOnDemandSettings(
          visible: $0.visible ?? false,
          eligible: $0.eligible ?? false,
          dashboardUrl: $0.dashboardUrl.flatMap(URL.init(string:))
        )
      },
      currentPeriodStart: wire.currentPeriodStart,
      nextResetTimestampUtc: wire.nextResetTimestampUtc
    )
  }
}

enum XSubscriptionPlanParser {
  static func parse(_ data: Data) throws -> XSubscriptionPlanInfo {
    try JSONDecoder().decode(XSubscriptionPlanInfo.self, from: data)
  }
}

struct XSubscriptionPlanInfo: Equatable, Sendable {
  let planName: String?
  let includedUsagePeriod: String?
  let includedUsageResetsAt: Date?
  let billingCycleEnd: Date?
  let isMerged: Bool?
}

enum XSubscriptionMeParser {
  static func parse(_ data: Data) throws -> Int64 {
    let wire = try JSONDecoder().decode(MeWireResponse.self, from: data)
    guard let userId = wire.resolvedUserId else {
      throw DecodingError.valueNotFound(
        Int64.self,
        DecodingError.Context(
          codingPath: [],
          debugDescription: "userId missing"
        )
      )
    }
    return userId
  }
}

enum XSubscriptionPrepaidParser {
  static func parse(_ data: Data) throws -> XSubscriptionPrepaidBilling {
    let wire = try JSONDecoder().decode(PrepaidWireResponse.self, from: data)
    return XSubscriptionPrepaidBilling(
      availableCents: wire.availableCents ?? 0,
      spentThisMonthCents: wire.spentThisMonthCents,
      spentCents: wire.spentCents,
      fundedCents: wire.fundedCents,
      eligible: wire.eligible,
      hasPaymentMethod: wire.hasPaymentMethod,
      billingMode: wire.billingMode
    )
  }
}

enum XSubscriptionDailySpendParser {
  static func parse(_ data: Data) throws -> XSubscriptionProductBreakdown {
    let wire = try JSONDecoder().decode(DailySpendWireResponse.self, from: data)
    return aggregate(wire)
  }

  static func aggregate(_ wire: DailySpendWireResponse) -> XSubscriptionProductBreakdown {
    var tokens: [String: Int64] = [:]
    var cents: [String: Int64] = [:]
    var sawCents: Set<String> = []
    for item in wire.dailySpend ?? [] {
      guard let category = item.category?.nonEmpty else { continue }
      if let value = item.totalTokens {
        tokens[category, default: 0] += value
      }
      if let value = item.spendCents ?? item.totalCents {
        cents[category, default: 0] += value
        sawCents.insert(category)
      }
    }
    let cursorTokens = tokens["cursor"] ?? 0
    let sandTokens = tokens["sand"] ?? 0
    let total = cursorTokens + sandTokens
    func share(_ value: Int64) -> Int? {
      guard total > 0 else { return nil }
      return XSubscriptionPercent.usedPercent(from: Double(value) / Double(total) * 100)
    }
    return XSubscriptionProductBreakdown(
      cursor: XSubscriptionProductSpend(
        tokens: cursorTokens,
        spendCents: sawCents.contains("cursor") ? cents["cursor"] : nil,
        sharePercent: share(cursorTokens)
      ),
      grokBot: XSubscriptionProductSpend(
        tokens: sandTokens,
        spendCents: sawCents.contains("sand") ? cents["sand"] : nil,
        sharePercent: share(sandTokens)
      )
    )
  }
}

enum XSubscriptionHardLimitParser {
  static func parse(_ data: Data) throws -> XSubscriptionHardLimit {
    let wire = try JSONDecoder().decode(HardLimitWireResponse.self, from: data)
    guard let dollars = wire.hardLimit else {
      throw DecodingError.valueNotFound(
        Int64.self,
        DecodingError.Context(
          codingPath: [],
          debugDescription: "hardLimit missing"
        )
      )
    }
    return XSubscriptionHardLimit(dollars: dollars)
  }
}

private struct SandWireResponse: Decodable {
  let usagePercent: Double?
  let hasNonZeroIncludedLimit: Bool?
  let usesPooledEnterpriseAllowance: Bool?
  let sandTrialCancelable: Bool?
  let grokPlanLabel: String?
  let includedUsageSuperGrokPlan: String?
  let cursorPlanName: String?
  let isUnified: Bool?
  let unifiedBillingUrl: String?
  let onDemandSettings: OnDemandWire?
  let sandTrialExpiresAt: Date?
  let nextResetTimestampUtc: Date?
  let currentPeriodStart: Date?

  struct OnDemandWire: Decodable {
    let visible: Bool?
    let eligible: Bool?
    let dashboardUrl: String?
  }

  enum CodingKeys: String, CodingKey {
    case usagePercent
    case hasNonZeroIncludedLimit
    case usesPooledEnterpriseAllowance
    case sandTrialExpiresAt
    case sandTrialCancelable
    case grokPlanLabel
    case includedUsageSuperGrokPlan
    case cursorPlanName
    case isUnified
    case unifiedBillingUrl
    case onDemandSettings
    case nextResetTimestampUtc
    case currentPeriodStart
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    usagePercent = try container.decodeIfPresent(Double.self, forKey: .usagePercent)
    hasNonZeroIncludedLimit = try container.decodeIfPresent(
      Bool.self,
      forKey: .hasNonZeroIncludedLimit
    )
    usesPooledEnterpriseAllowance = try container.decodeIfPresent(
      Bool.self,
      forKey: .usesPooledEnterpriseAllowance
    )
    sandTrialCancelable = try container.decodeIfPresent(Bool.self, forKey: .sandTrialCancelable)
    grokPlanLabel = try container.decodeIfPresent(String.self, forKey: .grokPlanLabel)
    includedUsageSuperGrokPlan = try container.decodeIfPresent(
      String.self,
      forKey: .includedUsageSuperGrokPlan
    )
    cursorPlanName = try container.decodeIfPresent(String.self, forKey: .cursorPlanName)
    isUnified = try container.decodeIfPresent(Bool.self, forKey: .isUnified)
    unifiedBillingUrl = try container.decodeIfPresent(String.self, forKey: .unifiedBillingUrl)
    onDemandSettings = try container.decodeIfPresent(OnDemandWire.self, forKey: .onDemandSettings)
    sandTrialExpiresAt = ConnectTimestampDecoder.decode(container, forKey: .sandTrialExpiresAt)
    nextResetTimestampUtc = ConnectTimestampDecoder.decode(
      container,
      forKey: .nextResetTimestampUtc
    )
    currentPeriodStart = ConnectTimestampDecoder.decode(container, forKey: .currentPeriodStart)
  }
}

extension XSubscriptionPlanInfo: Decodable {
  enum CodingKeys: String, CodingKey {
    case planInfo
    case isMerged
  }

  enum PlanInfoKeys: String, CodingKey {
    case planName
    case includedUsagePeriod
    case includedUsageResetsAt
    case billingCycleEnd
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    isMerged = try container.decodeIfPresent(Bool.self, forKey: .isMerged)
    if let nested = try? container.nestedContainer(keyedBy: PlanInfoKeys.self, forKey: .planInfo) {
      planName = try nested.decodeIfPresent(String.self, forKey: .planName)
      includedUsagePeriod = try nested.decodeIfPresent(String.self, forKey: .includedUsagePeriod)
      includedUsageResetsAt = ConnectFlexibleInt64.dateFromEpochMs(
        ConnectFlexibleInt64.decode(nested, forKey: .includedUsageResetsAt)
      )
      billingCycleEnd = ConnectFlexibleInt64.dateFromEpochMs(
        ConnectFlexibleInt64.decode(nested, forKey: .billingCycleEnd)
      )
    } else {
      planName = nil
      includedUsagePeriod = nil
      includedUsageResetsAt = nil
      billingCycleEnd = nil
    }
  }
}

private struct MeWireResponse: Decodable {
  let userId: Int64?
  let id: Int64?
  let user: Nested?

  struct Nested: Decodable {
    let userId: Int64?
    let id: Int64?

    enum CodingKeys: String, CodingKey {
      case userId
      case id
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      userId = ConnectFlexibleInt64.decode(container, forKey: .userId)
      id = ConnectFlexibleInt64.decode(container, forKey: .id)
    }
  }

  var resolvedUserId: Int64? { userId ?? id ?? user?.userId ?? user?.id }

  enum CodingKeys: String, CodingKey {
    case userId
    case id
    case user
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    userId = ConnectFlexibleInt64.decode(container, forKey: .userId)
    id = ConnectFlexibleInt64.decode(container, forKey: .id)
    user = try container.decodeIfPresent(Nested.self, forKey: .user)
  }
}

private struct PrepaidWireResponse: Decodable {
  let billingMode: String?
  let eligible: Bool?
  let availableCents: Int64?
  let fundedCents: Int64?
  let spentCents: Int64?
  let hasPaymentMethod: Bool?
  let spentThisMonthCents: Int64?

  enum CodingKeys: String, CodingKey {
    case billingMode
    case eligible
    case availableCents
    case fundedCents
    case spentCents
    case hasPaymentMethod
    case spentThisMonthCents
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    billingMode = try container.decodeIfPresent(String.self, forKey: .billingMode)
    eligible = try container.decodeIfPresent(Bool.self, forKey: .eligible)
    hasPaymentMethod = try container.decodeIfPresent(Bool.self, forKey: .hasPaymentMethod)
    availableCents = ConnectFlexibleInt64.decode(container, forKey: .availableCents)
    fundedCents = ConnectFlexibleInt64.decode(container, forKey: .fundedCents)
    spentCents = ConnectFlexibleInt64.decode(container, forKey: .spentCents)
    spentThisMonthCents = ConnectFlexibleInt64.decode(container, forKey: .spentThisMonthCents)
  }
}

struct DailySpendWireResponse: Equatable, Sendable {
  let categories: [String]?
  let dailySpend: [Day]?

  struct Day: Equatable, Sendable {
    let day: String?
    let category: String?
    let totalTokens: Int64?
    let spendCents: Int64?
    let totalCents: Int64?
  }
}

extension DailySpendWireResponse: Decodable {
  enum CodingKeys: String, CodingKey {
    case categories
    case dailySpend
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    categories = try container.decodeIfPresent([String].self, forKey: .categories)
    dailySpend = try container.decodeIfPresent([Day].self, forKey: .dailySpend)
  }
}

extension DailySpendWireResponse.Day: Decodable {
  enum CodingKeys: String, CodingKey {
    case day
    case category
    case totalTokens
    case spendCents
    case totalCents
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let asString = try? container.decode(String.self, forKey: .day) {
      day = asString.nonEmpty
    } else if let asNumber = ConnectFlexibleInt64.decode(container, forKey: .day) {
      day = String(asNumber)
    } else {
      day = nil
    }
    category = try container.decodeIfPresent(String.self, forKey: .category)
    totalTokens = ConnectFlexibleInt64.decode(container, forKey: .totalTokens)
    spendCents = ConnectFlexibleInt64.decode(container, forKey: .spendCents)
    totalCents = ConnectFlexibleInt64.decode(container, forKey: .totalCents)
  }
}

private struct HardLimitWireResponse: Decodable {
  let hardLimit: Int64?

  enum CodingKeys: String, CodingKey {
    case hardLimit
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    hardLimit = ConnectFlexibleInt64.decode(container, forKey: .hardLimit)
  }
}

private extension String {
  var nonEmpty: String? {
    isEmpty ? nil : self
  }
}
