/// Native background delivery (Android WorkManager, iOS background tasks).
///
/// The native side runs its own uploader against the same database; this
/// interface only tells it where the database is and when work is pending.
abstract interface class BackgroundScheduler {
  /// Called once at startup. Returns setup problems worth logging, such as
  /// missing iOS `Info.plist` entries.
  Future<List<String>> configure({
    required String databasePath,
    required bool enabled,
  });

  /// Ensures a background flush will run when the OS allows it.
  Future<void> schedule();

  /// Cancels pending background flushes; the queue is empty.
  Future<void> cancel();
}

/// Used when background delivery is off or unavailable (custom store, tests).
class NoopBackgroundScheduler implements BackgroundScheduler {
  const NoopBackgroundScheduler();

  @override
  Future<List<String>> configure({
    required String databasePath,
    required bool enabled,
  }) async => const [];

  @override
  Future<void> schedule() async {}

  @override
  Future<void> cancel() async {}
}
