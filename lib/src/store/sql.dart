/// SQL shared with the native uploaders.
///
/// Statements under "Spec" are verbatim copies of `spec/schema.sql` and
/// `spec/claim_protocol.sql`; `test/store/spec_conformance_test.dart` keeps
/// them in sync. Statements under "Dart only" are used by the foreground
/// runtime alone.
library;

const int schemaVersion = 2;

// ---- Spec: schema.sql ------------------------------------------------------

const String createEvents = '''
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
)''';

const String createEventsReadyIndex =
    'CREATE INDEX events_ready ON events (lease_owner, priority DESC, seq)';

const String createMeta = '''
CREATE TABLE meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
)''';

const String createBgLog = '''
CREATE TABLE bg_log (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  at INTEGER NOT NULL,
  source TEXT NOT NULL,
  level TEXT NOT NULL,
  message TEXT NOT NULL
)''';

const String createCounters = '''
CREATE TABLE counters (
  key TEXT PRIMARY KEY,
  value INTEGER NOT NULL DEFAULT 0
)''';

// ---- Spec: claim_protocol.sql ----------------------------------------------

const String claim = '''
UPDATE events SET lease_owner = ?, lease_until = ?
WHERE seq IN (
  SELECT seq FROM events
  WHERE (lease_owner IS NULL OR lease_until < ?)
    AND next_attempt_at <= ?
    AND (? = 0 OR priority = 1)
  ORDER BY priority DESC, seq
  LIMIT ?
)''';

const String selectClaimed = '''
SELECT seq, id, name, payload, encrypted, priority, created_at, size_bytes, attempts
FROM events
WHERE lease_owner = ?
ORDER BY priority DESC, seq''';

const String deleteLeased =
    'DELETE FROM events WHERE lease_owner = ? AND id IN ({ids})';

const String releaseRetry = '''
UPDATE events
SET attempts = attempts + 1, next_attempt_at = ?, lease_owner = NULL, lease_until = NULL
WHERE lease_owner = ? AND id IN ({ids})''';

const String releaseBackoff = '''
UPDATE events SET next_attempt_at = ?, lease_owner = NULL, lease_until = NULL
WHERE lease_owner = ? AND id IN ({ids})''';

const String release = '''
UPDATE events SET lease_owner = NULL, lease_until = NULL
WHERE lease_owner = ? AND id IN ({ids})''';

const String getMeta = 'SELECT value FROM meta WHERE key = ?';

const String setMeta = 'INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)';

const String countEvents = 'SELECT COUNT(*) FROM events';

const String ensureCounter =
    'INSERT OR IGNORE INTO counters (key, value) VALUES (?, 0)';

const String incrementCounter =
    'UPDATE counters SET value = value + ? WHERE key = ?';

const String selectCounters = 'SELECT key, value FROM counters';

const String insertBgLog =
    'INSERT INTO bg_log (at, source, level, message) VALUES (?, ?, ?, ?)';

const String trimBgLog =
    'DELETE FROM bg_log WHERE seq <= (SELECT MAX(seq) FROM bg_log) - ?';

const String selectBgLog =
    'SELECT at, source, level, message FROM bg_log ORDER BY seq DESC LIMIT ?';

// ---- Dart only -------------------------------------------------------------

const String insertEvent = '''
INSERT INTO events (id, name, payload, encrypted, priority, created_at, size_bytes)
VALUES (?, ?, ?, ?, ?, ?, ?)''';

/// params: now
const String totals = '''
SELECT COUNT(*) AS total,
  COALESCE(SUM(CASE WHEN lease_owner IS NOT NULL AND lease_until >= ? THEN 1 ELSE 0 END), 0) AS in_flight,
  COALESCE(SUM(size_bytes), 0) AS bytes
FROM events''';

/// params: created_before, now
const String selectExpired = '''
SELECT id FROM events
WHERE created_at < ? AND (lease_owner IS NULL OR lease_until < ?)''';

/// Eviction order: normal priority before immediate, oldest first.
/// params: now
const String selectEvictable = '''
SELECT id, size_bytes FROM events
WHERE lease_owner IS NULL OR lease_until < ?
ORDER BY priority ASC, seq ASC''';

/// Read-only listing for the inspector, FIFO. params: limit
const String inspectEvents = '''
SELECT id, name, payload, priority, created_at, size_bytes, attempts,
  next_attempt_at, lease_owner, lease_until
FROM events
ORDER BY seq
LIMIT ?''';

const String deleteByIds = 'DELETE FROM events WHERE id IN ({ids})';

const String selectAllIds = 'SELECT id FROM events';

const String deleteAll = 'DELETE FROM events';

const String deleteMeta = 'DELETE FROM meta WHERE key = ?';

const String resetBackoff =
    'UPDATE events SET next_attempt_at = 0 WHERE next_attempt_at > 0';

/// Replaces `{ids}` in [sql] with [count] positional placeholders.
String expandIds(String sql, int count) =>
    sql.replaceFirst('{ids}', List.filled(count, '?').join(', '));
