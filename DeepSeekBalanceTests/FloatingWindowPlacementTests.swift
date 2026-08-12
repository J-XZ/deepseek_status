import CoreGraphics
import XCTest

@testable import DeepSeekBalance

final class FloatingWindowPlacementTests: XCTestCase {
  private let screen = FloatingScreenGeometry(
    visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)
  )
  private let frame = CGRect(x: 0, y: 0, width: 200, height: 32)

  func testCGWindowBoundsAreConvertedToAppKitCoordinates() {
    // 单屏：屏幕 AppKit 高 800，CG y=0 是顶部。
    let topBar = CGRect(x: 0, y: 0, width: 1000, height: 24)
    XCTAssertEqual(
      FloatingPlacement.appKitRect(fromCG: topBar, globalMaxY: 800),
      CGRect(x: 0, y: 776, width: 1000, height: 24)
    )

    // 双屏：上方屏让 AppKit 全局最高点变为 1600。
    let bottomRightWindow = CGRect(x: 100, y: 700, width: 300, height: 100)
    XCTAssertEqual(
      FloatingPlacement.appKitRect(fromCG: bottomRightWindow, globalMaxY: 1600),
      CGRect(x: 100, y: 800, width: 300, height: 100)
    )
  }

  func testSnappedModeOnlyChangesXAndKeepsTop() {
    let current = CGPoint(x: 100, y: 50)
    let origin = tryUnwrap(
      FloatingPlacement.bestOrigin(
        frame: frame,
        screen: screen,
        snappedToMenuBar: true,
        obstacles: [],
        currentOrigin: current
      )
    )
    XCTAssertEqual(origin.y, 800 - frame.height)
    XCTAssertTrue(screen.visibleFrame.contains(CGRect(origin: origin, size: frame.size)))
    XCTAssertTrue(screen.visibleFrame.contains(CGRect(origin: origin, size: frame.size)))
  }

  func testSnappedRespectsNotchSafeArea() {
    let notchedScreen = FloatingScreenGeometry(
      visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
      safeAreaInsets: FloatingSafeAreaInsets(top: 40, left: 0, bottom: 0, right: 0)
    )
    let origin = tryUnwrap(
      FloatingPlacement.bestOrigin(
        frame: frame,
        screen: notchedScreen,
        snappedToMenuBar: true,
        obstacles: [],
        currentOrigin: CGPoint(x: 100, y: 50)
      )
    )
    XCTAssertEqual(origin.y, 800 - 40 - frame.height)
    XCTAssertTrue(notchedScreen.safeFrame.contains(CGRect(origin: origin, size: frame.size)))
  }

  func testSnappedChoosesTopPositionWithLeastObstructionAcrossWholeScreen() {
    let notchedScreen = FloatingScreenGeometry(
      visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
      safeAreaInsets: FloatingSafeAreaInsets(top: 40, left: 0, bottom: 0, right: 0)
    )
    // 顶部行大部分被障碍覆盖，只有最右一段空闲；整屏搜索应选中右段。
    let obstacles = [
      ScreenObstacle(rect: CGRect(x: 8, y: 800 - 40 - 32, width: 700, height: 32)),
    ]
    let origin = tryUnwrap(
      FloatingPlacement.bestOrigin(
        frame: frame,
        screen: notchedScreen,
        snappedToMenuBar: true,
        obstacles: obstacles,
        currentOrigin: CGPoint(x: 100, y: 400)
      )
    )
    let chosen = CGRect(origin: origin, size: frame.size)
    XCTAssertEqual(origin.y, 800 - 40 - frame.height)
    XCTAssertEqual(FloatingPlacement.intersectionArea(chosen, obstacles[0].rect), 0)
    XCTAssertNotEqual(origin.x, 100)
  }

  func testNonSnappedCanChangeBothAxes() {
    let current = CGPoint(x: 100, y: 50)
    // 横向条 + 纵向条组成 L 形遮挡，当前点在横向条内；
    // 零遮挡位置需要同时向右、向上移动。
    let obstacles = [
      ScreenObstacle(rect: CGRect(x: 8, y: 8, width: 784, height: 92)),
      ScreenObstacle(rect: CGRect(x: 100, y: 100, width: 200, height: 692)),
    ]
    let origin = tryUnwrap(
      FloatingPlacement.bestOrigin(
        frame: frame,
        screen: screen,
        snappedToMenuBar: false,
        obstacles: obstacles,
        currentOrigin: current
      )
    )
    XCTAssertNotEqual(origin.x, current.x)
    XCTAssertNotEqual(origin.y, current.y)
    let chosen = CGRect(origin: origin, size: frame.size)
    XCTAssertEqual(FloatingPlacement.intersectionArea(chosen, obstacles[0].rect), 0)
    XCTAssertEqual(FloatingPlacement.intersectionArea(chosen, obstacles[1].rect), 0)
    XCTAssertTrue(screen.visibleFrame.contains(chosen))
  }

  func testChoosesSmallerIntersectionArea() {
    let obstacles = [
      ScreenObstacle(rect: CGRect(x: 8, y: 8, width: 250, height: 32)),
    ]
    let origin = tryUnwrap(
      FloatingPlacement.bestOrigin(
        frame: frame,
        screen: screen,
        snappedToMenuBar: false,
        obstacles: obstacles,
        currentOrigin: CGPoint(x: 8, y: 8)
      )
    )
    let chosen = CGRect(origin: origin, size: frame.size)
    XCTAssertEqual(FloatingPlacement.intersectionArea(chosen, obstacles[0].rect), 0)
  }

  func testFindsNarrowVerticalGapNotOnCoarseGrid() {
    // 障碍几乎覆盖整个中部，只留 700...900 的竖直窄缝；粗网格会错过。
    let obstacles = [
      ScreenObstacle(rect: CGRect(x: 8, y: 8, width: 692, height: 784)),
    ]
    let origin = tryUnwrap(
      FloatingPlacement.bestOrigin(
        frame: frame,
        screen: screen,
        snappedToMenuBar: false,
        obstacles: obstacles,
        currentOrigin: CGPoint(x: 400, y: 400)
      )
    )
    let chosen = CGRect(origin: origin, size: frame.size)
    XCTAssertEqual(origin.x, 700)
    XCTAssertEqual(FloatingPlacement.intersectionArea(chosen, obstacles[0].rect), 0)
  }

  func testFindsNarrowHorizontalGapNotOnCoarseGrid() {
    let obstacles = [
      ScreenObstacle(rect: CGRect(x: 8, y: 8, width: 984, height: 692)),
    ]
    let origin = tryUnwrap(
      FloatingPlacement.bestOrigin(
        frame: frame,
        screen: screen,
        snappedToMenuBar: false,
        obstacles: obstacles,
        currentOrigin: CGPoint(x: 400, y: 400)
      )
    )
    let chosen = CGRect(origin: origin, size: frame.size)
    XCTAssertEqual(origin.y, 700)
    XCTAssertEqual(FloatingPlacement.intersectionArea(chosen, obstacles[0].rect), 0)
  }

  func testIgnoresObstaclesOutsideCurrentScreen() {
    let origin = tryUnwrap(
      FloatingPlacement.bestOrigin(
        frame: frame,
        screen: screen,
        snappedToMenuBar: false,
        obstacles: [
          ScreenObstacle(rect: CGRect(x: 2000, y: 0, width: 500, height: 800)),
        ],
        currentOrigin: CGPoint(x: 100, y: 600)
      )
    )
    XCTAssertTrue(screen.visibleFrame.contains(CGRect(origin: origin, size: frame.size)))
  }

  func testTieBreaksByFullyInsideSafeArea() {
    let safeScreen = FloatingScreenGeometry(
      visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
      safeAreaInsets: FloatingSafeAreaInsets(top: 100, left: 0, bottom: 0, right: 0)
    )
    let origin = tryUnwrap(
      FloatingPlacement.bestOrigin(
        frame: frame,
        screen: safeScreen,
        snappedToMenuBar: false,
        obstacles: [],
        currentOrigin: CGPoint(x: 8, y: 8)
      )
    )
    let chosen = CGRect(origin: origin, size: frame.size)
    XCTAssertTrue(safeScreen.safeFrame.contains(chosen))
  }

  func testGridPrefersGlobalDarkRegionOverCurrentPosition() {
    // 8pt 网格：125x100 覆盖 1000x800 屏幕。暗色区域集中在屏幕底部。
    let width = 125
    let height = 100
    var content = [UInt8](repeating: 0, count: width * height)
    var colors = [UInt32](repeating: 0x000000, count: width * height)
    // row 0 在顶部；底部 64pt 对应 row 92...99。
    for row in 92..<height {
      for col in 0..<width {
        colors[row * width + col] = 0x101010
      }
    }
    // 顶部区域模拟彩色混乱，让单色深色区胜出。
    for row in 0..<4 {
      for col in 0..<width {
        colors[row * width + col] = (col % 2 == 0) ? 0xFF0000 : 0x00FF00
      }
    }
    let grid = FloatingScreenGrid(
      width: width,
      height: height,
      cellSize: 8,
      origin: CGPoint(x: 0, y: 0),
      content: content,
      colors: colors
    )
    let snapshot = ScreenSnapshot(obstacles: [], grid: grid)
    let origin = tryUnwrap(
      FloatingPlacement.bestOrigin(
        frame: frame,
        screen: screen,
        snappedToMenuBar: false,
        snapshot: snapshot,
        currentOrigin: CGPoint(x: 8, y: 768)
      )
    )
    // 全局最优应落在屏幕底部暗色区域。
    XCTAssertEqual(origin.y, 8)
    XCTAssertTrue(screen.visibleFrame.contains(CGRect(origin: origin, size: frame.size)))
  }

  func testGridPrefersSingleColorWhiteRegionOverTextRegion() {
    let width = 125
    let height = 100
    var content = [UInt8](repeating: 0, count: width * height)
    var colors = [UInt32](repeating: 0xFFFFFF, count: width * height)
    // 顶部 32pt 模拟大量文字：每行交替颜色制造颜色杂乱。
    for row in 0..<4 {
      for col in 0..<width {
        colors[row * width + col] = (col % 2 == 0) ? 0x101010 : 0xFFFFFF
        content[row * width + col] = 1
      }
    }
    let grid = FloatingScreenGrid(
      width: width,
      height: height,
      cellSize: 8,
      origin: CGPoint(x: 0, y: 0),
      content: content,
      colors: colors
    )
    let snapshot = ScreenSnapshot(obstacles: [], grid: grid)
    let origin = tryUnwrap(
      FloatingPlacement.bestOrigin(
        frame: frame,
        screen: screen,
        snappedToMenuBar: false,
        snapshot: snapshot,
        currentOrigin: CGPoint(x: 500, y: 600)
      )
    )
    // 全白区域在屏幕底部（y=8）应胜出：避开顶部文字区。
    XCTAssertEqual(origin.y, 8)
  }

  func testGridAvoidsContentWhenNoLargeDarkArea() {
    let width = 125
    let height = 100
    var content = [UInt8](repeating: 0, count: width * height)
    var colors = [UInt32](repeating: 0xFFFFFF, count: width * height)
    // 顶部 32pt 模拟文字：内容标记 + 颜色交替，其余区域纯白。
    for col in 0..<width {
      content[0 * width + col] = 1
      colors[0 * width + col] = (col % 2 == 0) ? 0x101010 : 0xFFFFFF
    }
    for row in 1..<4 {
      for col in 0..<width {
        colors[row * width + col] = (col % 2 == 0) ? 0x101010 : 0xFFFFFF
      }
    }
    let grid = FloatingScreenGrid(
      width: width,
      height: height,
      cellSize: 8,
      origin: CGPoint(x: 0, y: 0),
      content: content,
      colors: colors,
    )
    let snapshot = ScreenSnapshot(obstacles: [], grid: grid)
    let origin = tryUnwrap(
      FloatingPlacement.bestOrigin(
        frame: frame,
        screen: screen,
        snappedToMenuBar: false,
        snapshot: snapshot,
        currentOrigin: CGPoint(x: 500, y: 700)
      )
    )
    // 顶部 32pt 是内容，候选应避开并落在底部纯白区（y=8）。
    XCTAssertEqual(origin.y, 8)
  }

  func testResultStaysWithinCurrentScreen() {
    let origin = tryUnwrap(
      FloatingPlacement.bestOrigin(
        frame: frame,
        screen: screen,
        snappedToMenuBar: false,
        obstacles: [
          ScreenObstacle(rect: CGRect(x: 0, y: 0, width: 1000, height: 800)),
        ],
        currentOrigin: CGPoint(x: 500, y: 400)
      )
    )
    XCTAssertTrue(screen.visibleFrame.contains(CGRect(origin: origin, size: frame.size)))
  }

  func testEmptyObstaclesDegradesToVisiblePosition() {
    let origin = tryUnwrap(
      FloatingPlacement.bestOrigin(
        frame: frame,
        screen: screen,
        snappedToMenuBar: true,
        obstacles: [],
        currentOrigin: CGPoint(x: 300, y: 0)
      )
    )
    XCTAssertTrue(screen.visibleFrame.contains(CGRect(origin: origin, size: frame.size)))
  }

  func testBestScreenUsesMaxIntersectionThenCenterThenFallback() {
    let other = FloatingScreenGeometry(
      visibleFrame: CGRect(x: 1000, y: 0, width: 1000, height: 800)
    )
    let screens = [screen, other]
    XCTAssertEqual(
      FloatingPlacement.bestScreenIndex(
        frame: CGRect(x: 850, y: 100, width: 200, height: 32),
        screens: screens
      ),
      0
    )
    XCTAssertEqual(
      FloatingPlacement.bestScreenIndex(
        frame: CGRect(x: 1200, y: 100, width: 200, height: 32),
        screens: screens
      ),
      1
    )
    XCTAssertEqual(
      FloatingPlacement.bestScreenIndex(
        frame: CGRect(x: -1000, y: -1000, width: 200, height: 32),
        screens: screens,
        fallback: 0
      ),
      0
    )
  }

  private func tryUnwrap<T>(_ value: T?) -> T {
    guard let value else {
      XCTFail("expected non-nil value")
      fatalError("test precondition failed")
    }
    return value
  }
}
