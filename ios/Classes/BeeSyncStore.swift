import Foundation
import SQLite3

/// A row returned by `BeeSyncStore.claim`.
struct StoredEvent {
  let seq: Int64
  let id: String
  let name: String
  let payload: Data
  let encrypted: Bool
  let priority: Int
  let createdAt: Int64
  let sizeBytes: Int
  let attempts: Int
}

struct StoreError: Error, CustomStringConvertible {
  let description: String
}

/// Native access to bee_sync.db, which the Dart side creates and migrates.
/// Implements the claim protocol in spec/claim_protocol.sql. Not thread-safe:
/// use one instance per upload run, on one queue.
final class BeeSyncStore {
  private let db: OpaquePointer

  /// Opens an existing database, or returns nil when Dart has not created it
  /// yet. Never creates the file: only Dart owns the schema. The journal mode
  /// (WAL, set by Dart) is left untouched.
  static func open(path: String) throws -> BeeSyncStore? {
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    var handle: OpaquePointer?
    let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
    guard rc == SQLITE_OK, let db = handle else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
      sqlite3_close(handle)
      throw StoreError(description: "Cannot open database: \(message)")
    }
    sqlite3_busy_timeout(db, 5000)
    return BeeSyncStore(db: db)
  }

  private init(db: OpaquePointer) {
    self.db = db
  }

  deinit {
    sqlite3_close_v2(db)
  }

  /// PRAGMA user_version; uploaders only run when it equals `Sql.schemaVersion`.
  func schemaVersion() throws -> Int32 {
    var version: Int32 = 0
    try query("PRAGMA user_version", []) { version = sqlite3_column_int($0, 0) }
    return version
  }

  /// Leases up to `limit` ready rows to `owner` and returns all rows it holds.
  func claim(owner: String, now: Int64, leaseUntil: Int64, limit: Int) throws -> [StoredEvent] {
    try transaction {
      try execute(Sql.claim, [owner, leaseUntil, now, now, Int64(0), Int64(limit)])
      var rows: [StoredEvent] = []
      try query(Sql.selectClaimed, [owner]) { s in
        rows.append(
          StoredEvent(
            seq: sqlite3_column_int64(s, 0),
            id: Self.text(s, 1),
            name: Self.text(s, 2),
            payload: Self.blob(s, 3),
            encrypted: sqlite3_column_int(s, 4) == 1,
            priority: Int(sqlite3_column_int(s, 5)),
            createdAt: sqlite3_column_int64(s, 6),
            sizeBytes: Int(sqlite3_column_int64(s, 7)),
            attempts: Int(sqlite3_column_int(s, 8))))
      }
      return rows
    }
  }

  /// Deletes leased rows and adds `counters` in the same transaction.
  func deleteLeased(owner: String, ids: [String], counters: [String: Int] = [:]) throws {
    if ids.isEmpty && counters.isEmpty { return }
    try transaction {
      if !ids.isEmpty {
        try execute(Sql.expandIds(Sql.deleteLeased, count: ids.count), [owner] + ids.map { $0 as Value })
      }
      for (key, delta) in counters where delta != 0 {
        try execute(Sql.ensureCounter, [key])
        try execute(Sql.incrementCounter, [Int64(delta), key])
      }
    }
  }

  func releaseRetry(owner: String, ids: [String], nextAttemptAt: Int64) throws {
    if ids.isEmpty { return }
    try execute(Sql.expandIds(Sql.releaseRetry, count: ids.count), [nextAttemptAt, owner] + ids.map { $0 as Value })
  }

  func release(owner: String, ids: [String]) throws {
    if ids.isEmpty { return }
    try execute(Sql.expandIds(Sql.release, count: ids.count), [owner] + ids.map { $0 as Value })
  }

  func getMeta(_ key: String) throws -> String? {
    var value: String?
    try query(Sql.getMeta, [key]) { value = Self.text($0, 0) }
    return value
  }

  func setMeta(_ key: String, _ value: String) throws {
    try execute(Sql.setMeta, [key, value])
  }

  func countEvents() throws -> Int64 {
    var count: Int64 = 0
    try query(Sql.countEvents, []) { count = sqlite3_column_int64($0, 0) }
    return count
  }

  func counters() throws -> [String: Int64] {
    var result: [String: Int64] = [:]
    try query(Sql.selectCounters, []) { result[Self.text($0, 0)] = sqlite3_column_int64($0, 1) }
    return result
  }

  func log(at: Int64, source: String, level: String, message: String) throws {
    try execute(Sql.insertBgLog, [at, source, level, message])
  }

  func trimLog(keep: Int) throws {
    try execute(Sql.trimBgLog, [Int64(keep)])
  }

  // MARK: SQLite plumbing

  /// Parameter values: String, Int64, Data, or nil (NSNull).
  typealias Value = Any?

  func execute(_ sql: String, _ params: [Value]) throws {
    let stmt = try prepare(sql, params)
    defer { sqlite3_finalize(stmt) }
    let rc = sqlite3_step(stmt)
    guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw error("step") }
  }

  func query(_ sql: String, _ params: [Value], row: (OpaquePointer) throws -> Void) throws {
    let stmt = try prepare(sql, params)
    defer { sqlite3_finalize(stmt) }
    while true {
      let rc = sqlite3_step(stmt)
      if rc == SQLITE_DONE { return }
      guard rc == SQLITE_ROW else { throw error("step") }
      try row(stmt)
    }
  }

  /// BEGIN IMMEDIATE ... COMMIT, as the claim protocol requires.
  private func transaction<T>(_ body: () throws -> T) throws -> T {
    try execute("BEGIN IMMEDIATE", [])
    do {
      let result = try body()
      try execute("COMMIT", [])
      return result
    } catch {
      try? execute("ROLLBACK", [])
      throw error
    }
  }

  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  private func prepare(_ sql: String, _ params: [Value]) throws -> OpaquePointer {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
      throw error("prepare")
    }
    for (i, param) in params.enumerated() {
      let index = Int32(i + 1)
      let rc: Int32
      switch param {
      case let v as String: rc = sqlite3_bind_text(s, index, v, -1, Self.transient)
      case let v as Int64: rc = sqlite3_bind_int64(s, index, v)
      case let v as Int: rc = sqlite3_bind_int64(s, index, Int64(v))
      case let v as Data:
        rc = v.withUnsafeBytes { sqlite3_bind_blob(s, index, $0.baseAddress, Int32(v.count), Self.transient) }
      default: rc = sqlite3_bind_null(s, index)
      }
      guard rc == SQLITE_OK else {
        sqlite3_finalize(s)
        throw error("bind")
      }
    }
    return s
  }

  private func error(_ op: String) -> StoreError {
    StoreError(description: "SQLite \(op) failed: \(String(cString: sqlite3_errmsg(db)))")
  }

  private static func text(_ s: OpaquePointer, _ col: Int32) -> String {
    sqlite3_column_text(s, col).map { String(cString: $0) } ?? ""
  }

  private static func blob(_ s: OpaquePointer, _ col: Int32) -> Data {
    let count = Int(sqlite3_column_bytes(s, col))
    guard count > 0, let bytes = sqlite3_column_blob(s, col) else { return Data() }
    return Data(bytes: bytes, count: count)
  }
}
