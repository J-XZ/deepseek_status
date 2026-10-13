import XCTest

@testable import DeepSeekBalance

final class XSubscriptionHistoryTests: XCTestCase {
  func testKeyCodecRoundTrip() {
    let credentialID = "xsubscription"
    let bucket = Date(timeIntervalSince1970: 1_700_000_000)
    let key = XSubscriptionHistoryKeyCodec.key(credentialID: credentialID, bucketStart: bucket)
    XCTAssertTrue(key.hasPrefix(XSubscriptionHistoryKeyCodec.schemaPrefix))
    let parsed = XSubscriptionHistoryKeyCodec.parse(key: key)
    XCTAssertEqual(parsed?.credentialID, credentialID)
    XCTAssertEqual(parsed?.bucketSeconds, Int64(bucket.timeIntervalSince1970))
  }

  func testValueCodecStoresRemainingOnly() throws {
    let sample = XSubscriptionUsageSample(
      credentialID: "xsubscription",
      bucketStart: Date(timeIntervalSince1970: 1_700_000_000),
      observedAt: Date(timeIntervalSince1970: 1_700_000_100),
      remainingPercent: 73
    )
    let data = try XSubscriptionHistoryValueCodec.encode(sample: sample)
    let decoded = try XCTUnwrap(XSubscriptionHistoryValueCodec.decode(data))
    XCTAssertEqual(decoded.remainingPercent, 73)
    XCTAssertEqual(decoded.credentialID, "xsubscription")
  }

  func testInMemoryStoreUpsertAndFetch() async throws {
    let store = InMemoryXSubscriptionHistoryStore()
    let service = XSubscriptionHistoryService(store: store, clock: FixedClock(date: Date()))
    let sample = service.makeSample(
      remainingPercent: 55,
      credentialID: "xsubscription",
      at: Date(timeIntervalSince1970: 1_700_000_000)
    )
    try await service.save(sample: sample)
    let fetched = try await store.fetch(
      credentialID: "xsubscription",
      from: Date(timeIntervalSince1970: 0),
      to: Date(timeIntervalSince1970: 1_800_000_000)
    )
    XCTAssertEqual(fetched.count, 1)
    XCTAssertEqual(fetched.first?.remainingPercent, 55)
  }

  func testChartModelZeroSamplesCannotDrawAndUsesRelativeDomain() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let model = XSubscriptionTrendProcessor.chartModel(samples: [], now: now)
    XCTAssertFalse(model.canDraw)
    XCTAssertTrue(model.points.isEmpty)
    XCTAssertNil(model.latestRemainingPercent)
    XCTAssertEqual(model.xDomain.lowerBound, now.addingTimeInterval(-TrendPeriod.fourteenDays.duration))
    XCTAssertEqual(model.xDomain.upperBound, now)
  }

  func testChartModelOneSampleCannotDrawButExposesRemaining() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let model = XSubscriptionTrendProcessor.chartModel(
      samples: [sample(1_800_000_000 - 600, remaining: 73)],
      now: now
    )
    XCTAssertFalse(model.canDraw)
    XCTAssertEqual(model.points.count, 1)
    XCTAssertEqual(model.latestRemainingPercent, 73)
    XCTAssertEqual(model.xDomain.upperBound, now)
    XCTAssertEqual(model.xDomain.lowerBound, now.addingTimeInterval(-TrendPeriod.fourteenDays.duration))
  }

  func testChartModelMultipleSamplesCanDrawOnRelativeDomain() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let samples = [
      sample(1_800_000_000 - 1_200, remaining: 80),
      sample(1_800_000_000 - 600, remaining: 74),
      sample(1_800_000_000, remaining: 73),
    ]
    let model = XSubscriptionTrendProcessor.chartModel(samples: samples, now: now, period: .oneDay)
    XCTAssertTrue(model.canDraw)
    XCTAssertEqual(model.points.map(\.percent), [80, 74, 73])
    XCTAssertEqual(model.latestRemainingPercent, 73)
    XCTAssertEqual(model.xDomain.lowerBound, now.addingTimeInterval(-TrendPeriod.oneDay.duration))
    XCTAssertEqual(model.xDomain.upperBound, now)
  }

  func testChartModelDropsSamplesOutsideCurrentPeriod() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let model = XSubscriptionTrendProcessor.chartModel(
      samples: [
        sample(1_700_000_000, remaining: 40),
        sample(1_800_000_000 - 60, remaining: 90),
      ],
      now: now,
      period: .oneHour
    )
    XCTAssertFalse(model.canDraw)
    XCTAssertEqual(model.latestRemainingPercent, 90)
    XCTAssertEqual(model.xDomain.lowerBound, now.addingTimeInterval(-3_600))
  }

  func testSegmentsKeepOneLineAcrossGap() {
    let samples = [
      sample(1_800_000, remaining: 40),
      sample(1_800_600, remaining: 39),
      sample(1_803_000, remaining: 38),
      sample(1_803_600, remaining: 37),
    ]
    let segments = XSubscriptionTrendProcessor.segments(samples)
    XCTAssertEqual(segments.count, 1)
    XCTAssertEqual(segments[0].map(\.percent), [40, 39, 38, 37])
    XCTAssertEqual(Set(segments[0].map(\.segment)), [0])
  }

  func testMigratorImportsWeeklyPercentsOnceAndDeletesLegacyDirs() async throws {
    let defaults = UserDefaults(suiteName: "XSubscriptionHistoryMigration")!
    defaults.removePersistentDomain(forName: "XSubscriptionHistoryMigration")
    let fileManager = FileManager.default
    let temp = fileManager.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    let grokDir = temp.appendingPathComponent("GrokBotHistory.leveldb", isDirectory: true)
    let cursorDir = temp.appendingPathComponent("CursorHistory.leveldb", isDirectory: true)
    try fileManager.createDirectory(at: grokDir, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: cursorDir, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: grokDir.appendingPathComponent("CURRENT").path, contents: Data())
    FileManager.default.createFile(atPath: cursorDir.appendingPathComponent("CURRENT").path, contents: Data())

    let destination = InMemoryXSubscriptionHistoryStore()
    let legacy = [
      XSubscriptionUsageSample(
        credentialID: "legacy",
        bucketStart: Date(timeIntervalSince1970: 1_700_000_000),
        observedAt: Date(timeIntervalSince1970: 1_700_000_100),
        remainingPercent: 81
      ),
      XSubscriptionUsageSample(
        credentialID: "legacy",
        bucketStart: Date(timeIntervalSince1970: 1_700_000_600),
        observedAt: Date(timeIntervalSince1970: 1_700_000_700),
        remainingPercent: 150
      ),
    ]
    let imported = XSubscriptionHistoryMigrator.importedSamples(
      from: legacy,
      credentialID: "xsubscription"
    )
    XCTAssertEqual(imported.map(\.remainingPercent), [81])
    XCTAssertEqual(imported.first?.credentialID, "xsubscription")
    try await destination.upsert(samples: imported, credentialID: "xsubscription")

    XCTAssertTrue(XSubscriptionHistoryMigrator.shouldMigrate(defaults: defaults))
    XSubscriptionHistoryMigrator.removeLegacyDirectories(
      grokBot: grokDir,
      cursor: cursorDir,
      fileManager: fileManager
    )
    XSubscriptionHistoryMigrator.markMigrated(defaults: defaults)
    XCTAssertFalse(fileManager.fileExists(atPath: grokDir.path))
    XCTAssertFalse(fileManager.fileExists(atPath: cursorDir.path))
    XCTAssertFalse(XSubscriptionHistoryMigrator.shouldMigrate(defaults: defaults))

    await XSubscriptionHistoryMigrator.migrateIfNeeded(
      grokBotDirectory: grokDir,
      cursorDirectory: cursorDir,
      destination: destination,
      credentialID: "xsubscription",
      defaults: defaults,
      fileManager: fileManager
    )
    let count = await destination.count
    XCTAssertEqual(count, 1)
    try? fileManager.removeItem(at: temp)
  }

  private func sample(_ seconds: TimeInterval, remaining: Int) -> XSubscriptionUsageSample {
    XSubscriptionUsageSample(
      credentialID: "xsubscription",
      bucketStart: Date(timeIntervalSince1970: seconds),
      observedAt: Date(timeIntervalSince1970: seconds),
      remainingPercent: remaining
    )
  }
}
