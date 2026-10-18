import Foundation

/// Verbatim copies of spec/schema.sql and spec/claim_protocol.sql.
/// SqlConformanceTests fails if these drift from the spec.
enum Sql {
  static let schemaVersion: Int32 = 2

  // MARK: schema.sql

  static let createEvents = """
    CREATE TABLE events (
      seq INTEGER PRIMARY KEY AUTOINCREMENT,
      id TEXT NOT NULL UNIQUE,
      name TEXT NOT NULL,
      payload BLOB NOT NULL,
      encrypted INTEGER NOT NULL DEFAULT 0,
      priority INTEGER NOT NULL,
      created_at INTEGER NOT NULL,
      size_bytes INTEGER NOT NULL,
      attempts INTEGER NOT NULL DEFAULT 0,
      next_attempt_at INTEGER NOT NULL DEFAULT 0,
      lease_owner TEXT,
      lease_until INTEGER
    )
    """

  static let createEventsReadyIndex =
    "CREATE INDEX events_ready ON events (lease_owner, priority DESC, seq)"

  static let createMeta = """
    CREATE TABLE meta (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
    """

  static let createBgLog = """
    CREATE TABLE bg_log (
      seq INTEGER PRIMARY KEY AUTOINCREMENT,
      at INTEGER NOT NULL,
      source TEXT NOT NULL,
      level TEXT NOT NULL,
      message TEXT NOT NULL
    )
    """

  static let createCounters = """
    CREATE TABLE counters (
      key TEXT PRIMARY KEY,
      value INTEGER NOT NULL DEFAULT 0
    )
    """

  // MARK: claim_protocol.sql

  static let claim = """
    UPDATE events SET lease_owner = ?, lease_until = ?
    WHERE seq IN (
      SELECT seq FROM events
      WHERE (lease_owner IS NULL OR lease_until < ?)
        AND next_attempt_at <= ?
        AND (? = 0 OR priority = 1)
      ORDER BY priority DESC, seq
      LIMIT ?
    )
    """

  static let selectClaimed = """
    SELECT seq, id, name, payload, encrypted, priority, created_at, size_bytes, attempts
    FROM events
    WHERE lease_owner = ?
    ORDER BY priority DESC, seq
    """

  static let deleteLeased = "DELETE FROM events WHERE lease_owner = ? AND id IN ({ids})"

  static let releaseRetry = """
    UPDATE events
    SET attempts = attempts + 1, next_attempt_at = ?, lease_owner = NULL, lease_until = NULL
    WHERE lease_owner = ? AND id IN ({ids})
    """

  static let releaseBackoff = """
    UPDATE events SET next_attempt_at = ?, lease_owner = NULL, lease_until = NULL
    WHERE lease_owner = ? AND id IN ({ids})
    """

  static let release = """
    UPDATE events SET lease_owner = NULL, lease_until = NULL
    WHERE lease_owner = ? AND id IN ({ids})
    """

  static let getMeta = "SELECT value FROM meta WHERE key = ?"

  static let setMeta = "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)"

  static let countEvents = "SELECT COUNT(*) FROM events"

  static let ensureCounter = "INSERT OR IGNORE INTO counters (key, value) VALUES (?, 0)"

  static let incrementCounter = "UPDATE counters SET value = value + ? WHERE key = ?"

  static let selectCounters = "SELECT key, value FROM counters"

  static let insertBgLog = "INSERT INTO bg_log (at, source, level, message) VALUES (?, ?, ?, ?)"

  static let trimBgLog = "DELETE FROM bg_log WHERE seq <= (SELECT MAX(seq) FROM bg_log) - ?"

  static let selectBgLog =
    "SELECT at, source, level, message FROM bg_log ORDER BY seq DESC LIMIT ?"

  /// Replaces `{ids}` with `count` positional placeholders.
  static func expandIds(_ sql: String, count: Int) -> String {
    sql.replacingOccurrences(
      of: "{ids}", with: Array(repeating: "?", count: count).joined(separator: ", "))
  }

  /// Spec name -> statement, for the conformance test.
  static let schemaStatements: [String: String] = [
    "create_events": createEvents,
    "create_events_ready_index": createEventsReadyIndex,
    "create_meta": createMeta,
    "create_bg_log": createBgLog,
    "create_counters": createCounters,
  ]

  static let protocolStatements: [String: String] = [
    "claim": claim,
    "select_claimed": selectClaimed,
    "delete_leased": deleteLeased,
    "release_retry": releaseRetry,
    "release_backoff": releaseBackoff,
    "release": release,
    "get_meta": getMeta,
    "set_meta": setMeta,
    "count_events": countEvents,
    "ensure_counter": ensureCounter,
    "increment_counter": incrementCounter,
    "select_counters": selectCounters,
    "insert_bg_log": insertBgLog,
    "trim_bg_log": trimBgLog,
    "select_bg_log": selectBgLog,
  ]
}
