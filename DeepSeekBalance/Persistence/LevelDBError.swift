import Foundation

enum LevelDBError: Error, LocalizedError, Equatable {
  case openFailed(String)
  case readFailed(String)
  case writeFailed(String)
  case deleteFailed(String)
  case notOpen
  case unavailable
  case invalidPath
  case corruptRecord

  var errorDescription: String? {
    switch self {
    case .openFailed(let detail):
      return "无法打开本地历史数据库（\(detail)）"
    case .readFailed(let detail):
      return "无法读取本地历史数据库（\(detail)）"
    case .writeFailed(let detail):
      return "无法写入本地历史数据库（\(detail)）"
    case .deleteFailed(let detail):
      return "无法清理本地历史数据库（\(detail)）"
    case .notOpen:
      return "本地历史数据库未打开"
    case .unavailable:
      return "本地历史存储不可用"
    case .invalidPath:
      return "本地历史数据库路径无效"
    case .corruptRecord:
      return "本地历史记录已损坏"
    }
  }
}
