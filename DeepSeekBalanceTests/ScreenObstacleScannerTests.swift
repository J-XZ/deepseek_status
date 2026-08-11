import XCTest

@testable import DeepSeekBalance

@MainActor
final class ScreenObstacleScannerTests: XCTestCase {
  /// 单帧内容单元合并为连通矩形，且坐标从屏幕左下原点生成。
  func testStableRegionsMergeConnectedCells() {
    // 4x4 网格：左上两格为内容。
    let frame: [UInt8] = [1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    let regions = ScreenObstacleScanner.stableRegionsForTesting(
      frame: frame,
      darkFrame: nil,
      width: 4,
      height: 4,
      screenBounds: CGRect(x: 0, y: 0, width: 32, height: 32)
    )
    XCTAssertEqual(regions.count, 1)
    XCTAssertEqual(regions[0].rect.minX, 0)
    XCTAssertEqual(regions[0].rect.minY, 24)
    XCTAssertEqual(regions[0].rect.width, 16)
    XCTAssertEqual(regions[0].rect.height, 8)
  }

  /// 空帧返回空区域。
  func testEmptyFrameReturnsNoRegions() {
    let frame: [UInt8] = [1, 0, 0, 0, 0, 0, 0, 0]
    let regions = ScreenObstacleScanner.stableRegionsForTesting(
      frame: frame,
      darkFrame: nil,
      width: 4,
      height: 2,
      screenBounds: CGRect(x: 0, y: 0, width: 32, height: 16)
    )
    XCTAssertEqual(regions.count, 1)
  }
}
