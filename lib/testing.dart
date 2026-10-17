/// Test doubles for apps that use bee_sync.
///
/// ```dart
/// final harness = await BeeSyncTestHarness.start();
/// await myFeature.checkout(); // calls BeeSync.instance.track(...)
/// expect(harness.trackedNames, contains('purchase'));
/// await harness.close();
/// ```
library;

import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'bee_sync.dart';
import 'src/store/memory_store.dart';

export 'src/platform/background.dart';
export 'src/store/event_store.dart';
export 'src/store/memory_store.dart' show InMemoryEventStore;

/// [EventTransport] that records batches and replies from a script.
class FakeTransport implements EventTransport {
  FakeTransport({TransportResult defaultResult = const Success()})
    : _default = defaultResult;

  final TransportResult _default;
  final Queue<TransportResult Function(EventBatch)> _script = Queue();

  /// Every batch passed to [send], in order.
  final List<EventBatch> batches = [];

  /// Every event sent, in order (retries appear again).
  List<BatchEvent> get sentEvents => [for (final b in batches) ...b.events];

  /// Replies to the next send with [result].
  void enqueue(TransportResult result) => _script.add((_) => result);

  /// Replies to the next send with whatever [respond] returns.
  void enqueueWith(TransportResult Function(EventBatch batch) respond) =>
      _script.add(respond);

  /// Replies to every send not covered by the script with [result].
  TransportResult Function(EventBatch)? fallback;

  @override
  Future<TransportResult> send(EventBatch batch) async {
    batches.add(batch);
    if (_script.isNotEmpty) return _script.removeFirst()(batch);
    return fallback?.call(batch) ?? _default;
  }
}

/// [BackgroundScheduler] that records calls instead of talking to native code.
class FakeBackgroundScheduler implements BackgroundScheduler {
  FakeBackgroundScheduler({
    this.warnings = const [],
    this.failConfigure = false,
  });

  final List<String> warnings;

  /// Simulates a platform without the native plugin.
  final bool failConfigure;

  String? databasePath;
  bool? enabled;
  int scheduled = 0;
  int cancelled = 0;

  @override
  Future<List<String>> configure({
    required String databasePath,
    required bool enabled,
  }) async {
    if (failConfigure) throw StateError('No native plugin');
    this.databasePath = databasePath;
    this.enabled = enabled;
    return warnings;
  }

  @override
  Future<void> schedule() async => scheduled++;

  @override
  Future<void> cancel() async => cancelled++;
}

/// [PlatformSignals] driven by the test.
class FakePlatformSignals implements PlatformSignals {
  final _backgrounded = StreamController<void>.broadcast(sync: true);
  final _restored = StreamController<void>.broadcast(sync: true);

  void background() => _backgrounded.add(null);

  void restoreConnectivity() => _restored.add(null);

  @override
  Stream<void> get appBackgrounded => _backgrounded.stream;

  @override
  Stream<void> get connectivityRestored => _restored.stream;

  @override
  void dispose() {
    _backgrounded.close();
    _restored.close();
  }
}

/// Runs a real [BeeSync] (as `BeeSync.instance`) on an in-memory store and a
/// [FakeTransport], with no platform channels or network.
class BeeSyncTestHarness {
  BeeSyncTestHarness._(this.bee, this.transport, this.signals, this.store) {
    _sub = bee.events.listen(deliveryEvents.add);
  }

  /// Initializes `BeeSync.instance`. Adjust behaviour through [config]; its
  /// transport is ignored in favour of [transport].
  static Future<BeeSyncTestHarness> start({
    BeeSyncConfig? config,
    FakeTransport? transport,
  }) async {
    final fake = transport ?? FakeTransport();
    final signals = FakePlatformSignals();
    final store = InMemoryEventStore();
    final base = config ?? BeeSyncConfig(transport: fake);
    final bee = await BeeSync.initialize(
      BeeSyncConfig(
        transport: fake,
        batching: base.batching,
        retry: base.retry,
        retention: base.retention,
        consent: base.consent,
        maxEventBytes: base.maxEventBytes,
        leaseDuration: base.leaseDuration,
        logger: config?.logger ?? const BeeLogger.silent(),
      ),
      store: store,
      signals: signals,
      random: Random(0),
    );
    return BeeSyncTestHarness._(bee, fake, signals, store);
  }

  final BeeSync bee;
  final FakeTransport transport;
  final FakePlatformSignals signals;
  final InMemoryEventStore store;
  final List<DeliveryEvent> deliveryEvents = [];
  late final StreamSubscription<DeliveryEvent> _sub;

  /// Names of events that reached the transport, in order.
  List<String> get trackedNames => [
    for (final e in transport.sentEvents) e.name,
  ];

  /// Flushes and returns everything sent so far.
  Future<List<BatchEvent>> flushAndCollect() async {
    await bee.flush();
    return transport.sentEvents;
  }

  Future<void> close() async {
    await bee.close();
    await _sub.cancel();
  }
}
