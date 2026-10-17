# Configuration

Every option, with its default. All of them are optional except `transport`.

**Contents:** [Overview](#overview) · [Transport](#transport) · [Batching](#batching) · [Retries](#retries) · [Retention](#retention) · [Consent](#consent) · [Priorities](#priorities) · [Background](#background) · [Logging](#logging) · [Monitoring](#monitoring) · [Custom transports](#custom-transports) · [Custom stores](#custom-stores) · [Testing](#testing)

## Overview

```dart
await BeeSync.initialize(BeeSyncConfig(
  transport: HttpTransport(endpoint: Uri.parse('https://api.example.com/events')),
  batching: const BatchingPolicy(),
  retry: const RetryPolicy(),
  retention: const RetentionPolicy(),
  consent: const ConsentConfig(),
  background: const BackgroundConfig(),
  maxEventBytes: 32 * 1024,
  logger: const BeeLogger.console(),
));
```

## Transport

```dart
HttpTransport(
  endpoint: Uri.parse('https://api.example.com/events'),
  headers: {'Authorization': 'Bearer <key>'}, // sent with every request
  gzip: false,                                // compress request bodies
  timeout: const Duration(seconds: 30),
)
```

Change headers at runtime, for example after a token refresh. The new headers are used by background uploads too, and uploads paused by a 401 resume:

```dart
await BeeSync.instance.setHeaders({'Authorization': 'Bearer $newToken'});
```

## Batching

| Option | Default | Meaning |
|---|---|---|
| `flushAt` | `20` | Send when this many events are waiting. |
| `flushInterval` | 30 s | Also send on this interval while the app runs. |
| `maxBatchSize` | `100` | Most events per request. |
| `maxBatchBytes` | 512 KB | Most payload bytes per request (one oversized event is still sent alone). |

Uploads also start when the app goes to the background, when connectivity returns, after an immediate-priority event, and when you call `flush()`.

## Retries

| Option | Default | Meaning |
|---|---|---|
| `base` | 2 s | First retry delay. |
| `max` | 10 min | Longest delay. |
| `maxAttempts` | `12` | After this many failures, an event is dropped (`DropReason.maxAttempts`). |

Delays double on each attempt, with some randomness so many devices don't retry at once. A server `Retry-After` header wins if it's longer.

## Retention

| Option | Default | Meaning |
|---|---|---|
| `maxEvents` | `10000` | Most events kept on the device. |
| `maxBytes` | 10 MB | Most payload bytes kept. |
| `maxAge` | 7 days | Older events are dropped (`DropReason.expired`). |
| `overflow` | `dropOldest` | When full: drop the oldest normal-priority events first (`dropOldest`), or refuse new ones (`dropNewest`). |

## Consent

| State | `track()` | Uploads |
|---|---|---|
| `granted` | stored | on |
| `unknown` (with `whileUnknown: hold`, the default) | stored | paused until granted |
| `unknown` (with `whileUnknown: drop`) | dropped | off |
| `denied` | dropped | off |

```dart
ConsentConfig(initial: ConsentState.unknown) // used on first launch only

await bee.setConsent(ConsentState.granted);             // send held events
await bee.setConsent(ConsentState.denied, purge: true); // stop and delete the queue
```

Consent is saved on the device, and the background uploader respects it.

## Priorities

```dart
await bee.track('purchase', properties: {...}, priority: Priority.immediate);
```

- `Priority.normal` (the default) waits for the next batch.
- `Priority.immediate` is stored, then sent within about 50 ms. Immediate events go first in every batch and are the last to be evicted when the queue is full.

## Background

```dart
const BackgroundConfig(enabled: true) // default
```

Background delivery needs `HttpTransport`. See [Background delivery](background-delivery.md).

## Logging

```dart
logger: const BeeLogger.console(level: LogLevel.debug), // trace | debug | info | warn | error | off
logger: const BeeLogger.silent(),
```

Event properties are only logged at `trace`. Implement `BeeLogger` to forward logs to your own logging system.

## Monitoring

```dart
final stats = await bee.getStats(); // pending, inFlight, sent, dropped by reason, backoffUntil, …

bee.stats.listen((s) => …);         // updates whenever the queue changes

bee.events.listen((e) => switch (e) {
  Delivered(:final ids) => …,
  Dropped(:final ids, :final reason) => …, // overflow, expired, maxAttempts, rejectedByServer, …
  FlushFailed(:final reason, :final retryAt) => …,
});

final log = await bee.backgroundLog();   // what the native uploader did
```

Other controls:
- `flush()`: send now.
- `resetBackoff()`: retry now after an outage.
- `purgeQueue()`: delete everything queued.

The [inspector](../README.md#debugging) shows all of this on screen.

## Custom transports

Send events anywhere (an analytics SDK, GraphQL, a message queue) by implementing `EventTransport`:

```dart
class MyTransport implements EventTransport {
  @override
  Future<TransportResult> send(EventBatch batch) async {
    try {
      await myClient.upload(batch.events);
      return const Success();
    } on TimeoutException {
      return const RetryableFailure('timeout');
    }
  }
}
```

The result tells bee_sync what to do next:
- `Success`: delivered (optionally with `rejectedIds`).
- `RetryableFailure`: retry with backoff (optionally with `retryAfter`).
- `AuthFailure`: pause until new credentials.
- `PayloadTooLarge`: split the batch.
- `PermanentFailure`: drop the events the server refuses.

Custom transports run only while the app runs; there is no background delivery for them.

## Custom stores

The default store is SQLite, through sqflite, in the app's support directory. To use another, implement `EventStore` and pass it to `BeeSync.initialize(config, store: …)`.

The contract is defined in [`spec/uploader_contract.md`](../spec/uploader_contract.md), and the contract tests in `test/store/store_contract.dart` show the expected behaviour. A store without a `databasePath` gets no background delivery.

## Testing

`package:bee_sync/testing.dart` runs a real `BeeSync` in memory, with no network or platform channels:

```dart
final harness = await BeeSyncTestHarness.start(
  transport: FakeTransport(latency: const Duration(milliseconds: 50)),
);
harness.transport.enqueue(const RetryableFailure('HTTP 503')); // script a failure

await myFeature.checkout();
await harness.flushAndCollect();
expect(harness.trackedNames, ['purchase']);

await harness.close();
```

Other helpers:
- `FakePlatformSignals`: simulate app backgrounding or connectivity changes.
- `FakeBackgroundScheduler`: check background scheduling.
- `InMemoryEventStore`: a store with no database.
