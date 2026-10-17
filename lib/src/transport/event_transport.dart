import '../api/models.dart';

/// Sends batches of events somewhere.
///
/// Custom transports run in the foreground only; background delivery (v0.2)
/// is done natively and requires `HttpTransport`.
abstract interface class EventTransport {
  /// Sends one batch. Report failures through the returned result; a thrown
  /// exception is treated as a [RetryableFailure].
  Future<TransportResult> send(EventBatch batch);
}

/// Outcome of [EventTransport.send].
sealed class TransportResult {
  const TransportResult();
}

/// The batch was accepted, except for any [rejectedIds], which are dropped.
class Success extends TransportResult {
  const Success({this.rejectedIds = const {}});

  final Set<String> rejectedIds;
}

/// Temporary failure (network, timeout, 408, 429, 5xx). Events are retried
/// with backoff, no sooner than [retryAfter] if given.
class RetryableFailure extends TransportResult {
  const RetryableFailure(this.reason, {this.retryAfter});

  final String reason;
  final Duration? retryAfter;
}

/// Credentials were refused (401/403). Events stay queued without using up
/// an attempt; automatic flushing pauses until `BeeSync.setHeaders` is
/// called.
class AuthFailure extends TransportResult {
  const AuthFailure(this.reason);

  final String reason;
}

/// The batch was too large (413). It is split; a single event that is still
/// too large is dropped.
class PayloadTooLarge extends TransportResult {
  const PayloadTooLarge();
}

/// The server will never accept this batch as-is (other 4xx). It is bisected
/// to isolate the offending events, which are dropped.
class PermanentFailure extends TransportResult {
  const PermanentFailure(this.reason);

  final String reason;
}
