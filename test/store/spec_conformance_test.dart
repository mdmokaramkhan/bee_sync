import 'dart:io';

import 'package:bee_sync/src/store/sql.dart' as sql;
import 'package:flutter_test/flutter_test.dart';

/// Parses `-- name: x` sections of a spec file into statements, with
/// comments, trailing semicolons and whitespace differences removed.
Map<String, String> parseSpec(String path) {
  final statements = <String, String>{};
  String? name;
  final buffer = StringBuffer();
  void finish() {
    if (name != null) statements[name] = normalize(buffer.toString());
    buffer.clear();
  }

  for (final line in File(path).readAsLinesSync()) {
    final header = RegExp(r'^-- name: (\w+)').firstMatch(line);
    if (header != null) {
      finish();
      name = header.group(1);
    } else if (!line.trimLeft().startsWith('--')) {
      buffer.writeln(line);
    }
  }
  finish();
  return statements;
}

String normalize(String s) =>
    s.replaceAll(RegExp(r'\s+'), ' ').trim().replaceAll(RegExp(r';$'), '');

void main() {
  test('schema statements match spec/schema.sql', () {
    expect(parseSpec('spec/schema.sql'), {
      'create_events': normalize(sql.createEvents),
      'create_events_ready_index': normalize(sql.createEventsReadyIndex),
      'create_meta': normalize(sql.createMeta),
      'create_bg_log': normalize(sql.createBgLog),
    });
  });

  test('claim protocol statements match spec/claim_protocol.sql', () {
    expect(parseSpec('spec/claim_protocol.sql'), {
      'claim': normalize(sql.claim),
      'select_claimed': normalize(sql.selectClaimed),
      'delete_leased': normalize(sql.deleteLeased),
      'release_retry': normalize(sql.releaseRetry),
      'release': normalize(sql.release),
      'get_meta': normalize(sql.getMeta),
      'set_meta': normalize(sql.setMeta),
    });
  });
}
