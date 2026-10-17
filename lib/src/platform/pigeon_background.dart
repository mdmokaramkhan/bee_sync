import 'background.dart';
import 'messages.g.dart';

/// [BackgroundScheduler] backed by the native plugin.
class PigeonBackgroundScheduler implements BackgroundScheduler {
  PigeonBackgroundScheduler({BeeSyncHostApi? api})
    : _api = api ?? BeeSyncHostApi();

  final BeeSyncHostApi _api;

  @override
  Future<List<String>> configure({
    required String databasePath,
    required bool enabled,
  }) => _api.configure(
    BackgroundSetup(databasePath: databasePath, enabled: enabled),
  );

  @override
  Future<void> schedule() => _api.scheduleBackgroundFlush();

  @override
  Future<void> cancel() => _api.cancelBackgroundFlush();
}
