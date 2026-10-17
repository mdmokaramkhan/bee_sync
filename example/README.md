# bee_sync example

A small app that tracks events with [bee_sync](../README.md) and lets you watch them with the built-in inspector.

- **Track normal** / **Track immediate**: queue an event (immediate ones are sent right away).
- **Flush**: send everything now.
- **Tracking consent**: grant or deny (denying deletes the queue).
- 🐞 (top right): opens `BeeSyncInspector`.

## Run it

By default events go to `https://httpbin.org/post`, which echoes each request so you can inspect the format:

```bash
flutter run
```

## Run it against a local server

Start the test server from the repository root. It logs every batch, and `--mode fail` makes it answer 503 so you can watch retries:

```bash
dart run tool/test_server.dart --mode fail
```

Then run the app against it, tracking 3 events at startup:

```bash
flutter run --dart-define=BEE_ENDPOINT=http://10.0.2.2:8080/events --dart-define=BEE_DEMO_EVENTS=3
```

`10.0.2.2` is your computer as seen from the Android emulator; use `localhost` on the iOS Simulator. Switch the server back to success while it runs:

```bash
curl "localhost:8080/mode?set=ok"
```

The [Background delivery guide](../doc/background-delivery.md#testing) shows how to test uploads after the app is closed.
