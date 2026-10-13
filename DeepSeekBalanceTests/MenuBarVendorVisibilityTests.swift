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
  }

  private func visibility() -> MenuBarVendorVisibility {
    MenuBarVendorVisibility(defaults: defaults)
  }

  func testDefaultsToAllVisible() {
    let visibility = visibility()
    XCTAssertTrue(visibility.showsDeepSeek)
    XCTAssertTrue(visibility.showsCodex)
    XCTAssertTrue(visibility.showsXSubscription)
    XCTAssertTrue(visibility.showsOpenCode)
    XCTAssertTrue(visibility.showsVPS)
    XCTAssertTrue(visibility.isVisible(.deepseek))
    XCTAssertTrue(visibility.isVisible(.codex))
    XCTAssertTrue(visibility.isVisible(.xSubscription))
    XCTAssertTrue(visibility.isVisible(.vps))
  }

  func testToggleCodexOff() {
    let visibility = visibility()
    XCTAssertTrue(visibility.toggle(.codex))
    XCTAssertFalse(visibility.showsCodex)
    XCTAssertTrue(visibility.showsDeepSeek)
    XCTAssertTrue(visibility.showsXSubscription)
    XCTAssertTrue(visibility.isVisible(.deepseek))
    XCTAssertFalse(visibility.isVisible(.codex))
    XCTAssertTrue(visibility.isVisible(.xSubscription))
  }

  func testToggleDeepSeekOff() {
    let visibility = visibility()
    XCTAssertTrue(visibility.toggle(.deepseek))
    XCTAssertFalse(visibility.showsDeepSeek)
    XCTAssertTrue(visibility.showsCodex)
    XCTAssertTrue(visibility.showsXSubscription)
  }

  func testToggleBackOn() {
    let visibility = visibility()
    XCTAssertTrue(visibility.toggle(.codex))
    XCTAssertTrue(visibility.toggle(.codex))
    XCTAssertTrue(visibility.showsCodex)
  }

  func testToggleXSubscriptionOff() {
    let visibility = visibility()
    XCTAssertTrue(visibility.toggle(.xSubscription))
    XCTAssertFalse(visibility.showsXSubscription)
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
    XCTAssertFalse(visibility.toggle(.xSubscription))
    XCTAssertTrue(visibility.showsXSubscription)
    XCTAssertFalse(visibility.showsDeepSeek)
    XCTAssertFalse(visibility.showsCodex)
  }

  func testCannotHideLastVisibleVendorOtherOrder() {
    let visibility = visibility()
    XCTAssertTrue(visibility.toggle(.vps))
    XCTAssertTrue(visibility.toggle(.openCode))
    XCTAssertTrue(visibility.toggle(.codex))
    XCTAssertTrue(visibility.toggle(.xSubscription))
    XCTAssertTrue(visibility.toggle(.commandCode))
    XCTAssertFalse(visibility.toggle(.deepseek))
    XCTAssertTrue(visibility.showsDeepSeek)
    XCTAssertFalse(visibility.showsCodex)
    XCTAssertFalse(visibility.showsXSubscription)
  }

  func testPersistsAcrossInstances() {
    let first = visibility()
    XCTAssertTrue(first.toggle(.deepseek))
    XCTAssertFalse(first.showsDeepSeek)

    let second = visibility()
    XCTAssertFalse(second.showsDeepSeek)
    XCTAssertTrue(second.showsCodex)
    XCTAssertTrue(second.showsXSubscription)
  }

  func testToggleRejectsRejectedState() {
    let visibility = visibility()
    XCTAssertTrue(visibility.toggle(.vps))
    XCTAssertTrue(visibility.toggle(.openCode))
    XCTAssertTrue(visibility.toggle(.deepseek))
    XCTAssertTrue(visibility.toggle(.codex))
    XCTAssertTrue(visibility.toggle(.commandCode))
    XCTAssertFalse(visibility.toggle(.xSubscription))
    XCTAssertFalse(visibility.toggle(.xSubscription))
    XCTAssertTrue(visibility.showsXSubscription)
    XCTAssertFalse(visibility.showsDeepSeek)
    XCTAssertFalse(visibility.showsCodex)
  }

  func testOrderDefaultsToDeclarationOrder() {
    let visibility = visibility()
    XCTAssertEqual(
      visibility.orderedVendors,
      [.deepseek, .codex, .xSubscription, .openCode, .vps, .commandCode]
    )
  }

  func testMovePersistsVisibleOrder() {
    let vis = visibility()
    let reordered = vis.move([.vps, .deepseek, .xSubscription, .openCode, .codex, .commandCode])
    XCTAssertEqual(
      reordered,
      [.vps, .deepseek, .xSubscription, .openCode, .codex, .commandCode]
    )
    let second = visibility()
    XCTAssertEqual(
      second.orderedVendors,
      [.vps, .deepseek, .xSubscription, .openCode, .codex, .commandCode]
    )
    XCTAssertEqual(
      second.orderedVisibleVendors,
      [.vps, .deepseek, .xSubscription, .openCode, .codex, .commandCode]
    )
  }

  func testMoveAppendsHiddenVendorsToKeepFullSet() {
    let vis = visibility()
    XCTAssertTrue(vis.toggle(.codex))
    let reordered = vis.move([.xSubscription, .deepseek, .vps, .openCode, .commandCode])
    XCTAssertEqual(reordered, [.xSubscription, .deepseek, .vps, .openCode, .commandCode, .codex])
    XCTAssertEqual(
      vis.orderedVisibleVendors,
      [.xSubscription, .deepseek, .vps, .openCode, .commandCode]
    )
  }

  func testMoveSingleVendorBeforeTarget() {
    let vis = visibility()
    let reordered = vis.move(.vps, before: .deepseek)
    XCTAssertEqual(reordered, [.vps, .deepseek, .codex, .xSubscription, .openCode, .commandCode])
    XCTAssertEqual(vis.orderedVendors.first, .vps)
  }

  func testMoveSingleVendorToEnd() {
    let vis = visibility()
    let reordered = vis.move(.deepseek, before: nil)
    XCTAssertEqual(reordered, [.codex, .xSubscription, .openCode, .vps, .commandCode, .deepseek])
  }

  func testOrderedVisibleVendorsReflectsVisibility() {
    let vis = visibility()
    XCTAssertTrue(vis.toggle(.openCode))
    XCTAssertEqual(
      vis.orderedVisibleVendors,
      [.deepseek, .codex, .xSubscription, .vps, .commandCode]
    )
  }

  func testOrderedVendorsToleratesIncompleteSavedOrder() {
    defaults.set(
      [MenuBarVendor.vps.rawValue, MenuBarVendor.deepseek.rawValue],
      forKey: MenuBarVendorVisibility.orderKey
    )
    let vis = visibility()
    XCTAssertEqual(
      vis.orderedVendors,
      [.vps, .deepseek, .codex, .xSubscription, .openCode, .commandCode]
    )
  }

  func testOrderedVendorsToleratesDuplicateSavedOrder() {
    defaults.set(
      [1, 1, 2, 0],
      forKey: MenuBarVendorVisibility.orderKey
    )
    let vis = visibility()
    XCTAssertEqual(
      vis.orderedVendors,
      [.codex, .xSubscription, .deepseek, .openCode, .vps, .commandCode]
    )
  }

  func testLegacyCursorAndGrokBotRawValuesMapToXSubscription() {
    defaults.set(
      [0, 1, 2, 3, 4, 5, 6],
      forKey: MenuBarVendorVisibility.orderKey
    )
    let vis = visibility()
    XCTAssertEqual(
      vis.orderedVendors,
      [.deepseek, .codex, .xSubscription, .openCode, .vps, .commandCode]
    )
  }

  func testLegacyVisibilityEitherCursorOrGrokBotShowsXSubscription() {
    defaults.set(false, forKey: MenuBarVendorVisibility.legacyCursorKey)
    defaults.set(true, forKey: MenuBarVendorVisibility.legacyGrokBotKey)
    XCTAssertTrue(visibility().showsXSubscription)

    defaults.removePersistentDomain(forName: suiteName)
    defaults.set(true, forKey: MenuBarVendorVisibility.legacyCursorKey)
    defaults.set(false, forKey: MenuBarVendorVisibility.legacyGrokBotKey)
    XCTAssertTrue(visibility().showsXSubscription)

    defaults.removePersistentDomain(forName: suiteName)
    defaults.set(false, forKey: MenuBarVendorVisibility.legacyCursorKey)
    defaults.set(false, forKey: MenuBarVendorVisibility.legacyGrokBotKey)
    XCTAssertFalse(visibility().showsXSubscription)
  }

  func testMoveVendorBeforeWritesCompleteOrder() {
    let vis = visibility()
    XCTAssertTrue(vis.toggle(.openCode))
    _ = vis.move(.vps, before: .deepseek)
    let reloaded = visibility()
    XCTAssertEqual(
      reloaded.orderedVendors,
      [.vps, .deepseek, .codex, .xSubscription, .commandCode, .openCode]
    )
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
      MenuBarIconLayout.xSubscriptionMaxDimension,
      MenuBarIconLayout.codexMaxDimension
    )
    XCTAssertEqual(
      MenuBarIconLayout.vpsMaxDimension,
      MenuBarIconLayout.codexMaxDimension
    )
  }

  func testCompactMenuBarFontIsSmallerThanRegular() {
    XCTAssertLessThan(
      MenuBarDisplayLayout.compactFontSize,
      MenuBarDisplayLayout.regularFontSize
    )
    XCTAssertLessThan(
      MenuBarDisplayLayout.compactLineHeight,
      MenuBarIconLayout.xSubscriptionMaxDimension
    )
    XCTAssertGreaterThan(MenuBarDisplayLayout.compactVerticalInset, 0)
  }
}
