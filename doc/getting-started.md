# Getting started

This guide takes you from an empty project to events arriving on your server. It takes about 10 minutes.

**Contents:** [Requirements](#requirements) · [1. Install](#1-install) · [2. Platform setup](#2-platform-setup) · [3. Initialize](#3-initialize) · [4. Track events](#4-track-events) · [5. Ask for consent](#5-ask-for-consent-optional) · [6. Verify it works](#6-verify-it-works) · [Next steps](#next-steps)

## Requirements

| | Minimum |
|---|---|
| Flutter | 3.38 (Dart 3.10) |
| Android | API 24 (Android 7.0) |
| iOS | 13.0 |
| Server | An HTTPS endpoint that accepts a JSON `POST` (see the [Server guide](server-guide.md)) |

## 1. Install

```bash
flutter pub add bee_sync
```

## 2. Platform setup

### Android

Nothing to do. The plugin declares the `INTERNET` permission and uses WorkManager, which is set up automatically.

### iOS

Add these entries to `ios/Runner/Info.plist`. They let bee_sync upload from background tasks.

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

If any are missing, bee_sync logs a warning at startup. Delivery still works while the app runs and when it goes to the background; only the scheduled background tasks are skipped.

> **Scene-based apps.** Apple requires background tasks to be registered before `application(_:didFinishLaunchingWithOptions:)` returns. The standard Flutter `AppDelegate` registers plugins in time. If yours registers plugins later, add this to `didFinishLaunchingWithOptions`:
>
> ```swift
> import bee_sync
>
> BeeSyncPlugin.registerBackgroundTasks()
> ```

## 3. Initialize

Call `BeeSync.initialize` once, before `runApp`:

```dart
import 'package:bee_sync/bee_sync.dart';
import 'package:flutter/material.dart';

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

`BeeSync.instance` is then available everywhere. The defaults suit most apps:
- batches of up to 100 events, sent when 20 are waiting or every 30 seconds;
- retries for up to 12 attempts;
- the queue keeps at most 10,000 events or 10 MB, for up to 7 days.

All of it is adjustable; see [Configuration](configuration.md).

> **Which key to use?** The background uploader sends whatever headers you last set, even hours later. Use a long-lived, write-only **ingestion key**, not a user session token that expires. If you must use user tokens, call `setHeaders()` whenever the token refreshes.

## 4. Track events

```dart
final bee = BeeSync.instance;

await bee.track('screen_view', properties: {'screen': 'checkout'});

// Important events can skip the batch and go out within ~50 ms:
await bee.track(
  'purchase',
  properties: {'order_id': 'A1', 'total': 42.5},
  priority: Priority.immediate,
);
```

`track()` completes once the event is **on disk**; it doesn't wait for the network. It throws `InvalidEventException` for:
- an empty name;
- properties that can't be encoded as JSON;
- events larger than 32 KB.

## 5. Ask for consent (optional)

If you need permission before tracking, start in `unknown`. Events are stored but not sent until the user decides:

```dart
await BeeSync.initialize(BeeSyncConfig(
  transport: …,
  consent: const ConsentConfig(initial: ConsentState.unknown),
));

// When the user answers:
await BeeSync.instance.setConsent(ConsentState.granted);              // sends held events
await BeeSync.instance.setConsent(ConsentState.denied, purge: true);  // deletes them
```

The choice is saved, so `initial` only applies on the very first launch.

## 6. Verify it works

**In the app.** Open the inspector from a debug menu or button:

```dart
import 'package:bee_sync/inspector.dart';

BeeSyncInspector.show(context);
```

- **Status** shows pending, sent and dropped counts.
- **Activity** shows each request and its result. A row reading `2xx: 3 accepted` means your server received the batch.

**Against a local server.** Run the test server from the bee_sync repository, which logs every batch it receives:

```bash
dart run tool/test_server.dart
```

Then point your app at it:
- Android emulator: `http://10.0.2.2:8080/events`
- iOS Simulator: `http://localhost:8080/events`

Plain HTTP needs cleartext allowed in debug builds; the [example app](../example) shows how.

## Next steps

- [Background delivery](background-delivery.md): what happens when the app is closed, and how to test it.
- [Server guide](server-guide.md): build or adapt the endpoint.
- [Configuration](configuration.md): batching, retries, retention, logging, custom transports.
