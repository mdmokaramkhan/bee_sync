import 'package:bee_sync/bee_sync.dart';
import 'package:bee_sync/testing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'BeeSyncTestHarness runs BeeSync.instance without platform code',
    () async {
      final harness = await BeeSyncTestHarness.start();
      addTearDown(harness.close);

      await BeeSync.instance.track('purchase', properties: {'order_id': 'A1'});
      final sent = await harness.flushAndCollect();

      expect(harness.trackedNames, ['purchase']);
      expect(sent.single.properties, {'order_id': 'A1'});
      expect(harness.deliveryEvents.whereType<Delivered>(), hasLength(1));
    },
  );

  test('harness transport can script failures', () async {
    final transport = FakeTransport()
      ..enqueue(const RetryableFailure('HTTP 503'));
    final harness = await BeeSyncTestHarness.start(transport: transport);
    addTearDown(harness.close);

    await harness.bee.track('a');
    await harness.bee.flush();

    expect(harness.transport.batches, hasLength(1));
    expect((await harness.bee.getStats()).pending, 1);
  });
}
