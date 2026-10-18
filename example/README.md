# bee_sync example

A small shop app that tracks what a real app would, through [bee_sync](../README.md), with a tab for testing delivery.

| Tab | What it does |
|---|---|
| **Shop** | A product list. Each card tracks `widget_viewed` as it scrolls into view; opening a product tracks `product_tapped` and a `screen_view`. |
| **Cart** | Products you added. **Checkout** tracks `purchase` as an immediate event, sent right away. |
| **Delivery** | Queue status (pending, sent, dropped, next retry), buttons to track test events, **Flush now**, **Reset backoff**, **Simulate offline**, the consent switch, and a log of everything tracked and delivered. |

The chip in the top bar shows how many events are queued; 🐞 opens `BeeSyncInspector`.

## Events

Every event carries `session_id` and `seq` (1, 2, 3, … within a session), so your server can check that no event of a session is missing.

| Event | When |
|---|---|
| `session_start` | Cold start, or returning after 30 minutes in the background |
| `app_background` / `app_foreground` | The app is hidden / shown again, with the time spent in the other state |
| `screen_view` | A tab is selected or a screen is pushed or popped, with the previous screen and the time spent on it |
| `widget_viewed` | The promo banner or a product card scrolls into view (once per visit to the screen) |
| `promo_tapped`, `product_tapped`, `add_to_cart` | The matching tap |
| `purchase` | **Buy now** or **Checkout** (immediate) |
| `test_event` | The Delivery tab's buttons |

See `lib/analytics.dart` for how sessions, screens and widget views are tracked.

## Run it

By default events go to `https://httpbin.org/post`, which echoes each request so you can inspect the format:

```bash
flutter run
```

## Run it against your own server

Settings come from dart-defines, so you never need to edit the code. Copy the template and set your endpoint:

```bash
cp bee.local.json.example bee.local.json
```

`bee.local.json` is gitignored. Then run with it:

```bash
flutter run --dart-define-from-file=bee.local.json
```

| Key | Default | Meaning |
|---|---|---|
| `BEE_ENDPOINT` | `https://httpbin.org/post` | Where events are posted |
| `BEE_FLUSH_AT` | `5` | Send once this many events are pending |
| `BEE_FLUSH_INTERVAL` | `15` | Send pending events this often (seconds) |
| `BEE_MAX_ATTEMPTS` | `12` | Drop an event after this many failed responses. Network failures don't count. |
| `BEE_AUTO_EVENTS` | `true` | Track sessions, screens and widget views. Set `false` when a test counts events exactly. |
| `BEE_DEMO_EVENTS` | `0` | Track this many events at startup |

## Run it against the local test server

Start the test server from the repository root. It logs every batch, and `--mode fail` makes it answer 503 so you can watch retries:

```bash
dart run tool/test_server.dart --mode fail
```

Then point the app at it. `10.0.2.2` is your computer as seen from the Android emulator; use `localhost` on the iOS Simulator:

```bash
flutter run --dart-define=BEE_ENDPOINT=http://10.0.2.2:8080/events
```

Switch the server back to success while it runs:

```bash
curl "localhost:8080/mode?set=ok"
```

The [test plan](../doc/test-plan.md) has step-by-step scenarios, including offline and background delivery.
