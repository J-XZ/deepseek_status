import Foundation

enum CursorConnectRPC {
  static func postRequest(
    url: URL,
    accessToken: String,
    timeoutInterval: TimeInterval
  ) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    // Cursor 客户端后端要求该协议版本头。
    request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
    request.httpBody = Data("{}".utf8)
    request.timeoutInterval = timeoutInterval
    return request
  }
}
