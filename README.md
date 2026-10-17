# bee_sync

Durable, offline-first event delivery for Flutter.

Every event is written to an on-device SQLite queue **before** any network attempt, then delivered in batches (or right away, for high-priority events) with retries, backoff, consent controls and bounded storage. Delivery is **at-least-once**: each event carries a UUIDv7 `id`, and your server should dedupe on it.

> **Status: 0.2.0-dev.** Delivery while the app runs, plus native background delivery on Android (WorkManager) and iOS (background-exit upload and BGTaskScheduler). Encryption at rest comes in v0.3. See [docs/DESIGN.md](docs/DESIGN.md).

## Quick start

```dart
import 'package:bee_sync/bee_sync.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await BeeSync.initialize(BeeSyncConfig(
    transport: HttpTransport(
      endpoint: Uri.parse('https://api.example.com/v1/events'),
      headers: {'Authorization': 'Bearer $token'},
    ),
  ));
  runApp(const MyApp());
}

// Anywhere:
await BeeSync.instance.track('checkout_started', properties: {'cart_value': 42.5});
await BeeSync.instance.track(
  'purchase',
  properties: {'order_id': 'A1'},
  priority: Priority.immediate, // sent right away instead of batched
);
```

`track()` completes once the event is on disk. It throws `InvalidEventException` for an empty name, non-JSON properties, or a payload over `maxEventBytes` (32 KB by default).

## What gets sent

`HttpTransport` POSTs JSON:

```json
{
  "batch_id": "…",
  "sent_at": 1771234567890,
  "events": [
    {"id": "0192…", "name": "purchase", "timestamp": 1771234560000,
     "priority": "immediate", "attempt": 1, "properties": {"order_id": "A1"}}
  ]
}
```

How responses are handled:

| Response | Result |
|---|---|
| 2xx | Delivered. An optional body `{"rejected": ["<id>", …]}` drops just those events. |
| 408, 429, 5xx, network error | Retried with exponential backoff; `Retry-After` is honoured. |
| 401, 403 | Kept without using an attempt; automatic flushing pauses until `setHeaders()` or `flush()`. |
| 413 | Batch is split; a single event that is still too large is dropped. |
| Other 4xx | Batch is bisected to find and drop only the events the server refuses. |

**Server checklist:** dedupe on `id` (keep ids at least as long as `RetentionPolicy.maxAge`), return 2xx for duplicates, and use `sent_at` to correct device clock skew.

## Configuration

```dart
BeeSyncConfig(
  transport: …,
  batching: BatchingPolicy(flushAt: 20, flushInterval: Duration(seconds: 30),
                           maxBatchSize: 100, maxBatchBytes: 512 * 1024),
  retry: RetryPolicy(base: Duration(seconds: 2), max: Duration(minutes: 10),
                     maxAttempts: 12),
  retention: RetentionPolicy(maxEvents: 10000, maxBytes: 10 * 1024 * 1024,
                             maxAge: Duration(days: 7),
                             overflow: OverflowPolicy.dropOldest),
  consent: ConsentConfig(initial: ConsentState.granted,
                         whileUnknown: UnknownConsentBehavior.hold),
  logger: BeeLogger.console(level: LogLevel.info),
)
```

Flushes happen when `flushAt` events are pending, every `flushInterval`, when the app goes to the background, when connectivity returns, after an immediate event, and on `flush()`.

## Consent

```dart
await bee.setConsent(ConsentState.unknown);              // hold: store, don't send
await bee.setConsent(ConsentState.granted);              // send held events
await bee.setConsent(ConsentState.denied, purge: true);  // stop and delete the queue
```

Consent is persisted and survives restarts. The `initial` value is used only on first launch.

## Observability

```dart
bee.stats.listen((s) => print(s));          // pending, inFlight, sent, dropped by reason…
bee.events.listen((e) => switch (e) {
  Delivered(:final ids) => …,
  Dropped(:final ids, :final reason) => …,  // overflow, expired, maxAttempts, …
  FlushFailed(:final reason, :final retryAt) => …,
});
```

## Background delivery

With `HttpTransport`, events queued when the app goes to the background are uploaded by native code even after the app process is gone. No Flutter engine is started for this. It's on by default (`BackgroundConfig(enabled: true)`).

**Android:** nothing to set up. WorkManager runs the upload once there's network, retries when the backoff ends, and checks every 15 minutes while events remain. One caveat: if the user **force-stops** the app, Android cancels all its jobs until the app is opened again.

**iOS:** add this to your app's `Info.plist`. bee_sync logs a warning at startup if any of it is missing.

```xml
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
  <string>dev.beesync.refresh</string>
  <string>dev.beesync.processing</string>
</array>
<key>UIBackgroundModes</key>
<array>
  <string>fetch</string>
  <string>processing</string>
</array>
```

When the app goes to the background, bee_sync uses the extra time iOS grants to upload what's queued. This catches most events. It then schedules `BGAppRefreshTask` and `BGProcessingTask` for anything left. iOS decides when those run (it may be hours), and doesn't run them at all after the user force-quits the app. Anything still queued goes out on the next launch.

If your app registers plugins after `didFinishLaunching` returns (some scene-based setups do), also call this in `application(_:didFinishLaunchingWithOptions:)`:

```swift
BeeSyncPlugin.registerBackgroundTasks()
```

What the background uploader did shows up in `getStats()` counters and in:

```dart
for (final entry in await bee.backgroundLog()) print(entry);
```

Auth tokens: the background uploader uses the headers you last set. If they expire it gets a 401, stops, and waits for the app to call `setHeaders()`.

## Custom transports

Implement `EventTransport` to send anywhere (GraphQL, an analytics SDK, a queue):

```dart
class MyTransport implements EventTransport {
  @override
  Future<TransportResult> send(EventBatch batch) async { … return const Success(); }
}
```

Custom transports run in the foreground only: background delivery is done natively and needs `HttpTransport`.

## Testing your app

```dart
import 'package:bee_sync/testing.dart';

final harness = await BeeSyncTestHarness.start();   // in-memory, no network
await checkout();                                    // calls BeeSync.instance.track
await harness.flushAndCollect();
expect(harness.trackedNames, contains('purchase'));
await harness.close();
```

`FakeTransport` can script responses (`enqueue(const RetryableFailure('503'))`) to test failure handling.

## Development

```bash
flutter test
```

iOS tests (XCTest) run in the example app's `RunnerTests` target. Build once with `flutter build ios --simulator` first:

```bash
cd example/ios && xcodebuild test -workspace Runner.xcworkspace -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17'
```

Android tests (Robolectric) run through the example app's Gradle project:

```bash
cd example/android && ./gradlew :bee_sync:testDebugUnitTest
```

`spec/` holds the SQL, the uploader contract and the shared test cases. The Dart, Android and iOS test suites all check against it.

Try it end to end: run the local server, then point the example app at it (`10.0.2.2` is the host machine as seen from the Android emulator):

```bash
dart run tool/test_server.dart --mode fail
```

```bash
cd example && flutter run --dart-define=BEE_ENDPOINT=http://10.0.2.2:8080/events --dart-define=BEE_DEMO_EVENTS=3
```

Then background the app, kill it with `adb shell am kill dev.beesync.bee_sync_example`, and switch the server to OK with `curl "localhost:8080/mode?set=ok"`. The `android_worker` upload shows up within a minute.
