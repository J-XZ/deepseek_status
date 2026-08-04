import XCTest

@testable import DeepSeekBalance

final class CodexHistoryTests: XCTestCase {
  private let clock = FixedClock(date: Date(timeIntervalSince1970: 1_800_000))

  // MARK: - Key codec

  func testKeyCodecRoundTrip() {
    let date = Date(timeIntervalSince1970: 1_800_600)
    let key = CodexHistoryKeyCodec.key(credentialID: "codex", bucketStart: date)
    XCTAssertEqual(key, "codex/v1/codex/0001800600")
    let parsed = CodexHistoryKeyCodec.parse(key: key)
    XCTAssertEqual(parsed?.credentialID, "codex")
    XCTAssertEqual(parsed?.bucketSeconds, 1_800_600)
  }

  func testKeyCodecRejectsMalformedKeys() {
    XCTAssertNil(CodexHistoryKeyCodec.parse(key: "balance/v1/codex/0001800600"))
    XCTAssertNil(CodexHistoryKeyCodec.parse(key: "codex/v1/codex"))
    XCTAssertNil(CodexHistoryKeyCodec.parse(key: "codex/v1/codex/abc"))
  }

  func testCredentialPrefix() {
    XCTAssertEqual(
      CodexHistoryKeyCodec.credentialPrefix(credentialID: "codex"),
      "codex/v1/codex/"
    )
  }

  // MARK: - Value codec

  func testValueCodecRoundTrip() throws {
    let sample = CodexUsageSample(
      credentialID: "codex",
      bucketStart: Date(timeIntervalSince1970: 1_800_000),
      observedAt: Date(timeIntervalSince1970: 1_800_600),
      remainingPercent: 93
    )
    let data = try CodexHistoryValueCodec.encode(sample: sample)
    let decoded = try XCTUnwrap(CodexHistoryValueCodec.decode(data))
    XCTAssertEqual(decoded, sample)
  }

  func testValueCodecRejectsUnknownVersion() {
    let json = """
      {"version":99,"credential_id":"codex","bucket_start":1800000,
       "observed_at":1800600,"remaining_percent":93}
      """
    let data = Data(json.utf8)
    XCTAssertNil(try? CodexHistoryValueCodec.decode(data))
  }

  func testValueCodecRejectsCorruptData() {
    let data = Data("garbage".utf8)
    XCTAssertNil(try? CodexHistoryValueCodec.decode(data))
  }

  // MARK: - Service

  func testMakeSampleUsesTimeBucket() {
    let service = CodexHistoryService(store: InMemoryCodexHistoryStore(), clock: clock)
    let sample = service.makeSample(
      remainingPercent: 80,
      credentialID: CodexUsageStore.credentialID,
      at: Date(timeIntervalSince1970: 1_800_650)
    )
    XCTAssertEqual(sample.bucketStart, Date(timeIntervalSince1970: 1_800_600))
    XCTAssertEqual(sample.observedAt, Date(timeIntervalSince1970: 1_800_650))
    XCTAssertEqual(sample.remainingPercent, 80)
  }

  func testSaveAndFetchWithinWindow() async throws {
    let store = InMemoryCodexHistoryStore()
    let service = CodexHistoryService(store: store, clock: clock)
    let now = clock.now()
    let sample = service.makeSample(
      remainingPercent: 93,
      credentialID: CodexUsageStore.credentialID,
      at: now
    )
    try await service.save(sample: sample)

    let fetched = try await service.recentSamples(
      credentialID: CodexUsageStore.credentialID
    )
    XCTAssertEqual(fetched, [sample])
  }

  func testFetchFiltersOutsideWindow() async throws {
    let store = InMemoryCodexHistoryStore()
    let service = CodexHistoryService(store: store, clock: clock)
    let old = service.makeSample(
      remainingPercent: 50,
      credentialID: CodexUsageStore.credentialID,
      at: clock.now().addingTimeInterval(-(UsageHistoryWindow.seconds + 1))
    )
    try await service.save(sample: old)

    let fetched = try await service.recentSamples(
      credentialID: CodexUsageStore.credentialID
    )
    XCTAssertTrue(fetched.isEmpty)
  }

  func testUpsertSameBucketKeepsLatest() async throws {
    let store = InMemoryCodexHistoryStore()
    let service = CodexHistoryService(store: store, clock: clock)
    let bucket = Date(timeIntervalSince1970: 1_800_000)
    let first = CodexUsageSample(
      credentialID: CodexUsageStore.credentialID,
      bucketStart: bucket,
      observedAt: Date(timeIntervalSince1970: 1_800_600),
      remainingPercent: 90
    )
    let second = CodexUsageSample(
      credentialID: CodexUsageStore.credentialID,
      bucketStart: bucket,
      observedAt: Date(timeIntervalSince1970: 1_801_200),
      remainingPercent: 85
    )
    try await store.upsert(samples: [first], credentialID: CodexUsageStore.credentialID)
    try await store.upsert(samples: [second], credentialID: CodexUsageStore.credentialID)
    let fetched = try await store.fetch(
      credentialID: CodexUsageStore.credentialID,
      from: bucket,
      to: bucket.addingTimeInterval(3600)
    )
    XCTAssertEqual(fetched, [second])
  }

  func testClearHistory() async throws {
    let store = InMemoryCodexHistoryStore()
    let service = CodexHistoryService(store: store, clock: clock)
    try await service.save(
      sample: service.makeSample(
        remainingPercent: 93,
        credentialID: CodexUsageStore.credentialID,
        at: clock.now()
      )
    )
    try await service.clear(credentialID: CodexUsageStore.credentialID)
    let fetched = try await service.recentSamples(
      credentialID: CodexUsageStore.credentialID
    )
    XCTAssertTrue(fetched.isEmpty)
  }

  // MARK: - Trend processor

  private func sample(_ bucket: Int64, remaining: Int) -> CodexUsageSample {
    CodexUsageSample(
      credentialID: "codex",
      bucketStart: Date(timeIntervalSince1970: TimeInterval(bucket)),
      observedAt: Date(timeIntervalSince1970: TimeInterval(bucket)),
      remainingPercent: remaining
    )
  }

  func testSegmentsMergesConsecutiveBuckets() {
    let samples = [
      sample(1_800_000, remaining: 90),
      sample(1_800_600, remaining: 89),
      sample(1_801_200, remaining: 88),
    ]
    let segments = CodexTrendProcessor.segments(samples)
    XCTAssertEqual(segments.count, 1)
    XCTAssertEqual(segments[0].count, 3)
  }

  func testSegmentsBreaksOnGap() {
    let samples = [
      sample(1_800_000, remaining: 90),
      sample(1_800_600, remaining: 89),
      sample(1_803_000, remaining: 88),  // 间隔 40 分钟 > 20 分钟阈值
      sample(1_803_600, remaining: 87),
    ]
    let segments = CodexTrendProcessor.segments(samples)
    XCTAssertEqual(segments.count, 2)
    XCTAssertEqual(segments[0].count, 2)
    XCTAssertEqual(segments[1].count, 2)
  }

  func testSegmentsDeduplicatesBucketKeepingLatest() {
    let samples = [
      CodexUsageSample(
        credentialID: "codex",
        bucketStart: Date(timeIntervalSince1970: 1_800_600),
        observedAt: Date(timeIntervalSince1970: 1_800_650),
        remainingPercent: 89
      ),
      CodexUsageSample(
        credentialID: "codex",
        bucketStart: Date(timeIntervalSince1970: 1_800_000),
        observedAt: Date(timeIntervalSince1970: 1_800_300),
        remainingPercent: 80
      ),
      CodexUsageSample(
        credentialID: "codex",
        bucketStart: Date(timeIntervalSince1970: 1_800_000),
        observedAt: Date(timeIntervalSince1970: 1_800_100),
        remainingPercent: 90
      ),
    ]
    let segments = CodexTrendProcessor.segments(samples)
    XCTAssertEqual(segments.count, 1)
    // 同桶保留最新 observedAt 的样本（80），并按时间升序。
    XCTAssertEqual(segments[0].map(\.remainingPercent), [80, 89])
  }

  func testSegmentsReturnsEmptyForTooFewSamples() {
    XCTAssertTrue(CodexTrendProcessor.segments([sample(1_800_000, remaining: 90)]).isEmpty)
    XCTAssertTrue(CodexTrendProcessor.segments([]).isEmpty)
  }

  func testSegmentsDropsIsolatedSegments() {
    let samples = [
      sample(1_800_000, remaining: 90),
      sample(1_803_000, remaining: 89),
      sample(1_803_600, remaining: 88),
    ]
    let segments = CodexTrendProcessor.segments(samples)
    XCTAssertEqual(segments.count, 1)
    XCTAssertEqual(segments[0].count, 2)
  }

  func testNearestSampleUsesLatestDuplicateAndNearestTime() {
    let bucket = Date(timeIntervalSince1970: 1_800_000)
    let samples = [
      CodexUsageSample(
        credentialID: "codex",
        bucketStart: bucket,
        observedAt: bucket.addingTimeInterval(60),
        remainingPercent: 90
      ),
      CodexUsageSample(
        credentialID: "codex",
        bucketStart: bucket,
        observedAt: bucket.addingTimeInterval(120),
        remainingPercent: 80
      ),
      sample(1_800_600, remaining: 70),
    ]

    let selected = CodexTrendProcessor.nearestSample(
      to: bucket.addingTimeInterval(30),
      samples: samples
    )
    XCTAssertEqual(selected?.remainingPercent, 80)
  }
}
