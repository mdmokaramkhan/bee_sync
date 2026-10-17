import 'dart:convert';
import 'dart:io';

import 'package:bee_sync/bee_sync.dart';
import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

EventBatch batchOf(List<String> ids) => EventBatch(
  batchId: 'batch-1',
  events: [
    for (final id in ids)
      BatchEvent(
        id: id,
        name: 'evt',
        properties: {'k': 1},
        timestamp: DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
        priority: Priority.immediate,
        attempt: 2,
      ),
  ],
);

void main() {
  group('HttpTransport.send', () {
    test('posts the wire format with headers', () async {
      late http.Request captured;
      final transport = HttpTransport(
        endpoint: Uri.parse('https://example.com/e'),
        headers: {'Authorization': 'Bearer t'},
        client: MockClient((req) async {
          captured = req;
          return http.Response('', 200);
        }),
      );

      final result = await withClock(
        Clock.fixed(DateTime.fromMillisecondsSinceEpoch(5000, isUtc: true)),
        () => transport.send(batchOf(['a'])),
      );

      expect(result, isA<Success>());
      expect(captured.method, 'POST');
      expect(captured.headers['Authorization'], 'Bearer t');
      expect(captured.headers['Content-Type'], startsWith('application/json'));
      expect(captured.headers['X-BeeSync-Batch-Id'], 'batch-1');
      expect(captured.headers['X-BeeSync-Sdk'], startsWith('bee_sync/'));
      expect(jsonDecode(captured.body), {
        'batch_id': 'batch-1',
        'sent_at': 5000,
        'events': [
          {
            'id': 'a',
            'name': 'evt',
            'timestamp': 1000,
            'priority': 'immediate',
            'attempt': 2,
            'properties': {'k': 1},
          },
        ],
      });
    });

    test('gzips the body when enabled', () async {
      late http.Request captured;
      final transport = HttpTransport(
        endpoint: Uri.parse('https://example.com/e'),
        gzip: true,
        client: MockClient((req) async {
          captured = req;
          return http.Response('', 202);
        }),
      );
      await transport.send(batchOf(['a']));
      expect(captured.headers['Content-Encoding'], 'gzip');
      final body = jsonDecode(utf8.decode(gzip.decode(captured.bodyBytes)));
      expect((body as Map)['batch_id'], 'batch-1');
    });

    test('network errors are retryable', () async {
      final transport = HttpTransport(
        endpoint: Uri.parse('https://example.com/e'),
        client: MockClient((_) => throw const SocketException('offline')),
      );
      expect(await transport.send(batchOf(['a'])), isA<RetryableFailure>());
    });

    test('headers can be replaced and are mirrored in config json', () {
      final transport = HttpTransport(
        endpoint: Uri.parse('https://example.com/e'),
        headers: {'a': '1'},
      )..headers = {'b': '2'};
      expect(transport.toConfigJson(), {
        'endpoint': 'https://example.com/e',
        'headers': {'b': '2'},
        'gzip': false,
        'timeout_ms': 30000,
      });
    });
  });

  group('HttpTransport.classify', () {
    TransportResult classify(
      int status, {
      String body = '',
      String? retryAfter,
    }) => HttpTransport.classify(status, {'retry-after': ?retryAfter}, body);

    test('2xx is success, with optional per-event rejects', () {
      expect((classify(200) as Success).rejectedIds, isEmpty);
      expect(
        (classify(200, body: '{"rejected":["x","y"]}') as Success).rejectedIds,
        {'x', 'y'},
      );
      expect((classify(204, body: 'not json') as Success).rejectedIds, isEmpty);
    });

    test('401 and 403 are auth failures', () {
      expect(classify(401), isA<AuthFailure>());
      expect(classify(403), isA<AuthFailure>());
    });

    test('413 is payload too large', () {
      expect(classify(413), isA<PayloadTooLarge>());
    });

    test('408, 429 and 5xx are retryable and honour Retry-After', () {
      expect(classify(408), isA<RetryableFailure>());
      expect(classify(503), isA<RetryableFailure>());
      final r = classify(429, retryAfter: '120') as RetryableFailure;
      expect(r.retryAfter, const Duration(seconds: 120));
    });

    test('other 4xx are permanent', () {
      expect(classify(400), isA<PermanentFailure>());
      expect(classify(422), isA<PermanentFailure>());
    });
  });

  test('parseRetryAfter handles seconds, HTTP dates and garbage', () {
    final now = DateTime.utc(2026, 10, 17, 12);
    withClock(Clock.fixed(now), () {
      expect(HttpTransport.parseRetryAfter('5'), const Duration(seconds: 5));
      expect(
        HttpTransport.parseRetryAfter(
          HttpDate.format(now.add(const Duration(minutes: 2))),
        ),
        const Duration(minutes: 2),
      );
      expect(HttpTransport.parseRetryAfter('soon'), isNull);
      expect(HttpTransport.parseRetryAfter(null), isNull);
    });
  });
}
