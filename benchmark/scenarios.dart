// track() throughput scenarios, shared by the host benchmark
// (benchmark/track_benchmark_test.dart) and the on-device one
// (example/integration_test/track_benchmark_test.dart).
//
// The transport is a FakeTransport, so only track() and the store are
// measured, not the network.
import 'package:bee_sync/bee_sync.dart';

/// Opens a fresh, empty BeeSync whose batches flush at [flushAt] events.
typedef OpenBeeSync = Future<BeeSync> Function({required int flushAt});

class BenchResult {
  BenchResult(this.name, this.events, this.total, List<int> latenciesUs)
    : _sorted = [...latenciesUs]..sort();

  final String name;
  final int events;
  final Duration total;
  final List<int> _sorted;

  double get perSecond => events / (total.inMicroseconds / 1e6);

  /// Per-call latency percentile in milliseconds (empty for concurrent runs).
  String percentile(double p) {
    if (_sorted.isEmpty) return '—';
    final i = ((_sorted.length - 1) * p).round();
    return (_sorted[i] / 1000).toStringAsFixed(2);
  }

  static const header =
      '| scenario | events | total | events/s | p50 ms | p95 ms | p99 ms |\n'
      '|---|---:|---:|---:|---:|---:|---:|';

  String get row =>
      '| $name | $events | ${total.inMilliseconds} ms | '
      '${perSecond.toStringAsFixed(0)} | ${percentile(.5)} | '
      '${percentile(.95)} | ${percentile(.99)} |';
}

const _small = {'screen': 'checkout', 'cart_value': 42.5, 'items': 3};
final _large = {'blob': 'x' * 2000, 'n': 1};

Future<BenchResult> _sequential(
  BeeSync bee,
  String name,
  int n,
  Map<String, Object?> properties,
) async {
  final latencies = <int>[];
  final total = Stopwatch()..start();
  for (var i = 0; i < n; i++) {
    final call = Stopwatch()..start();
    await bee.track('bench', properties: properties);
    latencies.add(call.elapsedMicroseconds);
  }
  total.stop();
  return BenchResult(name, n, total.elapsed, latencies);
}

Future<BenchResult> _concurrent(BeeSync bee, String name, int n) async {
  final total = Stopwatch()..start();
  await Future.wait([
    for (var i = 0; i < n; i++) bee.track('bench', properties: _small),
  ]);
  total.stop();
  return BenchResult(name, n, total.elapsed, const []);
}

/// Runs every scenario with a fresh BeeSync each, returning the results.
Future<List<BenchResult>> runTrackBenchmark(
  OpenBeeSync open, {
  int n = 1000,
}) async {
  Future<BenchResult> scenario(
    int flushAt,
    Future<BenchResult> Function(BeeSync bee) body,
  ) async {
    final bee = await open(flushAt: flushAt);
    try {
      return await body(bee);
    } finally {
      await bee.purgeQueue();
      await bee.close();
    }
  }

  const noFlush = 1 << 30; // nothing is sent while measuring
  return [
    await scenario(
      noFlush,
      (b) => _sequential(b, 'sequential, small (~60 B)', n, _small),
    ),
    await scenario(
      noFlush,
      (b) => _sequential(b, 'sequential, 2 KB', n ~/ 2, _large),
    ),
    await scenario(
      noFlush,
      (b) => _concurrent(b, 'concurrent burst, small', n),
    ),
    await scenario(
      20,
      (b) => _sequential(b, 'sequential, flushing every 20', n, _small),
    ),
  ];
}

String formatResults(String title, List<BenchResult> results) => [
  '### $title',
  '',
  BenchResult.header,
  for (final r in results) r.row,
].join('\n');
