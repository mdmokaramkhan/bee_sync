import 'dart:convert';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import '../api/errors.dart';
import '../api/models.dart';
import 'event_store.dart';
import 'sql.dart' as sql;

/// [EventStore] backed by SQLite through sqflite.
///
/// sqflite uses the platform's system SQLite library, the same one the native
/// background uploaders use, which keeps POSIX file locks consistent within
/// the process (see doc/DESIGN.md §2.1).
class SqfliteEventStore implements EventStore {
  SqfliteEventStore({required this.path, DatabaseFactory? factory})
    : _factory = factory ?? databaseFactory;

  /// Database file path, or [inMemoryDatabasePath].
  final String path;
  final DatabaseFactory _factory;
  Database? _db;

  @override
  String? get databasePath => path == inMemoryDatabasePath ? null : path;

  Database get _database {
    final db = _db;
    if (db == null) throw StateError('SqfliteEventStore is not open');
    return db;
  }

  @override
  Future<void> open() async {
    _db = await _factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: sql.schemaVersion,
        onConfigure: (db) async {
          // Both PRAGMAs return a row, so they must go through rawQuery.
          await db.rawQuery('PRAGMA journal_mode = WAL');
          await db.rawQuery('PRAGMA busy_timeout = 5000');
        },
        onCreate: (db, version) async {
          final batch = db.batch()
            ..execute(sql.createEvents)
            ..execute(sql.createEventsReadyIndex)
            ..execute(sql.createMeta)
            ..execute(sql.createBgLog)
            ..execute(sql.createCounters);
          await batch.commit(noResult: true);
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) await _migrateV1ToV2(db);
        },
        onDowngrade: (db, oldVersion, newVersion) {
          throw BeeSyncException(
            'bee_sync database is schema v$oldVersion but this version of '
            'bee_sync only understands up to v$newVersion. Was the app '
            'downgraded?',
          );
        },
      ),
    );
  }

  @override
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  @override
  Future<void> insert(NewEvent event) async {
    await _database.rawInsert(sql.insertEvent, _insertArgs(event));
  }

  @override
  Future<QueueTotals> insertAndCount(NewEvent event, {required int now}) async {
    // Two plain calls, deliberately not a batch: sqflite's Batch.commit()
    // wraps the batch in its own transaction (BEGIN, batch, COMMIT = three
    // platform calls plus a Dart-side lock), which measured slower per
    // track() than this. The count may include events inserted concurrently,
    // which is fine for its uses (eviction check, flushAt trigger).
    await _database.rawInsert(sql.insertEvent, _insertArgs(event));
    return totals(now);
  }

  static List<Object?> _insertArgs(NewEvent event) => [
    event.id,
    event.name,
    event.payload,
    event.encrypted ? 1 : 0,
    event.priority.code,
    event.createdAt,
    event.sizeBytes,
  ];

  @override
  Future<List<StoredEvent>> claim({
    required String owner,
    required int now,
    required int leaseUntil,
    required int limit,
    bool immediateOnly = false,
  }) {
    return _database.transaction((txn) async {
      await txn.rawUpdate(sql.claim, [
        owner,
        leaseUntil,
        now,
        now,
        immediateOnly ? 1 : 0,
        limit,
      ]);
      final rows = await txn.rawQuery(sql.selectClaimed, [owner]);
      return rows.map(_toStoredEvent).toList();
    });
  }

  @override
  Future<void> deleteLeased(
    String owner,
    Iterable<String> ids, {
    Map<String, int> counters = const {},
  }) async {
    final list = ids.toList();
    if (list.isEmpty && counters.isEmpty) return;
    await _database.transaction((txn) async {
      if (list.isNotEmpty) {
        await txn.rawDelete(sql.expandIds(sql.deleteLeased, list.length), [
          owner,
          ...list,
        ]);
      }
      await _increment(txn, counters);
    });
  }

  @override
  Future<void> releaseRetry(
    String owner,
    Iterable<String> ids, {
    required int nextAttemptAt,
    bool countAttempt = true,
  }) async {
    final list = ids.toList();
    if (list.isEmpty) return;
    final statement = countAttempt ? sql.releaseRetry : sql.releaseBackoff;
    await _database.rawUpdate(sql.expandIds(statement, list.length), [
      nextAttemptAt,
      owner,
      ...list,
    ]);
  }

  @override
  Future<void> release(String owner, Iterable<String> ids) async {
    final list = ids.toList();
    if (list.isEmpty) return;
    await _database.rawUpdate(sql.expandIds(sql.release, list.length), [
      owner,
      ...list,
    ]);
  }

  @override
  Future<QueueTotals> totals(int now) async {
    final row = (await _database.rawQuery(sql.totals, [now])).single;
    return QueueTotals(
      total: row['total']! as int,
      inFlight: row['in_flight']! as int,
      bytes: row['bytes']! as int,
    );
  }

  @override
  Future<List<QueuedEvent>> inspect({required int now, int limit = 200}) async {
    final rows = await _database.rawQuery(sql.inspectEvents, [limit]);
    return [
      for (final r in rows)
        QueuedEvent(
          id: r['id']! as String,
          name: r['name']! as String,
          priority: Priority.fromCode(r['priority']! as int),
          createdAt: DateTime.fromMillisecondsSinceEpoch(
            r['created_at']! as int,
            isUtc: true,
          ),
          attempts: r['attempts']! as int,
          nextAttemptAt: _nextAttempt(r['next_attempt_at']! as int, now),
          sizeBytes: r['size_bytes']! as int,
          inFlight:
              r['lease_owner'] != null && (r['lease_until']! as int) >= now,
          payload: r['payload']! as Uint8List,
        ),
    ];
  }

  static DateTime? _nextAttempt(int at, int now) =>
      at > now ? DateTime.fromMillisecondsSinceEpoch(at, isUtc: true) : null;

  @override
  Future<List<String>> deleteExpired({
    required int createdBefore,
    required int now,
  }) {
    return _database.transaction((txn) async {
      final rows = await txn.rawQuery(sql.selectExpired, [createdBefore, now]);
      final ids = [for (final r in rows) r['id']! as String];
      await _deleteIds(txn, ids);
      return ids;
    });
  }

  @override
  Future<List<String>> evict({
    required int now,
    required int maxEvents,
    required int maxBytes,
  }) {
    return _database.transaction((txn) async {
      final t = (await txn.rawQuery(sql.totals, [now])).single;
      var count = t['total']! as int;
      var bytes = t['bytes']! as int;
      if (count <= maxEvents && bytes <= maxBytes) return const <String>[];

      final ids = <String>[];
      final rows = await txn.rawQuery(sql.selectEvictable, [now]);
      for (final r in rows) {
        if (count <= maxEvents && bytes <= maxBytes) break;
        ids.add(r['id']! as String);
        count--;
        bytes -= r['size_bytes']! as int;
      }
      await _deleteIds(txn, ids);
      return ids;
    });
  }

  @override
  Future<List<String>> purge() {
    return _database.transaction((txn) async {
      final rows = await txn.rawQuery(sql.selectAllIds);
      await txn.rawDelete(sql.deleteAll);
      return [for (final r in rows) r['id']! as String];
    });
  }

  @override
  Future<void> resetBackoff() => _database.rawUpdate(sql.resetBackoff);

  @override
  Future<String?> getMeta(String key) async {
    final rows = await _database.rawQuery(sql.getMeta, [key]);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  @override
  Future<void> setMeta(String key, String value) async {
    await _database.rawInsert(sql.setMeta, [key, value]);
  }

  @override
  Future<void> deleteMeta(String key) async {
    await _database.rawDelete(sql.deleteMeta, [key]);
  }

  @override
  Future<void> incrementCounters(Map<String, int> deltas) async {
    if (deltas.isEmpty) return;
    await _database.transaction((txn) => _increment(txn, deltas));
  }

  @override
  Future<Map<String, int>> counters() async {
    final rows = await _database.rawQuery(sql.selectCounters);
    return {for (final r in rows) r['key']! as String: r['value']! as int};
  }

  @override
  Future<List<BackgroundLogEntry>> backgroundLog(int limit) async {
    final rows = await _database.rawQuery(sql.selectBgLog, [limit]);
    return [
      for (final r in rows)
        BackgroundLogEntry(
          at: DateTime.fromMillisecondsSinceEpoch(r['at']! as int, isUtc: true),
          source: r['source']! as String,
          level: r['level']! as String,
          message: r['message']! as String,
        ),
    ];
  }

  static Future<void> _increment(
    DatabaseExecutor db,
    Map<String, int> deltas,
  ) async {
    for (final e in deltas.entries) {
      if (e.value == 0) continue;
      await db.rawInsert(sql.ensureCounter, [e.key]);
      await db.rawUpdate(sql.incrementCounter, [e.value, e.key]);
    }
  }

  /// v1 kept counters as JSON in `meta.counters`; v2 has a table that every
  /// uploader can increment atomically.
  static Future<void> _migrateV1ToV2(Database db) async {
    await db.execute(sql.createCounters);
    final rows = await db.rawQuery(sql.getMeta, ['counters']);
    if (rows.isEmpty) return;
    final deltas = <String, int>{};
    try {
      final json = jsonDecode(rows.first['value']! as String) as Map;
      final sent = json['sent'];
      if (sent is int) deltas['sent'] = sent;
      final dropped = json['dropped'];
      if (dropped is Map) {
        for (final e in dropped.entries) {
          if (e.value is int) deltas['dropped.${e.key}'] = e.value as int;
        }
      }
    } on Object {
      // Corrupt counters are not worth failing an upgrade for.
    }
    await _increment(db, deltas);
    await db.rawDelete(sql.deleteMeta, ['counters']);
  }

  static Future<void> _deleteIds(DatabaseExecutor db, List<String> ids) async {
    // Stay well under SQLite's 999 host-parameter limit on old Android.
    const chunk = 500;
    for (var i = 0; i < ids.length; i += chunk) {
      final part = ids.sublist(i, (i + chunk).clamp(0, ids.length));
      await db.rawDelete(sql.expandIds(sql.deleteByIds, part.length), part);
    }
  }

  static StoredEvent _toStoredEvent(Map<String, Object?> row) => StoredEvent(
    seq: row['seq']! as int,
    id: row['id']! as String,
    name: row['name']! as String,
    payload: row['payload']! as Uint8List,
    encrypted: row['encrypted'] == 1,
    priority: Priority.fromCode(row['priority']! as int),
    createdAt: row['created_at']! as int,
    sizeBytes: row['size_bytes']! as int,
    attempts: row['attempts']! as int,
  );
}
