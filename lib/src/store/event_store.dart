import 'dart:typed_data';

import '../api/models.dart';

/// An event as handed to the store for persisting.
class NewEvent {
  const NewEvent({
    required this.id,
    required this.name,
    required this.payload,
    required this.priority,
    required this.createdAt,
    this.encrypted = false,
  });

  final String id;
  final String name;

  /// UTF-8 JSON of the event properties (or ciphertext when [encrypted]).
  final Uint8List payload;
  final bool encrypted;
  final Priority priority;

  /// Milliseconds since the Unix epoch, UTC.
  final int createdAt;

  int get sizeBytes => payload.length;
}

/// An event read back from the store by a claim.
class StoredEvent {
  const StoredEvent({
    required this.seq,
    required this.id,
    required this.name,
    required this.payload,
    required this.encrypted,
    required this.priority,
    required this.createdAt,
    required this.sizeBytes,
    required this.attempts,
  });

  final int seq;
  final String id;
  final String name;
  final Uint8List payload;
  final bool encrypted;
  final Priority priority;
  final int createdAt;
  final int sizeBytes;

  /// Failed delivery attempts so far.
  final int attempts;
}

/// Queue size snapshot.
class QueueTotals {
  const QueueTotals({
    required this.total,
    required this.inFlight,
    required this.bytes,
  });

  /// All stored events, including in-flight ones.
  final int total;

  /// Events under a live lease.
  final int inFlight;
  final int bytes;

  int get pending => total - inFlight;
}

/// Persistent event queue implementing the claim protocol in
/// `spec/claim_protocol.sql`.
///
/// All times are milliseconds since the Unix epoch and are passed in by the
/// caller, so implementations never read a clock themselves.
abstract interface class EventStore {
  Future<void> open();

  Future<void> close();

  Future<void> insert(NewEvent event);

  /// Leases up to [limit] ready events to [owner] until [leaseUntil] and
  /// returns everything [owner] holds, highest priority first, then FIFO.
  Future<List<StoredEvent>> claim({
    required String owner,
    required int now,
    required int leaseUntil,
    required int limit,
    bool immediateOnly = false,
  });

  /// Deletes events leased by [owner]: delivered, or dropped after failure.
  Future<void> deleteLeased(String owner, Iterable<String> ids);

  /// Returns leased events to the queue, counting a failed attempt and
  /// deferring them until [nextAttemptAt].
  Future<void> releaseRetry(
    String owner,
    Iterable<String> ids, {
    required int nextAttemptAt,
  });

  /// Returns leased events to the queue untouched.
  Future<void> release(String owner, Iterable<String> ids);

  Future<QueueTotals> totals(int now);

  /// Deletes unleased events created before [createdBefore]; returns their ids.
  Future<List<String>> deleteExpired({
    required int createdBefore,
    required int now,
  });

  /// Evicts unleased events (normal priority first, oldest first) until the
  /// queue fits [maxEvents] and [maxBytes]; returns the evicted ids.
  Future<List<String>> evict({
    required int now,
    required int maxEvents,
    required int maxBytes,
  });

  /// Deletes every event; returns the removed ids.
  Future<List<String>> purge();

  /// Makes every event immediately eligible for delivery again.
  Future<void> resetBackoff();

  Future<String?> getMeta(String key);

  Future<void> setMeta(String key, String value);
}
