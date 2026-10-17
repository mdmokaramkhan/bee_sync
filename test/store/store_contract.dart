import 'dart:convert';
import 'dart:typed_data';

import 'package:bee_sync/bee_sync.dart';
import 'package:bee_sync/testing.dart';
import 'package:flutter_test/flutter_test.dart';

/// Behaviour every [EventStore] must share. Run against each implementation
/// so the in-memory test double cannot drift from SQLite.
void runStoreContract(String label, Future<EventStore> Function() create) {
  group('$label contract', () {
    late EventStore store;
    const a = 'owner-a';
    const b = 'owner-b';
    const lease = 1000;

    setUp(() async {
      store = await create();
      await store.open();
    });
    tearDown(() => store.close());

    Future<void> add(
      String id, {
      Priority priority = Priority.normal,
      int createdAt = 0,
      int size = 2,
    }) => store.insert(
      NewEvent(
        id: id,
        name: 'e_$id',
        payload: Uint8List.fromList(utf8.encode('${'{'.padRight(size - 1)}}')),
        priority: priority,
        createdAt: createdAt,
      ),
    );

    Future<List<String>> claimIds(
      String owner, {
      int now = 0,
      int limit = 100,
      bool immediateOnly = false,
    }) async => [
      for (final e in await store.claim(
        owner: owner,
        now: now,
        leaseUntil: now + lease,
        limit: limit,
        immediateOnly: immediateOnly,
      ))
        e.id,
    ];

    test('claims immediate first, then FIFO, up to limit', () async {
      await add('1');
      await add('2', priority: Priority.immediate);
      await add('3');
      await add('4', priority: Priority.immediate);
      expect(await claimIds(a, limit: 3), ['2', '4', '1']);
    });

    test('round-trips event fields', () async {
      await add('x', priority: Priority.immediate, createdAt: 42, size: 5);
      final e = (await store.claim(
        owner: a,
        now: 0,
        leaseUntil: lease,
        limit: 1,
      )).single;
      expect(e.name, 'e_x');
      expect(e.priority, Priority.immediate);
      expect(e.createdAt, 42);
      expect(e.sizeBytes, 5);
      expect(e.payload.length, 5);
      expect(e.attempts, 0);
      expect(e.encrypted, isFalse);
    });

    test('immediateOnly claims only immediate events', () async {
      await add('1');
      await add('2', priority: Priority.immediate);
      expect(await claimIds(a, immediateOnly: true), ['2']);
    });

    test(
      'a live lease hides events from other owners until it expires',
      () async {
        await add('1');
        await add('2');
        expect(await claimIds(a, limit: 1), ['1']);
        expect(await claimIds(b, now: 10), ['2']);
        expect(await claimIds(b, now: lease + 1), ['1', '2']);
      },
    );

    test('deleteLeased deletes only events leased by the owner', () async {
      await add('1');
      await add('2');
      await claimIds(a, limit: 1);
      await store.deleteLeased(a, ['1', '2']);
      await store.deleteLeased(b, ['2']);
      expect((await store.totals(0)).total, 1);
      expect(await claimIds(b), ['2']);
    });

    test('releaseRetry counts the attempt and defers the event', () async {
      await add('1');
      await claimIds(a);
      await store.releaseRetry(a, ['1'], nextAttemptAt: 500);
      expect(await claimIds(b, now: 499), isEmpty);
      final e = (await store.claim(
        owner: b,
        now: 500,
        leaseUntil: 500 + lease,
        limit: 10,
      )).single;
      expect(e.attempts, 1);
    });

    test('release returns events untouched', () async {
      await add('1');
      await claimIds(a);
      await store.release(a, ['1']);
      final e = (await store.claim(
        owner: b,
        now: 0,
        leaseUntil: lease,
        limit: 10,
      )).single;
      expect(e.attempts, 0);
    });

    test('totals count pending, in flight and bytes', () async {
      await add('1', size: 10);
      await add('2', size: 20);
      await claimIds(a, limit: 1);
      final t = await store.totals(0);
      expect((t.total, t.inFlight, t.pending, t.bytes), (2, 1, 1, 30));
      expect((await store.totals(lease + 1)).inFlight, 0);
    });

    test('deleteExpired skips events under a live lease', () async {
      await add('old1', createdAt: 0);
      await add('old2', createdAt: 0);
      await add('new', createdAt: 100);
      await claimIds(a, limit: 1); // leases old1
      expect(await store.deleteExpired(createdBefore: 50, now: 10), ['old2']);
      expect((await store.totals(10)).total, 2);
    });

    test('evict removes normal before immediate, oldest first', () async {
      await add('i1', priority: Priority.immediate);
      await add('n1');
      await add('n2');
      await add('n3');
      final evicted = await store.evict(
        now: 0,
        maxEvents: 2,
        maxBytes: 1 << 20,
      );
      expect(evicted, ['n1', 'n2']);
      expect(await claimIds(a), ['i1', 'n3']);
    });

    test('evict respects maxBytes and skips leased events', () async {
      await add('1', size: 10);
      await add('2', size: 10);
      await add('3', size: 10);
      await claimIds(a, limit: 1); // leases 1
      expect(await store.evict(now: 0, maxEvents: 100, maxBytes: 15), [
        '2',
        '3',
      ]);
      expect(await store.evict(now: 0, maxEvents: 100, maxBytes: 15), isEmpty);
    });

    test('purge removes everything and returns the ids', () async {
      await add('1');
      await add('2');
      await claimIds(a, limit: 1);
      expect(await store.purge(), unorderedEquals(['1', '2']));
      expect((await store.totals(0)).total, 0);
    });

    test('resetBackoff makes deferred events ready', () async {
      await add('1');
      await claimIds(a);
      await store.releaseRetry(a, ['1'], nextAttemptAt: 1 << 40);
      await store.resetBackoff();
      expect(await claimIds(b), ['1']);
    });

    test('meta values can be set and overwritten', () async {
      expect(await store.getMeta('k'), isNull);
      await store.setMeta('k', 'v1');
      await store.setMeta('k', 'v2');
      expect(await store.getMeta('k'), 'v2');
    });
  });
}
