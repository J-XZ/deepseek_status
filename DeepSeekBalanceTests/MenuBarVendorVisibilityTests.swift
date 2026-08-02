import XCTest

@testable import DeepSeekBalance

final class MenuBarVendorVisibilityTests: XCTestCase {
  private var suiteName = "MenuBarVendorVisibilityTests"
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    defaults = UserDefaults(suiteName: suiteName)
    defaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  private func visibility() -> MenuBarVendorVisibility {
    MenuBarVendorVisibility(defaults: defaults)
  }

  func testDefaultsToAllVisible() {
    let visibility = visibility()
    XCTAssertTrue(visibility.showsDeepSeek)
    XCTAssertTrue(visibility.showsCodex)
    XCTAssertTrue(visibility.showsCursor)
    XCTAssertTrue(visibility.showsOpenCode)
    XCTAssertTrue(visibility.isVisible(.deepseek))
    XCTAssertTrue(visibility.isVisible(.codex))
    XCTAssertTrue(visibility.isVisible(.cursor))
  }

  func testToggleCodexOff() {
    let visibility = visibility()
    XCTAssertTrue(visibility.toggle(.codex))
    XCTAssertFalse(visibility.showsCodex)
    XCTAssertTrue(visibility.showsDeepSeek)
    XCTAssertTrue(visibility.showsCursor)
    XCTAssertTrue(visibility.isVisible(.deepseek))
    XCTAssertFalse(visibility.isVisible(.codex))
    XCTAssertTrue(visibility.isVisible(.cursor))
  }

  func testToggleDeepSeekOff() {
    let visibility = visibility()
    XCTAssertTrue(visibility.toggle(.deepseek))
    XCTAssertFalse(visibility.showsDeepSeek)
    XCTAssertTrue(visibility.showsCodex)
    XCTAssertTrue(visibility.showsCursor)
  }

  func testToggleBackOn() {
    let visibility = visibility()
    XCTAssertTrue(visibility.toggle(.codex))
    XCTAssertTrue(visibility.toggle(.codex))
    XCTAssertTrue(visibility.showsCodex)
  }

  func testToggleCursorOff() {
    let visibility = visibility()
    XCTAssertTrue(visibility.toggle(.cursor))
    XCTAssertFalse(visibility.showsCursor)
    XCTAssertTrue(visibility.showsDeepSeek)
    XCTAssertTrue(visibility.showsCodex)
  }

  func testCannotHideLastVisibleVendor() {
    let visibility = visibility()
    XCTAssertTrue(visibility.toggle(.openCode))
    XCTAssertTrue(visibility.toggle(.deepseek))
    XCTAssertTrue(visibility.toggle(.codex))
    // 只剩 Cursor 可见时不可再隐藏。
    XCTAssertFalse(visibility.toggle(.cursor))
    XCTAssertTrue(visibility.showsCursor)
    XCTAssertFalse(visibility.showsDeepSeek)
    XCTAssertFalse(visibility.showsCodex)
  }

  func testCannotHideLastVisibleVendorOtherOrder() {
    let visibility = visibility()
    XCTAssertTrue(visibility.toggle(.openCode))
    XCTAssertTrue(visibility.toggle(.codex))
    XCTAssertTrue(visibility.toggle(.cursor))
    // 只剩 DeepSeek 可见时不可再隐藏。
    XCTAssertFalse(visibility.toggle(.deepseek))
    XCTAssertTrue(visibility.showsDeepSeek)
    XCTAssertFalse(visibility.showsCodex)
    XCTAssertFalse(visibility.showsCursor)
  }

  func testPersistsAcrossInstances() {
    let first = visibility()
    XCTAssertTrue(first.toggle(.deepseek))
    XCTAssertFalse(first.showsDeepSeek)

    let second = visibility()
    XCTAssertFalse(second.showsDeepSeek)
    XCTAssertTrue(second.showsCodex)
    XCTAssertTrue(second.showsCursor)
  }

  func testToggleRejectsRejectedState() {
    let visibility = visibility()
    XCTAssertTrue(visibility.toggle(.openCode))
    XCTAssertTrue(visibility.toggle(.deepseek))
    XCTAssertTrue(visibility.toggle(.codex))
    XCTAssertFalse(visibility.toggle(.cursor))
    XCTAssertFalse(visibility.toggle(.cursor))
    XCTAssertTrue(visibility.showsCursor)
    XCTAssertFalse(visibility.showsDeepSeek)
    XCTAssertFalse(visibility.showsCodex)
  }

  func testCursorMenuBarTextStacksTwoChannelsVertically() {
    XCTAssertEqual(
      MenuBarDisplayLayout.cursorText("30% (+20%)/17% (+33%)"),
      "30% (+20%)\n17% (+33%)"
    )
  }

  func testCursorMenuBarTextKeepsSingleChannelOnOneLine() {
    XCTAssertEqual(MenuBarDisplayLayout.cursorText("30% (+20%)"), "30% (+20%)")
  }

  func testCursorMenuBarUsesSmallerFont() {
    XCTAssertLessThan(
      MenuBarDisplayLayout.cursorFontSize,
      MenuBarDisplayLayout.regularFontSize
    )
  }

  func testCursorMenuBarUsesCompactLinesWithTopInset() {
    XCTAssertLessThan(
      MenuBarDisplayLayout.cursorLineHeight,
      MenuBarIconLayout.cursorMaxDimension
    )
    XCTAssertGreaterThan(MenuBarDisplayLayout.cursorVerticalInset, 0)
  }

  func testMenuBarIconLayoutPreservesAspectRatio() {
    let size = MenuBarIconLayout.fittingSize(
      NSSize(width: 466.73, height: 532.09),
      maxDimension: 10
    )

    XCTAssertEqual(size.height, 10, accuracy: 0.001)
    XCTAssertEqual(size.width / size.height, 466.73 / 532.09, accuracy: 0.001)
    XCTAssertLessThan(size.width, size.height)
  }

  func testMenuBarIconSizesBalanceOpticalHeight() {
    XCTAssertGreaterThan(
      MenuBarIconLayout.deepSeekMaxDimension,
      MenuBarIconLayout.codexMaxDimension
    )
    XCTAssertEqual(
      MenuBarIconLayout.cursorMaxDimension,
      MenuBarIconLayout.codexMaxDimension
    )
  }
}
