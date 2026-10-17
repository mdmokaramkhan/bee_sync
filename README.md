# bee_sync

Durable, offline-first event delivery for Flutter.

Every event is written to an on-device SQLite queue **before** any network attempt, then delivered in batches (or right away, for high-priority events) with retries, backoff, consent controls and bounded storage. Delivery is **at-least-once**: each event carries a UUIDv7 `id`, and your server should dedupe on it.

> **Status: v0.1 (Dart core).** Delivery runs while the app is running. Native background delivery (Android WorkManager, iOS background tasks) lands in v0.2; encryption at rest in v0.3. See [docs/DESIGN.md](docs/DESIGN.md).

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

## Custom transports

Implement `EventTransport` to send anywhere (GraphQL, an analytics SDK, a queue):

```dart
class MyTransport implements EventTransport {
  @override
  Future<TransportResult> send(EventBatch batch) async { … return const Success(); }
}
```

Custom transports run in the foreground only. Background delivery (v0.2) will require `HttpTransport`.

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

`spec/` holds the SQL shared with the upcoming native uploaders; `test/store/spec_conformance_test.dart` fails if the Dart copy drifts from it.
