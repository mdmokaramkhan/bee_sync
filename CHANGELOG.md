## 0.3.1 — 2026-10-18

A patch release fixing issues found in a full code review: an iOS App Store privacy requirement, data loss on HTTP redirects, and a possible crash on iOS. It also adds CI.

### Fixed
* **iOS: the privacy manifest now ships.** `PrivacyInfo.xcprivacy` was never bundled, and it didn't declare the `UserDefaults` usage. Apps could get App Store privacy warnings. It is now bundled and declares `UserDefaults` with reason `CA92.1`.
* **HTTP redirects are no longer followed (iOS and Dart).** A redirected `POST` could be re-sent as a `GET` without a body. If that returned 2xx, events were marked delivered although the server never received them; if it returned 405, they were dropped. A 3xx is now retried, as on Android. *(Android was already correct.)*
* **iOS: late background-task registration no longer crashes.** Apps that register plugins after launch (add-to-app, some scene-based setups) crashed in `BGTaskScheduler`. The refusal is now caught and reported as a startup warning, and only registered tasks are scheduled.
* **A huge `Retry-After` header could crash the iOS app** (integer overflow). On all platforms, `Retry-After` is now capped at 24 hours and parsed without overflow.
* **iOS: background runs stop promptly when time runs out.** The request in progress is cancelled, the BGTask is completed exactly once, and splitting a refused batch checks between halves whether to continue. Android and Dart split the same way now.
* **iOS: failed background runs** are logged to the background log and rescheduled, instead of silently ending the background chain.
* **iOS: the database path is stored relative to the app's home directory**, so background delivery keeps working after an app update moves the container.
* **iOS: gzip falls back to an uncompressed body** if compression fails, instead of sending an empty body.
* **`close()` waits for `track()` calls already in progress**, instead of closing the database under them.

### Changed
* SDK constraints: `sdk: ^3.10.0` (was `^3.10.9`) and `flutter: '>=3.38.0'` (was `'>=3.3.0'`, which was meaningless with the Dart constraint).
* `connectivity_plus` now accepts `>=6.0.0 <8.0.0` (was `^7.3.2`). connectivity_plus 7.3 uses iOS 26 SDK APIs, so apps building with an older Xcode couldn't compile; they can now resolve a 6.x release. Tested against 6.0.4.
* `spec/uploader_contract.md`: never follow redirects, cap `Retry-After` at 24 hours, and check "should continue" while splitting. There are two new shared test cases.

### Added
* CI (`.github/workflows/ci.yml`): Dart format, analysis, tests and publish dry run; Android tests; iOS tests, using the newest stable Xcode on the runner.

### Docs
* `doc/DESIGN.md` refreshed from the code (API, transport results, observability, testing, layout, risks).
* Contributor test commands fixed for a fresh clone; `leaseDuration` documented.

## 0.3.0 — 2026-10-18

**Debugging tools and a faster `track()`.** A built-in inspector screen shows the queue, recent requests and the native background log. `track()` makes one store call instead of five, which makes it about 2× faster. First release intended for pub.dev.

### Upgrading from 0.2.0
* **`DropReason` has a new value, `purged`.** An exhaustive `switch` on `DropReason` needs a case for it.
* **Custom `EventStore` implementations** must add `inspect({now, limit})` and `insertAndCount(event, now:)`.
* No schema change: 0.2.0 databases are used as they are.

### Added
* **`BeeSyncInspector`**, a debug screen (`import 'package:bee_sync/inspector.dart'`, opened with `BeeSyncInspector.show(context)`):
  * **Status:** queue, delivery and settings.
  * **Queue:** stored events. Properties are shown only when you tap an event.
  * **Activity:** this app's last 50 requests and drops, plus the native background log.

  Actions: flush now, simulate offline, reset backoff, and purge (asks first). Keep it out of release builds.
* `BeeSync.purgeQueue()`: deletes every queued event. The events are reported as `Dropped` with `DropReason.purged`.
* `BeeSync.resetBackoff()`: clears the global backoff and makes deferred events ready again. Doesn't flush.
* Diagnostics used by the inspector:
  * `BeeSync.debugQueue({limit})`, which returns `QueuedEvent`s;
  * `BeeSync.debugActivity`, which returns `RequestActivity` and `DropActivity` entries;
  * `BeeSync.debugSimulateOffline`, which makes this app's uploads fail like a network error. The native background uploader isn't affected.
* `EventStore.inspect({now, limit})`: lists stored events without claiming them.
* `FakeTransport(latency: …)` simulates server response time.
* `track()` throughput benchmark on host and on device (`benchmark/`), with old and new numbers.
* Example app: an Inspector button in the app bar.

### Changed
* **`track()` is about 2× faster** (1.7–2.0× in the benchmarks on host, iOS Simulator and Android emulator). It now makes one store call, `EventStore.insertAndCount` (an insert plus a count for sqflite), instead of five. The eviction transaction only runs when the queue is over its limits. See `benchmark/README.md`.

### Fixed
* `BeeSyncTestHarness.close()` no longer hangs inside `testWidgets` or `fakeAsync`.

### Known limitations
* iOS BGTask delivery has still not been verified on a physical device (the upload when the app is backgrounded is verified on the Simulator).
* Encryption at rest is planned after 1.0.

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
