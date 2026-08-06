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
    XCTAssertTrue(visibility.showsVPS)
    XCTAssertTrue(visibility.isVisible(.deepseek))
    XCTAssertTrue(visibility.isVisible(.codex))
    XCTAssertTrue(visibility.isVisible(.cursor))
    XCTAssertTrue(visibility.isVisible(.vps))
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

  func testToggleVPSOff() {
    let visibility = visibility()
    XCTAssertTrue(visibility.toggle(.vps))
    XCTAssertFalse(visibility.showsVPS)
    XCTAssertTrue(visibility.isVisible(.openCode))
  }

  func testCannotHideLastVisibleVendor() {
    let visibility = visibility()
    XCTAssertTrue(visibility.toggle(.vps))
    XCTAssertTrue(visibility.toggle(.openCode))
    XCTAssertTrue(visibility.toggle(.deepseek))
    XCTAssertTrue(visibility.toggle(.codex))
    XCTAssertTrue(visibility.toggle(.commandCode))
    // 只剩 Cursor 可见时不可再隐藏。
    XCTAssertFalse(visibility.toggle(.cursor))
    XCTAssertTrue(visibility.showsCursor)
    XCTAssertFalse(visibility.showsDeepSeek)
    XCTAssertFalse(visibility.showsCodex)
  }

  func testCannotHideLastVisibleVendorOtherOrder() {
    let visibility = visibility()
    XCTAssertTrue(visibility.toggle(.vps))
    XCTAssertTrue(visibility.toggle(.openCode))
    XCTAssertTrue(visibility.toggle(.codex))
    XCTAssertTrue(visibility.toggle(.cursor))
    XCTAssertTrue(visibility.toggle(.commandCode))
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
    XCTAssertTrue(visibility.toggle(.vps))
    XCTAssertTrue(visibility.toggle(.openCode))
    XCTAssertTrue(visibility.toggle(.deepseek))
    XCTAssertTrue(visibility.toggle(.codex))
    XCTAssertTrue(visibility.toggle(.commandCode))
    XCTAssertFalse(visibility.toggle(.cursor))
    XCTAssertFalse(visibility.toggle(.cursor))
    XCTAssertTrue(visibility.showsCursor)
    XCTAssertFalse(visibility.showsDeepSeek)
    XCTAssertFalse(visibility.showsCodex)
  }

  func testOrderDefaultsToDeclarationOrder() {
    let visibility = visibility()
    XCTAssertEqual(
      visibility.orderedVendors,
      [.deepseek, .codex, .cursor, .openCode, .vps, .commandCode]
    )
  }

  func testMovePersistsVisibleOrder() {
    let vis = visibility()
    let reordered = vis.move([.vps, .deepseek, .cursor, .openCode, .codex, .commandCode])
    XCTAssertEqual(reordered, [.vps, .deepseek, .cursor, .openCode, .codex, .commandCode])
    // 持久化：新实例读取相同顺序。
    let second = visibility()
    XCTAssertEqual(
      second.orderedVendors,
      [.vps, .deepseek, .cursor, .openCode, .codex, .commandCode]
    )
    XCTAssertEqual(
      second.orderedVisibleVendors,
      [.vps, .deepseek, .cursor, .openCode, .codex, .commandCode]
    )
  }

  func testMoveAppendsHiddenVendorsToKeepFullSet() {
    let vis = visibility()
    XCTAssertTrue(vis.toggle(.codex))
    let reordered = vis.move([.cursor, .deepseek, .vps, .openCode, .commandCode])
    XCTAssertEqual(reordered, [.cursor, .deepseek, .vps, .openCode, .commandCode, .codex])
    // 隐藏的 Codex 不参与可见顺序。
    XCTAssertEqual(
      vis.orderedVisibleVendors,
      [.cursor, .deepseek, .vps, .openCode, .commandCode]
    )
  }

  func testMoveSingleVendorBeforeTarget() {
    let vis = visibility()
    let reordered = vis.move(.vps, before: .deepseek)
    XCTAssertEqual(reordered, [.vps, .deepseek, .codex, .cursor, .openCode, .commandCode])
    XCTAssertEqual(vis.orderedVendors.first, .vps)
  }

  func testMoveSingleVendorToEnd() {
    let vis = visibility()
    let reordered = vis.move(.deepseek, before: nil)
    XCTAssertEqual(reordered, [.codex, .cursor, .openCode, .vps, .commandCode, .deepseek])
  }

  func testOrderedVisibleVendorsReflectsVisibility() {
    let vis = visibility()
    XCTAssertTrue(vis.toggle(.openCode))
    XCTAssertEqual(
      vis.orderedVisibleVendors,
      [.deepseek, .codex, .cursor, .vps, .commandCode]
    )
  }

  func testOrderedVendorsToleratesIncompleteSavedOrder() {
    // 旧版本可能只保存了可见供应商子集；读取时缺失项按声明顺序补尾。
    defaults.set(
      [MenuBarVendor.vps.rawValue, MenuBarVendor.deepseek.rawValue],
      forKey: MenuBarVendorVisibility.orderKey
    )
    let vis = visibility()
    XCTAssertEqual(
      vis.orderedVendors,
      [.vps, .deepseek, .codex, .cursor, .openCode, .commandCode]
    )
  }

  func testOrderedVendorsToleratesDuplicateSavedOrder() {
    defaults.set(
      [1, 1, 2, 0],  // codex 重复、deepseek 置后
      forKey: MenuBarVendorVisibility.orderKey
    )
    let vis = visibility()
    XCTAssertEqual(
      vis.orderedVendors,
      [.codex, .cursor, .deepseek, .openCode, .vps, .commandCode]
    )
  }

  func testMoveVendorBeforeWritesCompleteOrder() {
    let vis = visibility()
    // 先隐藏一个供应商，再移动另一个；存储仍须包含全部供应商。
    XCTAssertTrue(vis.toggle(.openCode))
    _ = vis.move(.vps, before: .deepseek)
    let reloaded = visibility()
    XCTAssertEqual(
      reloaded.orderedVendors,
      [.vps, .deepseek, .codex, .cursor, .commandCode, .openCode]
    )
    // 新实例读取顺序与写入一致，不会回退默认。
    XCTAssertEqual(reloaded.orderedVendors.first, .vps)
  }

  func testToggleVisibilityPersistsAcrossInstances() {
    let vis = visibility()
    XCTAssertTrue(vis.toggle(.vps))
    XCTAssertTrue(vis.toggle(.commandCode))
    XCTAssertFalse(vis.showsVPS)
    XCTAssertFalse(vis.showsCommandCode)

    let reloaded = visibility()
    XCTAssertFalse(reloaded.showsVPS)
    XCTAssertFalse(reloaded.showsCommandCode)
    XCTAssertTrue(reloaded.showsDeepSeek)
    XCTAssertTrue(reloaded.showsCodex)
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
    XCTAssertEqual(
      MenuBarIconLayout.vpsMaxDimension,
      MenuBarIconLayout.codexMaxDimension
    )
  }
}
