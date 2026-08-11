import XCTest

@testable import DeepSeekBalance

final class FloatingWindowClickInterpreterTests: XCTestCase {
  func testSingleClickConfirmsAfterDoubleClickWindow() {
    var interpreter = FloatingWindowClickInterpreter()
    XCTAssertEqual(interpreter.mouseDown(clickCount: 1), .none)
    XCTAssertEqual(interpreter.mouseUp(clickCount: 1), .none)
    XCTAssertTrue(interpreter.pendingSingleClick)
    XCTAssertEqual(interpreter.confirmPendingSingleClick(), .singleClick)
    XCTAssertEqual(interpreter.confirmPendingSingleClick(), .none)
  }

  func testDoubleClickCancelsSingleClickAndReturnsDouble() {
    var interpreter = FloatingWindowClickInterpreter()
    _ = interpreter.mouseDown(clickCount: 1)
    _ = interpreter.mouseUp(clickCount: 1)
    XCTAssertTrue(interpreter.pendingSingleClick)
    XCTAssertEqual(interpreter.mouseDown(clickCount: 2), .doubleClick)
    XCTAssertFalse(interpreter.pendingSingleClick)
    XCTAssertEqual(interpreter.confirmPendingSingleClick(), .none)
  }

  func testDragCancelsPendingSingleClick() {
    var interpreter = FloatingWindowClickInterpreter()
    _ = interpreter.mouseDown(clickCount: 1)
    _ = interpreter.mouseUp(clickCount: 1)
    interpreter.mouseDragged()
    XCTAssertFalse(interpreter.pendingSingleClick)
    XCTAssertEqual(interpreter.mouseUp(clickCount: 1), .none)
    XCTAssertEqual(interpreter.confirmPendingSingleClick(), .none)
  }

  func testDragBeforeReleaseDoesNotProduceClick() {
    var interpreter = FloatingWindowClickInterpreter()
    _ = interpreter.mouseDown(clickCount: 1)
    interpreter.mouseDragged()
    XCTAssertEqual(interpreter.mouseUp(clickCount: 1), .none)
    XCTAssertEqual(interpreter.confirmPendingSingleClick(), .none)
  }

  func testRightClickCancelsPendingSingleClick() {
    var interpreter = FloatingWindowClickInterpreter()
    _ = interpreter.mouseDown(clickCount: 1)
    _ = interpreter.mouseUp(clickCount: 1)
    interpreter.rightMouseDown()
    XCTAssertFalse(interpreter.pendingSingleClick)
    XCTAssertEqual(interpreter.confirmPendingSingleClick(), .none)
  }

  func testConfirmWithoutPendingReturnsNone() {
    var interpreter = FloatingWindowClickInterpreter()
    XCTAssertEqual(interpreter.confirmPendingSingleClick(), .none)
  }
}
