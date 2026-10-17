// Regenerate with: dart run pigeon --input pigeons/messages.dart
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/platform/messages.g.dart',
    dartPackageName: 'bee_sync',
    kotlinOut: 'android/src/main/kotlin/dev/beesync/bee_sync/Messages.g.kt',
    kotlinOptions: KotlinOptions(package: 'dev.beesync.bee_sync'),
    swiftOut: 'ios/Classes/Messages.g.swift',
  ),
)
class BackgroundSetup {
  BackgroundSetup({required this.databasePath, required this.enabled});

  /// Absolute path of bee_sync.db; persisted natively so a cold-started
  /// background job can find it.
  String databasePath;

  /// False disables and cancels all background work.
  bool enabled;
}

/// Dart -> native. Implemented by BeeSyncPlugin on each platform.
@HostApi()
abstract class BeeSyncHostApi {
  /// Returns setup warnings (e.g. missing iOS Info.plist entries).
  List<String> configure(BackgroundSetup setup);

  /// Ensures a background flush runs when the OS allows it.
  void scheduleBackgroundFlush();

  /// Cancels pending background flushes.
  void cancelBackgroundFlush();
}
