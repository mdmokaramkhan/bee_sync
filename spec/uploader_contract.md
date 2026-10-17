# Uploader contract

Every uploader (Dart foreground, Android `FlushWorker`, iOS background-exit and BGTask) runs the same algorithm against `bee_sync.db`. This file is the source of truth for native implementations. The Dart reference is `lib/src/core/flush_controller.dart`. The test cases in `fixtures/uploader/` are run by all three runtimes.

SQL statements are referenced by name from `schema.sql` and `claim_protocol.sql`.

## 1. `meta` keys

All values are TEXT.

| Key | Written by | Format | Meaning |
|---|---|---|---|
| `consent_state` | Dart | `granted` \| `denied` \| `unknown` | Upload only when `granted`. |
| `transport_config` | Dart | JSON, §1.1 | How to reach the server. Absent when the app uses a custom transport: native must not upload. |
| `delivery_config` | Dart | JSON, §1.2 | Batching and retry settings. |
| `flush_not_before` | any uploader | ms since epoch, decimal; `0` = none | Global backoff. |
| `auth_blocked` | any uploader | `1` \| `0` | Set on 401/403. Cleared only by Dart (`setHeaders()` or a successful manual flush). |

Counters live in the `counters` table: `sent`, and `dropped.<reason>`. The reasons are `overflow`, `expired`, `maxAttempts`, `rejectedByServer`, `tooLarge`, `noConsent` and `unreadable`. Increment them with `ensure_counter` + `increment_counter`, in the same transaction as the matching `delete_leased`.

### 1.1 `transport_config`

```json
{"endpoint": "https://api.example.com/v1/events", "headers": {"Authorization": "Bearer …"},
 "gzip": true, "timeout_ms": 30000}
```

### 1.2 `delivery_config`

```json
{"max_batch_size": 100, "max_batch_bytes": 524288, "lease_ms": 60000,
 "retry_base_ms": 2000, "retry_max_ms": 600000, "max_attempts": 12}
```

These values are also the defaults when a fixture omits `delivery_config`.

## 2. Run algorithm

```
owner = "<runtime>:<uuid v4>"          # dart: / android: / ios:
check PRAGMA user_version == 2         # else: log to bg_log if possible, stop
read meta
if consent_state != "granted": stop(skipped)
if native and transport_config absent: stop(skipped)
if auth_blocked == "1" and not manual: stop(skipped)
if now < flush_not_before and not manual: stop(skipped)

loop:
  rows = claim(owner, lease_until = now + lease_ms, now, now,
               immediate_only, max_batch_size) + select_claimed(owner)
  if rows empty: stop(drained)
  batch = longest prefix of rows whose summed size_bytes <= max_batch_bytes,
          but at least one row
  release(owner, rows not in batch)
  outcome = send(batch)                # §3, may recurse
  if outcome stops: stop(outcome)

on stop(drained):     if flush_not_before != 0: set_meta(flush_not_before, "0")
                      if manual: set_meta(auth_blocked, "0")
on stop(backingOff):  set_meta(flush_not_before, retry_at)
on stop(authBlocked): set_meta(auth_blocked, "1")
```

Native runs are never `manual`. They also stop early when the OS budget expires. Leased rows are then left alone, and their leases expire.

## 3. Sending a batch

1. Decode each payload: UTF-8 JSON object. Rows that fail to decode are deleted with `delete_leased` and counted as `dropped.unreadable`. They are not sent.
2. POST the body (§4). Classify the result:

| Result | Action |
|---|---|
| 2xx | `delete_leased` all. Ids in the optional body `{"rejected": [...]}` count as `dropped.rejectedByServer`, the rest as `sent`. Continue. |
| 408, 429, ≥500, 1xx/3xx, network error, timeout | Retry (§3.1); stop(backingOff). |
| 401, 403 | `release` all (no attempt counted); stop(authBlocked). |
| 413 | More than one row: split (§3.2). One row: delete, `dropped.tooLarge`. |
| other 4xx | More than one row: split (§3.2). One row: delete, `dropped.rejectedByServer`. |

### 3.1 Retry

For each row, `attempt = attempts + 1`. Rows with `attempt >= max_attempts` are deleted and counted as `dropped.maxAttempts`. For the rest:

```
a        = max attempt among retried rows (1 if none)
cap      = min(retry_max_ms, retry_base_ms * 2^(a-1))
delay    = cap/2 + uniform_int(0, cap - cap/2)        # integer division
delay    = max(delay, Retry-After in ms)              # if the header is present
retry_at = now + delay
release_retry(retry_at, owner, ids)
```

`Retry-After` is either delay-seconds or an HTTP-date (RFC 7231).

### 3.2 Split

Send the first `floor(n/2)` rows, then the rest. If the first half stops the run, `release` the second half untouched and return that stop. Requests made while splitting go out in this order: depth-first, first half first.

## 4. Request

```
POST <endpoint>
Content-Type: application/json
Content-Encoding: gzip                     # when gzip is true
X-BeeSync-Batch-Id: <uuid v4, new per request>
X-BeeSync-Sdk: bee_sync/<version> (<os>; <runtime>)
<transport_config.headers>
```

The body is shown in `fixtures/wire_format.json`. `timestamp` is `created_at`. `attempt` is `attempts + 1`. `priority` is `normal` for 0 and `immediate` for 1. `properties` is the decoded payload.

## 5. Background log (native only)

After each run, `insert_bg_log` one `info` summary line, for example `drained: sent 12, dropped 0`, plus a `warn` or `error` line for any failure. Then `trim_bg_log(200)`. Never log payloads or headers.

## 6. Fixture format (`fixtures/uploader/*.json`)

```jsonc
{
  "description": "…",
  "now": 1760000000000,
  "delivery_config": { … },            // optional, overrides defaults
  "meta": {"consent_state": "granted"},// optional; consent defaults to granted
  "manual": false,                     // optional
  "events": [{
    "id": "a", "name": "e", "properties": {}, "priority": "normal",
    "created_at": 0, "attempts": 0, "next_attempt_at": 0,
    "lease_owner": null, "lease_until": null,
    "payload_raw": "…"                 // optional: stored instead of properties
  }],
  "responses": [{"status": 200, "headers": {}, "body": ""}, {"network_error": true}],
  "expect": {
    "status": "drained|backingOff|authBlocked|skipped",
    "requests": [["a", "b"], ["c"]],   // event ids per request, in order
    "remaining": [{"id": "c", "attempts": 1,
                   "next_attempt_at": {"min": 1000, "max": 2000}}],
    "counters": {"sent": 2},           // omitted keys must be absent or 0
    "meta": {"flush_not_before": {"min": 1, "max": 2}, "auth_blocked": "1"}
  }
}
```

A number in `expect` means an exact match, and `{"min", "max"}` means an inclusive range. `remaining` lists every row left in `events`, in `seq` order. A runner fails if the uploader makes more requests than `responses` provides.
