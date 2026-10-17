// Host benchmark: real SQLite (sqflite_common_ffi, WAL, file on disk), run
// in a background isolate like sqflite's platform implementations.
//
//   flutter test benchmark/track_benchmark_test.dart
//
// Not part of `flutter test` (which only runs test/).
import 'dart:io';

import 'package:bee_sync/bee_sync.dart';
import 'package:bee_sync/src/store/sqflite_store.dart';
import 'package:bee_sync/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'scenarios.dart';

void main() {
  sqfliteFfiInit();

  test(
    'track() throughput (host, SQLite via FFI)',
    () async {
      final dir = await Directory.systemTemp.createTemp('bee_sync_bench');
      addTearDown(() => dir.delete(recursive: true));
      var run = 0;

      Future<BeeSync> open({required int flushAt, required Duration latency}) =>
          BeeSync.initialize(
            BeeSyncConfig(
              transport: FakeTransport(latency: latency),
              batching: BatchingPolicy(flushAt: flushAt),
              logger: const BeeLogger.silent(),
            ),
            store: SqfliteEventStore(
              path: p.join(dir.path, 'bench_${run++}.db'),
              factory: databaseFactoryFfi,
            ),
            signals: FakePlatformSignals(),
          );

      final results = await runTrackBenchmark(open);
      // ignore: avoid_print
      print(
        '\n${formatResults('Host (${Platform.operatingSystem}, FFI)', results)}\n',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
