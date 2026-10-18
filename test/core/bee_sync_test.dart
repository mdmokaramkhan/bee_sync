import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:bee_sync/bee_sync.dart';
import 'package:bee_sync/testing.dart';
import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Drives a real [BeeSync] on fake time with an in-memory store.
class Rig {
  Rig(this.async, {InMemoryEventStore? store})
    : store = store ?? InMemoryEventStore();

  final FakeAsync async;
  final InMemoryEventStore store;
  final transport = FakeTransport();
  final signals = FakePlatformSignals();
  final events = <DeliveryEvent>[];
  late BeeSync bee;

  void start({
    BatchingPolicy batching = const BatchingPolicy(),
    RetryPolicy retry = const RetryPolicy(),
    RetentionPolicy retention = const RetentionPolicy(),
    ConsentConfig consent = const ConsentConfig(),
    int maxEventBytes = 32 * 1024,
    EventTransport? transportOverride,
    BackgroundScheduler? background,
  }) {
    bee = wait(
      BeeSync.initialize(
        BeeSyncConfig(
          transport: transportOverride ?? transport,
          batching: batching,
          retry: retry,
          retention: retention,
          consent: consent,
          maxEventBytes: maxEventBytes,
          logger: const BeeLogger.silent(),
        ),
        store: store,
        signals: signals,
        random: Random(0),
        background: background,
      ),
    );
    bee.events.listen(events.add);
  }

  /// Runs fake time until [future] completes.
  T wait<T>(Future<T> future) {
    var done = false;
    late T value;
    Object? error;
    StackTrace? stack;
    future.then(
      (v) {
        value = v;
        done = true;
      },
      onError: (Object e, StackTrace s) {
        error = e;
        stack = s;
        done = true;
      },
    );
    for (var i = 0; i < 1000 && !done; i++) {
      async.flushMicrotasks();
      if (!done) async.elapse(const Duration(milliseconds: 1));
    }
    if (error != null) Error.throwWithStackTrace(error!, stack!);
    if (!done) throw StateError('Future did not complete');
    return value;
  }

  String track(
    String name, {
    Priority priority = Priority.normal,
    Map<String, Object?> properties = const {},
  }) => wait(bee.track(name, properties: properties, priority: priority));

  void elapse(Duration d) => async.elapse(d);

  List<String> get sentNames => [for (final e in transport.sentEvents) e.name];

  List<String> sentIdsInBatch(int i) => [
    for (final e in transport.batches[i].events) e.id,
  ];

  List<T> eventsOf<T extends DeliveryEvent>() => events.whereType<T>().toList();

  List<String> droppedIds(DropReason reason) => [
    for (final d in eventsOf<Dropped>())
      if (d.reason == reason) ...d.ids,
  ];

  int get stored => wait(store.totals(0)).total;

  QueueStats get stats => wait(bee.getStats());

  void close() => wait(bee.close());
}

void main() {
  void rigTest(String description, void Function(Rig rig) body) {
    test(description, () {
      fakeAsync((async) {
        final rig = Rig(async);
        try {
          body(rig);
        } finally {
          try {
            rig.close();
          } on Object catch (e, st) {
            fail("close failed: $e\n$st");
          }
        }
      });
    });
  }

  group('batching triggers', () {
    rigTest('flushes once flushAt events are pending', (rig) {
      rig.start(batching: const BatchingPolicy(flushAt: 3));
      rig.track('a');
      rig.track('b');
      rig.elapse(const Duration(seconds: 1));
      expect(rig.transport.batches, isEmpty);

      rig.track('c');
      rig.elapse(const Duration(seconds: 1));
      expect(rig.sentNames, ['a', 'b', 'c']);
      expect(rig.stored, 0);
      expect(rig.eventsOf<Delivered>().single.ids, hasLength(3));
    });

    rigTest('flushes on the interval', (rig) {
      rig.start(
        batching: const BatchingPolicy(flushInterval: Duration(seconds: 10)),
      );
      rig.track('a');
      rig.elapse(const Duration(seconds: 9));
      expect(rig.transport.batches, isEmpty);
      rig.elapse(const Duration(seconds: 2));
      expect(rig.sentNames, ['a']);
    });

    rigTest('immediate events go out right away, alone', (rig) {
      rig.start();
      rig.track('normal');
      rig.track('buy', priority: Priority.immediate);
      rig.elapse(const Duration(milliseconds: 100));
      expect(rig.sentNames, ['buy']);
      expect(
        rig.transport.batches.single.events.single.priority,
        Priority.immediate,
      );
    });

    rigTest('app backgrounding triggers a flush', (rig) {
      rig.start();
      rig.track('a');
      rig.signals.background();
      rig.elapse(const Duration(milliseconds: 10));
      expect(rig.sentNames, ['a']);
    });

    rigTest('splits into maxBatchSize batches', (rig) {
      rig.start(batching: const BatchingPolicy(flushAt: 100, maxBatchSize: 2));
      for (var i = 0; i < 5; i++) {
        rig.track('e$i');
      }
      rig.wait(rig.bee.flush());
      expect(
        [for (final b in rig.transport.batches) b.events.length],
        [2, 2, 1],
      );
      expect(rig.sentNames, ['e0', 'e1', 'e2', 'e3', 'e4']);
    });

    rigTest('splits by maxBatchBytes but always sends at least one', (rig) {
      rig.start(
        batching: const BatchingPolicy(flushAt: 100, maxBatchBytes: 30),
      );
      rig.track('a', properties: {'p': 'x' * 20}); // ~28 bytes
      rig.track('b', properties: {'p': 'x' * 20});
      rig.track('big', properties: {'p': 'x' * 100});
      rig.wait(rig.bee.flush());
      expect(
        [for (final b in rig.transport.batches) b.events.length],
        [1, 1, 1],
      );
    });

    rigTest('track before initialize completes is not lost', (rig) {
      final init = BeeSync.initialize(
        BeeSyncConfig(
          transport: rig.transport,
          logger: const BeeLogger.silent(),
        ),
        store: rig.store,
        signals: rig.signals,
      );
      final tracked = BeeSync.instance.track('early');
      rig.bee = rig.wait(init);
      rig.wait(tracked);
      rig.wait(rig.bee.flush());
      expect(rig.sentNames, ['early']);
    });
  });

  group('failures', () {
    rigTest('retryable failure backs off, then retries the same event', (rig) {
      rig.start(
        batching: const BatchingPolicy(flushInterval: Duration(seconds: 30)),
      );
      rig.transport.enqueue(const RetryableFailure('HTTP 503'));
      final id = rig.track('a', priority: Priority.immediate);
      rig.elapse(const Duration(milliseconds: 100));

      expect(rig.eventsOf<FlushFailed>().single.reason, 'HTTP 503');
      expect(rig.stored, 1);
      expect(rig.stats.backoffUntil, isNotNull);

      rig.elapse(const Duration(seconds: 30));
      expect(rig.transport.batches, hasLength(2));
      final retried = rig.transport.batches[1].events.single;
      expect(retried.id, id);
      expect(retried.attempt, 2);
      expect(
        rig.transport.batches[1].batchId,
        isNot(rig.transport.batches[0].batchId),
      );
      expect(rig.stored, 0);
      expect(rig.stats.backoffUntil, isNull);
    });

    rigTest('Retry-After holds back automatic flushes', (rig) {
      rig.start(
        batching: const BatchingPolicy(flushInterval: Duration(seconds: 30)),
      );
      rig.transport.enqueue(
        const RetryableFailure('HTTP 429', retryAfter: Duration(minutes: 5)),
      );
      rig.track('a', priority: Priority.immediate);
      rig.elapse(const Duration(minutes: 4));
      expect(rig.transport.batches, hasLength(1));
      rig.elapse(const Duration(minutes: 2));
      expect(rig.transport.batches, hasLength(2));
      expect(rig.stored, 0);
    });

    rigTest('a throwing transport is treated as retryable', (rig) {
      rig.start();
      rig.transport.enqueueWith((_) => throw StateError('boom'));
      rig.track('a', priority: Priority.immediate);
      rig.elapse(const Duration(milliseconds: 100));
      expect(rig.eventsOf<FlushFailed>(), hasLength(1));
      expect(rig.stored, 1);
    });

    rigTest('events are dropped after maxAttempts', (rig) {
      rig.start(
        retry: const RetryPolicy(
          base: Duration(seconds: 1),
          max: Duration(seconds: 1),
          maxAttempts: 3,
        ),
        batching: const BatchingPolicy(flushInterval: Duration(seconds: 5)),
      );
      rig.transport.fallback = (_) => const RetryableFailure('down');
      final id = rig.track('a');
      rig.elapse(const Duration(seconds: 30));
      expect(rig.transport.batches, hasLength(3));
      expect(rig.droppedIds(DropReason.maxAttempts), [id]);
      expect(rig.stored, 0);
      expect(rig.stats.dropped[DropReason.maxAttempts], 1);
    });

    rigTest('network failures never use up attempts', (rig) {
      rig.start(
        retry: const RetryPolicy(
          base: Duration(seconds: 1),
          max: Duration(seconds: 1),
          maxAttempts: 3,
        ),
        batching: const BatchingPolicy(flushInterval: Duration(seconds: 5)),
      );
      rig.transport.fallback = (_) => const NetworkFailure('offline');
      final id = rig.track('a');
      rig.elapse(const Duration(seconds: 30));
      expect(rig.transport.batches.length, greaterThan(3));
      expect(rig.droppedIds(DropReason.maxAttempts), isEmpty);
      expect(rig.stored, 1);

      rig.transport.fallback = (_) => const Success();
      rig.elapse(const Duration(seconds: 10));
      expect(rig.stored, 0);
      final last = rig.transport.batches.last.events.single;
      expect(last.id, id);
      expect(last.attempt, 1);
    });

    rigTest('auth failure pauses automatic flushes without using attempts', (
      rig,
    ) {
      rig.start(
        batching: const BatchingPolicy(flushInterval: Duration(seconds: 10)),
      );
      rig.transport.enqueue(const AuthFailure('HTTP 401'));
      rig.track('a', priority: Priority.immediate);
      rig.elapse(const Duration(minutes: 5));
      expect(rig.transport.batches, hasLength(1));
      expect(rig.stored, 1);

      // A manual flush (e.g. after the app refreshed its token) resumes.
      rig.wait(rig.bee.flush());
      expect(rig.transport.batches, hasLength(2));
      expect(rig.transport.batches[1].events.single.attempt, 1);
      expect(rig.stored, 0);
    });

    rigTest('permanent failure bisects to drop only the poison event', (rig) {
      rig.start(batching: const BatchingPolicy(flushAt: 100));
      final ids = [
        for (final n in ['a', 'b', 'poison', 'd']) rig.track(n),
      ];
      rig.transport.fallback = (batch) =>
          batch.events.any((e) => e.name == 'poison')
          ? const PermanentFailure('HTTP 400')
          : const Success();
      rig.wait(rig.bee.flush());

      expect(rig.droppedIds(DropReason.rejectedByServer), [ids[2]]);
      expect([
        for (final d in rig.eventsOf<Delivered>()) ...d.ids,
      ], unorderedEquals([ids[0], ids[1], ids[3]]));
      expect(rig.stored, 0);
    });

    rigTest('413 splits the batch until it fits', (rig) {
      rig.start(batching: const BatchingPolicy(flushAt: 100));
      for (var i = 0; i < 5; i++) {
        rig.track('e$i');
      }
      rig.transport.fallback = (batch) =>
          batch.events.length > 2 ? const PayloadTooLarge() : const Success();
      rig.wait(rig.bee.flush());
      expect(rig.stats.sent, 5);
      expect(rig.droppedIds(DropReason.tooLarge), isEmpty);
    });

    rigTest('413 for a single event drops it', (rig) {
      rig.start();
      rig.transport.fallback = (_) => const PayloadTooLarge();
      final id = rig.track('huge');
      rig.wait(rig.bee.flush());
      expect(rig.droppedIds(DropReason.tooLarge), [id]);
    });

    rigTest('ids the server lists as rejected are dropped', (rig) {
      rig.start(batching: const BatchingPolicy(flushAt: 100));
      final a = rig.track('a');
      final b = rig.track('b');
      rig.transport.enqueue(Success(rejectedIds: {b}));
      rig.wait(rig.bee.flush());
      expect(rig.eventsOf<Delivered>().single.ids, [a]);
      expect(rig.droppedIds(DropReason.rejectedByServer), [b]);
    });

    rigTest('unreadable payloads are dropped, not retried forever', (rig) {
      rig.start();
      rig.wait(
        rig.store.insert(
          NewEvent(
            id: 'corrupt',
            name: 'x',
            payload: Uint8List.fromList([0xff, 0xfe]),
            priority: Priority.normal,
            createdAt: 0,
          ),
        ),
      );
      rig.track('ok');
      rig.wait(rig.bee.flush());
      expect(rig.droppedIds(DropReason.unreadable), ['corrupt']);
      expect(rig.sentNames, ['ok']);
    });

    rigTest('connectivity restored resets backoff and flushes', (rig) {
      rig.start(
        batching: const BatchingPolicy(flushInterval: Duration(hours: 1)),
      );
      rig.transport.enqueue(
        const RetryableFailure('offline', retryAfter: Duration(minutes: 30)),
      );
      rig.track('a', priority: Priority.immediate);
      rig.elapse(const Duration(seconds: 1));
      expect(rig.transport.batches, hasLength(1));

      rig.signals.restoreConnectivity();
      rig.elapse(const Duration(seconds: 1));
      expect(rig.transport.batches, hasLength(2));
      expect(rig.stored, 0);
    });
  });

  group('consent', () {
    rigTest('unknown + hold stores events and sends them once granted', (rig) {
      rig.start(consent: const ConsentConfig(initial: ConsentState.unknown));
      rig.track('a', priority: Priority.immediate);
      rig.elapse(const Duration(minutes: 5));
      expect(rig.transport.batches, isEmpty);
      expect(rig.stored, 1);

      rig.wait(rig.bee.setConsent(ConsentState.granted));
      rig.elapse(const Duration(seconds: 1));
      expect(rig.sentNames, ['a']);
    });

    rigTest('unknown + drop discards events', (rig) {
      rig.start(
        consent: const ConsentConfig(
          initial: ConsentState.unknown,
          whileUnknown: UnknownConsentBehavior.drop,
        ),
      );
      final id = rig.track('a');
      expect(rig.droppedIds(DropReason.noConsent), [id]);
      expect(rig.stored, 0);
    });

    rigTest('denied with purge clears the queue and drops new events', (rig) {
      rig.start(consent: const ConsentConfig(initial: ConsentState.unknown));
      final queued = rig.track('a');
      rig.wait(rig.bee.setConsent(ConsentState.denied, purge: true));
      final later = rig.track('b');
      expect(rig.droppedIds(DropReason.noConsent), [queued, later]);
      expect(rig.stored, 0);
      rig.wait(rig.bee.flush());
      expect(rig.transport.batches, isEmpty);
    });

    test('consent persists across restarts', () {
      fakeAsync((async) {
        final store = InMemoryEventStore();
        final first = Rig(async, store: store)..start();
        first.wait(first.bee.setConsent(ConsentState.denied));
        first.close();

        final second = Rig(async, store: store)..start();
        expect(second.bee.consent, ConsentState.denied);
        second.close();
      });
    });
  });

  group('retention', () {
    const hold = ConsentConfig(initial: ConsentState.unknown);

    rigTest('dropOldest evicts the oldest normal events', (rig) {
      rig.start(consent: hold, retention: const RetentionPolicy(maxEvents: 3));
      final ids = [for (var i = 0; i < 5; i++) rig.track('e$i')];
      expect(rig.droppedIds(DropReason.overflow), [ids[0], ids[1]]);
      expect(rig.stored, 3);
    });

    rigTest('dropOldest keeps immediate events over normal ones', (rig) {
      rig.start(consent: hold, retention: const RetentionPolicy(maxEvents: 2));
      final vip = rig.track('vip', priority: Priority.immediate);
      rig.track('n1');
      rig.track('n2');
      expect(rig.droppedIds(DropReason.overflow), isNot(contains(vip)));
    });

    rigTest('dropNewest rejects incoming events when full', (rig) {
      rig.start(
        consent: hold,
        retention: const RetentionPolicy(
          maxEvents: 2,
          overflow: OverflowPolicy.dropNewest,
        ),
      );
      rig.track('a');
      rig.track('b');
      final c = rig.track('c');
      expect(rig.droppedIds(DropReason.overflow), [c]);
      expect(rig.stored, 2);
    });

    rigTest('events older than maxAge expire', (rig) {
      rig.start(
        consent: hold,
        retention: const RetentionPolicy(maxAge: Duration(minutes: 1)),
        batching: const BatchingPolicy(flushInterval: Duration(seconds: 30)),
      );
      final id = rig.track('a');
      rig.elapse(const Duration(seconds: 95));
      expect(rig.droppedIds(DropReason.expired), [id]);
      expect(rig.stored, 0);
    });
  });

  group('validation', () {
    rigTest('rejects invalid events', (rig) {
      rig.start(maxEventBytes: 50);
      expect(() => rig.track(''), throwsA(isA<InvalidEventException>()));
      expect(
        () => rig.track('a', properties: {'when': DateTime(2026)}),
        throwsA(isA<InvalidEventException>()),
      );
      expect(
        () => rig.track('a', properties: {'p': 'x' * 100}),
        throwsA(isA<InvalidEventException>()),
      );
      expect(rig.stored, 0);
    });
  });

  group('stats', () {
    rigTest('stream reports queue changes and counters', (rig) {
      rig.start(batching: const BatchingPolicy(flushAt: 100));
      final seen = <QueueStats>[];
      final sub = rig.bee.stats.listen(seen.add);
      rig.track('a');
      rig.elapse(const Duration(milliseconds: 200));
      expect(seen.last.pending, 1);

      rig.wait(rig.bee.flush());
      rig.elapse(const Duration(milliseconds: 200));
      expect(seen.last.pending, 0);
      expect(seen.last.sent, 1);
      expect(seen.last.lastSuccessAt, isNotNull);
      unawaited(sub.cancel());
    });

    test('counters persist across restarts', () {
      fakeAsync((async) {
        final store = InMemoryEventStore();
        final first = Rig(async, store: store)..start();
        first.track('a');
        first.wait(first.bee.flush());
        first.close();

        final second = Rig(async, store: store)..start();
        expect(second.stats.sent, 1);
        second.close();
      });
    });
  });

  group('background delivery', () {
    HttpTransport okHttp() => HttpTransport(
      endpoint: Uri.parse('https://example.test/events'),
      client: MockClient((_) async => http.Response('', 200)),
    );
    HttpTransport downHttp() => HttpTransport(
      endpoint: Uri.parse('https://example.test/events'),
      client: MockClient((_) async => http.Response('', 503)),
    );

    void bgTest(
      String description,
      void Function(Rig rig, FakeBackgroundScheduler bg) body, {
      FakeBackgroundScheduler? scheduler,
      String? databasePath = '/data/bee_sync.db',
    }) {
      test(description, () {
        fakeAsync((async) {
          final bg = scheduler ?? FakeBackgroundScheduler();
          final rig = Rig(
            async,
            store: InMemoryEventStore(databasePath: databasePath),
          );
          try {
            body(rig, bg);
          } finally {
            rig.close();
          }
        });
      });
    }

    bgTest('configures native with the database path', (rig, bg) {
      rig.start(transportOverride: okHttp(), background: bg);
      expect(bg.databasePath, '/data/bee_sync.db');
      expect(bg.enabled, isTrue);
      expect(rig.bee.backgroundEnabled, isTrue);
      expect(bg.cancelled, 0);
    });

    bgTest('schedules on backgrounding while events remain', (rig, bg) {
      rig.start(transportOverride: downHttp(), background: bg);
      rig.track('a');
      rig.signals.background();
      rig.elapse(const Duration(seconds: 1));
      expect(bg.scheduled, greaterThanOrEqualTo(1));
      expect(bg.cancelled, 0);
    });

    bgTest('schedules before the backgrounding flush finishes', (rig, bg) {
      // The server hasn't answered yet when the OS kills the app.
      final response = Completer<http.Response>();
      final hang = HttpTransport(
        endpoint: Uri.parse('https://example.test/events'),
        client: MockClient((_) => response.future),
      );
      rig.start(transportOverride: hang, background: bg);
      rig.track('a');
      rig.signals.background();
      rig.elapse(const Duration(milliseconds: 10));
      expect(bg.scheduled, 1, reason: 'scheduled while the flush is pending');

      response.complete(http.Response('', 200)); // let close() finish
    });

    bgTest('cancels on backgrounding once the queue is empty', (rig, bg) {
      rig.start(transportOverride: okHttp(), background: bg);
      rig.track('a');
      rig.signals.background();
      rig.elapse(const Duration(seconds: 1));
      // Scheduled first (an event was pending), cancelled once delivered.
      expect(bg.scheduled, 1);
      expect(bg.cancelled, 1);
      expect(rig.stats.sent, 1);
    });

    bgTest('is off with a custom transport, which native cannot replay', (
      rig,
      bg,
    ) {
      rig.start(background: bg); // FakeTransport
      expect(bg.enabled, isFalse);
      expect(bg.cancelled, 1);
      expect(rig.bee.backgroundEnabled, isFalse);
      expect(rig.wait(rig.store.getMeta(MetaKeys.transportConfig)), isNull);
    });

    bgTest('is off when the store is not file-backed', (rig, bg) {
      rig.start(transportOverride: okHttp(), background: bg);
      expect(bg.enabled, isFalse);
    }, databasePath: null);

    bgTest('is off when disabled in config', (rig, bg) {
      rig.bee = rig.wait(
        BeeSync.initialize(
          BeeSyncConfig(
            transport: okHttp(),
            background: const BackgroundConfig(enabled: false),
            logger: const BeeLogger.silent(),
          ),
          store: rig.store,
          signals: rig.signals,
          background: bg,
        ),
      );
      expect(bg.enabled, isFalse);
      expect(bg.cancelled, 1);
    });

    bgTest(
      'a missing native plugin leaves foreground delivery working',
      (rig, bg) {
        rig.start(transportOverride: okHttp(), background: bg);
        expect(rig.bee.backgroundEnabled, isFalse);
        rig.track('a');
        rig.wait(rig.bee.flush());
        expect(rig.stats.sent, 1);
      },
      scheduler: FakeBackgroundScheduler(failConfigure: true),
    );

    bgTest('mirrors transport and delivery settings for native', (rig, bg) {
      rig.start(
        transportOverride: okHttp(),
        background: bg,
        batching: const BatchingPolicy(maxBatchSize: 7),
      );
      final transport = jsonDecode(
        rig.wait(rig.store.getMeta(MetaKeys.transportConfig))!,
      );
      expect((transport as Map)['endpoint'], 'https://example.test/events');
      final delivery = jsonDecode(
        rig.wait(rig.store.getMeta(MetaKeys.deliveryConfig))!,
      );
      expect((delivery as Map)['max_batch_size'], 7);

      rig.wait(rig.bee.setHeaders({'Authorization': 'Bearer new'}));
      final updated = jsonDecode(
        rig.wait(rig.store.getMeta(MetaKeys.transportConfig))!,
      );
      expect((updated as Map)['headers'], {'Authorization': 'Bearer new'});
    });
  });

  group('state shared with native uploaders', () {
    rigTest('stats include counters written by native code', (rig) {
      rig.start();
      rig.wait(
        rig.store.incrementCounters({
          CounterKeys.sent: 5,
          CounterKeys.dropped(DropReason.maxAttempts): 2,
        }),
      );
      final s = rig.stats;
      expect(s.sent, 5);
      expect(s.dropped, {DropReason.maxAttempts: 2});
    });

    rigTest('an auth block set by native pauses automatic flushes', (rig) {
      rig.start(
        batching: const BatchingPolicy(flushInterval: Duration(seconds: 10)),
      );
      rig.wait(rig.store.setMeta(MetaKeys.authBlocked, '1'));
      rig.track('a', priority: Priority.immediate);
      rig.elapse(const Duration(minutes: 1));
      expect(rig.transport.batches, isEmpty);

      rig.wait(rig.bee.flush()); // manual flush clears it
      expect(rig.sentNames, ['a']);
      expect(rig.wait(rig.store.getMeta(MetaKeys.authBlocked)), '0');
    });

    rigTest('a backoff set by native holds automatic flushes', (rig) {
      rig.start(
        batching: const BatchingPolicy(flushInterval: Duration(seconds: 10)),
      );
      final until = clock.now().add(const Duration(minutes: 5));
      rig.wait(
        rig.store.setMeta(
          MetaKeys.flushNotBefore,
          '${until.millisecondsSinceEpoch}',
        ),
      );
      rig.track('a', priority: Priority.immediate);
      rig.elapse(const Duration(minutes: 4));
      expect(rig.transport.batches, isEmpty);
      expect(rig.stats.backoffUntil, isNotNull);
      rig.elapse(const Duration(minutes: 2));
      expect(rig.sentNames, ['a']);
    });

    rigTest('backgroundLog returns native entries, newest first', (rig) {
      rig.start();
      for (final m in ['one', 'two']) {
        rig.store.addBackgroundLog(
          BackgroundLogEntry(
            at: DateTime.utc(2026),
            source: 'android_worker',
            level: 'info',
            message: m,
          ),
        );
      }
      final log = rig.wait(rig.bee.backgroundLog(limit: 1));
      expect([for (final e in log) e.message], ['two']);
    });
  });

  group('diagnostics', () {
    rigTest('debugActivity records requests and drops, newest first', (rig) {
      rig.start(batching: const BatchingPolicy(flushAt: 100));
      rig.track('a');
      rig.transport.enqueue(
        const RetryableFailure('HTTP 503', retryAfter: Duration(seconds: 30)),
      );
      rig.wait(rig.bee.flush());
      rig.wait(rig.bee.resetBackoff());
      rig.wait(rig.bee.flush());
      rig.wait(rig.bee.purgeQueue()); // nothing left: no drop entry

      final activity = rig.bee.debugActivity;
      expect(activity, hasLength(2));
      final ok = activity[0] as RequestActivity;
      final failed = activity[1] as RequestActivity;
      expect(ok.succeeded, isTrue);
      expect(ok.outcome, '2xx: 1 accepted');
      expect(ok.events, 1);
      expect(failed.succeeded, isFalse);
      expect(failed.outcome, 'HTTP 503, retry after 30s');
      expect(failed.batchId, isNot(ok.batchId));
    });

    rigTest('debugActivity keeps the last 50 entries', (rig) {
      rig.start(batching: const BatchingPolicy(flushAt: 1000));
      for (var i = 0; i < 60; i++) {
        rig.track('e$i');
        rig.wait(rig.bee.flush());
      }
      expect(rig.bee.debugActivity, hasLength(50));
      expect(rig.transport.batches, hasLength(60));
    });

    rigTest('simulate offline fails uploads without calling the transport', (
      rig,
    ) {
      rig.start();
      rig.bee.debugSimulateOffline = true;
      rig.track('a', priority: Priority.immediate);
      rig.elapse(const Duration(milliseconds: 100));

      expect(rig.transport.batches, isEmpty);
      expect(rig.eventsOf<FlushFailed>().single.reason, 'Simulated offline');
      expect(
        (rig.bee.debugActivity.first as RequestActivity).outcome,
        'Simulated offline',
      );
      expect(rig.stored, 1);

      // Back online: clear the backoff it caused and the event goes out.
      rig.bee.debugSimulateOffline = false;
      rig.wait(rig.bee.resetBackoff());
      rig.wait(rig.bee.flush());
      expect(rig.sentNames, ['a']);
    });

    rigTest('resetBackoff makes deferred events ready again', (rig) {
      rig.start(
        batching: const BatchingPolicy(flushInterval: Duration(hours: 1)),
      );
      rig.transport.enqueue(
        const RetryableFailure('down', retryAfter: Duration(minutes: 30)),
      );
      rig.track('a', priority: Priority.immediate);
      rig.elapse(const Duration(seconds: 1));
      expect(rig.stats.backoffUntil, isNotNull);
      expect(rig.wait(rig.bee.debugQueue()).single.nextAttemptAt, isNotNull);

      rig.wait(rig.bee.resetBackoff());
      expect(rig.stats.backoffUntil, isNull);
      expect(rig.wait(rig.bee.debugQueue()).single.nextAttemptAt, isNull);
    });

    rigTest('purgeQueue drops everything as purged', (rig) {
      rig.start(consent: const ConsentConfig(initial: ConsentState.unknown));
      final ids = [rig.track('a'), rig.track('b')];
      expect(rig.wait(rig.bee.purgeQueue()), 2);
      expect(rig.stored, 0);
      expect(rig.droppedIds(DropReason.purged), ids);
      expect(rig.stats.dropped, {DropReason.purged: 2});
      final drop = rig.bee.debugActivity.first as DropActivity;
      expect((drop.events, drop.reason), (2, DropReason.purged));
    });

    rigTest('debugQueue lists stored events with their properties', (rig) {
      rig.start(consent: const ConsentConfig(initial: ConsentState.unknown));
      rig.track('a', properties: {'k': 1});
      rig.track('b', priority: Priority.immediate);
      final queue = rig.wait(rig.bee.debugQueue());
      expect([for (final e in queue) e.name], ['a', 'b']);
      expect(queue[0].properties, {'k': 1});
      expect(queue[1].priority, Priority.immediate);
      expect(queue.every((e) => !e.inFlight), isTrue);
    });
  });

  group('store round trips', () {
    test('track() makes one store call while under limits', () {
      fakeAsync((async) {
        final store = _CountingStore();
        final rig = Rig(async, store: store)
          ..start(batching: const BatchingPolicy(flushAt: 1000));
        store.calls.clear();

        rig.track('a');
        rig.track('b', priority: Priority.immediate);
        expect(store.calls, ['insertAndCount', 'insertAndCount']);
        rig.close();
      });
    });

    test('track() evicts only when the count is over the limits', () {
      fakeAsync((async) {
        final store = _CountingStore();
        final rig = Rig(async, store: store)
          ..start(
            consent: const ConsentConfig(initial: ConsentState.unknown),
            retention: const RetentionPolicy(maxEvents: 1),
          );
        rig.track('a');
        store.calls.clear();

        rig.track('b');
        expect(store.calls.take(2), ['insertAndCount', 'evict']);
        expect(rig.stored, 1);
        rig.close();
      });
    });
  });

  test('close() waits for a track() already in progress', () {
    fakeAsync((async) {
      final store = _SlowInsertStore();
      final rig = Rig(async, store: store)..start();
      var tracked = false;
      Object? trackError;
      rig.bee
          .track('a')
          .then((_) => tracked = true, onError: (Object e) => trackError = e);
      async.flushMicrotasks(); // track() is now waiting on the slow insert
      final closing = rig.bee.close();
      expect(() => rig.bee.track('late'), throwsStateError);

      store.unblock.complete();
      rig.wait(closing);
      expect(trackError, isNull);
      expect(tracked, isTrue);
      expect(store.closedAfterInsert, isTrue);
    });
  });

  test('only one instance at a time', () {
    fakeAsync((async) {
      final rig = Rig(async)..start();
      expect(
        () => rig.wait(
          BeeSync.initialize(BeeSyncConfig(transport: FakeTransport())),
        ),
        throwsStateError,
      );
      rig.close();
      expect(() => BeeSync.instance, throwsStateError);
    });
  });
}

/// Records which store methods track() calls.
class _CountingStore extends InMemoryEventStore {
  final calls = <String>[];

  @override
  Future<void> insert(NewEvent event) {
    calls.add('insert');
    return super.insert(event);
  }

  @override
  Future<QueueTotals> insertAndCount(NewEvent event, {required int now}) {
    calls.add('insertAndCount');
    // Not super.insertAndCount: it calls insert()/totals() internally.
    return _insertThenCount(event, now);
  }

  Future<QueueTotals> _insertThenCount(NewEvent event, int now) async {
    await super.insert(event);
    return super.totals(now);
  }

  @override
  Future<QueueTotals> totals(int now) {
    calls.add('totals');
    return super.totals(now);
  }

  @override
  Future<List<String>> evict({
    required int now,
    required int maxEvents,
    required int maxBytes,
  }) {
    calls.add('evict');
    return super.evict(now: now, maxEvents: maxEvents, maxBytes: maxBytes);
  }
}

/// An in-memory store whose insert waits until [unblock] completes.
class _SlowInsertStore extends InMemoryEventStore {
  final unblock = Completer<void>();
  bool _inserted = false;
  bool closedAfterInsert = false;

  @override
  Future<QueueTotals> insertAndCount(NewEvent event, {required int now}) async {
    await unblock.future;
    final totals = await super.insertAndCount(event, now: now);
    _inserted = true;
    return totals;
  }

  @override
  Future<void> close() async {
    closedAfterInsert = _inserted;
    await super.close();
  }
}
