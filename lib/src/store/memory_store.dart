import 'dart:typed_data';

import '../api/models.dart';
import 'event_store.dart';

/// In-memory [EventStore] with the same semantics as [SqfliteEventStore].
///
/// Used by tests and `BeeSyncTestHarness`. Nothing survives the process.
class InMemoryEventStore implements EventStore {
  /// [databasePath] only pretends to be file-backed, so tests can exercise
  /// background scheduling.
  InMemoryEventStore({this.databasePath});

  @override
  final String? databasePath;

  final List<_Row> _rows = [];
  final Map<String, String> _meta = {};
  final Map<String, int> _counters = {};
  final List<BackgroundLogEntry> _bgLog = [];
  int _nextSeq = 1;

  @override
  Future<void> open() async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> insert(NewEvent event) async {
    if (_rows.any((r) => r.id == event.id)) {
      throw StateError('Duplicate event id ${event.id}');
    }
    _rows.add(
      _Row(
        seq: _nextSeq++,
        id: event.id,
        name: event.name,
        payload: event.payload,
        encrypted: event.encrypted,
        priority: event.priority,
        createdAt: event.createdAt,
      ),
    );
  }

  @override
  Future<List<StoredEvent>> claim({
    required String owner,
    required int now,
    required int leaseUntil,
    required int limit,
    bool immediateOnly = false,
  }) async {
    final ready =
        _rows
            .where(
              (r) =>
                  !r.isLeased(now) &&
                  r.nextAttemptAt <= now &&
                  (!immediateOnly || r.priority == Priority.immediate),
            )
            .toList()
          ..sort(_claimOrder);
    for (final r in ready.take(limit)) {
      r
        ..leaseOwner = owner
        ..leaseUntil = leaseUntil;
    }
    final held = _rows.where((r) => r.leaseOwner == owner).toList()
      ..sort(_claimOrder);
    return [for (final r in held) r.toStored()];
  }

  @override
  Future<void> deleteLeased(
    String owner,
    Iterable<String> ids, {
    Map<String, int> counters = const {},
  }) async {
    final set = ids.toSet();
    _rows.removeWhere((r) => r.leaseOwner == owner && set.contains(r.id));
    await incrementCounters(counters);
  }

  @override
  Future<void> releaseRetry(
    String owner,
    Iterable<String> ids, {
    required int nextAttemptAt,
  }) async {
    for (final r in _held(owner, ids)) {
      r
        ..attempts += 1
        ..nextAttemptAt = nextAttemptAt
        ..leaseOwner = null
        ..leaseUntil = null;
    }
  }

  @override
  Future<void> release(String owner, Iterable<String> ids) async {
    for (final r in _held(owner, ids)) {
      r
        ..leaseOwner = null
        ..leaseUntil = null;
    }
  }

  @override
  Future<QueueTotals> totals(int now) async => QueueTotals(
    total: _rows.length,
    inFlight: _rows.where((r) => r.isLeased(now)).length,
    bytes: _rows.fold(0, (sum, r) => sum + r.payload.length),
  );

  @override
  Future<List<QueuedEvent>> inspect({
    required int now,
    int limit = 200,
  }) async => [
    for (final r in _rows.take(limit))
      QueuedEvent(
        id: r.id,
        name: r.name,
        priority: r.priority,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          r.createdAt,
          isUtc: true,
        ),
        attempts: r.attempts,
        nextAttemptAt: r.nextAttemptAt > now
            ? DateTime.fromMillisecondsSinceEpoch(r.nextAttemptAt, isUtc: true)
            : null,
        sizeBytes: r.payload.length,
        inFlight: r.isLeased(now),
        payload: r.payload,
      ),
  ];

  @override
  Future<List<String>> deleteExpired({
    required int createdBefore,
    required int now,
  }) async {
    final expired = _rows
        .where((r) => r.createdAt < createdBefore && !r.isLeased(now))
        .map((r) => r.id)
        .toList();
    final set = expired.toSet();
    _rows.removeWhere((r) => set.contains(r.id));
    return expired;
  }

  @override
  Future<List<String>> evict({
    required int now,
    required int maxEvents,
    required int maxBytes,
  }) async {
    var count = _rows.length;
    var bytes = _rows.fold(0, (sum, r) => sum + r.payload.length);
    final candidates = _rows.where((r) => !r.isLeased(now)).toList()
      ..sort((a, b) {
        final byPriority = a.priority.code.compareTo(b.priority.code);
        return byPriority != 0 ? byPriority : a.seq.compareTo(b.seq);
      });
    final evicted = <String>[];
    for (final r in candidates) {
      if (count <= maxEvents && bytes <= maxBytes) break;
      evicted.add(r.id);
      count--;
      bytes -= r.payload.length;
    }
    final set = evicted.toSet();
    _rows.removeWhere((r) => set.contains(r.id));
    return evicted;
  }

  @override
  Future<List<String>> purge() async {
    final ids = [for (final r in _rows) r.id];
    _rows.clear();
    return ids;
  }

  @override
  Future<void> resetBackoff() async {
    for (final r in _rows) {
      r.nextAttemptAt = 0;
    }
  }

  @override
  Future<String?> getMeta(String key) async => _meta[key];

  @override
  Future<void> setMeta(String key, String value) async => _meta[key] = value;

  @override
  Future<void> deleteMeta(String key) async => _meta.remove(key);

  @override
  Future<void> incrementCounters(Map<String, int> deltas) async {
    for (final e in deltas.entries) {
      if (e.value == 0) continue;
      _counters[e.key] = (_counters[e.key] ?? 0) + e.value;
    }
  }

  @override
  Future<Map<String, int>> counters() async => Map.of(_counters);

  @override
  Future<List<BackgroundLogEntry>> backgroundLog(int limit) async =>
      _bgLog.reversed.take(limit).toList();

  /// Simulates a native uploader writing to `bg_log`.
  void addBackgroundLog(BackgroundLogEntry entry) => _bgLog.add(entry);

  Iterable<_Row> _held(String owner, Iterable<String> ids) {
    final set = ids.toSet();
    return _rows.where((r) => r.leaseOwner == owner && set.contains(r.id));
  }

  static int _claimOrder(_Row a, _Row b) {
    final byPriority = b.priority.code.compareTo(a.priority.code);
    return byPriority != 0 ? byPriority : a.seq.compareTo(b.seq);
  }
}

class _Row {
  _Row({
    required this.seq,
    required this.id,
    required this.name,
    required this.payload,
    required this.encrypted,
    required this.priority,
    required this.createdAt,
  });

  final int seq;
  final String id;
  final String name;
  final Uint8List payload;
  final bool encrypted;
  final Priority priority;
  final int createdAt;
  int attempts = 0;
  int nextAttemptAt = 0;
  String? leaseOwner;
  int? leaseUntil;

  bool isLeased(int now) => leaseOwner != null && leaseUntil! >= now;

  StoredEvent toStored() => StoredEvent(
    seq: seq,
    id: id,
    name: name,
    payload: payload,
    encrypted: encrypted,
    priority: priority,
    createdAt: createdAt,
    sizeBytes: payload.length,
    attempts: attempts,
  );
}
