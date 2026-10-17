import 'package:bee_sync/bee_sync.dart';
import 'package:bee_sync/inspector.dart';
import 'package:bee_sync/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

late BeeSyncTestHarness harness;

/// Opens the inspector on a fresh in-memory BeeSync, runs [body], and always
/// closes BeeSync inside the test body: the widget-test framework checks for
/// pending timers (BeeSync's flush interval) before tearDown would run.
void inspectorTest(
  String description,
  Future<void> Function(WidgetTester tester) body, {
  ConsentState consent = ConsentState.granted,
}) {
  testWidgets(description, (tester) async {
    // A phone-like tall screen so the whole Status tab fits.
    tester.view
      ..physicalSize = const Size(800, 1400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    harness = await BeeSyncTestHarness.start(
      config: BeeSyncConfig(
        transport: FakeTransport(),
        consent: ConsentConfig(initial: consent),
      ),
    );
    try {
      await tester.pumpWidget(
        MaterialApp(home: BeeSyncInspector(bee: harness.bee)),
      );
      await settle(tester);
      await body(tester);
    } finally {
      await tester.pumpWidget(const SizedBox()); // disposes the inspector
      await harness.close();
    }
  });
}

/// Lets the inspector's async refresh and any snackbar/dialog animations
/// finish. (pumpAndSettle would wait on the 2 s refresh timer forever.)
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Future<void> tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await settle(tester);
}

Finder tab(String name) => find.widgetWithText(Tab, name);

void main() {
  inspectorTest('status tab shows counts and settings', (tester) async {
    await harness.bee.track('a');
    await harness.bee.track('b');
    await tap(tester, find.byTooltip('Refresh'));

    expect(find.text('bee_sync inspector'), findsOneWidget);
    expect(
      find.descendant(
        of: find.widgetWithText(Row, 'Pending'),
        matching: find.text('2'),
      ),
      findsOneWidget,
    );
    expect(find.text('unknown'), findsOneWidget); // consent
    expect(find.text('off'), findsOneWidget); // background (in-memory store)
  }, consent: ConsentState.unknown);

  inspectorTest('Flush now sends queued events', (tester) async {
    await harness.bee.track('a'); // below flushAt: stays queued
    await tap(tester, find.byKey(const Key('bee_inspector_flush')));

    expect(harness.trackedNames, ['a']);
    expect(find.text('Flush: drained, 1 delivered'), findsOneWidget);
  });

  inspectorTest(
    'queue tab lists events and shows properties on tap',
    (tester) async {
      await harness.bee.track('checkout', properties: {'cart': 42});
      await harness.bee.track('buy', priority: Priority.immediate);
      await tap(tester, tab('Queue'));

      expect(find.text('checkout'), findsOneWidget);
      expect(find.text('buy'), findsOneWidget);
      expect(find.byIcon(Icons.bolt), findsOneWidget); // immediate priority
      expect(find.textContaining('"cart": 42'), findsNothing); // hidden

      await tap(tester, find.text('checkout'));
      expect(find.textContaining('"cart": 42'), findsOneWidget);
      await tap(tester, find.text('Close'));
    },
    consent: ConsentState.unknown,
  );

  inspectorTest('queue tab says when empty', (tester) async {
    await tap(tester, tab('Queue'));
    expect(find.text('Queue is empty'), findsOneWidget);
  });

  inspectorTest('simulate offline toggles the debug switch', (tester) async {
    expect(harness.bee.debugSimulateOffline, isFalse);
    await tap(tester, find.byKey(const Key('bee_inspector_offline')));
    expect(harness.bee.debugSimulateOffline, isTrue);

    await harness.bee.track('a');
    await tap(tester, find.byKey(const Key('bee_inspector_flush')));
    expect(harness.transport.batches, isEmpty);
    expect(find.textContaining('backingOff'), findsOneWidget);
  });

  inspectorTest('reset backoff confirms', (tester) async {
    await tap(tester, find.byKey(const Key('bee_inspector_reset')));
    expect(find.text('Backoff cleared'), findsOneWidget);
  });

  inspectorTest('purge asks first, then deletes the queue', (tester) async {
    await harness.bee.track('a');
    await harness.bee.track('b');
    await tap(tester, find.byTooltip('Refresh'));

    await tap(tester, find.byKey(const Key('bee_inspector_purge')));
    expect(find.text('Purge queue?'), findsOneWidget);
    await tap(tester, find.text('Cancel'));
    expect((await harness.bee.getStats()).pending, 2);

    await tap(tester, find.byKey(const Key('bee_inspector_purge')));
    await tap(tester, find.byKey(const Key('bee_inspector_purge_confirm')));
    expect(find.text('Purged 2 event(s)'), findsOneWidget);
    expect((await harness.bee.getStats()).pending, 0);
  }, consent: ConsentState.unknown);

  inspectorTest('activity tab shows requests and the background log', (
    tester,
  ) async {
    harness.store.addBackgroundLog(
      BackgroundLogEntry(
        at: DateTime.utc(2026, 10, 18, 8),
        source: 'ios_bgtask',
        level: 'info',
        message: 'drained: sent 5, dropped 0',
      ),
    );
    await harness.bee.track('a');
    await harness.bee.flush();
    harness.transport.enqueue(const RetryableFailure('HTTP 503'));
    await harness.bee.track('b');
    await harness.bee.flush();
    await tap(tester, tab('Activity'));

    expect(find.text('Sent 1 event(s)'), findsOneWidget);
    expect(find.text('Request failed (1 event(s))'), findsOneWidget);
    expect(find.textContaining('2xx: 1 accepted'), findsOneWidget);
    expect(find.text('drained: sent 5, dropped 0'), findsOneWidget);
    expect(find.textContaining('ios_bgtask · info'), findsOneWidget);
  });
}
