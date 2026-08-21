import Foundation

@testable import DeepSeekBalance

actor InMemoryGrokBotHistoryStore: GrokBotHistoryStoring {
  private var samples: [GrokBotUsageSample] = []

  func upsert(samples incoming: [GrokBotUsageSample], credentialID: String) async throws {
    for sample in incoming {
      if let index = samples.firstIndex(where: {
        $0.credentialID == sample.credentialID && $0.bucketStart == sample.bucketStart
      }) {
        samples[index] = sample
      } else {
        samples.append(sample)
      }
    }
  }

  func fetch(credentialID: String, from: Date, to: Date) async throws -> [GrokBotUsageSample] {
    samples
      .filter {
        $0.credentialID == credentialID
          && $0.bucketStart >= from
          && $0.bucketStart <= to
      }
      .sorted { $0.bucketStart < $1.bucketStart }
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
