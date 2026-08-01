import XCTest

@testable import DeepSeekBalance

final class CursorHistoryTests: XCTestCase {
  private let clock = FixedClock(date: Date(timeIntervalSince1970: 1_800_000))

  // MARK: - Key codec

  func testKeyCodecRoundTrip() {
    let date = Date(timeIntervalSince1970: 1_800_600)
    let key = CursorHistoryKeyCodec.key(credentialID: "cursor", bucketStart: date)
    XCTAssertEqual(key, "cursor/v1/cursor/0001800600")
    let parsed = CursorHistoryKeyCodec.parse(key: key)
    XCTAssertEqual(parsed?.credentialID, "cursor")
    XCTAssertEqual(parsed?.bucketSeconds, 1_800_600)
  }

  func testKeyCodecRejectsMalformedKeys() {
    XCTAssertNil(CursorHistoryKeyCodec.parse(key: "codex/v1/cursor/0001800600"))
    XCTAssertNil(CursorHistoryKeyCodec.parse(key: "cursor/v1/cursor"))
    XCTAssertNil(CursorHistoryKeyCodec.parse(key: "cursor/v1/cursor/abc"))
  }

  func testCredentialPrefix() {
    XCTAssertEqual(
      CursorHistoryKeyCodec.credentialPrefix(credentialID: "cursor"),
      "cursor/v1/cursor/"
    )
  }

  // MARK: - Value codec

  func testValueCodecRoundTrip() throws {
    let sample = CursorUsageSample(
      credentialID: "cursor",
      bucketStart: Date(timeIntervalSince1970: 1_800_000),
      observedAt: Date(timeIntervalSince1970: 1_800_600),
      remainingPercent: 29
    )
    let data = try CursorHistoryValueCodec.encode(sample: sample)
    let decoded = try XCTUnwrap(CursorHistoryValueCodec.decode(data))
    XCTAssertEqual(decoded, sample)
  }

  func testValueCodecRejectsUnknownVersion() {
    let json = """
      {"version":99,"credential_id":"cursor","bucket_start":1800000,
       "observed_at":1800600,"remaining_percent":29}
      """
    let data = Data(json.utf8)
    XCTAssertNil(try? CursorHistoryValueCodec.decode(data))
  }

  func testValueCodecRejectsCorruptData() {
    let data = Data("garbage".utf8)
    XCTAssertNil(try? CursorHistoryValueCodec.decode(data))
  }

  // MARK: - Service

  func testMakeSampleUsesTimeBucket() {
    let service = CursorHistoryService(store: InMemoryCursorHistoryStore(), clock: clock)
    let sample = service.makeSample(
      remainingPercent: 80,
      credentialID: CursorUsageStore.credentialID,
      at: Date(timeIntervalSince1970: 1_800_650)
    )
    XCTAssertEqual(sample.bucketStart, Date(timeIntervalSince1970: 1_800_600))
    XCTAssertEqual(sample.observedAt, Date(timeIntervalSince1970: 1_800_650))
    XCTAssertEqual(sample.remainingPercent, 80)
  }

  func testSaveAndFetchWithinWindow() async throws {
    let store = InMemoryCursorHistoryStore()
    let service = CursorHistoryService(store: store, clock: clock)
    let now = clock.now()
    let sample = service.makeSample(
      remainingPercent: 29,
      credentialID: CursorUsageStore.credentialID,
      at: now
    )
    try await service.save(sample: sample)

    let fetched = try await service.recentSamples(
      credentialID: CursorUsageStore.credentialID
    )
    XCTAssertEqual(fetched, [sample])
  }

  func testFetchFiltersOutsideWindow() async throws {
    let store = InMemoryCursorHistoryStore()
    let service = CursorHistoryService(store: store, clock: clock)
    let old = service.makeSample(
      remainingPercent: 50,
      credentialID: CursorUsageStore.credentialID,
      at: clock.now().addingTimeInterval(-100 * 3600)
    )
    try await service.save(sample: old)

    let fetched = try await service.recentSamples(
      credentialID: CursorUsageStore.credentialID
    )
    XCTAssertTrue(fetched.isEmpty)
  }

  func testUpsertSameBucketKeepsLatest() async throws {
    let store = InMemoryCursorHistoryStore()
    let service = CursorHistoryService(store: store, clock: clock)
    let bucket = Date(timeIntervalSince1970: 1_800_000)
    let first = CursorUsageSample(
      credentialID: CursorUsageStore.credentialID,
      bucketStart: bucket,
      observedAt: Date(timeIntervalSince1970: 1_800_600),
      remainingPercent: 40
    )
    let second = CursorUsageSample(
      credentialID: CursorUsageStore.credentialID,
      bucketStart: bucket,
      observedAt: Date(timeIntervalSince1970: 1_801_200),
      remainingPercent: 35
    )
    try await store.upsert(samples: [first], credentialID: CursorUsageStore.credentialID)
    try await store.upsert(samples: [second], credentialID: CursorUsageStore.credentialID)
    let fetched = try await store.fetch(
      credentialID: CursorUsageStore.credentialID,
      from: bucket,
      to: bucket.addingTimeInterval(3600)
    )
    XCTAssertEqual(fetched, [second])
  }

  func testClearHistory() async throws {
    let store = InMemoryCursorHistoryStore()
    let service = CursorHistoryService(store: store, clock: clock)
    try await service.save(
      sample: service.makeSample(
        remainingPercent: 29,
        credentialID: CursorUsageStore.credentialID,
        at: clock.now()
      )
    )
    try await service.clear(credentialID: CursorUsageStore.credentialID)
    let fetched = try await service.recentSamples(
      credentialID: CursorUsageStore.credentialID
    )
    XCTAssertTrue(fetched.isEmpty)
  }

  // MARK: - Trend processor

  private func sample(_ bucket: Int64, remaining: Int) -> CursorUsageSample {
    CursorUsageSample(
      credentialID: "cursor",
      bucketStart: Date(timeIntervalSince1970: TimeInterval(bucket)),
      observedAt: Date(timeIntervalSince1970: TimeInterval(bucket)),
      remainingPercent: remaining
    )
  }

  func testSegmentsMergesConsecutiveBuckets() {
    let samples = [
      sample(1_800_000, remaining: 40),
      sample(1_800_600, remaining: 39),
      sample(1_801_200, remaining: 38),
    ]
    let segments = CursorTrendProcessor.segments(samples)
    XCTAssertEqual(segments.count, 1)
    XCTAssertEqual(segments[0].count, 3)
  }

  func testSegmentsBreaksOnGap() {
    let samples = [
      sample(1_800_000, remaining: 40),
      sample(1_800_600, remaining: 39),
      sample(1_803_000, remaining: 38),  // 间隔 40 分钟 > 20 分钟阈值
      sample(1_803_600, remaining: 37),
    ]
    let segments = CursorTrendProcessor.segments(samples)
    XCTAssertEqual(segments.count, 2)
    XCTAssertEqual(segments[0].count, 2)
    XCTAssertEqual(segments[1].count, 2)
  }

  func testSegmentsDeduplicatesBucketKeepingLatest() {
    let samples = [
      CursorUsageSample(
        credentialID: "cursor",
        bucketStart: Date(timeIntervalSince1970: 1_800_600),
        observedAt: Date(timeIntervalSince1970: 1_800_650),
        remainingPercent: 39
      ),
      CursorUsageSample(
        credentialID: "cursor",
        bucketStart: Date(timeIntervalSince1970: 1_800_000),
        observedAt: Date(timeIntervalSince1970: 1_800_300),
        remainingPercent: 30
      ),
      CursorUsageSample(
        credentialID: "cursor",
        bucketStart: Date(timeIntervalSince1970: 1_800_000),
        observedAt: Date(timeIntervalSince1970: 1_800_100),
        remainingPercent: 40
      ),
    ]
    let segments = CursorTrendProcessor.segments(samples)
    XCTAssertEqual(segments.count, 1)
    // 同桶保留最新 observedAt 的样本（30），并按时间升序。
    XCTAssertEqual(segments[0].map(\.remainingPercent), [30, 39])
  }

  func testSegmentsReturnsEmptyForTooFewSamples() {
    XCTAssertTrue(CursorTrendProcessor.segments([sample(1_800_000, remaining: 40)]).isEmpty)
    XCTAssertTrue(CursorTrendProcessor.segments([]).isEmpty)
  }

  func testPointsProducesFirstPartyAndApiSeries() {
    let samples = [
      CursorUsageSample(
        credentialID: "cursor",
        bucketStart: Date(timeIntervalSince1970: 1_800_000),
        observedAt: Date(timeIntervalSince1970: 1_800_000),
        remainingPercent: 40,
        apiRemainingPercent: 20
      ),
      CursorUsageSample(
        credentialID: "cursor",
        bucketStart: Date(timeIntervalSince1970: 1_800_600),
        observedAt: Date(timeIntervalSince1970: 1_800_600),
        remainingPercent: 39,
        apiRemainingPercent: 18
      ),
    ]
    let points = CursorTrendProcessor.points(samples)
    let firstParty = points.filter { $0.channel == .firstParty }
    let api = points.filter { $0.channel == .api }
    XCTAssertEqual(firstParty.map(\.percent), [40, 39])
    XCTAssertEqual(api.map(\.percent), [20, 18])
    // 两个通道各自一个分段。
    XCTAssertEqual(Set(firstParty.map(\.segment)), [0])
    XCTAssertEqual(Set(api.map(\.segment)), [0])
  }

  func testPointsSkipsApiForLegacySamples() {
    let samples = [sample(1_800_000, remaining: 40), sample(1_800_600, remaining: 39)]
    let points = CursorTrendProcessor.points(samples)
    XCTAssertTrue(points.allSatisfy { $0.channel == .firstParty })
    XCTAssertEqual(points.count, 2)
  }

  func testPointsBreaksEachChannelOnGapIndependently() {
    let samples = [
      sample(1_800_000, remaining: 40),
      sample(1_800_600, remaining: 39),
      sample(1_803_000, remaining: 38),
      sample(1_803_600, remaining: 37),
    ]
    let points = CursorTrendProcessor.points(samples)
    let firstParty = points.filter { $0.channel == .firstParty }
    // 第二段（gap>20 分钟后）分段号递增。
    XCTAssertEqual(Set(firstParty.map(\.segment)), [0, 1])
  }

  func testSegmentsDropsIsolatedSegments() {
    let samples = [
      sample(1_800_000, remaining: 40),
      sample(1_803_000, remaining: 39),
      sample(1_803_600, remaining: 38),
    ]
    let segments = CursorTrendProcessor.segments(samples)
    XCTAssertEqual(segments.count, 1)
    XCTAssertEqual(segments[0].count, 2)
  }
}
