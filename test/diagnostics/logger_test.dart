import 'package:bee_sync/bee_sync.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('console logger is enabled at its level and above', () {
    const logger = BeeLogger.console(level: LogLevel.info);
    expect(logger.isEnabled(LogLevel.trace), isFalse);
    expect(logger.isEnabled(LogLevel.debug), isFalse);
    expect(logger.isEnabled(LogLevel.info), isTrue);
    expect(logger.isEnabled(LogLevel.error), isTrue);
    expect(logger.isEnabled(LogLevel.off), isFalse);
  });

  test('silent logger is never enabled', () {
    const logger = BeeLogger.silent();
    for (final level in LogLevel.values) {
      expect(logger.isEnabled(level), isFalse);
    }
  });
}
