import Flutter
import UIKit

/// Receives the database location from Dart and schedules background flushes.
///
/// Placeholder until the background-task uploader lands (v0.2 step 4): it
/// stores the setup so a background launch can find the database, and
/// schedules nothing yet.
public class BeeSyncPlugin: NSObject, FlutterPlugin, BeeSyncHostApi {
  static let databasePathKey = "dev.beesync.database_path"
  static let enabledKey = "dev.beesync.background_enabled"

  public static func register(with registrar: FlutterPluginRegistrar) {
    BeeSyncHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: BeeSyncPlugin())
  }

  func configure(setup: BackgroundSetup) throws -> [String] {
    let defaults = UserDefaults.standard
    defaults.set(setup.databasePath, forKey: Self.databasePathKey)
    defaults.set(setup.enabled, forKey: Self.enabledKey)
    return []
  }

  func scheduleBackgroundFlush() throws {}

  func cancelBackgroundFlush() throws {}
}
