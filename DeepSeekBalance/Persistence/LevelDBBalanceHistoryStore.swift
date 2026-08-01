import Foundation
import os

/// LevelDB C API 的最小可注入封装：初始化失败路径与 iterator 错误路径均可测试。
struct LevelDBDependencies {
  // options / open
  var createOptions: () -> OpaquePointer?
  var setCreateIfMissing: (OpaquePointer) -> Void
  var createReadOptions: () -> OpaquePointer?
  var createWriteOptions: () -> OpaquePointer?
  var createDirectory: (URL) throws -> Void
  var open:
    (
      OpaquePointer,
      UnsafePointer<CChar>,
      UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    ) -> OpaquePointer?
  var close: (OpaquePointer) -> Void
  var destroyOptions: (OpaquePointer) -> Void
  var destroyReadOptions: (OpaquePointer) -> Void
  var destroyWriteOptions: (OpaquePointer) -> Void
  var free: (UnsafeMutablePointer<CChar>) -> Void

  // iterator
  var createIterator: (OpaquePointer, OpaquePointer) -> OpaquePointer?
  var iteratorDestroy: (OpaquePointer) -> Void
  var iteratorSeek: (OpaquePointer, UnsafePointer<CChar>, Int) -> Void
  var iteratorValid: (OpaquePointer) -> UInt8
  var iteratorKey: (OpaquePointer, UnsafeMutablePointer<Int>) -> UnsafePointer<CChar>?
  var iteratorValue: (OpaquePointer, UnsafeMutablePointer<Int>) -> UnsafePointer<CChar>?
  var iteratorNext: (OpaquePointer) -> Void
  var iteratorGetError: (OpaquePointer, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Void

  // write batch / put
  var writeBatchCreate: () -> OpaquePointer?
  var writeBatchDestroy: (OpaquePointer) -> Void
  var writeBatchPut:
    (OpaquePointer, UnsafePointer<CChar>, Int, UnsafePointer<CChar>?, Int) -> Void
  var writeBatchDelete: (OpaquePointer, UnsafePointer<CChar>, Int) -> Void
  var write:
    (
      OpaquePointer,
      OpaquePointer,
      OpaquePointer,
      UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    ) -> Void
  var put:
    (
      OpaquePointer,
      OpaquePointer,
      UnsafePointer<CChar>,
      Int,
      UnsafePointer<CChar>?,
      Int,
      UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    ) -> Void

  static let live = LevelDBDependencies(
    createOptions: { leveldb_options_create() },
    setCreateIfMissing: { leveldb_options_set_create_if_missing($0, 1) },
    createReadOptions: { leveldb_readoptions_create() },
    createWriteOptions: { leveldb_writeoptions_create() },
    createDirectory: { url in
      try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true
      )
    },
    open: { options, path, error in
      leveldb_open(options, path, error)
    },
    close: { leveldb_close($0) },
    destroyOptions: { leveldb_options_destroy($0) },
    destroyReadOptions: { leveldb_readoptions_destroy($0) },
    destroyWriteOptions: { leveldb_writeoptions_destroy($0) },
    free: { leveldb_free($0) },
    createIterator: { leveldb_create_iterator($0, $1) },
    iteratorDestroy: { leveldb_iter_destroy($0) },
    iteratorSeek: { leveldb_iter_seek($0, $1, $2) },
    iteratorValid: { leveldb_iter_valid($0) },
    iteratorKey: { leveldb_iter_key($0, $1) },
    iteratorValue: { leveldb_iter_value($0, $1) },
    iteratorNext: { leveldb_iter_next($0) },
    iteratorGetError: { leveldb_iter_get_error($0, $1) },
    writeBatchCreate: { leveldb_writebatch_create() },
    writeBatchDestroy: { leveldb_writebatch_destroy($0) },
    writeBatchPut: { leveldb_writebatch_put($0, $1, $2, $3, $4) },
    writeBatchDelete: { leveldb_writebatch_delete($0, $1, $2) },
    write: { leveldb_write($0, $1, $2, $3) },
    put: { leveldb_put($0, $1, $2, $3, $4, $5, $6) }
  )
}

/// 基于 LevelDB C API 的真实历史存储。
/// actor 串行化所有访问，LevelDB 句柄在应用生命周期内只打开一次。
actor LevelDBBalanceHistoryStore: BalanceHistoryStoring {
  private let directory: URL
  private let dependencies: LevelDBDependencies
  private let options: OpaquePointer
  private let readOptions: OpaquePointer
  private let writeOptions: OpaquePointer
  private var db: OpaquePointer?

  private static let logger = Logger(
    subsystem: "com.example.DeepSeekBalance",
    category: "history"
  )

  /// 全部 C 资源创建完成后的非抛错初始化。
  private init(
    directory: URL,
    dependencies: LevelDBDependencies,
    options: OpaquePointer,
    readOptions: OpaquePointer,
    writeOptions: OpaquePointer,
    db: OpaquePointer
  ) {
    self.directory = directory
    self.dependencies = dependencies
    self.options = options
    self.readOptions = readOptions
    self.writeOptions = writeOptions
    self.db = db
  }

  /// 打开数据库：资源在 actor 实例创建之前全部创建完成；
  /// 任何失败路径立即释放此前成功创建的资源，不依赖 deinit。
  static func open(
    directory: URL,
    dependencies: LevelDBDependencies = .live
  ) throws -> LevelDBBalanceHistoryStore {
    guard let options = dependencies.createOptions() else {
      throw LevelDBError.openFailed("无法创建 LevelDB options")
    }
    dependencies.setCreateIfMissing(options)

    var readOptions: OpaquePointer?
    var writeOptions: OpaquePointer?
    var openedDB: OpaquePointer?
    var openError: UnsafeMutablePointer<CChar>?

    do {
      guard let createdRead = dependencies.createReadOptions() else {
        throw LevelDBError.openFailed("无法创建 LevelDB read options")
      }
      readOptions = createdRead

      guard let createdWrite = dependencies.createWriteOptions() else {
        throw LevelDBError.openFailed("无法创建 LevelDB write options")
      }
      writeOptions = createdWrite

      try dependencies.createDirectory(directory)

      guard let db = directory.path.withCString({ path in
        dependencies.open(options, path, &openError)
      }) else {
        let message = Self.errorMessage(openError)
        if let openError {
          dependencies.free(openError)
        }
        throw LevelDBError.openFailed(message)
      }
      openedDB = db
    } catch {
      // 失败路径释放此前全部成功创建的 C 资源，不依赖 deinit。
      dependencies.destroyOptions(options)
      if let readOptions {
        dependencies.destroyReadOptions(readOptions)
      }
      if let writeOptions {
        dependencies.destroyWriteOptions(writeOptions)
      }
      if let openedDB {
        dependencies.close(openedDB)
      }
      throw error
    }

    return LevelDBBalanceHistoryStore(
      directory: directory,
      dependencies: dependencies,
      options: options,
      readOptions: readOptions!,
      writeOptions: writeOptions!,
      db: openedDB!
    )
  }

  deinit {
    if let db {
      dependencies.close(db)
    }
    dependencies.destroyOptions(options)
    dependencies.destroyReadOptions(readOptions)
    dependencies.destroyWriteOptions(writeOptions)
  }

  // MARK: - BalanceHistoryStoring

  func upsert(samples: [BalanceSample], credentialID: String) async throws {
    guard let db else { throw LevelDBError.notOpen }
    guard !samples.isEmpty else { return }
    guard HistoryKeyCodec.validCredentialID(credentialID) else {
      throw LevelDBError.writeFailed("凭据标识无效")
    }

    guard let batch = dependencies.writeBatchCreate() else {
      throw LevelDBError.writeFailed("无法创建写入批次")
    }
    defer { dependencies.writeBatchDestroy(batch) }

    for sample in samples {
      guard sample.credentialID == credentialID else {
        throw LevelDBError.writeFailed("样本与凭据不一致")
      }
      guard let currency = HistoryKeyCodec.normalizedCurrency(sample.currency) else {
        throw LevelDBError.writeFailed("币种格式无效")
      }
      let key = HistoryKeyCodec.key(
        credentialID: credentialID,
        currency: currency,
        bucketStart: sample.bucketStart
      )
      let value: Data
      do {
        value = try HistoryValueCodec.encode(sample: sample)
      } catch {
        throw LevelDBError.writeFailed("样本编码失败")
      }
      key.withCString { keyPointer in
        value.withUnsafeBytes { rawBuffer in
          dependencies.writeBatchPut(
            batch,
            keyPointer,
            key.utf8.count,
            rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self),
            value.count
          )
        }
      }
    }

    var error: UnsafeMutablePointer<CChar>?
    dependencies.write(db, writeOptions, batch, &error)
    if let error {
      defer { dependencies.free(error) }
      throw LevelDBError.writeFailed(Self.errorMessage(error))
    }
  }

  func fetch(credentialID: String, from: Date, to: Date) async throws -> [BalanceSample] {
    guard let db else { throw LevelDBError.notOpen }
    guard let iterator = dependencies.createIterator(db, readOptions) else {
      throw LevelDBError.notOpen
    }
    defer { dependencies.iteratorDestroy(iterator) }

    let prefix = HistoryKeyCodec.credentialPrefix(credentialID: credentialID)
    let fromSeconds = Int64(from.timeIntervalSince1970)
    let toSeconds = Int64(to.timeIntervalSince1970)
    let seekKey = prefix + HistoryKeyCodec.padded(fromSeconds)
    seekKey.withCString { pointer in
      dependencies.iteratorSeek(iterator, pointer, seekKey.utf8.count)
    }

    var result: [BalanceSample] = []
    var skippedCount = 0
    while dependencies.iteratorValid(iterator) != 0 {
      var keyLength = 0
      guard let keyPointer = dependencies.iteratorKey(iterator, &keyLength) else { break }
      let key = keyPointer.withMemoryRebound(to: UInt8.self, capacity: keyLength) {
        String(decoding: UnsafeBufferPointer(start: $0, count: keyLength), as: UTF8.self)
      }
      guard key.hasPrefix(prefix) else { break }

      if let parsed = HistoryKeyCodec.parse(key: key),
        parsed.bucketSeconds >= fromSeconds,
        parsed.bucketSeconds <= toSeconds
      {
        var valueLength = 0
        if let valuePointer = dependencies.iteratorValue(iterator, &valueLength) {
          let value = Data(bytes: valuePointer, count: valueLength)
          if let sample = try? HistoryValueCodec.decode(value),
            Self.isConsistent(sample: sample, parsed: parsed, requestedCredentialID: credentialID)
          {
            result.append(sample)
          } else {
            skippedCount += 1
          }
        }
      }
      dependencies.iteratorNext(iterator)
    }

    try throwIfIteratorError(iterator, failure: LevelDBError.readFailed)

    if skippedCount > 0 {
      Self.logger.debug("跳过 \(skippedCount) 条损坏的历史记录")
    }
    return result.sorted {
      if $0.bucketStart == $1.bucketStart { return $0.currency < $1.currency }
      return $0.bucketStart < $1.bucketStart
    }
  }

  func prune(before: Date) async throws {
    guard db != nil else { throw LevelDBError.notOpen }
    let threshold = Int64(before.timeIntervalSince1970)
    let keys = try collectKeys(matching: HistoryKeyCodec.schemaPrefixKey()) { key in
      guard let parsed = HistoryKeyCodec.parse(key: key) else { return false }
      return parsed.bucketSeconds < threshold
    }
    try deleteKeys(keys)
  }

  func deleteHistory(credentialID: String?) async throws {
    guard db != nil else { throw LevelDBError.notOpen }
    let prefix =
      credentialID.map(HistoryKeyCodec.credentialPrefix)
      ?? HistoryKeyCodec.schemaPrefixKey()
    let keys = try collectKeys(matching: prefix)
    try deleteKeys(keys)
  }

  /// 显式关闭数据库（测试用；正常生命周期由 deinit 关闭）。
  func close() async {
    if let db {
      dependencies.close(db)
      self.db = nil
    }
  }

  // MARK: - 测试支持

  /// 测试用：写入任意原始 value（用于损坏数据测试）。
  func writeRaw(key: String, value: Data) async throws {
    guard let db else { throw LevelDBError.notOpen }
    var error: UnsafeMutablePointer<CChar>?
    key.withCString { keyPointer in
      value.withUnsafeBytes { rawBuffer in
        dependencies.put(
          db,
          writeOptions,
          keyPointer,
          key.utf8.count,
          rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self),
          value.count,
          &error
        )
      }
    }
    if let error {
      defer { dependencies.free(error) }
      throw LevelDBError.writeFailed(Self.errorMessage(error))
    }
  }

  // MARK: - 内部工具

  /// 读取一致性校验：key 与 value 中的 credential、币种、时间桶必须一致。
  private static func isConsistent(
    sample: BalanceSample,
    parsed: (credentialID: String, currency: String, bucketSeconds: Int64),
    requestedCredentialID: String
  ) -> Bool {
    guard sample.credentialID == requestedCredentialID,
      parsed.credentialID == sample.credentialID,
      HistoryKeyCodec.normalizedCurrency(sample.currency) == parsed.currency,
      parsed.bucketSeconds == Int64(sample.bucketStart.timeIntervalSince1970)
    else {
      return false
    }
    return true
  }

  private func collectKeys(
    matching prefix: String,
    filter: ((String) -> Bool)? = nil
  ) throws -> [String] {
    guard let db else { throw LevelDBError.notOpen }
    guard let iterator = dependencies.createIterator(db, readOptions) else {
      throw LevelDBError.notOpen
    }
    defer { dependencies.iteratorDestroy(iterator) }

    prefix.withCString { pointer in
      dependencies.iteratorSeek(iterator, pointer, prefix.utf8.count)
    }
    var keys: [String] = []
    while dependencies.iteratorValid(iterator) != 0 {
      var keyLength = 0
      guard let keyPointer = dependencies.iteratorKey(iterator, &keyLength) else { break }
      let key = keyPointer.withMemoryRebound(to: UInt8.self, capacity: keyLength) {
        String(decoding: UnsafeBufferPointer(start: $0, count: keyLength), as: UTF8.self)
      }
      guard key.hasPrefix(prefix) else { break }
      if filter == nil || filter!(key) {
        keys.append(key)
      }
      dependencies.iteratorNext(iterator)
    }

    try throwIfIteratorError(iterator, failure: LevelDBError.readFailed)
    return keys
  }

  private func throwIfIteratorError(
    _ iterator: OpaquePointer,
    failure: (String) -> LevelDBError
  ) throws {
    var error: UnsafeMutablePointer<CChar>?
    dependencies.iteratorGetError(iterator, &error)
    if let error {
      defer { dependencies.free(error) }
      throw failure(Self.errorMessage(error))
    }
  }

  private func deleteKeys(_ keys: [String]) throws {
    guard let db else { throw LevelDBError.notOpen }
    guard !keys.isEmpty else { return }
    guard let batch = dependencies.writeBatchCreate() else {
      throw LevelDBError.deleteFailed("无法创建写入批次")
    }
    defer { dependencies.writeBatchDestroy(batch) }
    for key in keys {
      key.withCString { pointer in
        dependencies.writeBatchDelete(batch, pointer, key.utf8.count)
      }
    }
    var error: UnsafeMutablePointer<CChar>?
    dependencies.write(db, writeOptions, batch, &error)
    if let error {
      defer { dependencies.free(error) }
      throw LevelDBError.deleteFailed(Self.errorMessage(error))
    }
  }

  private static func errorMessage(_ error: UnsafeMutablePointer<CChar>?) -> String {
    guard let error else { return "未知错误" }
    return String(cString: error)
  }
}
