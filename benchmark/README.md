# Benchmarks

`track()` throughput: how fast events can be persisted. The transport is a
`FakeTransport`, so only `track()` and the on-device store are measured.

| Where | Command |
|---|---|
| Host (SQLite via FFI, WAL, file on disk) | `flutter test benchmark/track_benchmark_test.dart` |
| Device / simulator (real `sqflite` plugin) | `cd example && flutter test integration_test/track_benchmark_test.dart -d <device>` |

Simulators and emulators run in debug mode (JIT). Treat their numbers as indicative; a physical device in profile mode is the reference.

## Baseline: 0.3.0-dev, 2026-10-18

Each normal-priority `track()` currently makes **5 store round trips**: insert; an eviction check, which is a transaction (BEGIN, totals query, COMMIT); and a totals query for the `flushAt` check. On Android every round trip crosses the platform channel.

**Host (macOS, Apple silicon, FFI)**

| scenario | events | total | events/s | p50 ms | p95 ms | p99 ms |
|---|---:|---:|---:|---:|---:|---:|
| sequential, small (~60 B) | 1000 | 485 ms | 2061 | 0.43 | 0.68 | 0.86 |
| sequential, 2 KB | 500 | 214 ms | 2333 | 0.39 | 0.71 | 1.10 |
| concurrent burst, small | 1000 | 444 ms | 2248 | — | — | — |
| sequential, flushing every 20 | 1000 | 497 ms | 2011 | 0.36 | 1.25 | 1.48 |

**iOS Simulator (iPhone 17, debug)**

| scenario | events | total | events/s | p50 ms | p95 ms | p99 ms |
|---|---:|---:|---:|---:|---:|---:|
| sequential, small (~60 B) | 1000 | 466 ms | 2145 | 0.42 | 0.64 | 1.20 |
| sequential, 2 KB | 500 | 307 ms | 1629 | 0.61 | 0.88 | 1.00 |
| concurrent burst, small | 1000 | 429 ms | 2329 | — | — | — |
| sequential, flushing every 20 | 1000 | 554 ms | 1803 | 0.55 | 0.61 | 0.71 |

**Android emulator (Pixel 9, debug)**

| scenario | events | total | events/s | p50 ms | p95 ms | p99 ms |
|---|---:|---:|---:|---:|---:|---:|
| sequential, small (~60 B) | 1000 | 2136 ms | 468 | 1.34 | 4.05 | 17.97 |
| sequential, 2 KB | 500 | 744 ms | 671 | 1.28 | 2.81 | 4.16 |
| concurrent burst, small | 1000 | 1424 ms | 702 | — | — | — |
| sequential, flushing every 20 | 1000 | 1754 ms | 570 | 1.24 | 4.46 | 5.68 |
