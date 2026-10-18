# Background delivery

When your app goes to the background or is closed, bee_sync keeps uploading queued events from **native code** (Kotlin on Android, Swift on iOS). No Flutter engine is started. The native uploader reads the same SQLite queue and follows the same rules as the Dart side.

**Contents:** [Requirements](#requirements) · [Android](#android) · [iOS](#ios) · [What can stop it](#what-can-stop-it) · [Seeing what happened](#seeing-what-happened) · [Testing](#testing) · [Troubleshooting](#troubleshooting)

## Requirements

- `HttpTransport`. Custom transports are Dart code, which can't run without the app, so background delivery is off for them.
- `BackgroundConfig(enabled: true)`, which is the default.
- iOS only: the `Info.plist` entries from [Getting started](getting-started.md#ios).

## Android

bee_sync schedules three WorkManager jobs, each needing a network connection:

| Job | When it runs |
|---|---|
| `bee_sync_flush` | Once, as soon as there's network, after the app goes to the background with events queued |
| `bee_sync_retry` | Once, when a server backoff ends (honours `Retry-After`) |
| `bee_sync_periodic` | Every 15 minutes (the Android minimum) while events remain; cancelled once the queue is empty |

If the app process is gone, Android starts it just for the job, without the UI or Flutter. Verified on an emulator: events queued during a server outage were delivered about 45 s after the process was killed, and 7 s after the network returned when they were queued offline.

If the app is killed while an upload is in flight, the events stay leased for 60 s (`leaseDuration`). The worker schedules its next run for when that lease expires. The server may then receive those events twice, which is the at-least-once trade-off.

**Android 14+ timing:** Android can defer background jobs until the device is charging or idle, so a retry may take minutes. Deferred jobs run at the latest when the app's process next starts.

## iOS

Three layers, most reliable first:

1. **Upload when backgrounded.** As the app moves to the background, bee_sync asks iOS for extra time (`beginBackgroundTask`, about 30 s) and uploads what's queued. This catches most events.
2. **`BGAppRefreshTask`** (`dev.beesync.refresh`): scheduled for when the backoff ends, or in 15 minutes.
3. **`BGProcessingTask`** (`dev.beesync.processing`): needs network; for larger backlogs.

iOS alone decides when layers 2 and 3 run, based on battery, usage patterns and Low Power Mode. It can take minutes or hours.

## What can stop it

| Situation | What happens |
|---|---|
| User **force-stops** (Android) or **swipes the app away** (iOS) | The OS cancels all background work until the app is opened again. Events stay queued and go out on the next launch. |
| Consent is `denied` or `unknown` | Nothing is sent, in the background or foreground. |
| Server returns **401/403** | Background uploads pause until the app calls `setHeaders()`, or a manual `flush()` succeeds. |
| Server returns 5xx or 429 | Uploads back off (`Retry-After` is honoured) and resume automatically. |
| App was updated but not yet opened | Native code waits for the app to migrate the database on next launch. |

## Seeing what happened

Native runs write a short line to a background log, which you can read from Dart:

```dart
for (final entry in await BeeSync.instance.backgroundLog()) {
  print(entry); // 2026-10-18T09:12:03Z [android_worker/info] drained: sent 12, dropped 0
}
```

The inspector's **Activity** tab shows the same log. `getStats()` counters (`sent`, `dropped`) include background deliveries.

## Testing

**Android emulator.** Start the local test server (`dart run tool/test_server.dart --mode fail`) and open the app so events queue up. Then:

```bash
adb shell input keyevent KEYCODE_HOME
```

```bash
adb shell am kill <your.package.name>
```

```bash
curl "localhost:8080/mode?set=ok"
```

The worker uploads within a minute. The server logs `sdk="bee_sync/… (android; android_worker)"`.

Use `am kill`, not `am force-stop`: force-stop cancels all jobs by design.

**iOS Simulator.** The upload on backgrounding works. Queue events, switch the server to `ok`, then open another app; the server logs `ios_bg_exit`. BGTaskScheduler doesn't run on the Simulator.

**iOS device (BGTasks).**
1. Run from Xcode, queue some events, then send the app to the background.
2. Press **Pause** in Xcode and run this at the `(lldb)` prompt, then press **Continue**:

   ```
   e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"dev.beesync.refresh"]
   ```

3. The server logs `ios_bgtask`.

## Troubleshooting

| Symptom | Check |
|---|---|
| `backgroundEnabled` is false | Are you using a custom transport or a custom store? Is `BackgroundConfig.enabled` false? |
| iOS warns about `Info.plist` | Add the missing identifiers or background modes it names. |
| iOS warns a task "was not registered" | Your app registers plugins after launch; call `BeeSyncPlugin.registerBackgroundTasks()` in `didFinishLaunchingWithOptions`. |
| *No task request … has been scheduled* (lldb) | Nothing was queued when the app went to the background, or the `Info.plist` entries are missing. |
| Events pile up, background log says `skipped: auth` | Your token expired; call `setHeaders()` with a fresh one, or switch to an ingestion key. |
| Background log says `skipped: backoff` | The server asked to wait (`Retry-After`); uploads resume after it. |

Want the details? [`spec/uploader_contract.md`](../spec/uploader_contract.md) defines the exact algorithm all three uploaders (Dart, Kotlin, Swift) follow.
