import XCTest

@testable import DeepSeekBalance

final class CompactRemainingTests: XCTestCase {
  func testOmitsZeroUnits() {
    XCTAssertEqual(CompactRemaining.ascii(93_603), "1D2H3S")
    XCTAssertEqual(CompactRemaining.ascii(90_183), "1D1H3M3S")
    XCTAssertEqual(CompactRemaining.ascii(3_661), "1H1M1S")
    XCTAssertEqual(CompactRemaining.ascii(61), "1M1S")
    XCTAssertEqual(CompactRemaining.ascii(60), "1M")
    XCTAssertEqual(CompactRemaining.ascii(3_600), "1H")
    XCTAssertEqual(CompactRemaining.ascii(3_601), "1H1S")
    XCTAssertEqual(CompactRemaining.ascii(86_400), "1D")
    XCTAssertEqual(CompactRemaining.ascii(86_700), "1D5M")
    XCTAssertEqual(CompactRemaining.ascii(90_061), "1D1H1M1S")
    XCTAssertEqual(CompactRemaining.ascii(59), "59S")
  }

  func testFloorsAndClampsToZeroSeconds() {
    XCTAssertEqual(CompactRemaining.ascii(1.9), "1S")
    XCTAssertEqual(CompactRemaining.ascii(0.9), "0S")
    XCTAssertEqual(CompactRemaining.ascii(0), "0S")
    XCTAssertEqual(CompactRemaining.ascii(-12), "0S")
    XCTAssertEqual(CompactRemaining.ascii(.infinity), "0S")
    XCTAssertEqual(CompactRemaining.ascii(.nan), "0S")
  }
}
