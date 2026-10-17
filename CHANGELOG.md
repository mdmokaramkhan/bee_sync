## 0.2.0 — 2026-10-18

**Native background delivery.** With `HttpTransport`, events still queued when the app goes to the background are delivered by native code on Android and iOS, even after the app process is gone. No Flutter engine is started for it. Dart, Kotlin and Swift all follow one written contract and are tested against the same shared test cases.

### Upgrading from 0.1.0
* **Database schema v2.** It's migrated automatically on first launch, and existing counters are carried over. Native uploaders wait for this migration. They do nothing if the app was updated but hasn't been opened yet.
* **iOS:** add the `BGTaskSchedulerPermittedIdentifiers` and `UIBackgroundModes` entries shown in the README. Without them, only the upload when the app goes to the background runs, and a warning is logged at startup.
* **Custom `EventStore` implementations** must add `databasePath`, `deleteMeta`, `incrementCounters`, `counters` and `backgroundLog`. `deleteLeased` now takes `counters`.
* To opt out of background delivery: `BeeSyncConfig(background: BackgroundConfig(enabled: false))`.

### Added
* **Android:** a Kotlin uploader run by WorkManager:
  * `bee_sync_flush`: once, when there's network, after the app goes to the background with events queued;
  * `bee_sync_periodic`: every 15 minutes while events remain;
  * `bee_sync_retry`: once, when the backoff ends.

  The periodic job is cancelled when the queue is empty.
* **iOS:** a Swift uploader (system `libsqlite3`, `URLSession`):
  * runs when the app goes to the background, inside the extra time iOS grants;
  * runs from `BGAppRefreshTask` (`dev.beesync.refresh`) and `BGProcessingTask` (`dev.beesync.processing`), scheduled for when the backoff ends.

  Missing Info.plist entries are reported at startup. `BeeSyncPlugin.registerBackgroundTasks()` is for apps that register plugins after launch.
* `BackgroundConfig` (on by default; needs `HttpTransport` and the default store), `BeeSync.backgroundEnabled`, and `BeeSync.backgroundLog({limit})` to see what native uploads did while the app was closed.
* `spec/uploader_contract.md` and `spec/fixtures/` (18 uploader cases plus a wire-format case). The Dart, Android and iOS test suites all run them.
* `BackgroundScheduler` and `BeeSync.initialize(background:)`; `MetaKeys` and `CounterKeys` exported.
* Testing: `FakeBackgroundScheduler`, `InMemoryEventStore(databasePath:)`, `InMemoryEventStore.addBackgroundLog`.
* `tool/test_server.dart`: a local endpoint with `ok`, `fail`, `auth` and `slow` modes. It logs batches and counts duplicate ids.
* Example app: `--dart-define=BEE_ENDPOINT=…` and `--dart-define=BEE_DEMO_EVENTS=N`, the iOS background entries in Info.plist, and local-network HTTP in debug builds.

### Changed
* Shared state lives in the database, not in memory: consent, global backoff (`flush_not_before`), auth block, transport and delivery settings, and counters. Whichever uploader runs next, foreground or background, sees it.
* `QueueStats` counters and `backoffUntil` include work done by the native uploaders.
* `setHeaders()` also clears an auth block set by a background run.
* With a custom transport, `meta.transport_config` is removed, so native code never uploads.
* The plugin's Android manifest declares `INTERNET`.
* The iOS podspec links `BackgroundTasks` and `sqlite3`. Package metadata now points to the GitHub repository.
* Example app: iOS deployment target 15.0 and arm64-only simulator builds, to build with current Xcode and Flutter 3.38. The plugin itself still supports iOS 13+ and Android API 24+.
* Licensed under MIT (previously a template placeholder).

### Removed
* The plugin template's `getPlatformVersion` method channel.

### Known limitations
* iOS `BGTaskScheduler` doesn't run on the Simulator, so the scheduled iOS tasks have not been tested on a device yet. The upload when the app goes to the background is verified on the Simulator.
* Android force-stop and iOS force-quit cancel all background work until the user opens the app again (an OS rule). Events are kept and sent on the next launch.
* Auth headers are stored unencrypted in the app's database so native code can use them. Encryption at rest is planned after 1.0.

### Testing
* 151 Dart tests, 68 Android tests (Robolectric), 11 iOS tests (XCTest). Deliberately broken uploader logic fails the same shared cases on all three runtimes.
* Verified end to end with `tool/test_server.dart`: on the Android emulator, after the app process was killed; on the iOS Simulator, through the upload when the app goes to the background.

## 0.1.0

* Dart core: persistent SQLite queue (sqflite) with a lease-based claim protocol.
* Batching (`flushAt`, interval, size and byte limits), immediate priority.
* Retries with exponential backoff and `Retry-After`; batch bisection on permanent failures; 413 splitting.
* `HttpTransport` with gzip and per-event rejects; pluggable `EventTransport`.
* Retention: max events, max bytes, max age, drop-oldest / drop-newest.
* Persistent consent (granted / denied / unknown with hold or drop) and purge.
* Stats and delivery event streams; `BeeLogger`.
* `package:bee_sync/testing.dart`: `BeeSyncTestHarness`, `FakeTransport`, `InMemoryEventStore`.
