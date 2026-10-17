import '../api/config.dart';

/// Batching and retry settings an uploader needs; mirrored to
/// `meta.delivery_config` so native uploaders use the same values
/// (spec/uploader_contract.md §1.2).
class DeliverySettings {
  const DeliverySettings({
    this.maxBatchSize = 100,
    this.maxBatchBytes = 512 * 1024,
    this.leaseMs = 60000,
    this.retry = const RetryPolicy(),
  });

  factory DeliverySettings.fromConfig(BeeSyncConfig config) => DeliverySettings(
    maxBatchSize: config.batching.maxBatchSize,
    maxBatchBytes: config.batching.maxBatchBytes,
    leaseMs: config.leaseDuration.inMilliseconds,
    retry: config.retry,
  );

  /// Missing keys fall back to the defaults, as in the fixtures.
  factory DeliverySettings.fromJson(Map<String, Object?> json) {
    const d = DeliverySettings();
    int read(String key, int fallback) => (json[key] as int?) ?? fallback;
    return DeliverySettings(
      maxBatchSize: read('max_batch_size', d.maxBatchSize),
      maxBatchBytes: read('max_batch_bytes', d.maxBatchBytes),
      leaseMs: read('lease_ms', d.leaseMs),
      retry: RetryPolicy(
        base: Duration(
          milliseconds: read('retry_base_ms', d.retry.base.inMilliseconds),
        ),
        max: Duration(
          milliseconds: read('retry_max_ms', d.retry.max.inMilliseconds),
        ),
        maxAttempts: read('max_attempts', d.retry.maxAttempts),
      ),
    );
  }

  final int maxBatchSize;
  final int maxBatchBytes;
  final int leaseMs;
  final RetryPolicy retry;

  Map<String, Object?> toJson() => {
    'max_batch_size': maxBatchSize,
    'max_batch_bytes': maxBatchBytes,
    'lease_ms': leaseMs,
    'retry_base_ms': retry.base.inMilliseconds,
    'retry_max_ms': retry.max.inMilliseconds,
    'max_attempts': retry.maxAttempts,
  };
}
