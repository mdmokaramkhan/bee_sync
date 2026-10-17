# Benchmarks

`track()` throughput: how fast events can be persisted. The transport is a
`FakeTransport`, so `track()` and the on-device store are measured, not the
network.

| Where | Command |
|---|---|
| Host (SQLite via FFI, WAL, file on disk) | `flutter test benchmark/track_benchmark_test.dart` |
| Device / simulator (real `sqflite` plugin) | `cd example && flutter test integration_test/track_benchmark_test.dart -d <device>` |

Simulators and emulators run in debug mode (JIT). Treat their numbers as indicative; a physical device in profile mode is the reference.

## Scenarios

- **sequential / 2 KB / concurrent burst:** consent is held at `unknown`, so nothing uploads and only `track()` is measured.
- **flushing every 20, 50 ms server:** realistic. Uploads run alongside tracking against a server that answers in 50 ms.
- **flushing every 20, 0 ms server:** a worst case that no real backend matches. The flush never waits on the network, so it competes with `track()` for the database non-stop.

## 0.3.0-dev: `track()` store round trips, 5 → 1 (2026-10-18)

**Before:** a normal-priority `track()` made 5 store round trips: insert; an eviction check, which was a transaction (BEGIN, count, COMMIT); and a count for `flushAt`.

**After:** it makes one store call, `EventStore.insertAndCount`. For sqflite that is two plain statements: an insert, then a count. The eviction transaction runs only when the count is over the retention limits, and the count also answers the `flushAt` check.

An sqflite `Batch` was tried first and measured slower: `Batch.commit()` wraps the batch in its own transaction, which means three platform calls plus a Dart-side lock.

**Host (macOS, Apple silicon, FFI)**

| scenario | before: events/s · p50 | after: events/s · p50 | speed-up |
|---|---:|---:|---:|
| sequential, small (~60 B) | 2,017 · 0.45 ms | 3,562 · 0.24 ms | 1.8× |
| sequential, 2 KB | 2,099 · 0.41 ms | 3,641 · 0.23 ms | 1.7× |
| concurrent burst, small | 2,253 | 4,221 | 1.9× |
| flushing every 20, 0 ms server | 1,676 · 0.38 ms | 1,209 · 0.78 ms | 0.7× |
| flushing every 20, 50 ms server | 2,066 · 0.38 ms | 4,216 · 0.19 ms | 2.0× |

**iOS Simulator (iPhone 17, debug)**

| scenario | before: events/s · p50 | after: events/s · p50 | speed-up |
|---|---:|---:|---:|
| sequential, small (~60 B) | 2,114 · 0.43 ms | 3,820 · 0.22 ms | 1.8× |
| sequential, 2 KB | 1,557 · 0.65 ms | 2,905 · 0.34 ms | 1.9× |
| concurrent burst, small | 2,048 | 4,218 | 2.1× |
| flushing every 20, 0 ms server | 2,017 · 0.35 ms | 1,313 · 0.74 ms | 0.7× |
| flushing every 20, 50 ms server | 2,765 · 0.34 ms | 5,601 · 0.17 ms | 2.0× |

**Android emulator (Pixel 9, debug)**

| scenario | before: events/s · p50 | after: events/s · p50 | speed-up |
|---|---:|---:|---:|
| sequential, small (~60 B) | 613 · 1.35 ms | 1,086 · 0.73 ms | 1.8× |
| sequential, 2 KB | 701 · 1.27 ms | 1,228 · 0.68 ms | 1.8× |
| concurrent burst, small | 722 | 1,188 | 1.6× |
| flushing every 20, 0 ms server | 600 · 1.21 ms | 352 · 2.71 ms | 0.6× |
| flushing every 20, 50 ms server | 788 · 1.13 ms | 1,427 · 0.60 ms | 1.8× |

The worst-case "0 ms server" scenario is slower after the change. Faster inserts give a non-stop flush more chances to interleave with `track()` for the database. With any realistic server latency, as in the 50 ms row, the new path is faster.

An earlier baseline in this file was measured incorrectly. A flush started at startup kept uploading during the supposedly upload-free scenarios, so the numbers mixed `track()` with uploads. The scenarios now hold consent at `unknown`.
