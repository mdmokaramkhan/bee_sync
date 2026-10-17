# bee_sync — Design Document

**Status:** Implemented through 0.3.0 · **Last updated:** 2026-10-18 · **Source:** `deep-research-report.md`

---

## 1. Summary

`bee_sync` is a Flutter plugin that durably delivers client-side events (analytics, audit, telemetry) to a backend. Every event is persisted to an on-device SQLite queue *before* any network attempt, then delivered either immediately (high priority) or in batches. Batches are flushed by the app in the foreground, and by a **native uploader** (Android WorkManager / iOS background tasks) when the Flutter app isn't running.

Delivery guarantee: **at-least-once**. Every event carries a client-generated UUID; servers dedupe on it.

### 1.1 Goals

| # | Goal |
|---|------|
| G1 | No event loss across app kills, crashes, reboots, or long offline periods (bounded only by retention policy). |
| G2 | Background delivery on **both** Android and iOS without Dart running. |
| G3 | Priority tiers: `immediate` (sent right after persist) and `normal` (batched). |
| G4 | First-class consent: grant / deny / unknown, with hold or purge semantics. |
| G5 | Bounded storage: max events, max bytes, max age, explicit overflow policy. |
| G6 | Optional encryption at rest of event payloads. *Deferred until after 1.0 (decided 2026-10-18).* |
| G7 | Pluggable transport in the foreground; a standard HTTP transport everywhere. |
| G8 | Observability: stats stream, delivery/drop callbacks, background log visible from Dart. |
| G9 | Fully testable core: injectable clock, store, transport, scheduler. |

### 1.2 Non-goals

- Not an analytics SDK: no sessions, screen tracking, user identity, funnels, or dashboards. Apps (or wrapper packages) build those on top.
- No exactly-once delivery (impossible on mobile; we document server-side dedupe instead).
- No web/desktop background delivery in v1 (Dart core still works in the foreground on all platforms).
- No guaranteed iOS background timing — iOS decides when background tasks run.

---

## 2. Architecture

```
┌──────────────────────────── Flutter app process ─────────────────────────────┐
│                                                                              │
│  Dart (foreground)                         Native (always available)         │
│  ┌─────────────────────┐                   ┌──────────────────────────────┐  │
│  │ BeeSync (public API)│                   │ BeeSyncPlugin                │  │
│  │  ├ ConsentGate      │  method channel   │  ├ KeyProvider (Keystore/    │  │
│  │  ├ Enqueuer         │◄─────(pigeon)────►│  │   Keychain)               │  │
│  │  ├ FlushController  │                   │  ├ BackgroundScheduler       │  │
│  │  ├ RetentionPolicy  │                   │  │   (WorkManager / BGTask)  │  │
│  │  ├ Uploader ────────┼──► EventTransport │  └ NativeUploader ──► HTTP   │  │
│  │  └ Stats/Logger     │    (pluggable)    │        │                     │  │
│  └─────────┬───────────┘                   └────────┼─────────────────────┘  │
│            │ sqflite                                │ system SQLite API      │
│            └──────────────►  bee_sync.db  ◄─────────┘                        │
│                         (WAL, shared schema + claim protocol)                │
└──────────────────────────────────────────────────────────────────────────────┘
```

Two independent uploaders (Dart and native) operate on **one SQLite file**. Correctness comes from a shared schema and a lease-based claim protocol (§5), not from coordination messages. All shared state (consent, global backoff, auth block, settings, counters) lives in the database, so whichever uploader runs next sees it. The step-by-step algorithm every uploader follows is in [`spec/uploader_contract.md`](../spec/uploader_contract.md).

### 2.1 Key decisions

| Decision | Choice | Why |
|---|---|---|
| Background execution | **Native HTTP uploader** (Kotlin/Swift) | No headless Flutter engine to boot; works when Dart is dead; fastest and most reliable inside tight iOS budgets. |
| Consequence | Custom Dart `EventTransport`s run **foreground only**. Background requires `HttpTransport` (config-driven, reproducible natively). | Accepted trade-off. Custom-transport users get foreground + lifecycle flushes, and are told so. |
| Storage | **SQLite via `sqflite`** in Dart; platform SQLite (`android.database.sqlite`, iOS `libsqlite3`) natively | Readable from both runtimes. Critically, sqflite uses the **system** SQLite library — the same one native code uses. Bundling a second SQLite copy (e.g. `sqlite3_flutter_libs`) in the same process is a known corruption hazard: POSIX advisory locks are per-process, and two library copies can silently release each other's locks. |
| Journal mode | WAL + `busy_timeout=5000` | Concurrent reader/writer from both sides; short write transactions. |
| Hive | Rejected | Not readable from native; effectively unmaintained. |
| Encryption | Per-payload AES-256-GCM, data key wrapped by Keystore/Keychain | Native can decrypt for background upload; no SQLCipher build burden. Metadata (id, name, timestamps) stays plaintext for querying. |
| Delivery semantics | At-least-once + UUIDv7 event ids | UUIDv7 is time-ordered → good index locality and natural sort for servers. |

---

## 3. Public API (Dart)

```dart
final bee = await BeeSync.initialize(BeeSyncConfig(
  transport: HttpTransport(
    endpoint: Uri.parse('https://api.example.com/v1/events'),
    headers: {'Authorization': 'Bearer $token'},
    gzip: true,
  ),
  batching: BatchingPolicy(
    flushAt: 20,                         // flush when ≥ N normal events pending
    flushInterval: Duration(seconds: 30),
    maxBatchSize: 100,                   // events per request
    maxBatchBytes: 512 * 1024,
  ),
  retry: RetryPolicy.exponential(
    base: Duration(seconds: 2),
    max: Duration(minutes: 10),
    maxAttempts: 12,                     // then event is dropped (reason: maxAttempts)
  ),
  retention: RetentionPolicy(
    maxEvents: 10000,
    maxBytes: 10 * 1024 * 1024,
    maxAge: Duration(days: 7),
    overflow: OverflowPolicy.dropOldest, // or dropNewest
  ),
  consent: ConsentConfig(
    initial: ConsentState.granted,       // granted | denied | unknown
    whileUnknown: UnknownConsentBehavior.hold, // hold | drop
  ),
  background: BackgroundConfig(enabled: true),
  encryption: EncryptionConfig.platformKey(), // or EncryptionConfig.none()
  logger: BeeLogger.console(level: LogLevel.info),
));

// Persist-then-return. Completes once the event is durable on disk.
final id = await bee.track('checkout_started', properties: {'cart_value': 42.5});
await bee.track('purchase', properties: {'order_id': 'A1'}, priority: Priority.immediate);

await bee.flush();                              // foreground flush now
await bee.setHeaders({'Authorization': 'Bearer $newToken'}); // token rotation
await bee.setConsent(ConsentState.denied, purge: true);

bee.stats.listen((QueueStats s) => ...);        // pending, inFlight, sent, dropped{reason}
bee.events.listen((DeliveryEvent e) => ...);    // Delivered / Dropped / FlushFailed
final bgLog = await bee.backgroundLog(limit: 50); // (v0.2) what native did while we were away

await bee.close();
```

Design notes:
- `BeeSync.initialize` returns an instance; `BeeSync.instance` is a convenience singleton. All internals are constructor-injected for tests.
- `track()` is safe to call on `BeeSync.instance` before `initialize` completes: calls wait for the store to open.
- Properties must be JSON-encodable; validated at `track()` time. Events larger than `maxEventBytes` (default 32 KB) are rejected with an error, never silently truncated.
- `track()` returns the event id so apps can correlate.

### 3.1 Transport interface

```dart
abstract interface class EventTransport {
  /// Sends one batch. Must not throw for HTTP-level failures; return a result.
  Future<TransportResult> send(EventBatch batch);
}

sealed class TransportResult {}
class Success extends TransportResult { final Set<String> rejectedIds; }  // per-event rejects optional
class RetryableFailure extends TransportResult { final Duration? retryAfter; }
class PermanentFailure extends TransportResult { final String reason; }
```

`HttpTransport` is the only transport the native uploader understands. It serializes its config (endpoint, headers, gzip, timeout) into the DB `meta` table on init and on `setHeaders()`, so the native side always has the latest values.

---

## 4. Data model

Single file: `<app support dir>/bee_sync/bee_sync.db`. Schema version tracked in `PRAGMA user_version` (currently 2). Only Dart creates or migrates the file; Dart refuses a newer version than it knows, and native uploaders run only on exactly the version they were built for (otherwise they wait for the app's next launch to migrate).

```sql
CREATE TABLE events (
  seq            INTEGER PRIMARY KEY AUTOINCREMENT, -- FIFO order
  id             TEXT    NOT NULL UNIQUE,           -- UUIDv7
  name           TEXT    NOT NULL,
  payload        BLOB    NOT NULL,                  -- JSON (UTF-8) or AES-GCM ciphertext
  encrypted      INTEGER NOT NULL DEFAULT 0,
  priority       INTEGER NOT NULL,                  -- 0 normal, 1 immediate
  created_at     INTEGER NOT NULL,                  -- ms since epoch, UTC
  size_bytes     INTEGER NOT NULL,
  attempts       INTEGER NOT NULL DEFAULT 0,
  next_attempt_at INTEGER NOT NULL DEFAULT 0,
  lease_owner    TEXT,                              -- NULL = pending
  lease_until    INTEGER                            -- ms; expired lease = pending
);
CREATE INDEX events_ready ON events (lease_owner, priority DESC, seq);

CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
-- keys: consent_state, transport_config (JSON), delivery_config (JSON),
--       flush_not_before (global backoff), auth_blocked; post-1.0: wrapped_data_key
-- See spec/uploader_contract.md §1 for formats and who writes each key.

CREATE TABLE counters (key TEXT PRIMARY KEY, value INTEGER NOT NULL DEFAULT 0);
-- schema v2: "sent", "dropped.<reason>"; incremented atomically by every uploader

CREATE TABLE bg_log (                               -- ring buffer, capped at 200 rows
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  at INTEGER NOT NULL, source TEXT NOT NULL,        -- 'android_worker' | 'ios_bgtask' | 'ios_bg_exit'
  level TEXT NOT NULL, message TEXT NOT NULL
);
```

---

## 5. Claim protocol (the core correctness mechanism)

Any uploader (Dart foreground, Android worker, iOS task) follows the same four steps. The SQL lives once in `spec/claim_protocol.sql` and is copied verbatim into all three implementations; a conformance test suite (§10) checks they behave identically.

1. **Claim** — in `BEGIN IMMEDIATE`:
   ```sql
   UPDATE events SET lease_owner = :owner, lease_until = :now + :leaseMs
   WHERE seq IN (
     SELECT seq FROM events
     WHERE (lease_owner IS NULL OR lease_until < :now)
       AND next_attempt_at <= :now
       AND (:immediateOnly = 0 OR priority = 1)
     ORDER BY priority DESC, seq
     LIMIT :maxBatchSize);
   SELECT * FROM events WHERE lease_owner = :owner ORDER BY priority DESC, seq;
   ```
   Then trim to `maxBatchBytes` and release the overflow.
2. **Send** — outside any transaction.
3. **Ack** on success: `DELETE FROM events WHERE lease_owner = :owner AND id NOT IN (:rejected)`; rejected ids are dropped with reason `rejectedByServer`.
4. **Release** on failure: increment `attempts`, set `next_attempt_at` per backoff, clear lease. Events at `maxAttempts` are dropped (`maxAttempts`).

Properties:
- **No double send under normal operation:** a live lease excludes other uploaders.
- **Crash safety:** an uploader that dies mid-send leaves a lease that expires (`leaseMs` = request timeout × 2, default 60 s); the events become claimable again → possible duplicate delivery, which is the accepted at-least-once cost.
- **Owner ids** are unique per run: `dart:<random>`, `android:<workId>`, `ios:<taskId>`.

### 5.1 Failure classification

| Response | Class | Action |
|---|---|---|
| 2xx | Success | Ack (minus per-event rejects if the body lists them) |
| 408, 429, 5xx, network error, timeout | Retryable | Release with backoff; honor `Retry-After`; set global `flush_not_before` so all uploaders back off together |
| 401, 403 | Auth | Release **without** consuming an attempt; background uploaders stop and wait for the foreground to call `setHeaders()` |
| 413 | Too large | Split batch in half and retry; single event → drop (`tooLarge`) |
| other 4xx | Permanent | Batch > 1 → **bisect** to isolate the poison event(s); single event → drop (`rejectedByServer`) |

Backoff: exponential with equal jitter, `cap = min(max, base × 2^(attempt-1))`, `delay = random(cap/2, cap)`. Equal rather than full jitter so a retry is never near-instant.

An auth failure pauses automatic flushes in the foreground too; `setHeaders()` or a manual `flush()` resumes them.

---

## 6. Delivery triggers

| Trigger | Who | What |
|---|---|---|
| `track(priority: immediate)` | Dart | Persist, then claim with `immediateOnly=1` (debounced 50 ms to coalesce bursts). |
| pending normal ≥ `flushAt` | Dart | Flush. |
| `flushInterval` timer | Dart | Flush if anything is ready. |
| Connectivity regained | Dart | Flush (connectivity is a hint only — the request is the real test). |
| App → background (`paused`) | Dart + native | Dart attempts a flush; native schedules background work if queue non-empty. |
| `flush()` | Dart | Manual flush. |
| WorkManager / BGTask fires | Native | Native uploader drains until empty, budget expires, or retryable failure. |

---

## 7. Background execution

### 7.1 Android

Implemented in `android/src/main/kotlin/dev/beesync/bee_sync/`.

- When the app goes to the background with a non-empty queue, Dart calls `scheduleBackgroundFlush()`, which enqueues:
  - unique **OneTimeWorkRequest** `bee_sync_flush` (`NetworkType.CONNECTED`, policy `KEEP`);
  - unique **PeriodicWorkRequest** `bee_sync_periodic` (15 min, the OS minimum) as a safety net while the queue is non-empty. The worker cancels it once the queue drains.
- When a run backs off, or is skipped because a backoff is still active (often the app's own failed flush moments earlier), the worker enqueues `bee_sync_retry` (policy `REPLACE`), delayed until `flush_not_before`. WorkManager's own retry/backoff is not used: the worker always returns success.
- `FlushWorker` (a plain `Worker`) runs `NativeUploader` over `HttpURLConnection` (no OkHttp dependency). There is no Flutter engine: Android starts the process just for the job service, and the uploader reads the database path that `configure()` saved in SharedPreferences.
- The database is opened with `ENABLE_WRITE_AHEAD_LOGGING` (otherwise Android would switch the file out of WAL on open) and `NO_LOCALIZED_COLLATORS`.
- `minSdk 24` (the Flutter default). The plugin declares `INTERNET`; no other manifest changes are needed.
- **Force-stop** (Settings → Force stop, or `adb shell am force-stop`) cancels all of an app's jobs until the user opens it again. That's an OS rule no library can work around. Normal process death (swiped away, killed for memory) keeps the jobs. Verified on an emulator: events queued during a server outage were delivered about 40 s after `am kill`, from a process Android started only for the job.

### 7.2 iOS

Implemented in `ios/Classes/` (`BackgroundDelivery.swift`, `NativeUploader.swift`, `BeeSyncStore.swift`). Layered, most reliable first:
1. **Background exit flush:** on `didEnterBackground`, call `beginBackgroundTask` and run the native uploader within the extra time iOS grants (about 30 s). This catches most events in practice. Dart also flushes when the app is hidden; the leases keep the two from sending the same events. Verified on the Simulator: after a server outage, the exit flush (`ios_bg_exit`) delivered all queued events and Dart's flush found nothing left.
2. **`BGAppRefreshTask`** (`dev.beesync.refresh`): submitted when the queue is non-empty as the app backgrounds, and after each background run, with `earliestBeginDate` at the backoff end (default 15 min).
3. **`BGProcessingTask`** (`dev.beesync.processing`, `requiresNetworkConnectivity = true`): for larger backlogs.

Uploads run on a private serial queue. Expiration handlers set a flag the uploader checks between batches, and the exit flush ends its background task right away. Leases release anything left in flight. Both tasks are cancelled once the queue drains. The uploader uses the system `libsqlite3` (the same library sqflite uses on iOS), `URLSession`, and a hand-written gzip wrapper, because Foundation only offers raw DEFLATE.

User setup (validated at startup; problems are logged as warnings through `BeeLogger`):
- `Info.plist`: `BGTaskSchedulerPermittedIdentifiers` = `[dev.beesync.refresh, dev.beesync.processing]`; `UIBackgroundModes` = `fetch`, `processing`. Identifiers missing from Info.plist are not registered, because registering them would crash.
- Registration happens in the plugin's `register(with:)`, which runs during `didFinishLaunching`, satisfying Apple's rule that handlers are registered before launch completes. Apps that register plugins later (for example scene-based setups) call `BeeSyncPlugin.registerBackgroundTasks()` from `didFinishLaunching`.
- iOS 13+ for the plugin. The example app targets iOS 15 because of the installed Xcode.
- The database stays at the default iOS file protection (`completeUntilFirstUserAuthentication`), so background runs can read it while the device is locked after the first unlock.

**Not yet verified:** BGTaskScheduler doesn't run on the Simulator, so layers 2 and 3 need a device test. In Xcode, pause the app and run `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"dev.beesync.refresh"]`, then resume.

**Expectation to document loudly:** iOS schedules BG tasks at its discretion (app usage patterns, battery, Low Power Mode). They may run hours later or not at all if the user force-quits the app. Layer 1 is the workhorse.

---

## 8. Consent

| State | `track()` | Queue | Uploads |
|---|---|---|---|
| `granted` | persisted | normal | on |
| `unknown` + `hold` | persisted, flagged held | kept | **paused** (native too, via `meta.consent_state`) |
| `unknown` + `drop` | dropped (`noConsent`) | — | paused |
| `denied` | dropped (`noConsent`) | purged if `purge: true` | off |

Consent state is persisted, so a denial survives restarts and is respected by the native uploader. `setConsent(granted)` releases held events.

---

## 9. Retention & encryption

**Retention** runs after each insert (cheap count/size check from cached counters) and on init (full sweep):
1. Delete events older than `maxAge` (`expired`).
2. While over `maxEvents` / `maxBytes`: `dropOldest` evicts oldest **normal** events first, then oldest immediate; `dropNewest` rejects the incoming event.
3. Leased events are never evicted mid-flight.

**Encryption** (`EncryptionConfig.platformKey()`), *deferred until after 1.0; the design below is kept for then*:
- On first init, native generates a random 256-bit data key, wraps it with a non-exportable Keystore key (Android) / stores it in Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (iOS). The `AfterFirstUnlock` class is required so background tasks can read it while the device is locked.
- Dart fetches the unwrapped data key once per process over the method channel and encrypts payloads with AES-256-GCM (`package:cryptography`). Nonce (12 B) is prefixed to the ciphertext; the event `id` is the AAD, binding ciphertext to its row.
- Native decrypts with `javax.crypto` / CryptoKit before building the request body.
- Key loss (e.g. app restored to a new device): undecryptable rows are dropped with reason `keyUnavailable`.
- Turning encryption on/off later only affects new events; the `encrypted` column handles mixed queues.

---

## 10. Wire format (HttpTransport)

```
POST {endpoint}
Content-Type: application/json
Content-Encoding: gzip            (if enabled)
X-BeeSync-Batch-Id: <uuid>
X-BeeSync-Sdk: bee_sync/<version> (<platform>; <uploader>)

{
  "batch_id": "…",
  "sent_at": 1771234567890,
  "events": [
    { "id": "0192…", "name": "purchase", "timestamp": 1771234560000,
      "priority": "immediate", "attempt": 1, "properties": { … } }
  ]
}
```

- `sent_at` lets servers correct device clock skew (`server_now - sent_at`).
- Optional response body `{"rejected": ["<id>", …]}` → per-event drop; anything else in a 2xx = all accepted.
- Recommended server behaviour (documented): dedupe on `id` with a TTL ≥ `maxAge`; return 2xx for duplicates.

The Dart and native serializers are checked against the same golden fixtures (`spec/fixtures/*.json`).

---

## 11. Observability

- `stats` stream: `pending`, `inFlight`, `held`, `sent`, `dropped` (by reason: `overflow`, `expired`, `maxAttempts`, `rejectedByServer`, `tooLarge`, `noConsent`, `keyUnavailable`), `lastSuccessAt`, `lastError`.
- `events` stream: `Delivered(ids)`, `Dropped(ids, reason)`, `FlushFailed(error, nextRetryAt)`.
- `BeeLogger` interface with levels; never logs payload contents above `trace`.
- `backgroundLog()` reads `bg_log`, so apps can see what native did while Dart wasn't running.
- `BeeSyncInspector` (v0.3, `package:bee_sync/inspector.dart`) has three tabs. **Status** shows counts, backoff, consent and background state. **Queue** reads stored events via `EventStore.inspect`, which claims nothing; properties are shown only on tap. **Activity** shows the last 50 `RequestActivity`/`DropActivity` entries and the native `bg_log`. Actions: flush, simulate offline (this app's transport only), reset backoff, purge.

---

## 12. Testing strategy

| Layer | How |
|---|---|
| Dart core | Unit tests with `FakeClock`, `FakeTransport` (scripted results), in-memory store, `FakeScheduler`. Covers batching, backoff, bisection, retention, consent, lease expiry. |
| Store / claim protocol | Integration tests on real SQLite (`sqflite_common_ffi` on host). Concurrency tests: two uploaders racing on one DB. |
| Cross-runtime conformance | `spec/` contains the claim SQL, schema, and JSON fixtures (input rows → expected request body / expected DB state after each response class). Run by Dart tests, JUnit (Robolectric), and XCTest. |
| Native background | `WorkManagerTestInitHelper` on Android; `BGTaskScheduler` simulated via the debugger `_simulateLaunchForTaskWithIdentifier` on iOS (manual checklist). |
| End-to-end | Example app + tiny local test server (Dart `shelf`) with switchable failure modes; integration_test drives offline → kill app → background → verify server received each id exactly once or more. |
| Public helper | `BeeSyncTestHarness` exported for app developers: in-memory, network-free, with assertions like `expectTracked('purchase')`. |

---

## 13. Package layout

```
bee_sync/
├── lib/
│   ├── bee_sync.dart                # public exports
│   ├── testing.dart                 # BeeSyncTestHarness
│   └── src/
│       ├── api/        (bee_sync.dart, config.dart, models.dart)
│       ├── core/       (enqueuer, flush_controller, retry, retention, consent)
│       ├── store/      (event_store.dart, sqflite_store.dart, schema.dart, claim_sql.dart)
│       ├── transport/  (event_transport.dart, http_transport.dart, wire_format.dart)
│       ├── crypto/     (payload_cipher.dart)
│       ├── platform/   (pigeon-generated channel + wrapper)
│       └── diagnostics/(stats.dart, logger.dart)
├── android/src/main/kotlin/dev/beesync/  (Plugin, FlushWorker, NativeUploader, Store, KeyProvider)
├── ios/Classes/                          (Plugin, BackgroundTasks, NativeUploader, Store, KeyProvider)
├── pigeons/messages.dart
├── spec/        (schema.sql, claim_protocol.sql, fixtures/)
├── example/     (demo app + local test server)
└── test/
```

Dependencies (kept minimal): `sqflite`, `path_provider`, `uuid`, `cryptography`, `http`, `connectivity_plus` (hint only). Dev: `pigeon`, `sqflite_common_ffi`, `fake_async`, `mocktail`.

---

## 14. Milestones

| Version | Scope | Exit criteria |
|---|---|---|
| **v0.1** — Dart core ✅ | API, sqflite store, claim protocol, batching, retry/backoff/bisection, `HttpTransport`, retention, consent, stats/logger, test harness | ≥ 90% line coverage of `core/` + `store/`; works on Android/iOS foreground only |
| **v0.2** — Background ✅ (released 2026-10-18; iOS BGTasks still need a device test) | `spec/` conformance suite; Android WorkManager uploader; iOS exit-flush + BGTasks; `meta`-synced transport config; `bg_log` | Example app delivers events queued before process death (Android ✅ emulator) / backgrounding (iOS ✅ exit flush on Simulator; BGTasks need a device) without reopening |
| **v0.3** — Developer experience & hardening (0.3.0 released 2026-10-18) | ✅ `BeeSyncInspector` debug widget; ✅ `track()` benchmark and the 5 → 1 store-call speed-up; ✅ pub.dev readiness (150/160 points, dry-run clean); ⏳ iOS BGTask and Android real-device verification; ⏳ first pub.dev publish | Inspector usable in the example app ✅; throughput numbers recorded ✅; both background paths verified on real devices ⏳ |
| **v0.4** — Auth & transport options (candidates) | Ingestion-key auth mode (no expiring tokens in background); background HTTP fallback for apps using a custom transport | Decided after v0.3 feedback |
| **v1.0** | API freeze after real-app feedback | — |
| **After 1.0** | Encryption at rest (§9): per-payload AES-256-GCM, Keystore/Keychain-wrapped key, covering stored auth headers | — |

---

## 15. Risks & open questions

| Risk / question | Notes |
|---|---|
| Three implementations of the claim protocol drift | Mitigated by verbatim shared SQL + conformance fixtures run in CI on all three. |
| Auth headers are stored in plaintext in `meta.transport_config` | Needed so the native uploader can authenticate. Encryption (after 1.0) should cover this row too; until then prefer ingestion-only keys over user tokens. |
| Old system SQLite on Android (API 23 = SQLite 3.8.10) | All shared SQL avoids UPSERT, RETURNING and window functions; see the header of `spec/schema.sql`. |
| Auth tokens expire while app is backgrounded | Native stops on 401 and waits for `setHeaders()`. **Open:** offer an optional static "ingestion key" mode (common for analytics endpoints) to sidestep this entirely? |
| sqflite throughput for high-volume `track()` | Channel round-trip per insert (~0.1–0.5 ms). Mitigation: micro-batch inserts in a single transaction every ~10 ms. Benchmark in v0.1. |
| Custom transports get no background delivery | Documented. **Open:** later allow a "background HTTP fallback" config alongside a custom foreground transport. |
| iOS force-quit kills all background work | Platform limitation; documented. Events deliver on next launch. |
| Should `immediate` events bypass consent `hold`? | Proposed: **no** — consent applies uniformly. |
| Competitive claims in the research report | Several are unverified or contradictory (e.g. Baseerh listed as both MIT and closed-source). Verify before using in README/marketing. |
| Naming | Package `bee_sync`, native namespace `dev.beesync` — confirm the domain/namespace you want to own. |
