/// Settings for the example, from `--dart-define` or, more conveniently,
/// `--dart-define-from-file=bee.local.json` (see README.md). Nothing here
/// needs editing to point the app at your own server.
abstract final class DemoConfig {
  /// Where events are posted. httpbin echoes each request, which is handy for
  /// inspecting the wire format. For the local test server
  /// (tool/test_server.dart) use `http://10.0.2.2:8080/events` on the Android
  /// emulator, or `http://localhost:8080/events` on the iOS Simulator.
  static const endpoint = String.fromEnvironment(
    'BEE_ENDPOINT',
    defaultValue: 'https://httpbin.org/post',
  );

  /// Send a batch once this many events are pending.
  static const flushAt = int.fromEnvironment('BEE_FLUSH_AT', defaultValue: 5);

  /// Send whatever is pending this often, in seconds.
  static const flushIntervalSeconds = int.fromEnvironment(
    'BEE_FLUSH_INTERVAL',
    defaultValue: 15,
  );

  /// Drop an event after this many failed responses (408, 429, 5xx).
  /// Network failures never count.
  static const maxAttempts = int.fromEnvironment(
    'BEE_MAX_ATTEMPTS',
    defaultValue: 12,
  );

  /// Track sessions, screens and widget views automatically. Turn it off
  /// (`BEE_AUTO_EVENTS=false`) when a test counts events exactly, so only the
  /// Delivery tab's buttons create events.
  static const autoEvents = bool.fromEnvironment(
    'BEE_AUTO_EVENTS',
    defaultValue: true,
  );

  /// Track this many `demo_event`s at startup, for scripted checks.
  static const demoEvents = int.fromEnvironment('BEE_DEMO_EVENTS');
}
