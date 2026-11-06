import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bee_sync/bee_sync.dart';
import 'package:bee_sync/src/store/sql.dart' as sql;
import 'package:bee_sync/src/store/sqflite_store.dart';
import 'package:bee_sync/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'store_contract.dart';

void main() {
  sqfliteFfiInit();

  runStoreContract('InMemoryEventStore', () async => InMemoryEventStore());

  runStoreContract(
    'SqfliteEventStore',
    () async => SqfliteEventStore(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfiNoIsolate,
    ),
  );

  group('SqfliteEventStore on disk', () {
    late Directory dir;
    late String path;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('bee_sync_test');
      path = p.join(dir.path, 'bee_sync.db');
    });
    tearDown(() => dir.delete(recursive: true));

    test('events and meta survive reopening; WAL is enabled', () async {
      var store = SqfliteEventStore(
        path: path,
        factory: databaseFactoryFfiNoIsolate,
      );
      await store.open();
      await store.insert(
        NewEvent(
          id: 'a',
          name: 'n',
          payload: Uint8List.fromList(utf8.encode('{}')),
          priority: Priority.normal,
          createdAt: 1,
        ),
      );
      await store.setMeta('consent_state', 'denied');
      await store.close();

      store = SqfliteEventStore(
        path: path,
        factory: databaseFactoryFfiNoIsolate,
      );
      await store.open();
      expect((await store.totals(0)).total, 1);
      expect(await store.getMeta('consent_state'), 'denied');
      await store.close();

      final db = await databaseFactoryFfiNoIsolate.openDatabase(path);
      final mode = await db.rawQuery('PRAGMA journal_mode');
      expect(mode.single.values.single, 'wal');
      expect(await db.getVersion(), 2);
      await db.close();
    });

    test('migrates a v1 database, carrying counters over', () async {
      final v1 = await databaseFactoryFfiNoIsolate.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) async {
            for (final stmt in [
              sql.createEvents,
              sql.createEventsReadyIndex,
              sql.createMeta,
              sql.createBgLog,
            ]) {
              await db.execute(stmt);
            }
            await db.rawInsert(sql.setMeta, [
              'counters',
              '{"sent": 7, "dropped": {"overflow": 2}}',
            ]);
          },
        ),
      );
      await v1.close();

      final store = SqfliteEventStore(
        path: path,
        factory: databaseFactoryFfiNoIsolate,
      );
      await store.open();
      expect(await store.counters(), {'sent': 7, 'dropped.overflow': 2});
      expect(await store.getMeta('counters'), isNull);
      await store.close();
    });

    test('reads the background log written by native code', () async {
      final store = SqfliteEventStore(
        path: path,
        factory: databaseFactoryFfiNoIsolate,
      );
      await store.open();
      final native = await databaseFactoryFfiNoIsolate.openDatabase(
        path,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      await native.rawInsert(sql.insertBgLog, [
        1000,
        'android_worker',
        'info',
        'one',
      ]);
      await native.rawInsert(sql.insertBgLog, [
        2000,
        'android_worker',
        'warn',
        'two',
      ]);
      await native.rawInsert(sql.insertBgLog, [
        3000,
        'ios_bgtask',
        'info',
        'three',
      ]);
      await native.rawDelete(sql.trimBgLog, [2]);
      await native.close();

      final log = await store.backgroundLog(10);
      expect([for (final e in log) e.message], ['three', 'two']);
      expect(log.first.source, 'ios_bgtask');
      expect(log.first.at.millisecondsSinceEpoch, 3000);
      await store.close();
    });

    test('a resolving store asks for its path only when opened', () async {
      var asked = 0;
      final store = SqfliteEventStore.resolving(() async {
        asked++;
        return path;
      }, factory: databaseFactoryFfiNoIsolate);
      expect(store.databasePath, isNull);
      expect(asked, 0);

      await store.open();
      addTearDown(store.close);
      expect(store.databasePath, path);
      expect(asked, 1);
    });

    test('recreates a database from a newer schema version', () async {
      final db = await databaseFactoryFfiNoIsolate.openDatabase(
        path,
        options: OpenDatabaseOptions(version: 99, onCreate: (_, _) {}),
      );
      await db.close();

      final store = SqfliteEventStore(
        path: path,
        factory: databaseFactoryFfiNoIsolate,
      );
      await store.open();
      addTearDown(store.close);

      expect(store.recreatedAfter, isA<BeeSyncException>());
      expect((await store.totals(0)).total, 0);
    });

    test('recreates a file that is not a database', () async {
      File(path).writeAsStringSync('not a sqlite file' * 100);

      final store = SqfliteEventStore(
        path: path,
        factory: databaseFactoryFfiNoIsolate,
      );
      await store.open();
      addTearDown(store.close);

      expect(store.recreatedAfter, isNotNull);
      expect((await store.totals(0)).total, 0);
    });
  });
}
