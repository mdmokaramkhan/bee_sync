// Local endpoint for trying bee_sync end to end.
//
//   dart run tool/test_server.dart [--port 8080] [--mode ok|fail|auth|slow]
//
// POST /events  logs each batch and answers according to the mode:
//   ok    200
//   fail  503 with Retry-After: 30
//   auth  401
//   slow  200 after 10 s
// GET /mode?set=<mode>  switches mode at runtime.
//
// From the Android emulator the host is http://10.0.2.2:<port>/events.
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  var port = 8080;
  var mode = 'ok';
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--port') port = int.parse(args[i + 1]);
    if (args[i] == '--mode') mode = args[i + 1];
  }
  final seen = <String>{};

  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  stdout.writeln('bee_sync test server on :$port, mode=$mode');

  await for (final req in server) {
    if (req.method == 'GET' && req.uri.path == '/mode') {
      mode = req.uri.queryParameters['set'] ?? mode;
      stdout.writeln('mode=$mode');
      req.response.write('mode=$mode\n');
      await req.response.close();
      continue;
    }
    if (req.method != 'POST' || req.uri.path != '/events') {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      continue;
    }

    var bytes = await req.fold<List<int>>([], (a, b) => a..addAll(b));
    if (req.headers.value('content-encoding') == 'gzip') {
      bytes = gzip.decode(bytes);
    }
    final body = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
    final events = (body['events']! as List).cast<Map<String, Object?>>();
    final dupes = events.where((e) => !seen.add(e['id']! as String)).length;
    stdout.writeln(
      '${DateTime.now().toIso8601String()} batch=${body['batch_id']} '
      'sdk="${req.headers.value('x-beesync-sdk')}" mode=$mode '
      'events=${events.length} duplicates=$dupes '
      'names=${events.map((e) => e['name']).join(',')}',
    );

    switch (mode) {
      case 'fail':
        req.response
          ..statusCode = 503
          ..headers.set('Retry-After', '30');
      case 'auth':
        req.response.statusCode = 401;
      case 'slow':
        await Future<void>.delayed(const Duration(seconds: 10));
        req.response.statusCode = 200;
      default:
        req.response.statusCode = 200;
    }
    await req.response.close();
  }
}
