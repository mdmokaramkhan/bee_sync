// Local endpoint for testing bee_sync end to end. See doc/test-plan.md.
//
//   dart run tool/test_server.dart [--port 8080] [--mode <mode>]
//
// POST /events  logs each batch and answers according to the mode:
//   ok        200
//   fail      503 with Retry-After: 30
//   flaky     503 and 200, alternating
//   auth      401
//   slow      200 after 10 s
//   redirect  302 to /moved (bee_sync must not follow it)
//   reject    400 for every batch (bee_sync splits, then drops each event)
//   partial   200, but lists the batch's first event in "rejected"
//   toolarge  413 for batches of more than one event, 200 for single events
//
// GET /mode?set=<mode>  switch mode at runtime
// GET /stats            totals since start (or the last reset)
// GET /reset            clear the totals
//
// Hosts: Android emulator http://10.0.2.2:<port>/events, iOS Simulator
// http://localhost:<port>/events, physical devices http://<your-mac>.local:<port>/events
import 'dart:convert';
import 'dart:io';

const _modes = {
  'ok',
  'fail',
  'flaky',
  'auth',
  'slow',
  'redirect',
  'reject',
  'partial',
  'toolarge', //
};

Future<void> main(List<String> args) async {
  var port = 8080;
  var mode = 'ok';
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--port') port = int.parse(args[i + 1]);
    if (args[i] == '--mode') mode = args[i + 1];
  }
  final stats = _Stats();
  var flakyToggle = false;

  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  stdout.writeln('bee_sync test server on :$port, mode=$mode');

  await for (final req in server) {
    final res = req.response;
    if (req.method == 'GET' && req.uri.path == '/mode') {
      final wanted = req.uri.queryParameters['set'];
      if (wanted != null && !_modes.contains(wanted)) {
        res
          ..statusCode = HttpStatus.badRequest
          ..write('unknown mode "$wanted"; one of: ${_modes.join(', ')}\n');
      } else {
        mode = wanted ?? mode;
        stdout.writeln('mode=$mode');
        res.write('mode=$mode\n');
      }
      await res.close();
      continue;
    }
    if (req.method == 'GET' && req.uri.path == '/stats') {
      res.headers.contentType = ContentType.json;
      res.write(
        '${const JsonEncoder.withIndent('  ').convert(stats.toJson())}\n',
      );
      await res.close();
      continue;
    }
    if (req.method == 'GET' && req.uri.path == '/reset') {
      stats.reset();
      stdout.writeln('stats reset');
      res.write('reset\n');
      await res.close();
      continue;
    }
    if (req.method != 'POST' || req.uri.path != '/events') {
      // Includes GET /moved: if this is ever logged, a redirect was followed.
      stdout.writeln('unexpected ${req.method} ${req.uri.path}');
      res.statusCode = HttpStatus.notFound;
      await res.close();
      continue;
    }

    var bytes = await req.fold<List<int>>([], (a, b) => a..addAll(b));
    if (req.headers.value('content-encoding') == 'gzip') {
      bytes = gzip.decode(bytes);
    }
    final body = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
    final events = (body['events']! as List).cast<Map<String, Object?>>();
    final sdk = req.headers.value('x-beesync-sdk') ?? '?';
    final uploader = RegExp(r'; (\w+)\)$').firstMatch(sdk)?.group(1) ?? sdk;

    // Decide the answer before counting, so only accepted events count.
    var status = 200;
    var answer = '';
    final accepted = <Map<String, Object?>>[];
    switch (mode) {
      case 'fail':
        status = 503;
        res.headers.set('Retry-After', '30');
      case 'flaky':
        flakyToggle = !flakyToggle;
        status = flakyToggle ? 503 : 200;
      case 'auth':
        status = 401;
      case 'slow':
        await Future<void>.delayed(const Duration(seconds: 10));
      case 'redirect':
        status = 302;
        res.headers.set('Location', '/moved');
      case 'reject':
        status = 400;
      case 'partial':
        answer = jsonEncode({
          'rejected': [events.first['id']],
        });
      case 'toolarge':
        if (events.length > 1) status = 413;
    }
    if (status >= 200 && status < 300) {
      accepted.addAll(mode == 'partial' ? events.skip(1) : events);
    }
    final dupes = stats.record(uploader, events.length, accepted);

    stdout.writeln(
      '${DateTime.now().toIso8601String()} $status mode=$mode from=$uploader '
      'events=${events.length} stored=${accepted.length} duplicates=$dupes '
      'attempts=${events.map((e) => e['attempt']).toSet().join('/')} '
      'names=${events.map((e) => e['name']).join(',')}',
    );
    res.statusCode = status;
    if (answer.isNotEmpty) res.write(answer);
    await res.close();
  }
}

/// What the server has accepted, for checking "every event exactly once".
class _Stats {
  int requests = 0;
  int eventsReceived = 0;
  int duplicates = 0;
  final stored = <String>{};
  final byUploader = <String, int>{};

  int record(
    String uploader,
    int received,
    List<Map<String, Object?>> accepted,
  ) {
    requests++;
    eventsReceived += received;
    var dupes = 0;
    for (final e in accepted) {
      if (!stored.add(e['id']! as String)) dupes++;
    }
    duplicates += dupes;
    byUploader[uploader] = (byUploader[uploader] ?? 0) + accepted.length;
    return dupes;
  }

  void reset() {
    requests = 0;
    eventsReceived = 0;
    duplicates = 0;
    stored.clear();
    byUploader.clear();
  }

  Map<String, Object?> toJson() => {
    'requests': requests,
    'events_received': eventsReceived,
    'unique_events_stored': stored.length,
    'duplicates': duplicates,
    'stored_by_uploader': byUploader,
  };
}
