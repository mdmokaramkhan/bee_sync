package dev.beesync.bee_sync

/**
 * Verbatim copies of spec/schema.sql and spec/claim_protocol.sql.
 * SqlConformanceTest fails if these drift from the spec.
 */
internal object Sql {
    const val SCHEMA_VERSION = 2

    // ---- schema.sql ----------------------------------------------------------

    const val CREATE_EVENTS = """
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
)"""

    const val CREATE_EVENTS_READY_INDEX =
        "CREATE INDEX events_ready ON events (lease_owner, priority DESC, seq)"

    const val CREATE_META = """
CREATE TABLE meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
)"""

    const val CREATE_BG_LOG = """
CREATE TABLE bg_log (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  at INTEGER NOT NULL,
  source TEXT NOT NULL,
  level TEXT NOT NULL,
  message TEXT NOT NULL
)"""

    const val CREATE_COUNTERS = """
CREATE TABLE counters (
  key TEXT PRIMARY KEY,
  value INTEGER NOT NULL DEFAULT 0
)"""

    // ---- claim_protocol.sql --------------------------------------------------

    const val CLAIM = """
UPDATE events SET lease_owner = ?, lease_until = ?
WHERE seq IN (
  SELECT seq FROM events
  WHERE (lease_owner IS NULL OR lease_until < ?)
    AND next_attempt_at <= ?
    AND (? = 0 OR priority = 1)
  ORDER BY priority DESC, seq
  LIMIT ?
)"""

    const val SELECT_CLAIMED = """
SELECT seq, id, name, payload, encrypted, priority, created_at, size_bytes, attempts
FROM events
WHERE lease_owner = ?
ORDER BY priority DESC, seq"""

    const val DELETE_LEASED = "DELETE FROM events WHERE lease_owner = ? AND id IN ({ids})"

    const val RELEASE_RETRY = """
UPDATE events
SET attempts = attempts + 1, next_attempt_at = ?, lease_owner = NULL, lease_until = NULL
WHERE lease_owner = ? AND id IN ({ids})"""

    const val RELEASE = """
UPDATE events SET lease_owner = NULL, lease_until = NULL
WHERE lease_owner = ? AND id IN ({ids})"""

    const val GET_META = "SELECT value FROM meta WHERE key = ?"

    const val SET_META = "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)"

    const val COUNT_EVENTS = "SELECT COUNT(*) FROM events"

    const val ENSURE_COUNTER = "INSERT OR IGNORE INTO counters (key, value) VALUES (?, 0)"

    const val INCREMENT_COUNTER = "UPDATE counters SET value = value + ? WHERE key = ?"

    const val SELECT_COUNTERS = "SELECT key, value FROM counters"

    const val INSERT_BG_LOG = "INSERT INTO bg_log (at, source, level, message) VALUES (?, ?, ?, ?)"

    const val TRIM_BG_LOG = "DELETE FROM bg_log WHERE seq <= (SELECT MAX(seq) FROM bg_log) - ?"

    const val SELECT_BG_LOG =
        "SELECT at, source, level, message FROM bg_log ORDER BY seq DESC LIMIT ?"

    /** Replaces `{ids}` with [count] positional placeholders. */
    fun expandIds(sql: String, count: Int): String =
        sql.replaceFirst("{ids}", List(count) { "?" }.joinToString(", "))

    /** Spec name -> statement, for the conformance test. */
    val schemaStatements = mapOf(
        "create_events" to CREATE_EVENTS,
        "create_events_ready_index" to CREATE_EVENTS_READY_INDEX,
        "create_meta" to CREATE_META,
        "create_bg_log" to CREATE_BG_LOG,
        "create_counters" to CREATE_COUNTERS,
    )

    val protocolStatements = mapOf(
        "claim" to CLAIM,
        "select_claimed" to SELECT_CLAIMED,
        "delete_leased" to DELETE_LEASED,
        "release_retry" to RELEASE_RETRY,
        "release" to RELEASE,
        "get_meta" to GET_META,
        "set_meta" to SET_META,
        "count_events" to COUNT_EVENTS,
        "ensure_counter" to ENSURE_COUNTER,
        "increment_counter" to INCREMENT_COUNTER,
        "select_counters" to SELECT_COUNTERS,
        "insert_bg_log" to INSERT_BG_LOG,
        "trim_bg_log" to TRIM_BG_LOG,
        "select_bg_log" to SELECT_BG_LOG,
    )
}
