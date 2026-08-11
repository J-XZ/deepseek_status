import Foundation

/// 悬浮窗单击/双击/拖动/右键判定的纯逻辑状态机。
/// 视图层只负责在系统双击判定窗口结束后调用 `confirmPendingSingleClick`，
/// 状态转换可独立单元测试。
struct FloatingWindowClickInterpreter: Equatable, Sendable {
  enum Action: Equatable, Sendable {
    case none
    case singleClick
    case doubleClick
  }

  private(set) var pendingSingleClick = false
  private(set) var didDrag = false

  /// 每次左键按下先取消上一次可能尚未确认的单击。
  /// 第二次按下（clickCount >= 2）直接判定为双击。
  mutating func mouseDown(clickCount: Int) -> Action {
    pendingSingleClick = false
    didDrag = false
    return clickCount >= 2 ? .doubleClick : .none
  }

  /// 拖动开始：取消待确认单击，之后松开不再触发周期切换。
  mutating func mouseDragged() {
    didDrag = true
    pendingSingleClick = false
  }

  /// 左键松开：拖动结束后不产生单击；普通单击进入待确认状态，
  /// 等系统双击判定窗口结束后再确认，避免双击误触发两次切换。
  mutating func mouseUp(clickCount: Int) -> Action {
    if didDrag {
      didDrag = false
      return .none
    }
    if clickCount >= 2 {
      return .doubleClick
    }
    pendingSingleClick = true
    return .none
  }

  /// 右键按下：取消待确认单击，不触发周期切换。
  mutating func rightMouseDown() {
    pendingSingleClick = false
    didDrag = false
  }

  /// 双击判定窗口结束后的确认入口：只有仍是待确认单击时才返回 singleClick。
  mutating func confirmPendingSingleClick() -> Action {
    guard pendingSingleClick else { return .none }
    pendingSingleClick = false
    return .singleClick
  }

  mutating func cancelPendingSingleClick() {
    pendingSingleClick = false
    didDrag = false
  }
}
