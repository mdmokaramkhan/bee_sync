import 'dart:async';

import 'package:bee_sync/bee_sync.dart';
import 'package:flutter/material.dart';

/// Any endpoint that answers 2xx to a JSON POST works. httpbin echoes the
/// request, which is handy for inspecting the wire format.
final _endpoint = Uri.parse('https://httpbin.org/post');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await BeeSync.initialize(
    BeeSyncConfig(
      transport: HttpTransport(endpoint: _endpoint, gzip: false),
      batching: const BatchingPolicy(
        flushAt: 5,
        flushInterval: Duration(seconds: 15),
      ),
      logger: const BeeLogger.console(level: LogLevel.debug),
    ),
  );
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'bee_sync example',
    theme: ThemeData(colorSchemeSeed: Colors.amber),
    home: const HomePage(),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _bee = BeeSync.instance;
  final _log = <String>[];
  QueueStats? _stats;
  late final StreamSubscription<QueueStats> _statsSub;
  late final StreamSubscription<DeliveryEvent> _eventsSub;
  int _counter = 0;

  @override
  void initState() {
    super.initState();
    _statsSub = _bee.stats.listen((s) => setState(() => _stats = s));
    _eventsSub = _bee.events.listen(
      (e) => _addLog(switch (e) {
        Delivered(:final ids) => 'Delivered ${ids.length}',
        Dropped(:final ids, :final reason) =>
          'Dropped ${ids.length} (${reason.name})',
        FlushFailed(:final reason) => 'Flush failed: $reason',
      }),
    );
    _bee.getStats().then((s) => setState(() => _stats = s));
  }

  @override
  void dispose() {
    _statsSub.cancel();
    _eventsSub.cancel();
    super.dispose();
  }

  void _addLog(String line) => setState(() {
    _log.insert(0, '${TimeOfDay.now().format(context)}  $line');
    if (_log.length > 50) _log.removeLast();
  });

  Future<void> _track(Priority priority) async {
    final id = await _bee.track(
      priority == Priority.immediate ? 'purchase' : 'button_tap',
      properties: {'n': ++_counter},
      priority: priority,
    );
    _addLog('Tracked ${priority.name} ${id.substring(0, 8)}…');
  }

  @override
  Widget build(BuildContext context) {
    final s = _stats;
    return Scaffold(
      appBar: AppBar(title: const Text('bee_sync')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                s == null
                    ? 'Loading…'
                    : 'Pending: ${s.pending}   In flight: ${s.inFlight}\n'
                          'Sent: ${s.sent}   Dropped: ${s.droppedTotal}\n'
                          'Consent: ${s.consent.name}'
                          '${s.lastError == null ? '' : '\nLast error: ${s.lastError}'}',
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: () => _track(Priority.normal),
                child: const Text('Track normal'),
              ),
              FilledButton.tonal(
                onPressed: () => _track(Priority.immediate),
                child: const Text('Track immediate'),
              ),
              OutlinedButton(
                onPressed: () async => _addLog('${await _bee.flush()}'),
                child: const Text('Flush'),
              ),
            ],
          ),
          SwitchListTile(
            title: const Text('Tracking consent'),
            value: _bee.consent == ConsentState.granted,
            onChanged: (on) async {
              await _bee.setConsent(
                on ? ConsentState.granted : ConsentState.denied,
                purge: !on,
              );
              setState(() {});
            },
          ),
          const Divider(),
          for (final line in _log)
            Text(line, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
