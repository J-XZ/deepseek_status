import Foundation

/// 记录 observer token 与其注册中心，确保从同一个 center 删除。
struct NotificationObservation {
  let center: NotificationCenter
  let token: NSObjectProtocol

  func remove() {
    center.removeObserver(token)
  }
}
