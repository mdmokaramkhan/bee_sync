import 'dart:developer' as developer;

enum LogLevel { trace, debug, info, warn, error, off }

/// Receives bee_sync's diagnostic output. Event payloads are only ever
/// logged at [LogLevel.trace].
abstract class BeeLogger {
  const BeeLogger();

  /// Logs to `dart:developer` at [level] and above.
  const factory BeeLogger.console({LogLevel level}) = _ConsoleLogger;

  /// Discards everything.
  const factory BeeLogger.silent() = _SilentLogger;

  void log(
    LogLevel level,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  });
}

class _ConsoleLogger extends BeeLogger {
  const _ConsoleLogger({this.level = LogLevel.info});

  final LogLevel level;

  @override
  void log(
    LogLevel level,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (level == LogLevel.off || level.index < this.level.index) return;
    developer.log(
      message,
      name: 'bee_sync',
      level: _developerLevels[level.index],
      error: error,
      stackTrace: stackTrace,
    );
  }

  // package:logging values for FINEST, FINE, INFO, WARNING, SEVERE.
  static const _developerLevels = [300, 500, 800, 900, 1000, 0];
}

class _SilentLogger extends BeeLogger {
  const _SilentLogger();

  @override
  void log(
    LogLevel level,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {}
}
