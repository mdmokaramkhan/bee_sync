## 0.2.0 (unreleased)

Native background delivery. In progress on `feat/v0.2-native-background-delivery`: Android is done, iOS is next.

### Added
* **Android background delivery.** A native uploader written in Kotlin follows `spec/uploader_contract.md`. It runs from WorkManager:
  * `bee_sync_flush`: once, as soon as there's network, after the app goes to the background with events queued.
  * `bee_sync_periodic`: every 15 minutes while events remain.
  * `bee_sync_retry`: once, when the backoff ends.

  It runs without a Flutter engine, writes a summary to `bg_log`, and cancels the periodic job when the queue is empty. Verified on an emulator: queued events were delivered after the app process was killed.
* Android tests (Robolectric, 68): checks that the SQL matches the spec, runs every shared uploader test case with 3 seeds against a real MockWebServer, and covers the wire format, gzip, Retry-After parsing, the worker end to end, and scheduling.
* `tool/test_server.dart`: a local endpoint with switchable modes (`ok`, `fail`, `auth`, `slow`). It logs each batch and counts duplicate ids.
* Example app: set the endpoint with `--dart-define=BEE_ENDPOINT=…` and track N events at startup with `--dart-define=BEE_DEMO_EVENTS=N`. Its debug build allows cleartext HTTP so it can reach the local server.
* `spec/uploader_contract.md`: the algorithm every uploader (Dart, Android, iOS) follows, plus the shared `meta` keys.
* `spec/fixtures/`: 18 uploader test cases and a wire-format case, run by the Dart tests (and, later, by the native tests).
* `BackgroundConfig(enabled: true)` in `BeeSyncConfig`. Background delivery needs `HttpTransport` and the default SQLite store, and is turned off otherwise.
* `BeeSync.backgroundLog({limit})` reads what the native uploader recorded while the app was closed.
* `BeeSync.backgroundEnabled`.
* A typed (pigeon) channel to native code, `BeeSyncHostApi`: `configure`, `scheduleBackgroundFlush`, `cancelBackgroundFlush`. The Android and iOS sides are placeholders for now: they store the database path but don't schedule anything yet.
* `BeeSync.initialize(background:)` and `BackgroundScheduler`, to inject a scheduler in tests and advanced setups.
* `MetaKeys` and `CounterKeys` are exported.
* Testing: `FakeBackgroundScheduler`; `InMemoryEventStore(databasePath:)`; `InMemoryEventStore.addBackgroundLog`.

### Changed
* The plugin's Android manifest now declares `INTERNET`.
* Version is now `0.2.0-dev` in `pubspec.yaml`, `version.dart` and `BEE_SYNC_VERSION` (Kotlin), and appears in the `X-BeeSync-Sdk` header.
* Android tests now use JUnit4 and Robolectric instead of the template's JUnit Platform and Mockito.
* **Schema v2:** new `counters` table that every uploader increments atomically. v1 databases are migrated on open, and the old `meta.counters` JSON is carried over. *(schema)*
* `EventStore` has new members `databasePath`, `deleteMeta`, `incrementCounters`, `counters` and `backgroundLog`, and `deleteLeased` takes `counters`. Custom stores must implement them. *(public API)*
* `FlushController` now does what the contract specifies: it checks consent, auth block and backoff in `meta` before running, writes `flush_not_before` and `auth_blocked` afterwards, and counts deliveries and drops in the same transaction as the delete. Native uploaders and the app now share this state instead of keeping it in memory.
* `QueueStats` counts and `backoffUntil` are read from the database, so they include work done by the native uploader.
* `HttpTransport` settings are written to `meta.transport_config`, and batching and retry settings to `meta.delivery_config`. With a custom transport, `transport_config` is removed so native code won't upload.
* `setHeaders()` also clears an auth block set by a background run.

* Example app: raised its iOS deployment target to 15.0 and excluded `x86_64` for the simulator, so it builds with the installed Xcode and Flutter 3.38. The plugin itself still supports iOS 13+.

### Removed
* The `getPlatformVersion` method channel from the plugin template.

## 0.1.0

* Dart core: persistent SQLite queue (sqflite) with a lease-based claim protocol.
* Batching (`flushAt`, interval, size and byte limits), immediate priority.
* Retries with exponential backoff and `Retry-After`; batch bisection on permanent failures; 413 splitting.
* `HttpTransport` with gzip and per-event rejects; pluggable `EventTransport`.
* Retention: max events, max bytes, max age, drop-oldest / drop-newest.
* Persistent consent (granted / denied / unknown with hold or drop) and purge.
* Stats and delivery event streams; `BeeLogger`.
* `package:bee_sync/testing.dart`: `BeeSyncTestHarness`, `FakeTransport`, `InMemoryEventStore`.
