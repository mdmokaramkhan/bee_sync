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
