import AppKit
import XCTest

@testable import DeepSeekBalance

enum LoginItemTestError: Error {
  case failed
}

@MainActor
final class FakeLoginItemManager: LoginItemManaging {
  var current: LoginItemStatus = .notRegistered
  var currentStatusCount = 0
  var setEnabledResult: Result<LoginItemStatus, Error>?
  var openSettingsCount = 0

  func currentStatus() async -> LoginItemStatus {
    currentStatusCount += 1
    return current
  }

  func setEnabled(_ enabled: Bool) async throws -> LoginItemStatus {
    guard let setEnabledResult else { return current }
    return try setEnabledResult.get()
  }

  func openSystemSettings() {
    openSettingsCount += 1
  }
}

@MainActor
final class LoginItemTests: XCTestCase {
  private func makeStore(
    manager: FakeLoginItemManager,
    initialSync: Bool = false
  ) -> LoginItemStore {
    LoginItemStore(manager: manager, initialSync: initialSync)
  }

  func testInitialEnabled() async {
    let manager = FakeLoginItemManager()
    manager.current = .enabled
    let store = makeStore(manager: manager)
    await store.syncFromSystem()
    XCTAssertEqual(store.status, .enabled)
  }

  func testInitialNotRegistered() async {
    let manager = FakeLoginItemManager()
    manager.current = .notRegistered
    let store = makeStore(manager: manager)
    await store.syncFromSystem()
    XCTAssertEqual(store.status, .notRegistered)
  }

  func testRequiresApproval() async {
    let manager = FakeLoginItemManager()
    manager.current = .requiresApproval
    let store = makeStore(manager: manager)
    await store.syncFromSystem()
    XCTAssertEqual(store.status, .requiresApproval)
  }

  func testNotFound() async {
    let manager = FakeLoginItemManager()
    manager.current = .notFound
    let store = makeStore(manager: manager)
    await store.syncFromSystem()
    XCTAssertEqual(store.status, .notFound)
  }

  func testEnableSuccess() async {
    let manager = FakeLoginItemManager()
    manager.setEnabledResult = .success(.enabled)
    let store = makeStore(manager: manager)
    await store.setEnabled(true)
    XCTAssertEqual(store.status, .enabled)
    XCTAssertNil(store.lastError)
  }

  func testDisableSuccess() async {
    let manager = FakeLoginItemManager()
    manager.setEnabledResult = .success(.notRegistered)
    let store = makeStore(manager: manager)
    await store.setEnabled(false)
    XCTAssertEqual(store.status, .notRegistered)
  }

  func testAlreadyRegisteredIsIdempotentSuccess() async {
    let manager = FakeLoginItemManager()
    manager.setEnabledResult = .success(.enabled)
    let store = makeStore(manager: manager)
    await store.setEnabled(true)
    XCTAssertEqual(store.status, .enabled)
    XCTAssertNil(store.lastError)
  }

  func testAlreadyUnregisteredIsIdempotentSuccess() async {
    let manager = FakeLoginItemManager()
    manager.setEnabledResult = .success(.notRegistered)
    let store = makeStore(manager: manager)
    await store.setEnabled(false)
    XCTAssertEqual(store.status, .notRegistered)
    XCTAssertNil(store.lastError)
  }

  func testRegisterFailureRollsBackToRealStatus() async {
    let manager = FakeLoginItemManager()
    manager.setEnabledResult = .failure(LoginItemTestError.failed)
    manager.current = .notRegistered
    let store = makeStore(manager: manager)
    await store.setEnabled(true)
    XCTAssertEqual(store.status, .notRegistered)
    XCTAssertNotNil(store.lastError)
  }

  func testUnregisterFailureRollsBackToRealStatus() async {
    let manager = FakeLoginItemManager()
    manager.setEnabledResult = .failure(LoginItemTestError.failed)
    manager.current = .enabled
    let store = makeStore(manager: manager)
    await store.setEnabled(false)
    XCTAssertEqual(store.status, .enabled)
    XCTAssertNotNil(store.lastError)
  }

  func testUserRejectionMapsToRequiresApproval() async {
    let manager = FakeLoginItemManager()
    manager.setEnabledResult = .success(.requiresApproval)
    let store = makeStore(manager: manager)
    await store.setEnabled(true)
    XCTAssertEqual(store.status, .requiresApproval)
  }

  func testActiveEventResyncsFromSystem() async {
    let manager = FakeLoginItemManager()
    manager.current = .notRegistered
    let store = makeStore(manager: manager)

    manager.current = .enabled
    NotificationCenter.default.post(
      name: NSApplication.didBecomeActiveNotification,
      object: nil
    )

    let deadline = Date().addingTimeInterval(2)
    while manager.currentStatusCount == 0, Date() < deadline {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertGreaterThanOrEqual(manager.currentStatusCount, 1)
    XCTAssertEqual(store.status, .enabled)
    _ = store
  }

  func testOpenSystemSettingsAction() async {
    let manager = FakeLoginItemManager()
    let store = makeStore(manager: manager)
    store.openSystemSettings()
    XCTAssertEqual(manager.openSettingsCount, 1)
  }
}
