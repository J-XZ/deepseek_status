import Foundation
import os

/// 基于 LevelDB C API 的真实历史存储。
/// actor 串行化所有访问，LevelDB 句柄在应用生命周期内只打开一次。
actor LevelDBBalanceHistoryStore: BalanceHistoryStoring {
  private let directory: URL
  private let options: OpaquePointer
  private let readOptions: OpaquePointer
  private let writeOptions: OpaquePointer
  private var db: OpaquePointer?

  private static let logger = Logger(
    subsystem: "com.example.DeepSeekBalance",
    category: "history"
  )

  init(directory: URL) throws {
    self.directory = directory
    guard let options = leveldb_options_create() else {
      throw LevelDBError.openFailed("无法创建 LevelDB options")
    }
    leveldb_options_set_create_if_missing(options, 1)
    leveldb_options_set_paranoid_checks(options, 0)
    self.options = options
    guard let readOptions = leveldb_readoptions_create() else {
      throw LevelDBError.openFailed("无法创建 LevelDB read options")
    }
    guard let writeOptions = leveldb_writeoptions_create() else {
      throw LevelDBError.openFailed("无法创建 LevelDB write options")
    }
    self.readOptions = readOptions
    self.writeOptions = writeOptions

    do {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
    } catch {
      throw LevelDBError.invalidPath
    }

    var error: UnsafeMutablePointer<CChar>?
    guard let db = leveldb_open(options, directory.path, &error) else {
      let message = Self.errorMessage(error)
      if let error { leveldb_free(error) }
      throw LevelDBError.openFailed(message)
    }
    self.db = db
  }

  deinit {
    if let db {
      leveldb_close(db)
    }
    leveldb_options_destroy(options)
    leveldb_readoptions_destroy(readOptions)
    leveldb_writeoptions_destroy(writeOptions)
  }

  // MARK: - BalanceHistoryStoring

  func upsert(samples: [BalanceSample], credentialID: String) async throws {
    guard let db else { throw LevelDBError.notOpen }
    guard !samples.isEmpty else { return }
    let batch = leveldb_writebatch_create()
    defer { leveldb_writebatch_destroy(batch) }

    for sample in samples {
      let key = HistoryKeyCodec.key(
        credentialID: credentialID,
        currency: sample.currency,
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
          leveldb_writebatch_put(
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
    leveldb_write(db, writeOptions, batch, &error)
    if let error {
      defer { leveldb_free(error) }
      throw LevelDBError.writeFailed(Self.errorMessage(error))
    }
  }

  func fetch(credentialID: String, from: Date, to: Date) async throws -> [BalanceSample] {
    guard let db else { throw LevelDBError.notOpen }
    let iterator = leveldb_create_iterator(db, readOptions)
    defer { leveldb_iter_destroy(iterator) }

    let prefix = HistoryKeyCodec.credentialPrefix(credentialID: credentialID)
    let fromSeconds = Int64(from.timeIntervalSince1970)
    let toSeconds = Int64(to.timeIntervalSince1970)
    let seekKey = prefix + HistoryKeyCodec.padded(fromSeconds)
    seekKey.withCString { pointer in
      leveldb_iter_seek(iterator, pointer, seekKey.utf8.count)
    }

    var result: [BalanceSample] = []
    var skippedCount = 0
    while leveldb_iter_valid(iterator) != 0 {
      var keyLength = 0
      guard let keyPointer = leveldb_iter_key(iterator, &keyLength) else { break }
      let key = keyPointer.withMemoryRebound(to: UInt8.self, capacity: keyLength) {
        String(decoding: UnsafeBufferPointer(start: $0, count: keyLength), as: UTF8.self)
      }
      guard key.hasPrefix(prefix) else { break }

      if let parsed = HistoryKeyCodec.parse(key: key),
        parsed.bucketSeconds >= fromSeconds,
        parsed.bucketSeconds <= toSeconds
      {
        var valueLength = 0
        if let valuePointer = leveldb_iter_value(iterator, &valueLength) {
          let value = Data(bytes: valuePointer, count: valueLength)
          if let sample = try? HistoryValueCodec.decode(value) {
            result.append(sample)
          } else {
            skippedCount += 1
          }
        }
      }
      leveldb_iter_next(iterator)
    }

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
    let keys = collectKeys(matching: HistoryKeyCodec.schemaPrefixKey()) { key in
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
    let keys = collectKeys(matching: prefix)
    try deleteKeys(keys)
  }

  /// 显式关闭数据库（测试用；正常生命周期由 deinit 关闭）。
  func close() async {
    if let db {
      leveldb_close(db)
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
        leveldb_put(
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
      defer { leveldb_free(error) }
      throw LevelDBError.writeFailed(Self.errorMessage(error))
    }
  }

  // MARK: - 内部工具

  private func collectKeys(matching prefix: String, filter: ((String) -> Bool)? = nil) -> [String] {
    guard let db else { return [] }
    let iterator = leveldb_create_iterator(db, readOptions)
    defer { leveldb_iter_destroy(iterator) }

    prefix.withCString { pointer in
      leveldb_iter_seek(iterator, pointer, prefix.utf8.count)
    }
    var keys: [String] = []
    while leveldb_iter_valid(iterator) != 0 {
      var keyLength = 0
      guard let keyPointer = leveldb_iter_key(iterator, &keyLength) else { break }
      let key = keyPointer.withMemoryRebound(to: UInt8.self, capacity: keyLength) {
        String(decoding: UnsafeBufferPointer(start: $0, count: keyLength), as: UTF8.self)
      }
      guard key.hasPrefix(prefix) else { break }
      if filter == nil || filter!(key) {
        keys.append(key)
      }
      leveldb_iter_next(iterator)
    }
    return keys
  }

  private func deleteKeys(_ keys: [String]) throws {
    guard let db else { throw LevelDBError.notOpen }
    guard !keys.isEmpty else { return }
    let batch = leveldb_writebatch_create()
    defer { leveldb_writebatch_destroy(batch) }
    for key in keys {
      key.withCString { pointer in
        leveldb_writebatch_delete(batch, pointer, key.utf8.count)
      }
    }
    var error: UnsafeMutablePointer<CChar>?
    leveldb_write(db, writeOptions, batch, &error)
    if let error {
      defer { leveldb_free(error) }
      throw LevelDBError.deleteFailed(Self.errorMessage(error))
    }
  }

  private static func errorMessage(_ error: UnsafeMutablePointer<CChar>?) -> String {
    guard let error else { return "未知错误" }
    return String(cString: error)
  }
}
