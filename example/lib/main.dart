import 'dart:async';

import 'package:bee_sync/bee_sync.dart';
import 'package:bee_sync/inspector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'analytics.dart';
import 'delivery_screen.dart';
import 'demo_config.dart';
import 'shop.dart';

/// A small shop that tracks what a real app would (sessions, screens, widget
/// views, purchases) through bee_sync, plus a Delivery tab for testing.
/// Settings come from dart-defines; see README.md and demo_config.dart.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final bee = await BeeSync.initialize(
    BeeSyncConfig(
      transport: HttpTransport(
        endpoint: Uri.parse(DemoConfig.endpoint),
        gzip: false,
      ),
      batching: const BatchingPolicy(
        flushAt: DemoConfig.flushAt,
        flushInterval: Duration(seconds: DemoConfig.flushIntervalSeconds),
      ),
      retry: const RetryPolicy(maxAttempts: DemoConfig.maxAttempts),
      logger: kDebugMode
          ? const BeeLogger.console(level: LogLevel.debug)
          : const BeeLogger.silent(),
    ),
  );

  final log = DeliveryLog(bee);
  final analytics = Analytics(bee, autoEvents: DemoConfig.autoEvents)
    ..onTracked = (name, priority) => log.add(
      LogKind.tracked,
      priority == Priority.immediate ? '$name (immediate)' : name,
    );
  analytics.start();
  for (var i = 0; i < DemoConfig.demoEvents; i++) {
    await bee.track('demo_event', properties: {'n': i});
  }
  runApp(ExampleApp(analytics: analytics, log: log));
}

class ExampleApp extends StatefulWidget {
  const ExampleApp({required this.analytics, required this.log, super.key});

  final Analytics analytics;
  final DeliveryLog log;

  @override
  State<ExampleApp> createState() => _ExampleAppState();
}

class _ExampleAppState extends State<ExampleApp> {
  final _cart = Cart();
  var _tab = 0;
  late final _observer = AnalyticsRouteObserver(
    widget.analytics,
    rootScreen: () => _tabs[_tab].screen,
  );

  static const _tabs = [
    (screen: 'shop', label: 'Shop', icon: Icons.storefront),
    (screen: 'cart', label: 'Cart', icon: Icons.shopping_cart_outlined),
    (screen: 'delivery', label: 'Delivery', icon: Icons.sync),
  ];

  @override
  void initState() {
    super.initState();
    widget.analytics.screenView(_tabs[_tab].screen);
  }

  void _select(int tab) {
    setState(() => _tab = tab);
    widget.analytics.screenView(_tabs[tab].screen);
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'bee_sync example',
    theme: ThemeData(colorSchemeSeed: Colors.amber),
    navigatorObservers: [_observer],
    home: Builder(
      builder: (context) => Scaffold(
        appBar: AppBar(
          title: const Text('bee_sync shop'),
          actions: [
            _PendingChip(onTap: () => _select(2)),
            IconButton(
              tooltip: 'Inspector',
              icon: const Icon(Icons.bug_report_outlined),
              onPressed: () => BeeSyncInspector.show(context),
            ),
          ],
        ),
        body: switch (_tab) {
          0 => ShopScreen(analytics: widget.analytics, cart: _cart),
          1 => CartScreen(analytics: widget.analytics, cart: _cart),
          _ => DeliveryScreen(analytics: widget.analytics, log: widget.log),
        },
        bottomNavigationBar: ListenableBuilder(
          listenable: _cart,
          builder: (context, _) => NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: _select,
            destinations: [
              for (final t in _tabs)
                NavigationDestination(
                  label: t.label,
                  icon: t.screen == 'cart' && _cart.items.isNotEmpty
                      ? Badge.count(
                          count: _cart.items.length,
                          child: Icon(t.icon),
                        )
                      : Icon(t.icon),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Pending events at a glance: green when everything is delivered.
class _PendingChip extends StatefulWidget {
  const _PendingChip({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_PendingChip> createState() => _PendingChipState();
}

class _PendingChipState extends State<_PendingChip> {
  late final StreamSubscription<QueueStats> _sub;
  QueueStats? _stats;

  @override
  void initState() {
    super.initState();
    final bee = BeeSync.instance;
    _sub = bee.stats.listen((s) => setState(() => _stats = s));
    bee.getStats().then((s) {
      if (mounted) setState(() => _stats ??= s);
    });
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _stats;
    final queued = s == null ? 0 : s.pending + s.inFlight;
    final failing =
        queued > 0 && (s?.backoffUntil?.isAfter(DateTime.now()) ?? false);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: ActionChip(
        onPressed: widget.onTap,
        avatar: Icon(
          queued == 0 ? Icons.cloud_done : Icons.cloud_upload,
          size: 18,
          color: queued == 0
              ? Colors.green
              : failing
              ? Colors.red
              : Colors.amber.shade800,
        ),
        label: Text(queued == 0 ? 'Synced' : '$queued queued'),
      ),
    );
  }
}
