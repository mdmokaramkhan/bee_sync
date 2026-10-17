import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:http/http.dart' as http;

import '../api/models.dart';
import '../version.dart';
import 'event_transport.dart';
import 'wire_format.dart';

/// POSTs batches as JSON to [endpoint]. See docs/DESIGN.md §10 for the
/// format and how responses are interpreted.
///
/// This is the only transport the native background uploaders can replay, so
/// its settings are mirrored into the on-device database.
class HttpTransport implements EventTransport {
  HttpTransport({
    required this.endpoint,
    Map<String, String> headers = const {},
    this.gzip = false,
    this.timeout = const Duration(seconds: 30),
    http.Client? client,
  }) : _headers = Map.of(headers),
       _client = client ?? http.Client();

  final Uri endpoint;
  final bool gzip;
  final Duration timeout;
  final http.Client _client;
  Map<String, String> _headers;

  Map<String, String> get headers => Map.unmodifiable(_headers);

  /// Replaces the custom headers, e.g. after an auth token refresh.
  /// Prefer `BeeSync.setHeaders`, which also persists them and resumes
  /// flushing after an auth failure.
  set headers(Map<String, String> value) => _headers = Map.of(value);

  /// Settings mirrored to the database for the native uploaders.
  Map<String, Object?> toConfigJson() => {
    'endpoint': endpoint.toString(),
    'headers': _headers,
    'gzip': gzip,
    'timeout_ms': timeout.inMilliseconds,
  };

  @override
  Future<TransportResult> send(EventBatch batch) async {
    List<int> body = utf8.encode(
      jsonEncode(encodeBatch(batch, sentAt: clock.now())),
    );
    final headers = {
      ..._headers,
      'Content-Type': 'application/json',
      'X-BeeSync-Batch-Id': batch.batchId,
      'X-BeeSync-Sdk':
          'bee_sync/$beeSyncVersion (${Platform.operatingSystem}; dart)',
    };
    if (gzip) {
      body = GZipCodec().encode(body);
      headers['Content-Encoding'] = 'gzip';
    }

    final http.Response response;
    try {
      response = await _client
          .post(endpoint, headers: headers, body: body)
          .timeout(timeout);
    } on TimeoutException {
      return RetryableFailure('Timed out after ${timeout.inSeconds}s');
    } on Exception catch (e) {
      // SocketException, http.ClientException, TLS errors, ...
      return RetryableFailure('Network error: $e');
    }
    return classify(response.statusCode, response.headers, response.body);
  }

  void close() => _client.close();

  /// Maps an HTTP response to a [TransportResult].
  static TransportResult classify(
    int status,
    Map<String, String> headers,
    String body,
  ) {
    if (status >= 200 && status < 300) {
      Object? decoded;
      try {
        decoded = body.isEmpty ? null : jsonDecode(body);
      } on FormatException {
        decoded = null;
      }
      return Success(rejectedIds: parseRejectedIds(decoded));
    }
    final reason = 'HTTP $status';
    if (status == 401 || status == 403) return AuthFailure(reason);
    if (status == 413) return const PayloadTooLarge();
    if (status == 408 || status == 429 || status >= 500) {
      return RetryableFailure(
        reason,
        retryAfter: parseRetryAfter(headers['retry-after']),
      );
    }
    if (status >= 400) return PermanentFailure(reason);
    // 1xx/3xx: most likely a misconfigured endpoint. Keep the events.
    return RetryableFailure('Unexpected $reason');
  }

  /// Parses a `Retry-After` value: delay-seconds or an HTTP date.
  static Duration? parseRetryAfter(String? value) {
    if (value == null) return null;
    final seconds = int.tryParse(value.trim());
    if (seconds != null) return seconds < 0 ? null : Duration(seconds: seconds);
    try {
      final delay = HttpDate.parse(value).difference(clock.now());
      return delay.isNegative ? Duration.zero : delay;
    } on HttpException {
      return null;
    } on FormatException {
      return null;
    }
  }
}
