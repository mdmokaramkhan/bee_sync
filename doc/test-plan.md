# Test plan

A hands-on checklist to confirm bee_sync works end to end: foreground delivery, failures and retries, consent, persistence, and the background syncs on Android and iOS. Each scenario has steps, the expected result, and how to check it.

The automated suites (Dart, Kotlin, Swift) already cover the logic in detail; see [Automated coverage](#automated-coverage). This plan exercises the real apps, devices and OS schedulers that unit tests can't.

**Contents:** [Setup](#setup) · [How it works](#how-it-works) · [Quick reference](#quick-reference) · [A. Foreground delivery](#a-foreground-delivery) · [B. Failures and retries](#b-failures-and-retries) · [C. Auth](#c-auth) · [D. Consent](#d-consent) · [E. Persistence](#e-persistence) · [F. Android background](#f-android-background) · [G. iOS background](#g-ios-background) · [H. Inspector](#h-inspector) · [Automated coverage](#automated-coverage) · [Results sheet](#results-sheet)

## Setup

**1. Start the test server** from the repository root:

```bash
dart run tool/test_server.dart
```

It logs one line per request: the HTTP status it answered, the mode, which uploader sent it (`dart`, `android_worker`, `ios_bg_exit`, `ios_bgtask`), the event count, how many were stored, duplicates, and the attempt numbers.

| Mode | Server answers |
|---|---|
| `ok` | 200 |
| `fail` | 503 with `Retry-After: 30` |
| `flaky` | 503 and 200, alternating |
| `auth` | 401 |
| `slow` | 200 after 10 s |
| `redirect` | 302 to `/moved` |
| `reject` | 400 for every batch |
| `partial` | 200, rejecting the batch's first event |
| `toolarge` | 413 for batches of more than one event |

Switch modes, read totals, or clear them between scenarios:

```bash
curl "localhost:8080/mode?set=fail"
```

```bash
curl localhost:8080/stats
```

```bash
curl localhost:8080/reset
```

`/stats` reports `unique_events_stored`, `duplicates` and `stored_by_uploader`. It's the quickest way to confirm that every event arrived exactly once.

**2. Run the example app** against it. The endpoint depends on where the app runs:

| Device | `BEE_ENDPOINT` |
|---|---|
| Android emulator | `http://10.0.2.2:8080/events` |
| iOS Simulator | `http://localhost:8080/events` |
| Physical phone, same Wi-Fi as your Mac | `http://<your-mac>.local:8080/events` (find the name with `scutil --get LocalHostName`) |

```bash
cd example && flutter run --dart-define=BEE_ENDPOINT=http://10.0.2.2:8080/events
```

Add `--dart-define=BEE_DEMO_EVENTS=3` to track 3 events at startup without tapping anything; several background scenarios use it.

The committed example sends a batch at **5 events** or every **15 seconds**. Its buttons:
- **Track normal**
- **Track immediate**: sent right away
- **Flush**
- **Tracking consent** switch: turning it off purges the queue
- 🐞 in the top right: opens the inspector

If you changed `example/lib/main.dart` locally, adjust the numbers in the steps.

**3. Start each scenario clean:**
- `curl localhost:8080/reset` on the server;
- uninstall the app, or use the inspector's **Purge queue**, for an empty queue.

## How it works

### Tracking and foreground delivery

```text
track() ─► SQLite (events table) ─► FlushController ─► POST /events ─► 2xx: delete rows
            on disk before            claims a batch      (one batch)    other: see below
            track() returns           (lease 60 s)
```

**When a flush starts:**
- 5 events are pending (`flushAt`);
- every 15 s (`flushInterval`);
- about 50 ms after an immediate event;
- when the app goes to the background;
- when connectivity returns;
- on `flush()`.

**Claiming:** a flush *leases* up to 100 events, so no other uploader takes them, sends them, then deletes them or releases them.

### When a request fails

| Server answer | What bee_sync does |
|---|---|
| 408, 429, 5xx, network error, 3xx | Counts an attempt and waits (exponential backoff, at least `Retry-After`, capped at 24 h). After 12 attempts the event is dropped. |
| 401, 403 | Keeps the events, counts no attempt, and pauses automatic uploads (app *and* background) until `setHeaders()` or a manual `flush()`. |
| 413 | Splits the batch in half and retries; drops an event only if it's too large on its own. |
| Other 4xx | Splits the batch to find the refused events and drops only those. |
| 2xx with `rejected` ids | Drops those ids and keeps the rest as delivered. |

Backoff is shared through the database, so the app and the background uploaders respect the same wait.

### Android background sync

```text
app goes to background with events queued
  └─► Dart flushes, then asks native to schedule WorkManager jobs:
        bee_sync_flush     once, as soon as there is network
        bee_sync_periodic  every 15 min while events remain
        bee_sync_retry     once, when a backoff ends
  └─► each job: Android starts the app process (no UI, no Flutter),
      FlushWorker reads the same SQLite file and uploads
  └─► queue empty: the periodic job is cancelled
```

### iOS background sync

```text
app goes to background
  1. extra time (~30 s, beginBackgroundTask): upload what's queued   ← most events
  2. BGAppRefreshTask  dev.beesync.refresh    (when iOS decides)
  3. BGProcessingTask  dev.beesync.processing (needs network, when iOS decides)
expiration: the request is cancelled, the task completes, leases release the rows
```

**Gates checked by every uploader before each run:**
- consent must be `granted`;
- not auth-blocked;
- not inside a backoff;
- background only: the app must be using `HttpTransport`.

## Quick reference

| Goal | Android (emulator or device) | iOS |
|---|---|---|
| Send app to background | `adb shell input keyevent KEYCODE_HOME` | Simulator: `xcrun simctl launch booted com.apple.Preferences`; device: swipe home |
| Kill the process like the OS does | `adb shell am kill dev.beesync.bee_sync_example` (after backgrounding) | `xcrun simctl terminate booted dev.beesync.beeSyncExample` |
| Force-stop / force-quit | `adb shell am force-stop dev.beesync.bee_sync_example` | Swipe the app away in the app switcher |
| Go offline / online | `adb shell cmd connectivity airplane-mode enable` / `disable` | Control Center (device) |
| See scheduled jobs | `adb shell dumpsys jobscheduler \| grep -A3 bee_sync_example` | – |
| Run a scheduled job now | `adb shell cmd jobscheduler run -f dev.beesync.bee_sync_example <job id>` | lldb (G2) |
| Native logs | `adb logcat -s bee_sync WM-WorkerWrapper` | Xcode console, subsystem `dev.beesync.bee_sync` |
| What background runs did | Inspector → Activity → *Background (native)* | same |

## A. Foreground delivery

### A1 · Events reach the server in a batch
**Where:** both · **Server:** `ok`
1. Tap **Track normal** 5 times.

**Expect:** one request: `200 … from=dart events=5 stored=5 duplicates=0 attempts=1`. Inspector → Status: Pending 0, Sent +5.

### A2 · Immediate events skip the batch
**Where:** both · **Server:** `ok`
1. Tap **Track normal** twice (below the batch size).
2. Tap **Track immediate**.

**Expect:**
- Within about a second, a request with `events=1 names=purchase`.
- The two normal events stay pending until the batch fills or 15 s pass.

### A3 · The interval sends a partial batch
**Where:** both · **Server:** `ok`
1. Tap **Track normal** once and wait.

**Expect:** sent within about 15 s, `events=1`.

### A4 · Flush sends immediately
**Where:** both · **Server:** `ok`
1. Tap **Track normal** twice.
2. Tap **Flush** at once.

**Expect:** one request with both events; the app log shows `Flush: drained, 2 delivered`.

### A5 · Going to the background sends what's pending
**Where:** both · **Server:** `ok`
1. Tap **Track normal** twice.
2. Send the app to the background (see [Quick reference](#quick-reference)).

**Expect:**
- Both events arrive within seconds, from `dart`. On iOS they may come from `ios_bg_exit` instead, since both run and only one gets the events.
- `/stats`: `duplicates: 0`.

## B. Failures and retries

### B1 · Server down, then back
**Where:** both
1. Stop the server (Ctrl+C) and tap **Track immediate**.

   **Expect:** Inspector → Activity: *Request failed … Network error*.
2. Start the server again (`ok`) and wait up to 15 s.

**Expect:** delivered with `attempts=2`, `duplicates=0`.

### B2 · 503 with Retry-After is respected
**Where:** both · **Server:** `fail`
1. Tap **Track immediate**.

   **Expect:**
   - The server logs a `503`.
   - Inspector → Status: *Backing off until* about 30 s ahead.
   - For the next 30 s, no automatic request is made, even at the 15 s interval.
2. `curl "localhost:8080/mode?set=ok"` and wait until after the backoff.

**Expect:** delivered, `attempts=2`.

### B3 · Flaky server
**Where:** both · **Server:** `flaky`
1. Tap **Track normal** 10 times, then wait about a minute.

**Expect:** `/stats` shows `unique_events_stored: 10`, `duplicates: 0`. Some requests in the log show 503.

### B4 · Every batch refused (400)
**Where:** both · **Server:** `reject`
1. Tap **Track normal** 4 times, then **Flush**.

**Expect:**
- bee_sync splits the batch until it reaches single events: 7 requests (4, 2, 1, 1, 2, 1, 1), all 400.
- Inspector → Status: Dropped `rejectedByServer` 4.
- `/stats`: stored 0.

### B5 · Partly refused batch
**Where:** both · **Server:** `partial`
1. Tap **Track normal** 5 times.

**Expect:** one request; `stored=4`. Status: Sent +4, Dropped `rejectedByServer` +1.

### B6 · Batch too large (413)
**Where:** both · **Server:** `toolarge`
1. Tap **Track normal** 5 times.

**Expect:**
- bee_sync splits until it reaches single events: 9 requests (5, 2, 1, 1, 3, 1, 2, 1, 1). Only the single-event ones get 200.
- `/stats`: stored 5, duplicates 0. Nothing is dropped.

### B7 · Redirects are not followed
**Where:** both · **Server:** `redirect`
1. Tap **Track immediate**.

   **Expect:**
   - The server logs `302`.
   - The server **never** logs `unexpected GET /moved`. That line would mean the redirect was followed.
   - The event stays pending: Inspector shows *Request failed … Unexpected HTTP 302*.
2. Switch the server to `ok` and wait (backoff about 1–2 s, then the next interval).

**Expect:** delivered, `attempts=2`.

### B8 · Slow server
**Where:** both · **Server:** `slow`
1. Tap **Track normal** 5 times, then 5 more while the first request is in progress.

**Expect:**
- The first request takes about 10 s; Inspector → Status shows *In flight 5* meanwhile.
- All 10 events arrive, `duplicates: 0`.

### B9 · Connectivity coming back retries at once
**Where:** Android emulator, or any physical phone
1. Turn airplane mode on and tap **Track immediate**. This fails with a network error.
2. Turn airplane mode off.

**Expect:** delivered within a few seconds, without waiting for the 15 s interval. Regaining connectivity resets the backoff.

### B10 · At-least-once: duplicates only after a lost response
**Where:** Android emulator · **Server:** `slow`

This is the one case where a duplicate is *expected*. Your server must deduplicate on `id`.
1. Tap **Track normal** 5 times. While the request is in progress (10 s), background the app and run `adb shell am kill …`.
2. Switch the server to `ok`.

**Expect:**
- The server stored the first request when its 10 s ended, but the app was dead and never saw the 200.
- After the lease expires (60 s), the events are sent again, from the background worker or on next launch.
- `/stats`: `duplicates: 5`. That's correct at-least-once behaviour.

## C. Auth

### C1 · 401 pauses uploads until a manual flush
**Where:** both · **Server:** `auth`
1. Tap **Track immediate**.

   **Expect:** `401`; Inspector → Activity: *auth refused*.
2. Switch the server to `ok` and wait 30 s.

   **Expect:** nothing is sent: uploads stay paused.
3. Tap **Flush**.

**Expect:** delivered. After this, automatic uploads resume.

### C2 · The background worker respects the auth block
**Where:** Android · **Server:** `auth`
1. Tap **Track immediate**, which gets a 401.
2. Background the app, run `am kill`, and switch the server to `ok`.
3. Wait 2 minutes.

**Expect:**
- Nothing is sent.
- On reopening: Inspector → Activity → Background shows `skipped: auth`, if a job ran.
- **Flush** delivers.

## D. Consent

### D1 · Denying stops tracking and wipes the queue
**Where:** both · **Server:** `fail` (so events stay queued)
1. Tap **Track normal** 3 times.
2. Turn **Tracking consent** off.

**Expect:**
- Inspector: Pending 0, Dropped `noConsent` 3.
- New taps are dropped (`noConsent` grows).
- Even with the server switched to `ok`, nothing arrives.

### D2 · Consent survives a restart
**Where:** both
1. Turn consent off, kill the app and reopen it.

   **Expect:** the switch is still off, and **Track** taps are dropped.
2. Turn it on and tap **Track immediate**.

**Expect:** delivered.

## E. Persistence

### E1 · Queued events survive the app being killed
**Where:** both · **Server:** `fail`
1. Tap **Track normal** 3 times.
2. Kill the app: swipe it away on iOS, or `am force-stop` on Android.
3. Reopen. Inspector shows Pending 3.
4. Switch the server to `ok`.

**Expect:** all 3 delivered once (`duplicates: 0`).

### E2 · Android force-stop disables background delivery (OS rule)
**Where:** Android · **Server:** `fail`
1. Tap **Track normal** 3 times and background the app.
2. Run `am force-stop`, then switch the server to `ok`.
3. Wait 5 minutes.

**Expect:**
- Nothing is sent: Android cancels a force-stopped app's jobs.
- `dumpsys jobscheduler` lists no bee_sync jobs.
- Reopen the app: delivered.

## F. Android background

Use the emulator, then repeat F1 and F2 on a real phone if you can. Phone makers' battery savers (Xiaomi, Samsung, OnePlus) can delay jobs.

### F1 · Delivery after the process is killed
**Server:** `fail`
1. Run the app with `BEE_DEMO_EVENTS=3`. Its first upload gets a 503 with `Retry-After: 30`.
2. Background the app and run `am kill`.
3. Switch the server to `ok`.

**Expect:**
- About 30–60 s later (when the backoff ends), `from=android_worker events=3 stored=3`.
- `adb logcat` shows the process starting for the job and `Worker result SUCCESS`.
- Reopen the app: Inspector → Background shows `drained: sent 3`.

### F2 · Waits for network
**Server:** `ok`
1. Turn airplane mode on and run the app with `BEE_DEMO_EVENTS=3`.
2. Background the app and run `am kill`.
3. Turn airplane mode off.

**Expect:** delivered by `android_worker` shortly after the network returns. The job is constrained to need a network.

### F3 · Jobs are scheduled only while needed
**Server:** `fail`
1. Track 2 events and background the app.
2. Check `dumpsys jobscheduler | grep -A3 bee_sync_example`.

   **Expect:** `FlushWorker` jobs are listed: the 15-minute periodic one, plus a one-time or retry job.
3. Switch the server to `ok` and wait until delivered. Run `dumpsys` again.

**Expect:** the periodic job is gone, because it's cancelled once the queue is empty.

### F4 · Survives a reboot
**Server:** `fail`
1. Track 3 events and background the app.
2. Switch the server to `ok`, then run `adb reboot`. **Don't open the app.**

**Expect:**
- After boot, delivered by `android_worker`. WorkManager reschedules its jobs after a reboot.
- This can take up to the periodic interval (15 min).

### F5 · App open and worker running together
**Server:** `ok`
1. With the app in the foreground and events pending, find a bee_sync job id in `dumpsys jobscheduler`.
2. Force it: `adb shell cmd jobscheduler run -f dev.beesync.bee_sync_example <id>`.
3. Track more events.

**Expect:** both uploaders may send, but `/stats` shows `duplicates: 0`. Leases stop them from taking the same events.

### F6 · Doze (optional)
1. Queue events with the server in `fail`, background the app, then switch the server to `ok`.
2. `adb shell dumpsys deviceidle force-idle`

   **Expect:** jobs are deferred.
3. `adb shell dumpsys deviceidle unforce`

**Expect:** jobs run and events arrive.

### F7 · App updated before it is reopened
**Server:** `fail`
1. Queue events, background the app and run `am kill`.
2. Reinstall over it: `adb install -r` of a new build. Don't open it.
3. Switch the server to `ok`.

**Expect:** the worker still delivers. Same schema version, same database file.

## G. iOS background

The Simulator runs the upload on backgrounding (G1) but not BGTaskScheduler. **G2–G6 need a physical iPhone running from Xcode**, connected by cable.

### G1 · Upload on backgrounding
**Where:** Simulator or device · **Server:** `fail`
1. Run with `BEE_DEMO_EVENTS=3`. The first upload gets a 503 with a 30 s backoff.
2. Wait about 35 s, then switch the server to `ok`.
3. Send the app to the background.

**Expect:**
- `from=ios_bg_exit events=3 stored=3` within a second or two.
- Inspector → Background: `ios_bg_exit … drained: sent 3`.

### G2 · BGAppRefreshTask delivers
**Where:** device · **Server:** `fail`
1. Turn **Airplane Mode on** (Wi-Fi off too) and run from Xcode with `BEE_DEMO_EVENTS=5`. Don't tap anything.
2. Swipe home. Both the app's upload and the backgrounding upload fail, and the tasks get scheduled.
3. Turn Airplane Mode off, switch the server to `ok`, and wait about 20 s.
4. In Xcode press **Pause**, run this, then **Continue**:

```
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"dev.beesync.refresh"]
```

**Expect:**
- `from=ios_bgtask events=5 stored=5`, with `attempts` ≥ 2 (the offline attempts were counted).
- If the events arrived from `dart` before step 4, the app delivered them on reconnect instead. Retry without waiting at step 3.

### G3 · BGProcessingTask delivers
**Where:** device. Same as G2, with `@"dev.beesync.processing"`.

**Expect:** `from=ios_bgtask`.

### G4 · Running out of background time is handled
**Where:** device · **Server:** `slow`
1. Queue events as in G2, then simulate the launch (G2 step 4).
2. Within 10 s (while the request is in progress), pause again and run:

```
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateExpirationForTaskWithIdentifier:@"dev.beesync.refresh"]
```

**Expect:**
- No crash.
- The phone cancels its request, and the events stay queued. Usually they're released with a backoff; if iOS suspends the app first, they're freed when the 60 s lease expires.
- A later run, or reopening the app, delivers them.
- The slow server still stores the cancelled batch when its 10 s end, so `/stats` shows those events as **duplicates**, as in B10. That's expected at-least-once behaviour.

### G5 · Force-quit stops background work (OS rule)
**Where:** device · **Server:** `fail`
1. Queue events, then swipe the app away in the app switcher.
2. Switch the server to `ok`.

**Expect:**
- No background delivery.
- Reopen the app: delivered.

### G6 · Works while the phone is locked
**Where:** device
1. Do G2 up to step 3, then lock the phone. It must have been unlocked once since boot.
2. Trigger the task from Xcode.

**Expect:** delivered. The database is readable after first unlock.

### G7 · Missing Info.plist entries are reported
**Where:** Simulator
1. Temporarily remove `processing` from `UIBackgroundModes` in `example/ios/Runner/Info.plist`, then run.

**Expect:** the debug console shows `bee_sync: add "processing" to UIBackgroundModes …`. Restore the entry afterwards.

## H. Inspector

Open it with the 🐞 button.

| # | Check | Expect |
|---|---|---|
| H1 | Status after A1–A4 | Pending, In flight, Sent and Dropped match `/stats` and what you tapped |
| H2 | Queue: tap an event (server in `fail`) | Shows its id, time and properties; failed events show `1 failed attempt(s) · retry in …` |
| H3 | Simulate offline on, then Track immediate | Activity: *Request failed … Simulated offline*; the server receives nothing |
| H4 | Simulate offline off → Reset backoff → Flush now | Delivered |
| H5 | Purge queue | Asks first; Cancel keeps events; Purge drops them (`purged`) |

## Automated coverage

These run in CI on every pull request. Run them locally as in [CONTRIBUTING.md](../CONTRIBUTING.md#running-tests).

| Area | Covered by |
|---|---|
| Batching, intervals, immediate priority, background trigger | `test/core/bee_sync_test.dart` |
| Retries, Retry-After (and its 24 h cap), max attempts, 401/413/4xx handling, splitting, rejected ids, redirects | `spec/fixtures/uploader/*.json`, run by Dart, Kotlin and Swift (20 cases × 3 seeds each) |
| Consent (hold, drop, deny, persistence), retention (count, size, age), invalid events | `test/core/bee_sync_test.dart` |
| SQLite store, leases, migration from schema v1, WAL | `test/store/` |
| Wire format, gzip, HTTP status mapping | `test/transport/`, `NativeUploaderTest.kt`, `RunnerTests.swift` |
| Android worker end to end, job scheduling | `FlushWorkerTest.kt` |
| iOS background runs, registration refusal, redirects, path storage | `RunnerTests.swift` |
| Inspector screens and actions | `test/inspector_test.dart` |
| `close()` during `track()`, store calls per `track()` | `test/core/bee_sync_test.dart` |

**Only this manual plan covers:**
- real OS scheduling: WorkManager after a kill, a reboot or Doze, and iOS BGTasks on a device;
- network changes;
- force-stop and force-quit;
- file protection while the device is locked;
- behaviour on real phones from different manufacturers.

## Results sheet

Copy this table into an issue or PR and fill it in.

| Scenario | Android emulator | Android phone (model) | iOS Simulator | iPhone (model) | Notes |
|---|:---:|:---:|:---:|:---:|---|
| A1–A5 foreground | | | | | |
| B1–B9 failures | | | | | |
| B10 at-least-once | | | – | – | |
| C1 auth | | | | | |
| C2 auth in background | | | – | – | |
| D1–D2 consent | | | | | |
| E1 kill and reopen | | | | | |
| E2 force-stop | | | – | – | |
| F1–F7 Android background | | | – | – | |
| G1 iOS backgrounding upload | – | – | | | |
| G2–G6 iOS BGTasks | – | – | – | | |
| G7 Info.plist warnings | – | – | | | |
| H1–H5 inspector | | | | | |
