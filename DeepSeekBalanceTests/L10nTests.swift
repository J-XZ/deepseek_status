import XCTest

@testable import DeepSeekBalance

final class L10nTests: XCTestCase {
  func testAllKeysHaveBothLanguagesWithoutRawFallback() {
    for key in L10nKey.allCases {
      let en = L10n.string(key, language: .english)
      let zh = L10n.string(key, language: .simplifiedChinese)
      XCTAssertNotEqual(en, key.rawValue, "en 缺少翻译：\(key.rawValue)")
      XCTAssertNotEqual(zh, key.rawValue, "zh-Hans 缺少翻译：\(key.rawValue)")
      XCTAssertFalse(en.isEmpty)
      XCTAssertFalse(zh.isEmpty)
    }
  }

  func testBothLprojBundlesExist() {
    XCTAssertNotNil(Bundle.main.path(forResource: "en", ofType: "lproj"))
    XCTAssertNotNil(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"))
  }

  func testFormatArguments() {
    XCTAssertEqual(
      L10n.string(.errorHttp, language: .english, 500),
      "Service returned error (500)"
    )
    XCTAssertEqual(
      L10n.string(.errorHttp, language: .simplifiedChinese, 500),
      "服务返回错误（500）"
    )
    XCTAssertEqual(
      L10n.string(.balanceLastUpdated, language: .english, "now"),
      "Last updated: now"
    )
  }

  func testKnownEnglishValues() {
    XCTAssertEqual(L10n.string(.menuBarNotConfigured, language: .english), "Not configured")
    XCTAssertEqual(L10n.string(.indicatorNone, language: .english), "All Systems Operational")
    XCTAssertEqual(L10n.string(.componentMajorOutage, language: .english), "Major outage")
    XCTAssertEqual(L10n.string(.incidentInvestigating, language: .english), "Investigating")
    XCTAssertEqual(L10n.string(.impactCritical, language: .english), "Critical")
    XCTAssertEqual(
      L10n.string(.errorServer, language: .english, 503),
      "Service temporarily unavailable (503)"
    )
    XCTAssertEqual(
      L10n.string(.errorServer, language: .simplifiedChinese, 503),
      "服务暂时不可用（503）"
    )
    XCTAssertEqual(
      L10n.string(.codexTrendSummary, language: .english, "+5%"),
      "Usage change over the last 72 hours: +5%"
    )
    XCTAssertEqual(
      L10n.string(.codexCreditsBalance, language: .english),
      "Balance"
    )
    XCTAssertEqual(
      L10n.string(.appTitle, language: .simplifiedChinese),
      "DeepSeek API 余额"
    )
  }
}
