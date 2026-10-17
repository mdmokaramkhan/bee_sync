import 'dart:math';

import 'package:bee_sync/bee_sync.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const policy = RetryPolicy(
    base: Duration(seconds: 2),
    max: Duration(seconds: 60),
  );

  test('delay stays within [cap/2, cap] and doubles per attempt', () {
    final random = Random(1);
    for (final (attempt, capSeconds) in [(1, 2), (2, 4), (3, 8), (5, 32)]) {
      for (var i = 0; i < 50; i++) {
        final d = policy.delayAfter(attempt, random).inMilliseconds;
        expect(d, inInclusiveRange(capSeconds * 500, capSeconds * 1000));
      }
    }
  });

  test('delay is capped at max, even for huge attempt counts', () {
    final random = Random(2);
    for (final attempt in [6, 20, 1000]) {
      final d = policy.delayAfter(attempt, random);
      expect(d, lessThanOrEqualTo(const Duration(seconds: 60)));
      expect(d, greaterThanOrEqualTo(const Duration(seconds: 30)));
    }
  });
}
