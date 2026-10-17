import 'dart:convert';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:uuid/uuid.dart';

import '../api/config.dart';
import '../api/models.dart';
import '../diagnostics/logger.dart';
import '../store/event_store.dart';
import '../transport/event_transport.dart';

/// Receives the effects of a flush.
abstract interface class FlushListener {
  void onDelivered(List<String> ids);

  void onDropped(List<String> ids, DropReason reason);
}

enum FlushStatus {
  /// Nothing ready is left to send.
  drained,

  /// A retryable failure stopped the flush; see [FlushResult.retryAt].
  backingOff,

  /// Credentials were refused; waiting for new headers.
  authBlocked,

  /// The flush did not run, or was stopped early (consent, shutdown).
  skipped,
}

class FlushResult {
  const FlushResult(
    this.status, {
    this.delivered = 0,
    this.retryAt,
    this.error,
  });

  final FlushStatus status;

  /// Events acknowledged by the server during this flush.
  final int delivered;
  final DateTime? retryAt;
  final String? error;

  @override
  String toString() =>
      'FlushResult(${status.name}, delivered: $delivered'
      '${error == null ? '' : ', error: $error'})';
}

/// One uploader run of the claim protocol (docs/DESIGN.md §5): claim a
/// batch, send it, then delete, back off or release, until nothing is ready.
class FlushController {
  FlushController({
    required EventStore store,
    required EventTransport transport,
    required BeeSyncConfig config,
    required String owner,
    required Random random,
    required FlushListener listener,
  }) : _store = store,
       _transport = transport,
       _config = config,
       _owner = owner,
       _random = random,
       _listener = listener;

  final EventStore _store;
  final EventTransport _transport;
  final BeeSyncConfig _config;
  final String _owner;
  final Random _random;
  final FlushListener _listener;
  static const _uuid = Uuid();

  BeeLogger get _log => _config.logger;

  /// Runs until drained or stopped. [shouldContinue] is checked before each
  /// batch so consent changes and shutdown take effect promptly.
  Future<FlushResult> run({
    bool immediateOnly = false,
    required bool Function() shouldContinue,
  }) async {
    var delivered = 0;
    while (shouldContinue()) {
      final now = clock.now().millisecondsSinceEpoch;
      final claimed = await _store.claim(
        owner: _owner,
        now: now,
        leaseUntil: now + _config.leaseDuration.inMilliseconds,
        limit: _config.batching.maxBatchSize,
        immediateOnly: immediateOnly,
      );
      if (claimed.isEmpty) {
        return FlushResult(FlushStatus.drained, delivered: delivered);
      }

      final batch = _trimToBytes(claimed);
      if (batch.length < claimed.length) {
        await _store.release(_owner, [
          for (final e in claimed.skip(batch.length)) e.id,
        ]);
      }

      final outcome = await _send(batch);
      delivered += outcome.delivered;
      if (outcome.stop != null) {
        return FlushResult(
          outcome.stop!,
          delivered: delivered,
          retryAt: outcome.retryAt,
          error: outcome.error,
        );
      }
    }
    return FlushResult(FlushStatus.skipped, delivered: delivered);
  }

  List<StoredEvent> _trimToBytes(List<StoredEvent> events) {
    var bytes = 0;
    for (var i = 0; i < events.length; i++) {
      bytes += events[i].sizeBytes;
      // Always send at least one event, even if it alone exceeds the limit.
      if (i > 0 && bytes > _config.batching.maxBatchBytes) {
        return events.sublist(0, i);
      }
    }
    return events;
  }

  /// Sends [events], splitting the batch on 413 and bisecting on permanent
  /// failures to isolate the events the server refuses.
  Future<_Outcome> _send(List<StoredEvent> events) async {
    final decoded = <BatchEvent>[];
    final unreadable = <String>[];
    for (final e in events) {
      final batchEvent = _decode(e);
      batchEvent == null ? unreadable.add(e.id) : decoded.add(batchEvent);
    }
    if (unreadable.isNotEmpty) {
      await _drop(unreadable, DropReason.unreadable);
    }
    if (decoded.isEmpty) return const _Outcome();
    final readable = [
      for (final e in events)
        if (!unreadable.contains(e.id)) e,
    ];

    final batch = EventBatch(batchId: _uuid.v4(), events: decoded);
    final TransportResult result;
    try {
      result = await _transport.send(batch);
    } catch (e, st) {
      _log.log(LogLevel.warn, 'Transport threw', error: e, stackTrace: st);
      return _retry(readable, RetryableFailure('Transport threw: $e'));
    }

    switch (result) {
      case Success(:final rejectedIds):
        final ids = [for (final e in readable) e.id];
        await _store.deleteLeased(_owner, ids);
        final accepted = [
          for (final id in ids)
            if (!rejectedIds.contains(id)) id,
        ];
        final rejected = [
          for (final id in ids)
            if (rejectedIds.contains(id)) id,
        ];
        _log.log(LogLevel.debug, 'Delivered ${accepted.length} event(s)');
        if (accepted.isNotEmpty) _listener.onDelivered(accepted);
        if (rejected.isNotEmpty) {
          _listener.onDropped(rejected, DropReason.rejectedByServer);
        }
        return _Outcome(delivered: accepted.length);

      case RetryableFailure():
        return _retry(readable, result);

      case AuthFailure(:final reason):
        _log.log(LogLevel.warn, 'Auth failure ($reason); pausing uploads');
        await _store.release(_owner, [for (final e in readable) e.id]);
        return _Outcome(stop: FlushStatus.authBlocked, error: reason);

      case PayloadTooLarge():
        return _splitOrDrop(readable, DropReason.tooLarge, 'HTTP 413');

      case PermanentFailure(:final reason):
        return _splitOrDrop(readable, DropReason.rejectedByServer, reason);
    }
  }

  Future<_Outcome> _splitOrDrop(
    List<StoredEvent> events,
    DropReason reason,
    String error,
  ) async {
    if (events.length == 1) {
      _log.log(LogLevel.warn, 'Dropping event ${events.single.id}: $error');
      await _drop([events.single.id], reason);
      return const _Outcome();
    }
    final mid = events.length ~/ 2;
    final first = await _send(events.sublist(0, mid));
    if (first.stop != null) {
      await _store.release(_owner, [for (final e in events.skip(mid)) e.id]);
      return first;
    }
    final second = await _send(events.sublist(mid));
    return second.plusDelivered(first.delivered);
  }

  Future<_Outcome> _retry(
    List<StoredEvent> events,
    RetryableFailure failure,
  ) async {
    final now = clock.now();
    final exhausted = <String>[];
    final retry = <String>[];
    var maxAttempt = 1;
    for (final e in events) {
      final attempt = e.attempts + 1;
      if (attempt >= _config.retry.maxAttempts) {
        exhausted.add(e.id);
      } else {
        retry.add(e.id);
        maxAttempt = max(maxAttempt, attempt);
      }
    }

    var delay = _config.retry.delayAfter(maxAttempt, _random);
    final retryAfter = failure.retryAfter;
    if (retryAfter != null && retryAfter > delay) delay = retryAfter;
    final retryAt = now.add(delay);

    if (exhausted.isNotEmpty) await _drop(exhausted, DropReason.maxAttempts);
    await _store.releaseRetry(
      _owner,
      retry,
      nextAttemptAt: retryAt.millisecondsSinceEpoch,
    );
    _log.log(
      LogLevel.info,
      'Flush failed (${failure.reason}); retrying in ${delay.inSeconds}s',
    );
    return _Outcome(
      stop: FlushStatus.backingOff,
      retryAt: retryAt,
      error: failure.reason,
    );
  }

  Future<void> _drop(List<String> ids, DropReason reason) async {
    await _store.deleteLeased(_owner, ids);
    _listener.onDropped(ids, reason);
  }

  BatchEvent? _decode(StoredEvent e) {
    try {
      final properties = jsonDecode(utf8.decode(e.payload));
      if (properties is! Map<String, Object?>) return null;
      return BatchEvent(
        id: e.id,
        name: e.name,
        properties: properties,
        timestamp: DateTime.fromMillisecondsSinceEpoch(
          e.createdAt,
          isUtc: true,
        ),
        priority: e.priority,
        attempt: e.attempts + 1,
      );
    } on FormatException {
      return null;
    }
  }
}

class _Outcome {
  const _Outcome({this.delivered = 0, this.stop, this.retryAt, this.error});

  final int delivered;

  /// Non-null when the flush must stop.
  final FlushStatus? stop;
  final DateTime? retryAt;
  final String? error;

  _Outcome plusDelivered(int n) => _Outcome(
    delivered: delivered + n,
    stop: stop,
    retryAt: retryAt,
    error: error,
  );
}
