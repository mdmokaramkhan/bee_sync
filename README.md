# bee_sync

**Never lose an analytics event.** Durable, offline-first event delivery for Flutter, with native background upload on Android and iOS.

[![pub package](https://img.shields.io/pub/v/bee_sync.svg)](https://pub.dev/packages/bee_sync)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platforms](https://img.shields.io/badge/platforms-Android%20%7C%20iOS-lightgrey.svg)

Every event is saved to an on-device queue **before** anything touches the network. bee_sync then delivers it in batches, retries on failure, and keeps sending from native background tasks after your app is closed. Offline, crashed, or killed by the OS: the event still arrives.

## Features

- 💾 **Durable:** events persist in SQLite first and survive crashes, restarts and long offline periods.
- 📦 **Batched:** sent in batches, by size, time or app backgrounding; urgent events can go out right away.
- 🔁 **Resilient:** exponential backoff, `Retry-After`, and smart handling of 401, 413 and 4xx responses.
- 🌙 **Background upload:** native WorkManager (Android) and BGTaskScheduler (iOS). No Flutter engine needed.
- 🔒 **Consent-aware:** grant, deny or hold; denying can wipe the queue. The choice is saved across restarts.
- 📏 **Bounded:** limits on event count, size and age, so the queue never grows forever.
- 🔍 **Inspector:** a built-in debug screen to watch the queue, requests and background runs live.
- 🧪 **Testable:** an in-memory test harness and fake transport for your app's tests.

## Quick start

**1. Install**

```bash
flutter pub add bee_sync
```

**2. Initialize** once, before `runApp`:

```dart
import 'package:bee_sync/bee_sync.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await BeeSync.initialize(BeeSyncConfig(
    transport: HttpTransport(
      endpoint: Uri.parse('https://api.example.com/events'),
      headers: {'Authorization': 'Bearer <your-ingestion-key>'},
    ),
  ));
  runApp(const MyApp());
}
```

**3. Track** from anywhere:

```dart
await BeeSync.instance.track('signup_completed', properties: {'plan': 'pro'});

// Sent right away instead of waiting for the next batch:
await BeeSync.instance.track('purchase', properties: {'order_id': 'A1'}, priority: Priority.immediate);
```

That's all for Android. On **iOS**, add the background-task entries to `Info.plist`. bee_sync logs a warning at startup if they're missing.

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

➡️ **Full walkthrough:** [Getting started](doc/getting-started.md)

## How it works

```text
 track()  ──►  SQLite queue  ──►  batch upload  ──►  your server
  (app)        (on device)        (with retries)      (dedupes by id)
                    │                    ▲
                    └── app in background or closed?
                        Android WorkManager / iOS background tasks
                        upload natively, no Flutter engine
```

- **At-least-once delivery.** An event may arrive twice, but never zero times. Each event has a unique UUIDv7 `id`, so your server can drop duplicates.
- **One queue, many uploaders.** The app and the native background code share the same database and never send the same event at the same time.

## Your server

bee_sync `POST`s JSON batches to your endpoint:

```json
{
  "batch_id": "6f1c1a52-…",
  "sent_at": 1771234567890,
  "events": [
    { "id": "0199a3c0-…", "name": "purchase", "timestamp": 1771234560000,
      "priority": "immediate", "attempt": 1, "properties": { "order_id": "A1" } }
  ]
}
```

Reply **2xx** when stored, and **skip ids you've already seen**. Anything else is retried or handled automatically. See the [Server guide](doc/server-guide.md) for response codes and a minimal example server.

## Common tasks

```dart
final bee = BeeSync.instance;

// Consent: hold events until the user decides, then grant or deny.
await bee.setConsent(ConsentState.granted);
await bee.setConsent(ConsentState.denied, purge: true); // stop and delete the queue

// Rotate an auth token (also resumes uploads paused by a 401).
await bee.setHeaders({'Authorization': 'Bearer $newToken'});

// Send everything now, e.g. before logout.
await bee.flush();

// Watch what's happening.
bee.stats.listen((s) => print('pending: ${s.pending}, sent: ${s.sent}'));
```

All options (batching, retries, retention, consent, logging, custom transports) are in [Configuration](doc/configuration.md).

## Debugging

Open the built-in inspector to see the queue, every request and the native background runs, and to flush, simulate an outage or purge:

```dart
import 'package:bee_sync/inspector.dart';

if (kDebugMode) BeeSyncInspector.show(context);
```

Event properties can contain personal data, so keep the inspector out of release builds.

## Testing your app

```dart
import 'package:bee_sync/testing.dart';

final harness = await BeeSyncTestHarness.start(); // in-memory, no network
await checkout();                                  // your code calls BeeSync.instance.track
await harness.flushAndCollect();
expect(harness.trackedNames, contains('purchase'));
await harness.close();
```

## Platform support

| | Android | iOS | Web / desktop |
|---|:---:|:---:|:---:|
| Delivery while the app runs | ✅ API 24+ | ✅ iOS 13+ | ❌ |
| Background delivery | ✅ WorkManager | ✅ BGTaskScheduler | ❌ |

Background delivery requires `HttpTransport`. Custom transports deliver only while the app is running.

## Good to know

- **Force-quit stops background work.** After Android *Force stop* or an iOS swipe-away, the OS runs no background jobs until the app is opened again. Events wait and go out then.
- **iOS decides when background tasks run.** It may take minutes or hours. Most events still go out on the upload bee_sync makes when the app is backgrounded.
- **Data is stored unencrypted** in the app's private storage, so don't put secrets in event properties. Encryption at rest is planned after 1.0.

## Documentation

| Guide | What's inside |
|---|---|
| [Getting started](doc/getting-started.md) | Install, platform setup, first event, verifying it works |
| [Background delivery](doc/background-delivery.md) | How the native upload works, its limits, testing and troubleshooting |
| [Server guide](doc/server-guide.md) | Request format, responses, deduplication, example server |
| [Configuration](doc/configuration.md) | Every option, consent, priorities, custom transports and stores |
| [Test plan](doc/test-plan.md) | Hands-on scenarios for foreground, failures, consent and background sync |
| [Design](doc/DESIGN.md) | Architecture and design decisions |
| [Changelog](CHANGELOG.md) | Release history |

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, tests and conventions.

## License

MIT. See [LICENSE](LICENSE).
