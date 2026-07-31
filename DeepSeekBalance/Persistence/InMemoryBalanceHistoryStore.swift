import Foundation

/// 内存版历史存储，用于测试与无 LevelDB 环境。
actor InMemoryBalanceHistoryStore: BalanceHistoryStoring {
  private var samples: [BalanceSample] = []

  func upsert(samples incoming: [BalanceSample], credentialID: String) async throws {
    for sample in incoming {
      if let index = samples.firstIndex(where: {
        $0.credentialID == sample.credentialID
          && $0.currency == sample.currency
          && $0.bucketStart == sample.bucketStart
      }) {
        samples[index] = sample
      } else {
        samples.append(sample)
      }
    }
  }

  func fetch(credentialID: String, from: Date, to: Date) async throws -> [BalanceSample] {
    samples
      .filter {
        $0.credentialID == credentialID
          && $0.bucketStart >= from
          && $0.bucketStart <= to
      }
      .sorted {
        if $0.bucketStart == $1.bucketStart { return $0.currency < $1.currency }
        return $0.bucketStart < $1.bucketStart
      }
  }

  func prune(before: Date) async throws {
    samples.removeAll { $0.bucketStart < before }
  }

  func deleteHistory(credentialID: String?) async throws {
    if let credentialID {
      samples.removeAll { $0.credentialID == credentialID }
    } else {
      samples.removeAll()
    }
  }

  var count: Int { samples.count }
}
