import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bee_sync/bee_sync.dart';
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
      expect(await db.getVersion(), 1);
      await db.close();
    });

    test('refuses a database from a newer schema version', () async {
      final db = await databaseFactoryFfiNoIsolate.openDatabase(
        path,
        options: OpenDatabaseOptions(version: 99, onCreate: (_, _) {}),
      );
      await db.close();

      final store = SqfliteEventStore(
        path: path,
        factory: databaseFactoryFfiNoIsolate,
      );
      await expectLater(store.open(), throwsA(isA<BeeSyncException>()));
    });
  });
}
