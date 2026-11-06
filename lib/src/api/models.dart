import 'dart:convert';

/// Delivery priority of an event.
enum Priority {
  /// Batched; sent when a batch threshold, timer or lifecycle trigger fires.
  normal(0, 'normal'),

  /// Persisted, then sent right away (after a short debounce that coalesces
  /// bursts).
  immediate(1, 'immediate');

  const Priority(this.code, this.wireName);

  /// Value stored in the `priority` column.
  final int code;

  /// Value sent in the wire format.
  final String wireName;

  static Priority fromCode(int code) =>
      code == immediate.code ? immediate : normal;
}

/// The user's tracking consent.
enum ConsentState {
  granted,
  denied,

  /// Not asked yet. See `UnknownConsentBehavior`.
  unknown,
}

/// Why events were removed without being delivered.
enum DropReason {
  /// Evicted, or rejected, to keep the queue within `RetentionPolicy` limits.
  overflow,

  /// Older than `RetentionPolicy.maxAge`.
  expired,

  /// Failed `RetryPolicy.maxAttempts` times.
  maxAttempts,

  /// The server permanently rejected the event (non-retryable 4xx, or listed
  /// in the response's `rejected` ids).
  rejectedByServer,

  /// The server returned 413 for a batch containing only this event.
  tooLarge,

  /// Tracked or purged while consent was not granted.
  noConsent,

  /// The stored payload could not be decoded.
  unreadable,

  /// Removed by `BeeSync.purgeQueue()`.
  purged,

  /// Refused by `track()`: an empty name, properties that are not JSON, or a
  /// payload over `maxEventBytes`.
  invalid,
}

/// One event inside an [EventBatch] handed to a transport.
class BatchEvent {
  const BatchEvent({
    required this.id,
    required this.name,
    required this.properties,
    required this.timestamp,
    required this.priority,
    required this.attempt,
  });

  /// UUIDv7; stable across retries. Servers should dedupe on it.
  final String id;
  final String name;
  final Map<String, Object?> properties;

  /// When the event was tracked, in UTC.
  final DateTime timestamp;
  final Priority priority;

  /// 1 for the first delivery attempt.
  final int attempt;
}

/// A group of events delivered in one transport call.
class EventBatch {
  const EventBatch({required this.batchId, required this.events});

  /// Unique per send; a retried event goes out in a new batch.
  final String batchId;
  final List<BatchEvent> events;
}

/// Snapshot of the queue and delivery counters.
class QueueStats {
  const QueueStats({
    required this.pending,
    required this.inFlight,
    required this.queuedBytes,
    required this.sent,
    required this.dropped,
    required this.consent,
    this.lastSuccessAt,
    this.lastError,
    this.backoffUntil,
  });

  /// Stored events not currently being sent.
  final int pending;

  /// Events currently leased by an uploader.
  final int inFlight;
  final int queuedBytes;

  /// Events delivered since install.
  final int sent;

  /// Events dropped since install, by reason.
  final Map<DropReason, int> dropped;
  final ConsentState consent;
  final DateTime? lastSuccessAt;
  final String? lastError;

  /// Automatic flushes are paused until this time after a retryable failure.
  final DateTime? backoffUntil;

  int get droppedTotal => dropped.values.fold(0, (a, b) => a + b);

  @override
  String toString() =>
      'QueueStats(pending: $pending, inFlight: $inFlight, sent: $sent, '
      'dropped: $droppedTotal, consent: ${consent.name})';
}

/// A stored event as shown by `BeeSync.debugQueue`, read without claiming it.
class QueuedEvent {
  const QueuedEvent({
    required this.id,
    required this.name,
    required this.priority,
    required this.createdAt,
    required this.attempts,
    required this.nextAttemptAt,
    required this.sizeBytes,
    required this.inFlight,
    required this.payload,
  });

  final String id;
  final String name;
  final Priority priority;
  final DateTime createdAt;

  /// Failed delivery attempts so far.
  final int attempts;

  /// When the event may be sent again after a failure; null if it is ready.
  final DateTime? nextAttemptAt;
  final int sizeBytes;

  /// Leased by an uploader (this app or the native background one) right now.
  final bool inFlight;

  /// The stored properties as UTF-8 JSON.
  final List<int> payload;

  /// The decoded properties, or null if the payload is not a JSON object.
  Map<String, Object?>? get properties {
    try {
      final decoded = jsonDecode(utf8.decode(payload));
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }
}

/// One entry in `BeeSync.debugActivity`: what this app's uploader did.
sealed class ActivityEntry {
  const ActivityEntry(this.at);

  final DateTime at;
}

/// A transport call.
class RequestActivity extends ActivityEntry {
  const RequestActivity(
    super.at, {
    required this.batchId,
    required this.events,
    required this.succeeded,
    required this.outcome,
    required this.elapsed,
  });

  final String batchId;
  final int events;

  /// The server accepted the batch (possibly rejecting some events).
  final bool succeeded;

  /// Human-readable result, e.g. `2xx: 20 accepted`, `HTTP 503, retry after 30s`.
  final String outcome;
  final Duration elapsed;
}

/// Events removed without delivery.
class DropActivity extends ActivityEntry {
  const DropActivity(super.at, {required this.events, required this.reason});

  final int events;
  final DropReason reason;
}

/// A line written by a native background uploader. See `BeeSync.backgroundLog`.
class BackgroundLogEntry {
  const BackgroundLogEntry({
    required this.at,
    required this.source,
    required this.level,
    required this.message,
  });

  final DateTime at;

  /// `android_worker`, `ios_bg_exit` or `ios_bgtask`.
  final String source;

  /// `debug`, `info`, `warn` or `error`.
  final String level;
  final String message;

  @override
  String toString() => '${at.toIso8601String()} [$source/$level] $message';
}

/// Notifications on `BeeSync.events`.
sealed class DeliveryEvent {
  const DeliveryEvent();
}

/// The server acknowledged these events.
class Delivered extends DeliveryEvent {
  const Delivered(this.ids);

  final List<String> ids;
}

/// These events were removed without being delivered.
class Dropped extends DeliveryEvent {
  const Dropped(this.ids, this.reason);

  final List<String> ids;
  final DropReason reason;
}

/// A flush stopped early; remaining events stay queued.
class FlushFailed extends DeliveryEvent {
  const FlushFailed(this.reason, {this.retryAt});

  final String reason;

  /// When automatic flushing resumes, if known.
  final DateTime? retryAt;
}
