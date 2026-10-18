import 'dart:convert';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:uuid/uuid.dart';

import '../api/models.dart';
import '../diagnostics/logger.dart';
import '../store/event_store.dart';
import '../transport/event_transport.dart';
import 'delivery_settings.dart';

/// Receives the effects of a flush. Counters are already updated in the
/// store when these are called.
abstract interface class FlushListener {
  void onDelivered(List<String> ids);

  void onDropped(List<String> ids, DropReason reason);

  /// Every transport call, for diagnostics.
  void onRequest(EventBatch batch, TransportResult result, Duration elapsed);
}

enum FlushStatus {
  /// Nothing ready is left to send.
  drained,

  /// A retryable failure stopped the flush; see [FlushResult.retryAt].
  backingOff,

  /// Credentials were refused; waiting for new headers.
  authBlocked,

  /// The flush did not run (consent, auth block, backoff) or was stopped
  /// early (shutdown); see [FlushResult.error].
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

  /// For [FlushStatus.skipped]: `consent`, `auth` or `backoff` when a gate
  /// stopped the run. Otherwise the failure that stopped it.
  final String? error;

  @override
  String toString() =>
      'FlushResult(${status.name}, delivered: $delivered'
      '${error == null ? '' : ', error: $error'})';
}

/// One uploader run, exactly as specified in spec/uploader_contract.md §2–3:
/// check the meta gates, then claim, send and delete / back off / release
/// until nothing is ready. The native uploaders implement the same steps.
class FlushController {
  FlushController({
    required EventStore store,
    required EventTransport transport,
    required DeliverySettings settings,
    required String owner,
    required Random random,
    FlushListener? listener,
    BeeLogger logger = const BeeLogger.silent(),
  }) : _store = store,
       _transport = transport,
       _settings = settings,
       _owner = owner,
       _random = random,
       _listener = listener,
       _log = logger;

  final EventStore _store;
  final EventTransport _transport;
  final DeliverySettings _settings;
  final String _owner;
  final Random _random;
  final FlushListener? _listener;
  final BeeLogger _log;
  static const _uuid = Uuid();

  /// The current run's [run] `shouldContinue`, also checked while splitting.
  bool Function() _keepGoing = () => true;

  /// Runs one upload pass.
  ///
  /// A [manual] run ignores the global backoff and the auth block (the app
  /// asked explicitly) but never consent. [shouldContinue] is checked before
  /// each batch so consent changes and shutdown take effect promptly.
  Future<FlushResult> run({
    bool manual = false,
    bool immediateOnly = false,
    bool Function()? shouldContinue,
  }) async {
    final keepGoing = _keepGoing = shouldContinue ?? () => true;
    if (await _store.getMeta(MetaKeys.consent) != ConsentState.granted.name) {
      return const FlushResult(FlushStatus.skipped, error: 'consent');
    }
    final notBefore =
        int.tryParse(await _store.getMeta(MetaKeys.flushNotBefore) ?? '') ?? 0;
    if (!manual) {
      if (await _store.getMeta(MetaKeys.authBlocked) == '1') {
        return const FlushResult(FlushStatus.skipped, error: 'auth');
      }
      if (clock.now().millisecondsSinceEpoch < notBefore) {
        return FlushResult(
          FlushStatus.skipped,
          retryAt: DateTime.fromMillisecondsSinceEpoch(notBefore),
          error: 'backoff',
        );
      }
    }

    final result = await _drain(immediateOnly, keepGoing);
    switch (result.status) {
      case FlushStatus.drained:
        if (notBefore != 0) await _store.setMeta(MetaKeys.flushNotBefore, '0');
        if (manual) await _store.setMeta(MetaKeys.authBlocked, '0');
      case FlushStatus.backingOff:
        await _store.setMeta(
          MetaKeys.flushNotBefore,
          '${result.retryAt!.millisecondsSinceEpoch}',
        );
      case FlushStatus.authBlocked:
        await _store.setMeta(MetaKeys.authBlocked, '1');
      case FlushStatus.skipped:
        break;
    }
    return result;
  }

  Future<FlushResult> _drain(
    bool immediateOnly,
    bool Function() keepGoing,
  ) async {
    var delivered = 0;
    while (keepGoing()) {
      final now = clock.now().millisecondsSinceEpoch;
      final claimed = await _store.claim(
        owner: _owner,
        now: now,
        leaseUntil: now + _settings.leaseMs,
        limit: _settings.maxBatchSize,
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
      if (i > 0 && bytes > _settings.maxBatchBytes) {
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
    final stopwatch = clock.stopwatch()..start();
    try {
      result = await _transport.send(batch);
    } catch (e, st) {
      _log.log(LogLevel.warn, 'Transport threw', error: e, stackTrace: st);
      final failure = RetryableFailure('Transport threw: $e');
      _listener?.onRequest(batch, failure, stopwatch.elapsed);
      return _retry(readable, failure);
    }
    _listener?.onRequest(batch, result, stopwatch.elapsed);

    switch (result) {
      case Success(:final rejectedIds):
        final ids = [for (final e in readable) e.id];
        final accepted = [
          for (final id in ids)
            if (!rejectedIds.contains(id)) id,
        ];
        final rejected = [
          for (final id in ids)
            if (rejectedIds.contains(id)) id,
        ];
        await _store.deleteLeased(
          _owner,
          ids,
          counters: {
            CounterKeys.sent: accepted.length,
            CounterKeys.dropped(DropReason.rejectedByServer): rejected.length,
          },
        );
        _log.log(LogLevel.debug, 'Delivered ${accepted.length} event(s)');
        if (accepted.isNotEmpty) _listener?.onDelivered(accepted);
        if (rejected.isNotEmpty) {
          _listener?.onDropped(rejected, DropReason.rejectedByServer);
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
    // Splitting can take many requests; stop when the run should end (§3.2).
    if (!_keepGoing()) {
      await _store.release(_owner, [for (final e in events.skip(mid)) e.id]);
      return _Outcome(delivered: first.delivered, stop: FlushStatus.skipped);
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
      if (attempt >= _settings.retry.maxAttempts) {
        exhausted.add(e.id);
      } else {
        retry.add(e.id);
        maxAttempt = max(maxAttempt, attempt);
      }
    }

    var delay = _settings.retry.delayAfter(maxAttempt, _random);
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
    await _store.deleteLeased(
      _owner,
      ids,
      counters: {CounterKeys.dropped(reason): ids.length},
    );
    _listener?.onDropped(ids, reason);
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
