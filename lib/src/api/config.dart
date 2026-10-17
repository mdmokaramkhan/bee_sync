import 'dart:math';

import '../diagnostics/logger.dart';
import '../transport/event_transport.dart';
import 'models.dart';

/// Configuration for `BeeSync.initialize`.
class BeeSyncConfig {
  const BeeSyncConfig({
    required this.transport,
    this.batching = const BatchingPolicy(),
    this.retry = const RetryPolicy(),
    this.retention = const RetentionPolicy(),
    this.consent = const ConsentConfig(),
    this.background = const BackgroundConfig(),
    this.maxEventBytes = 32 * 1024,
    this.leaseDuration = const Duration(seconds: 60),
    this.logger = const BeeLogger.console(),
  });

  /// Where events go. Background delivery requires `HttpTransport`.
  final EventTransport transport;
  final BatchingPolicy batching;
  final RetryPolicy retry;
  final RetentionPolicy retention;
  final ConsentConfig consent;
  final BackgroundConfig background;

  /// Largest encoded properties payload accepted by `track()`.
  final int maxEventBytes;

  /// How long a claimed batch stays hidden from other uploaders. Must exceed
  /// the transport's request timeout; an uploader that dies mid-send releases
  /// its events when the lease expires.
  final Duration leaseDuration;
  final BeeLogger logger;
}

/// When and how much to send.
class BatchingPolicy {
  const BatchingPolicy({
    this.flushAt = 20,
    this.flushInterval = const Duration(seconds: 30),
    this.maxBatchSize = 100,
    this.maxBatchBytes = 512 * 1024,
  }) : assert(flushAt > 0),
       assert(maxBatchSize > 0),
       assert(maxBatchBytes > 0);

  /// Flush once this many events are pending.
  final int flushAt;

  /// Flush on this interval while the app is running.
  final Duration flushInterval;

  /// Most events per transport call.
  final int maxBatchSize;

  /// Most payload bytes per transport call. A single event larger than this
  /// is still sent on its own.
  final int maxBatchBytes;
}

/// Backoff after retryable failures.
///
/// The delay after the n-th failed attempt is drawn uniformly from
/// `[cap / 2, cap]` where `cap = min(max, base * 2^(n-1))` ("equal jitter":
/// spreads retries out without ever retrying instantly).
class RetryPolicy {
  const RetryPolicy({
    this.base = const Duration(seconds: 2),
    this.max = const Duration(minutes: 10),
    this.maxAttempts = 12,
  }) : assert(maxAttempts > 0);

  final Duration base;
  final Duration max;

  /// Events are dropped ([DropReason.maxAttempts]) after this many failures.
  final int maxAttempts;

  /// Delay after the [attempt]-th failure (1-based).
  Duration delayAfter(int attempt, Random random) {
    final exp = attempt < 1 ? 0 : (attempt - 1).clamp(0, 30);
    final capMs = min(max.inMilliseconds, base.inMilliseconds * (1 << exp));
    final half = capMs ~/ 2;
    return Duration(milliseconds: half + random.nextInt(capMs - half + 1));
  }
}

/// What to do when the queue is full.
enum OverflowPolicy {
  /// Evict the oldest normal-priority events (then immediate ones).
  dropOldest,

  /// Reject the incoming event.
  dropNewest,
}

/// Bounds on what the queue keeps.
class RetentionPolicy {
  const RetentionPolicy({
    this.maxEvents = 10000,
    this.maxBytes = 10 * 1024 * 1024,
    this.maxAge = const Duration(days: 7),
    this.overflow = OverflowPolicy.dropOldest,
  }) : assert(maxEvents > 0),
       assert(maxBytes > 0);

  final int maxEvents;
  final int maxBytes;
  final Duration maxAge;
  final OverflowPolicy overflow;
}

/// What `track()` does while consent is [ConsentState.unknown].
enum UnknownConsentBehavior {
  /// Persist events but send nothing until consent is granted.
  hold,

  /// Drop events.
  drop,
}

class ConsentConfig {
  const ConsentConfig({
    this.initial = ConsentState.granted,
    this.whileUnknown = UnknownConsentBehavior.hold,
  });

  /// Used on first launch only; afterwards the persisted state wins.
  final ConsentState initial;
  final UnknownConsentBehavior whileUnknown;
}

/// Native background delivery (doc/DESIGN.md §7).
class BackgroundConfig {
  const BackgroundConfig({this.enabled = true});

  /// Upload from Android WorkManager and iOS background tasks when the app is
  /// not running. Only takes effect with `HttpTransport`; custom transports
  /// cannot run without Dart. iOS also needs Info.plist entries (see README).
  final bool enabled;
}
