import XCTest

@testable import DeepSeekBalance

final class GrokBotExhaustionTests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

  func testForecastAlreadyExhausted() {
    let samples = [
      GrokBotUsageSample(
        credentialID: "grokbot",
        bucketStart: t0.addingTimeInterval(-3600),
        observedAt: t0.addingTimeInterval(-3600),
        remainingPercent: 0
      ),
    ]
    XCTAssertEqual(
      GrokBotExhaustion.forecast(samples: samples, now: t0, resetsAt: t0.addingTimeInterval(86400)),
      .alreadyExhausted
    )
  }

  func testForecastNilWithoutSamples() {
    XCTAssertNil(GrokBotExhaustion.forecast(samples: [], now: t0, resetsAt: nil))
  }

  func testClampToResetDepletesBeforeReset() {
    XCTAssertEqual(
      GrokBotExhaustion.clampToReset(
        seconds: 3600,
        now: t0,
        resetsAt: t0.addingTimeInterval(86400)
      ),
      .depletesBeforeReset(3600)
    )
  }

  func testClampToResetSurvivesUntilReset() {
    let reset = t0.addingTimeInterval(7200)
    XCTAssertEqual(
      GrokBotExhaustion.clampToReset(seconds: 86400, now: t0, resetsAt: reset),
      .survivesUntilReset(7200)
    )
  }

  func testClampToResetNilResetDoesNotClamp() {
    XCTAssertEqual(
      GrokBotExhaustion.clampToReset(seconds: 86400, now: t0, resetsAt: nil),
      .depletesBeforeReset(86400)
    )
  }

  func testClampToResetPastResetDoesNotClamp() {
    XCTAssertEqual(
      GrokBotExhaustion.clampToReset(
        seconds: 86400,
        now: t0,
        resetsAt: t0.addingTimeInterval(-60)
      ),
      .depletesBeforeReset(86400)
    )
  }
}
