// On-device benchmark: the real sqflite plugin (platform channel to the
// system SQLite), the app's support directory, WAL.
//
//   cd example && flutter test integration_test/track_benchmark_test.dart -d <device>
//
// Simulators and emulators run in debug mode (JIT), so treat their numbers
// as indicative; a physical device in profile mode is the reference.
import 'package:bee_sync/bee_sync.dart';
import 'package:bee_sync/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../../benchmark/scenarios.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('track() throughput (device, sqflite)', (tester) async {
    Future<BeeSync> open({
      required int flushAt,
      required Duration latency,
    }) async {
      final bee = await BeeSync.initialize(
        BeeSyncConfig(
          transport: FakeTransport(latency: latency),
          batching: BatchingPolicy(flushAt: flushAt),
          background: const BackgroundConfig(enabled: false),
          logger: const BeeLogger.silent(),
        ),
        signals: FakePlatformSignals(),
      );
      await bee.purgeQueue(); // start from an empty queue
      return bee;
    }

    final results = await tester.runAsync(() => runTrackBenchmark(open));
    // ignore: avoid_print
    print('\n${formatResults('Device (sqflite)', results!)}\n');
  });
}
