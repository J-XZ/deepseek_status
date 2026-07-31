import Foundation

/// 余额历史存储抽象。实现必须保证并发安全且不阻塞调用方线程。
protocol BalanceHistoryStoring: Sendable {
  func upsert(samples: [BalanceSample], credentialID: String) async throws
  func fetch(credentialID: String, from: Date, to: Date) async throws -> [BalanceSample]
  func prune(before: Date) async throws
  func deleteHistory(credentialID: String?) async throws
}

/// LevelDB 不可用时使用的空实现：余额功能不受影响，历史区域显示错误。
struct UnavailableBalanceHistoryStore: BalanceHistoryStoring {
  func upsert(samples: [BalanceSample], credentialID: String) async throws {
    throw LevelDBError.unavailable
  }

  func fetch(credentialID: String, from: Date, to: Date) async throws -> [BalanceSample] {
    throw LevelDBError.unavailable
  }

  func prune(before: Date) async throws {
    throw LevelDBError.unavailable
  }

  func deleteHistory(credentialID: String?) async throws {
    throw LevelDBError.unavailable
  }
}
