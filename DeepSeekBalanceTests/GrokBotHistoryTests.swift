import XCTest

@testable import DeepSeekBalance

final class GrokBotHistoryTests: XCTestCase {
  func testKeyCodecRoundTrip() {
    let credentialID = "grokbot"
    let bucket = Date(timeIntervalSince1970: 1_700_000_000)
    let key = GrokBotHistoryKeyCodec.key(credentialID: credentialID, bucketStart: bucket)
    XCTAssertTrue(key.hasPrefix(GrokBotHistoryKeyCodec.schemaPrefix))
    let parsed = GrokBotHistoryKeyCodec.parse(key: key)
    XCTAssertEqual(parsed?.credentialID, credentialID)
    XCTAssertEqual(parsed?.bucketSeconds, Int64(bucket.timeIntervalSince1970))
  }

  func testValueCodecStoresRemainingOnly() throws {
    let sample = GrokBotUsageSample(
      credentialID: "grokbot",
      bucketStart: Date(timeIntervalSince1970: 1_700_000_000),
      observedAt: Date(timeIntervalSince1970: 1_700_000_100),
      remainingPercent: 73
    )
    let data = try GrokBotHistoryValueCodec.encode(sample: sample)
    let decoded = try XCTUnwrap(GrokBotHistoryValueCodec.decode(data))
    XCTAssertEqual(decoded.remainingPercent, 73)
    XCTAssertEqual(decoded.credentialID, "grokbot")
  }

  func testInMemoryStoreUpsertAndFetch() async throws {
    let store = InMemoryGrokBotHistoryStore()
    let service = GrokBotHistoryService(store: store, clock: FixedClock(date: Date()))
    let sample = service.makeSample(
      remainingPercent: 55,
      credentialID: "grokbot",
      at: Date(timeIntervalSince1970: 1_700_000_000)
    )
    try await service.save(sample: sample)
    let fetched = try await store.fetch(
      credentialID: "grokbot",
      from: Date(timeIntervalSince1970: 0),
      to: Date(timeIntervalSince1970: 1_800_000_000)
    )
    XCTAssertEqual(fetched.count, 1)
    XCTAssertEqual(fetched.first?.remainingPercent, 55)
  }
}
