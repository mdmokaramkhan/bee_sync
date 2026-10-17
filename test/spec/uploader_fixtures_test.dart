import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bee_sync/bee_sync.dart';
import 'package:bee_sync/src/core/delivery_settings.dart';
import 'package:bee_sync/src/core/flush_controller.dart';
import 'package:bee_sync/src/store/sqflite_store.dart';
import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Runs spec/fixtures through the Dart reference uploader. The Android and
/// iOS uploaders run the same files (spec/uploader_contract.md §6).
void main() {
  sqfliteFfiInit();

  final fixtures =
      Directory('spec/fixtures/uploader')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  test('fixtures exist', () => expect(fixtures, isNotEmpty));

  for (final file in fixtures) {
    final fixture = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    final name = p.basenameWithoutExtension(file.path);
    // Several seeds, so ranged expectations are checked against more than
    // one jitter value.
    for (final seed in [0, 1, 2]) {
      test('$name (seed $seed): ${fixture['description']}', () async {
        await _runFixture(fixture, seed);
      });
    }
  }

  test('wire format matches spec/fixtures/wire_format.json', () async {
    final fixture =
        jsonDecode(File('spec/fixtures/wire_format.json').readAsStringSync())
            as Map<String, Object?>;
    final rig = await _Rig.open();
    addTearDown(rig.close);
    await rig.store.setMeta(MetaKeys.consent, 'granted');
    for (final e in (fixture['events']! as List).cast<Map<String, Object?>>()) {
      await rig.insertRow(
        id: e['id']! as String,
        name: e['name']! as String,
        payload: utf8.encode(e['payload']! as String),
        priority: e['priority']! as int,
        createdAt: e['created_at']! as int,
        attempts: e['attempts']! as int,
      );
    }

    Map<String, Object?>? body;
    final client = MockClient((req) async {
      body = jsonDecode(req.body) as Map<String, Object?>;
      return http.Response('', 200);
    });
    final now = fixture['sent_at']! as int;
    await withClock(Clock.fixed(_time(now)), () async {
      await rig.controller(client, const DeliverySettings()).run(manual: true);
    });

    final expected = Map.of(fixture['expected_body']! as Map<String, Object?>);
    // batch_id is generated per request; check its shape, then the rest.
    expect(body!['batch_id'], matches(RegExp(r'^[0-9a-f-]{36}$')));
    expected.remove('batch_id');
    body!.remove('batch_id');
    expect(body, expected);
  });
}

Future<void> _runFixture(Map<String, Object?> fixture, int seed) async {
  final now = fixture['now']! as int;
  final rig = await _Rig.open();
  addTearDown(rig.close);

  for (final e in (fixture['events']! as List).cast<Map<String, Object?>>()) {
    final raw = e['payload_raw'] as String?;
    await rig.insertRow(
      id: e['id']! as String,
      name: e['name']! as String,
      payload: utf8.encode(raw ?? jsonEncode(e['properties'])),
      priority: e['priority'] == 'immediate' ? 1 : 0,
      createdAt: e['created_at']! as int,
      attempts: e['attempts']! as int,
      nextAttemptAt: e['next_attempt_at']! as int,
      leaseOwner: e['lease_owner'] as String?,
      leaseUntil: e['lease_until'] as int?,
    );
  }
  final meta = {
    MetaKeys.consent: 'granted',
    ...((fixture['meta'] as Map<String, Object?>?) ?? const {}),
  };
  for (final entry in meta.entries) {
    await rig.store.setMeta(entry.key, entry.value! as String);
  }

  final responses = (fixture['responses']! as List)
      .cast<Map<String, Object?>>()
      .toList();
  final requests = <List<String>>[];
  final client = MockClient((req) async {
    final body = jsonDecode(req.body) as Map<String, Object?>;
    requests.add([
      for (final e in (body['events']! as List).cast<Map<String, Object?>>())
        e['id']! as String,
    ]);
    if (requests.length > responses.length) {
      fail('Unexpected request #${requests.length}: ${requests.last}');
    }
    final r = responses[requests.length - 1];
    if (r['network_error'] == true) throw const SocketException('offline');
    return http.Response(
      (r['body'] as String?) ?? '',
      r['status']! as int,
      headers: ((r['headers'] as Map?) ?? const {}).cast<String, String>(),
    );
  });

  final settings = DeliverySettings.fromJson(
    (fixture['delivery_config'] as Map<String, Object?>?) ?? const {},
  );
  final result = await withClock(
    Clock.fixed(_time(now)),
    () => rig
        .controller(client, settings, seed: seed)
        .run(manual: fixture['manual'] == true),
  );

  final expect_ = fixture['expect']! as Map<String, Object?>;
  expect(result.status.name, expect_['status'], reason: 'status');
  expect(requests, expect_['requests'], reason: 'requests');

  final rows = await rig.raw.rawQuery(
    'SELECT id, attempts, next_attempt_at, lease_owner FROM events ORDER BY seq',
  );
  final remaining = (expect_['remaining']! as List)
      .cast<Map<String, Object?>>();
  expect(
    [for (final r in rows) r['id']],
    [for (final r in remaining) r['id']],
    reason: 'remaining ids',
  );
  for (var i = 0; i < rows.length; i++) {
    final id = rows[i]['id'];
    expect(
      rows[i]['lease_owner'],
      isNot(_Rig.owner),
      reason: '$id still leased by the uploader',
    );
    for (final field in ['attempts', 'next_attempt_at']) {
      if (remaining[i].containsKey(field)) {
        _expectValue(rows[i][field], remaining[i][field], '$id.$field');
      }
    }
  }

  final counters = await rig.store.counters()
    ..removeWhere((_, v) => v == 0);
  expect(counters, expect_['counters'] ?? const {}, reason: 'counters');

  final expectedMeta = (expect_['meta'] as Map<String, Object?>?) ?? const {};
  for (final entry in expectedMeta.entries) {
    final actual = await rig.store.getMeta(entry.key);
    if (entry.key == MetaKeys.flushNotBefore) {
      _expectValue(int.parse(actual ?? '0'), entry.value, entry.key);
    } else {
      expect(actual, entry.value, reason: 'meta.${entry.key}');
    }
  }
}

/// [expected] is a number (exact) or {"min", "max"} (inclusive).
void _expectValue(Object? actual, Object? expected, String what) {
  if (expected is Map) {
    expect(
      actual,
      inInclusiveRange(expected['min']! as int, expected['max']! as int),
      reason: what,
    );
  } else {
    expect(actual, expected, reason: what);
  }
}

DateTime _time(int ms) => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);

class _Rig {
  _Rig(this.dir, this.store, this.raw);

  static const owner = 'dart:fixture';

  static Future<_Rig> open() async {
    final dir = await Directory.systemTemp.createTemp('bee_sync_fixture');
    final path = p.join(dir.path, 'bee_sync.db');
    final store = SqfliteEventStore(
      path: path,
      factory: databaseFactoryFfiNoIsolate,
    );
    await store.open();
    // A second connection, like a native runtime would hold.
    final raw = await databaseFactoryFfiNoIsolate.openDatabase(
      path,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    return _Rig(dir, store, raw);
  }

  final Directory dir;
  final SqfliteEventStore store;
  final Database raw;

  Future<void> insertRow({
    required String id,
    required String name,
    required List<int> payload,
    required int priority,
    required int createdAt,
    int attempts = 0,
    int nextAttemptAt = 0,
    String? leaseOwner,
    int? leaseUntil,
  }) => raw.rawInsert(
    'INSERT INTO events (id, name, payload, encrypted, priority, created_at, '
    'size_bytes, attempts, next_attempt_at, lease_owner, lease_until) '
    'VALUES (?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?)',
    [
      id,
      name,
      payload,
      priority,
      createdAt,
      payload.length,
      attempts,
      nextAttemptAt,
      leaseOwner,
      leaseUntil,
    ],
  );

  FlushController controller(
    http.Client client,
    DeliverySettings settings, {
    int seed = 0,
  }) => FlushController(
    store: store,
    transport: HttpTransport(
      endpoint: Uri.parse('https://example.test/events'),
      client: client,
    ),
    settings: settings,
    owner: owner,
    random: Random(seed),
  );

  Future<void> close() async {
    await raw.close();
    await store.close();
    await dir.delete(recursive: true);
  }
}
