import Foundation
import os

/// 基于 LevelDB C API 的 Cursor 用量历史存储。
/// actor 串行化所有访问，LevelDB 句柄在应用生命周期内只打开一次。
/// 与余额/Codex 历史使用不同的目录，避免两个实例同时打开同一数据库。
actor LevelDBCursorHistoryStore: CursorHistoryStoring {
  private let directory: URL
  private let dependencies: LevelDBDependencies
  private let options: OpaquePointer
  private let readOptions: OpaquePointer
  private let writeOptions: OpaquePointer
  private var db: OpaquePointer?

  private static let logger = Logger(
    subsystem: "com.example.DeepSeekBalance",
    category: "cursorHistory"
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
  ) throws -> LevelDBCursorHistoryStore {
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

    return LevelDBCursorHistoryStore(
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

  // MARK: - CursorHistoryStoring

  func upsert(samples: [CursorUsageSample], credentialID: String) async throws {
    guard let db else { throw LevelDBError.notOpen }
    guard !samples.isEmpty else { return }
    guard CursorHistoryKeyCodec.validCredentialID(credentialID) else {
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
      let key = CursorHistoryKeyCodec.key(
        credentialID: credentialID,
        bucketStart: sample.bucketStart
      )
      let value: Data
      do {
        value = try CursorHistoryValueCodec.encode(sample: sample)
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

  func fetch(credentialID: String, from: Date, to: Date) async throws -> [CursorUsageSample] {
    guard let db else { throw LevelDBError.notOpen }
    guard let iterator = dependencies.createIterator(db, readOptions) else {
      throw LevelDBError.notOpen
    }
    defer { dependencies.iteratorDestroy(iterator) }

    let prefix = CursorHistoryKeyCodec.credentialPrefix(credentialID: credentialID)
    let fromSeconds = Int64(from.timeIntervalSince1970)
    let toSeconds = Int64(to.timeIntervalSince1970)
    let seekKey = prefix + CursorHistoryKeyCodec.padded(fromSeconds)
    seekKey.withCString { pointer in
      dependencies.iteratorSeek(iterator, pointer, seekKey.utf8.count)
    }

    var result: [CursorUsageSample] = []
    var skippedCount = 0
    while dependencies.iteratorValid(iterator) != 0 {
      var keyLength = 0
      guard let keyPointer = dependencies.iteratorKey(iterator, &keyLength) else { break }
      let key = keyPointer.withMemoryRebound(to: UInt8.self, capacity: keyLength) {
        String(decoding: UnsafeBufferPointer(start: $0, count: keyLength), as: UTF8.self)
      }
      guard key.hasPrefix(prefix) else { break }

      if let parsed = CursorHistoryKeyCodec.parse(key: key),
        parsed.bucketSeconds >= fromSeconds,
        parsed.bucketSeconds <= toSeconds
      {
        var valueLength = 0
        if let valuePointer = dependencies.iteratorValue(iterator, &valueLength) {
          let value = Data(bytes: valuePointer, count: valueLength)
          if let sample = try? CursorHistoryValueCodec.decode(value),
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
    return result.sorted { $0.bucketStart < $1.bucketStart }
  }

  func prune(before: Date) async throws {
    guard db != nil else { throw LevelDBError.notOpen }
    let threshold = Int64(before.timeIntervalSince1970)
    let keys = try collectKeys(matching: CursorHistoryKeyCodec.schemaPrefixKey()) { key in
      guard let parsed = CursorHistoryKeyCodec.parse(key: key) else { return false }
      return parsed.bucketSeconds < threshold
    }
    try deleteKeys(keys)
  }

  func deleteHistory(credentialID: String?) async throws {
    guard db != nil else { throw LevelDBError.notOpen }
    let prefix =
      credentialID.map(CursorHistoryKeyCodec.credentialPrefix)
      ?? CursorHistoryKeyCodec.schemaPrefixKey()
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

  /// 读取一致性校验：key 与 value 中的 credential、时间桶必须一致。
  private static func isConsistent(
    sample: CursorUsageSample,
    parsed: (credentialID: String, bucketSeconds: Int64),
    requestedCredentialID: String
  ) -> Bool {
    guard sample.credentialID == requestedCredentialID,
      parsed.credentialID == sample.credentialID,
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
