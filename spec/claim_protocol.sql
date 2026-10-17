-- bee_sync claim protocol. See doc/DESIGN.md §5.
--
-- Every uploader (Dart foreground, Android worker, iOS background task) moves
-- events through: claim -> send -> delete_leased | release_retry | release.
-- A live lease (lease_until >= now) hides an event from other uploaders; an
-- expired lease makes it claimable again (at-least-once delivery).
--
-- Parameters are positional (?). "{ids}" is replaced at runtime with one "?"
-- per id, e.g. "?, ?, ?".
-- Times are milliseconds since the Unix epoch, UTC.

-- name: claim
-- params: owner, lease_until, now, now, immediate_only (0|1), limit
-- Run inside BEGIN IMMEDIATE together with select_claimed.
UPDATE events SET lease_owner = ?, lease_until = ?
WHERE seq IN (
  SELECT seq FROM events
  WHERE (lease_owner IS NULL OR lease_until < ?)
    AND next_attempt_at <= ?
    AND (? = 0 OR priority = 1)
  ORDER BY priority DESC, seq
  LIMIT ?
);

-- name: select_claimed
-- params: owner
SELECT seq, id, name, payload, encrypted, priority, created_at, size_bytes, attempts
FROM events
WHERE lease_owner = ?
ORDER BY priority DESC, seq;

-- name: delete_leased
-- params: owner, {ids}
-- Used both to acknowledge delivered events and to drop failed ones.
DELETE FROM events WHERE lease_owner = ? AND id IN ({ids});

-- name: release_retry
-- params: next_attempt_at, owner, {ids}
-- Failed attempt: count it and back off.
UPDATE events
SET attempts = attempts + 1, next_attempt_at = ?, lease_owner = NULL, lease_until = NULL
WHERE lease_owner = ? AND id IN ({ids});

-- name: release
-- params: owner, {ids}
-- Return events untouched (batch trimmed, auth failure, shutdown).
UPDATE events SET lease_owner = NULL, lease_until = NULL
WHERE lease_owner = ? AND id IN ({ids});

-- name: get_meta
-- params: key
SELECT value FROM meta WHERE key = ?;

-- name: set_meta
-- params: key, value
INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?);

-- name: count_events
-- Used by native schedulers to decide whether to keep background work queued.
SELECT COUNT(*) FROM events;

-- name: ensure_counter
-- params: key
INSERT OR IGNORE INTO counters (key, value) VALUES (?, 0);

-- name: increment_counter
-- params: delta, key  (run ensure_counter first, in the same transaction)
UPDATE counters SET value = value + ? WHERE key = ?;

-- name: select_counters
SELECT key, value FROM counters;

-- name: insert_bg_log
-- params: at, source, level, message
-- Native only. source: "android_worker" | "ios_bg_exit" | "ios_bgtask";
-- level: "debug" | "info" | "warn" | "error".
INSERT INTO bg_log (at, source, level, message) VALUES (?, ?, ?, ?);

-- name: trim_bg_log
-- params: keep  (200)
-- Native only, after each run.
DELETE FROM bg_log WHERE seq <= (SELECT MAX(seq) FROM bg_log) - ?;

-- name: select_bg_log
-- params: limit
SELECT at, source, level, message FROM bg_log ORDER BY seq DESC LIMIT ?;
