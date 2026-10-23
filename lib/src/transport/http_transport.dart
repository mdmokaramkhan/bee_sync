import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:clock/clock.dart';
import 'package:http/http.dart' as http;

import '../api/models.dart';
import '../version.dart';
import 'event_transport.dart';
import 'wire_format.dart';

/// POSTs batches as JSON to [endpoint]. See doc/DESIGN.md §10 for the
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

  /// Batches with more events than this are encoded (and gzipped) on a
  /// background isolate: a full 512 KB batch takes tens of milliseconds on a
  /// phone, enough to drop frames. Smaller ones aren't worth an isolate.
  static const backgroundEncodingMinEvents = 10;

  @override
  Future<TransportResult> send(EventBatch batch) async {
    final json = encodeBatch(batch, sentAt: clock.now());
    final gzip = this.gzip;
    final body = batch.events.length > backgroundEncodingMinEvents
        ? await Isolate.run(() => _encodeBody(json, gzip: gzip))
        : _encodeBody(json, gzip: gzip);
    final headers = {
      ..._headers,
      'Content-Type': 'application/json',
      'X-BeeSync-Batch-Id': batch.batchId,
      'X-BeeSync-Sdk':
          'bee_sync/$beeSyncVersion (${Platform.operatingSystem}; dart)',
    };
    if (gzip) headers['Content-Encoding'] = 'gzip';

    final http.Response response;
    try {
      // Never follow redirects: dart:io turns a 303 into a body-less GET, whose
      // 200 would mark events delivered. A 3xx is reported as retryable
      // instead (spec/uploader_contract.md §4).
      final request = http.Request('POST', endpoint)
        ..followRedirects = false
        ..headers.addAll(headers)
        ..bodyBytes = body;
      response = await _client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(timeout);
    } on TimeoutException {
      return NetworkFailure('Timed out after ${timeout.inSeconds}s');
    } on Exception catch (e) {
      // SocketException, http.ClientException, TLS errors, ...
      return NetworkFailure('Network error: $e');
    }
    return classify(response.statusCode, response.headers, response.body);
  }

  void close() => _client.close();

  static List<int> _encodeBody(
    Map<String, Object?> json, {
    required bool gzip,
  }) {
    final bytes = utf8.encode(jsonEncode(json));
    return gzip ? GZipCodec().encode(bytes) : bytes;
  }

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

  /// Longest `Retry-After` honoured; larger values are capped to it
  /// (spec/uploader_contract.md §3.1).
  static const maxRetryAfter = Duration(hours: 24);

  /// Parses a `Retry-After` value: delay-seconds or an HTTP date, capped at
  /// [maxRetryAfter].
  static Duration? parseRetryAfter(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    if (RegExp(r'^\d+$').hasMatch(trimmed)) {
      // Compare as digits first: a huge value would overflow int/Duration.
      final seconds = int.tryParse(trimmed);
      if (seconds == null || seconds > maxRetryAfter.inSeconds) {
        return maxRetryAfter;
      }
      return Duration(seconds: seconds);
    }
    if (int.tryParse(trimmed) != null) return null; // negative
    try {
      final delay = HttpDate.parse(value).difference(clock.now());
      if (delay.isNegative) return Duration.zero;
      return delay > maxRetryAfter ? maxRetryAfter : delay;
    } on HttpException {
      return null;
    } on FormatException {
      return null;
    }
  }
}
