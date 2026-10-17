-- bee_sync on-device schema, version 1 (PRAGMA user_version = 1).
--
-- Shared by every runtime that opens bee_sync.db: Dart (sqflite), Android
-- (android.database.sqlite) and iOS (libsqlite3). Each implementation copies
-- these statements verbatim; test/store/spec_conformance_test.dart fails if
-- the Dart copy drifts.
--
-- Compatibility: Android API 23 ships SQLite 3.8.10, so no UPSERT, RETURNING
-- or window functions anywhere in this file or claim_protocol.sql.
--
-- Connection setup (all runtimes): PRAGMA journal_mode = WAL;
--                                  PRAGMA busy_timeout = 5000;

-- name: create_events
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
);

-- name: create_events_ready_index
CREATE INDEX events_ready ON events (lease_owner, priority DESC, seq);

-- name: create_meta
CREATE TABLE meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

-- name: create_bg_log
CREATE TABLE bg_log (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  at INTEGER NOT NULL,
  source TEXT NOT NULL,
  level TEXT NOT NULL,
  message TEXT NOT NULL
);
