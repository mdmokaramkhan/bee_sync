import Flutter
import UIKit

/// Dart -> native bridge (pigeons/messages.dart). Records where the database
/// is, so a background launch can find it, and drives `BackgroundDelivery`.
public class BeeSyncPlugin: NSObject, FlutterPlugin, BeeSyncHostApi {
  static let databasePathKey = BackgroundDelivery.databasePathKey

  public static func register(with registrar: FlutterPluginRegistrar) {
    registerBackgroundTasks()
    BeeSyncHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: BeeSyncPlugin())
  }

  /// Registers the background task handlers. Called automatically when the
  /// plugin is registered. If your app registers plugins after
  /// `application(_:didFinishLaunchingWithOptions:)` returns (for example with
  /// a scene-based setup), call this from `didFinishLaunching` yourself.
  @objc public static func registerBackgroundTasks() {
    BackgroundDelivery.shared.registerTasks()
  }

  func configure(setup: BackgroundSetup) throws -> [String] {
    BackgroundDelivery.shared.configure(databasePath: setup.databasePath, enabled: setup.enabled)
  }

  func scheduleBackgroundFlush() throws {
    BackgroundDelivery.shared.schedule()
  }

  func cancelBackgroundFlush() throws {
    BackgroundDelivery.shared.cancel()
  }
}
