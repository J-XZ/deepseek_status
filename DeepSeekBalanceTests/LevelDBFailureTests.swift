import Foundation
import XCTest

@testable import DeepSeekBalance

/// 线程安全计数器，验证失败路径的资源释放次数。
final class ResourceCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: Int] = [:]

  func increment(_ key: String) {
    lock.lock()
    values[key, default: 0] += 1
    lock.unlock()
  }

  func count(_ key: String) -> Int {
    lock.lock()
    defer { lock.unlock() }
    return values[key, default: 0]
  }
}

final class LevelDBFailureTests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 1_752_000_000)
  private var directory: URL!

  override func setUp() {
    super.setUp()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("LevelDBFailureTests-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: directory)
    try await super.tearDown()
  }

  private var fakeOptions: OpaquePointer { OpaquePointer(bitPattern: 0x1234)! }
  private var fakeDB: OpaquePointer { OpaquePointer(bitPattern: 0x5678)! }

  private func makeDependencies(
    counter: ResourceCounter,
    options: OpaquePointer? = nil,
    readOptions: OpaquePointer? = nil,
    writeOptions: OpaquePointer? = nil,
    directoryError: Error? = nil,
    openResult: OpaquePointer? = nil,
    openErrorText: String? = nil
  ) -> LevelDBDependencies {
    var deps = LevelDBDependencies.live
    deps.createOptions = { options }
    // 假指针绝不能传给真实 C 函数。
    deps.setCreateIfMissing = { _ in }
    deps.createReadOptions = { readOptions }
    deps.createWriteOptions = { writeOptions }
    deps.createDirectory = { _ in
      if let directoryError { throw directoryError }
    }
    deps.open = { _, _, errorPointer in
      if let openErrorText {
        errorPointer.pointee = strdup(openErrorText)
      } else {
        errorPointer.pointee = nil
      }
      return openResult
    }
    deps.destroyOptions = { _ in counter.increment("options") }
    deps.destroyReadOptions = { _ in counter.increment("read") }
    deps.destroyWriteOptions = { _ in counter.increment("write") }
    deps.free = { _ in counter.increment("free") }
    deps.close = { _ in counter.increment("close") }
    return deps
  }

  func testCreateOptionsFailure() {
    let counter = ResourceCounter()
    let deps = makeDependencies(counter: counter, options: nil)
    XCTAssertThrowsError(try LevelDBBalanceHistoryStore.open(directory: directory, dependencies: deps))
    XCTAssertEqual(counter.count("options"), 0)
  }

  func testReadOptionsFailureReleasesOptions() {
    let counter = ResourceCounter()
    let deps = makeDependencies(
      counter: counter,
      options: fakeOptions,
      readOptions: nil
    )
    XCTAssertThrowsError(try LevelDBBalanceHistoryStore.open(directory: directory, dependencies: deps))
    XCTAssertEqual(counter.count("options"), 1)
    XCTAssertEqual(counter.count("read"), 0)
  }

  func testWriteOptionsFailureReleasesOptionsAndReadOptions() {
    let counter = ResourceCounter()
    let deps = makeDependencies(
      counter: counter,
      options: fakeOptions,
      readOptions: fakeOptions,
      writeOptions: nil
    )
    XCTAssertThrowsError(try LevelDBBalanceHistoryStore.open(directory: directory, dependencies: deps))
    XCTAssertEqual(counter.count("options"), 1)
    XCTAssertEqual(counter.count("read"), 1)
    XCTAssertEqual(counter.count("write"), 0)
  }

  func testDirectoryFailureReleasesAllOptions() {
    let counter = ResourceCounter()
    let deps = makeDependencies(
      counter: counter,
      options: fakeOptions,
      readOptions: fakeOptions,
      writeOptions: fakeOptions,
      directoryError: CocoaError(.fileWriteNoPermission)
    )
    XCTAssertThrowsError(try LevelDBBalanceHistoryStore.open(directory: directory, dependencies: deps))
    XCTAssertEqual(counter.count("options"), 1)
    XCTAssertEqual(counter.count("read"), 1)
    XCTAssertEqual(counter.count("write"), 1)
  }

  func testOpenFailureReleasesAllOptionsAndErrorString() {
    let counter = ResourceCounter()
    let deps = makeDependencies(
      counter: counter,
      options: fakeOptions,
      readOptions: fakeOptions,
      writeOptions: fakeOptions,
      openResult: nil,
      openErrorText: "boom"
    )
    XCTAssertThrowsError(try LevelDBBalanceHistoryStore.open(directory: directory, dependencies: deps)) { error in
      guard case LevelDBError.openFailed(let message) = error else {
        return XCTFail("应为 openFailed，得到 \(error)")
      }
      XCTAssertEqual(message, "boom")
    }
    XCTAssertEqual(counter.count("options"), 1)
    XCTAssertEqual(counter.count("read"), 1)
    XCTAssertEqual(counter.count("write"), 1)
    XCTAssertEqual(counter.count("free"), 1)
    XCTAssertEqual(counter.count("close"), 0)
  }

  // MARK: - iterator error 映射

  /// 固定 key/value 缓冲区的假 iterator，可注入迭代器错误。
  private final class FakeIteratorBox: @unchecked Sendable {
    let keyBuffer: UnsafeMutablePointer<CChar>
    let valueBuffer: UnsafeMutablePointer<CChar>
    let keyCount: Int
    let valueCount: Int
    var validCount = 1
    let errorText: String?

    init(key: String, value: Data, errorText: String?) {
      let keyLength = key.utf8.count
      keyCount = keyLength
      let allocatedKey = UnsafeMutablePointer<CChar>.allocate(capacity: keyLength + 1)
      key.withCString { _ = strcpy(allocatedKey, $0) }
      let valueLength = value.count
      valueCount = valueLength
      let allocatedValue = UnsafeMutablePointer<CChar>.allocate(capacity: valueLength)
      value.withUnsafeBytes { raw in
        if let base = raw.baseAddress {
          _ = memcpy(allocatedValue, base, valueLength)
        }
      }
      keyBuffer = allocatedKey
      valueBuffer = allocatedValue
      self.errorText = errorText
    }

    deinit {
      keyBuffer.deallocate()
      valueBuffer.deallocate()
    }
  }

  private func makeIteratorErrorDependencies(
    key: String,
    value: Data,
    errorText: String,
    counter: ResourceCounter
  ) -> LevelDBDependencies {
    let box = FakeIteratorBox(key: key, value: value, errorText: errorText)
    var deps = LevelDBDependencies.live
    deps.createOptions = { self.fakeOptions }
    deps.setCreateIfMissing = { _ in }
    deps.createReadOptions = { self.fakeOptions }
    deps.createWriteOptions = { self.fakeOptions }
    deps.createDirectory = { _ in }
    deps.open = { _, _, errorPointer in
      errorPointer.pointee = nil
      return self.fakeDB
    }
    deps.destroyOptions = { _ in counter.increment("options") }
    deps.destroyReadOptions = { _ in counter.increment("read") }
    deps.destroyWriteOptions = { _ in counter.increment("write") }
    deps.free = { _ in counter.increment("free") }
    deps.close = { _ in counter.increment("close") }
    deps.createIterator = { _, _ in self.fakeOptions }
    deps.iteratorDestroy = { _ in counter.increment("iteratorDestroy") }
    deps.iteratorSeek = { _, _, _ in }
    deps.iteratorValid = { _ in
      if box.validCount > 0 {
        box.validCount -= 1
        return 1
      }
      return 0
    }
    deps.iteratorKey = { _, length in
      length.pointee = box.keyCount
      return UnsafePointer(box.keyBuffer)
    }
    deps.iteratorValue = { _, length in
      length.pointee = box.valueCount
      return UnsafePointer(box.valueBuffer)
    }
    deps.iteratorNext = { _ in }
    deps.iteratorGetError = { _, errorPointer in
      errorPointer.pointee = strdup(box.errorText)
    }
    return deps
  }

  private func makeFakeStore(
    key: String,
    value: Data,
    errorText: String,
    counter: ResourceCounter
  ) throws -> LevelDBBalanceHistoryStore {
    try LevelDBBalanceHistoryStore.open(
      directory: directory,
      dependencies: makeIteratorErrorDependencies(
        key: key,
        value: value,
        errorText: errorText,
        counter: counter
      )
    )
  }

  func testFetchThrowsOnIteratorError() async throws {
    let sample = BalanceSample(
      credentialID: "cred",
      bucketStart: t0,
      observedAt: t0,
      currency: "CNY",
      totalBalance: "100.00",
      grantedBalance: "10.00",
      toppedUpBalance: "90.00",
      isAvailable: true
    )
    let key = HistoryKeyCodec.key(credentialID: "cred", currency: "CNY", bucketStart: t0)
    let value = try HistoryValueCodec.encode(sample: sample)
    let counter = ResourceCounter()
    let store = try makeFakeStore(
      key: key,
      value: value,
      errorText: "iterator exploded",
      counter: counter
    )
    do {
      _ = try await store.fetch(credentialID: "cred", from: .distantPast, to: .distantFuture)
      XCTFail("应抛出 readFailed")
    } catch let error as LevelDBError {
      guard case .readFailed(let message) = error else {
        return XCTFail("应为 readFailed，得到 \(error)")
      }
      XCTAssertEqual(message, "iterator exploded")
      XCTAssertFalse(message.contains("sk-secret"))
    } catch {
      XCTFail("意外的错误类型：\(error)")
    }
    XCTAssertEqual(counter.count("iteratorDestroy"), 1)
    XCTAssertEqual(counter.count("free"), 1)
    await store.close()
  }

  func testPruneAndDeleteHistoryThrowOnIteratorError() async throws {
    let sample = BalanceSample(
      credentialID: "cred",
      bucketStart: t0,
      observedAt: t0,
      currency: "CNY",
      totalBalance: "100.00",
      grantedBalance: "10.00",
      toppedUpBalance: "90.00",
      isAvailable: true
    )
    let key = HistoryKeyCodec.key(credentialID: "cred", currency: "CNY", bucketStart: t0)
    let value = try HistoryValueCodec.encode(sample: sample)
    let counter = ResourceCounter()
    let store = try makeFakeStore(
      key: key,
      value: value,
      errorText: "scan failed",
      counter: counter
    )

    do {
      try await store.prune(before: t0.addingTimeInterval(3600))
      XCTFail("prune 应抛出 readFailed")
    } catch let error as LevelDBError {
      guard case .readFailed = error else {
        return XCTFail("应为 readFailed，得到 \(error)")
      }
    }

    do {
      try await store.deleteHistory(credentialID: "cred")
      XCTFail("deleteHistory 应抛出 readFailed")
    } catch let error as LevelDBError {
      guard case .readFailed = error else {
        return XCTFail("应为 readFailed，得到 \(error)")
      }
    }
    await store.close()
  }

  func testCloseThenAccessThrowsNotOpen() async throws {
    let store = try LevelDBBalanceHistoryStore.open(directory: directory)
    await store.close()

    do {
      _ = try await store.fetch(credentialID: "cred", from: .distantPast, to: .distantFuture)
      XCTFail("关闭后 fetch 应失败")
    } catch let error as LevelDBError {
      XCTAssertEqual(error, .notOpen)
    }
    do {
      try await store.upsert(
        samples: [
          BalanceSample(
            credentialID: "cred",
            bucketStart: t0,
            observedAt: t0,
            currency: "CNY",
            totalBalance: "1.00",
            grantedBalance: "0.00",
            toppedUpBalance: "1.00",
            isAvailable: true
          )
        ],
        credentialID: "cred"
      )
      XCTFail("关闭后 upsert 应失败")
    } catch let error as LevelDBError {
      XCTAssertEqual(error, .notOpen)
    }
    do {
      try await store.prune(before: t0)
      XCTFail("关闭后 prune 应失败")
    } catch let error as LevelDBError {
      XCTAssertEqual(error, .notOpen)
    }
  }
}

/// LevelDB 数据一致性校验（真实 LevelDB + writeRaw 注入不一致记录）。
final class LevelDBConsistencyTests: XCTestCase {
  private var directory: URL!
  private var store: LevelDBBalanceHistoryStore?
  private let t0 = Date(timeIntervalSince1970: 1_752_000_000)

  override func setUp() {
    super.setUp()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("LevelDBConsistencyTests-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDown() async throws {
    if let store {
      await store.close()
    }
    store = nil
    try? FileManager.default.removeItem(at: directory)
    try await super.tearDown()
  }

  private func makeStore() throws -> LevelDBBalanceHistoryStore {
    let newStore = try LevelDBBalanceHistoryStore.open(directory: directory)
    store = newStore
    return newStore
  }

  private func sample(
    credentialID: String = "cred",
    currency: String = "CNY",
    bucket: Date,
    total: String = "100.00"
  ) -> BalanceSample {
    BalanceSample(
      credentialID: credentialID,
      bucketStart: bucket,
      observedAt: bucket,
      currency: currency,
      totalBalance: total,
      grantedBalance: "10.00",
      toppedUpBalance: "90.00",
      isAvailable: true
    )
  }

  func testRejectsCredentialMismatchOnWrite() async throws {
    let store = try makeStore()
    do {
      try await store.upsert(samples: [sample(credentialID: "other", bucket: t0)], credentialID: "cred")
      XCTFail("应拒绝 credential 不一致样本")
    } catch let error as LevelDBError {
      guard case .writeFailed = error else {
        return XCTFail("应为 writeFailed，得到 \(error)")
      }
    }
  }

  func testRejectsInvalidCurrencyOnWrite() async throws {
    let store = try makeStore()
    do {
      try await store.upsert(
        samples: [sample(currency: "CNY/USD", bucket: t0)],
        credentialID: "cred"
      )
      XCTFail("应拒绝非法币种")
    } catch let error as LevelDBError {
      guard case .writeFailed = error else {
        return XCTFail("应为 writeFailed，得到 \(error)")
      }
    }
  }

  func testSkipsCredentialMismatchedValue() async throws {
    let store = try makeStore()
    let key = HistoryKeyCodec.key(credentialID: "cred", currency: "CNY", bucketStart: t0)
    let value = try HistoryValueCodec.encode(sample: sample(credentialID: "other", bucket: t0))
    try await store.writeRaw(key: key, value: value)
    let fetched = try await store.fetch(credentialID: "cred", from: .distantPast, to: .distantFuture)
    XCTAssertTrue(fetched.isEmpty)
  }

  func testSkipsCurrencyMismatchedValue() async throws {
    let store = try makeStore()
    let key = HistoryKeyCodec.key(credentialID: "cred", currency: "CNY", bucketStart: t0)
    let value = try HistoryValueCodec.encode(sample: sample(currency: "USD", bucket: t0))
    try await store.writeRaw(key: key, value: value)
    let fetched = try await store.fetch(credentialID: "cred", from: .distantPast, to: .distantFuture)
    XCTAssertTrue(fetched.isEmpty)
  }

  func testSkipsBucketMismatchedValue() async throws {
    let store = try makeStore()
    let key = HistoryKeyCodec.key(credentialID: "cred", currency: "CNY", bucketStart: t0)
    let value = try HistoryValueCodec.encode(
      sample: sample(bucket: t0.addingTimeInterval(600))
    )
    try await store.writeRaw(key: key, value: value)
    let fetched = try await store.fetch(credentialID: "cred", from: .distantPast, to: .distantFuture)
    XCTAssertTrue(fetched.isEmpty)
  }

  func testSkipsCredentialOutsideRequestedCredential() async throws {
    let store = try makeStore()
    try await store.upsert(samples: [sample(bucket: t0)], credentialID: "cred")
    try await store.upsert(samples: [sample(credentialID: "other", bucket: t0)], credentialID: "other")
    let fetched = try await store.fetch(credentialID: "cred", from: .distantPast, to: .distantFuture)
    XCTAssertEqual(fetched.count, 1)
    XCTAssertEqual(fetched[0].credentialID, "cred")
  }
}

/// PruneGate：失败后可重试、并发只执行一次。
final class PruneGateTests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 1_752_000_000)

  actor FailingOnceStore: BalanceHistoryStoring {
    private var pruneCalls = 0
    private var samples: [BalanceSample] = []

    func upsert(samples incoming: [BalanceSample], credentialID: String) async throws {
      samples.append(contentsOf: incoming)
    }

    func fetch(credentialID: String, from: Date, to: Date) async throws -> [BalanceSample] {
      samples.filter { $0.credentialID == credentialID }
    }

    func prune(before: Date) async throws {
      pruneCalls += 1
      if pruneCalls == 1 {
        throw LevelDBError.readFailed("第一次失败")
      }
      samples.removeAll { $0.bucketStart < before }
    }

    func deleteHistory(credentialID: String?) async throws {}
  }

  actor CountingStore: BalanceHistoryStoring {
    private(set) var pruneCount = 0
    private var samples: [BalanceSample] = []

    func upsert(samples incoming: [BalanceSample], credentialID: String) async throws {
      samples.append(contentsOf: incoming)
    }

    func fetch(credentialID: String, from: Date, to: Date) async throws -> [BalanceSample] {
      samples.filter { $0.credentialID == credentialID }
    }

    func prune(before: Date) async throws {
      pruneCount += 1
      samples.removeAll { $0.bucketStart < before }
    }

    func deleteHistory(credentialID: String?) async throws {}
  }

  func testFailureDoesNotRecordGateAndAllowsRetry() async throws {
    let store = FailingOnceStore()
    let service = BalanceHistoryService(store: store, clock: FixedClock(date: t0))

    do {
      try await service.pruneThrottled()
      XCTFail("第一次应失败")
    } catch {
      // 预期失败
    }

    // 同一时刻重试：必须真正执行 prune。
    try await service.pruneThrottled()
  }

  func testConcurrentPruneExecutesOnlyOnce() async throws {
    let store = CountingStore()
    let service = BalanceHistoryService(store: store, clock: FixedClock(date: t0))

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<4 {
        group.addTask {
          try? await service.pruneThrottled()
        }
      }
    }
    let count = await store.pruneCount
    XCTAssertEqual(count, 1)
  }
}
