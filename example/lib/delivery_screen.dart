import 'dart:async';

import 'package:bee_sync/bee_sync.dart';
import 'package:bee_sync/inspector.dart';
import 'package:flutter/material.dart';

import 'analytics.dart';
import 'demo_config.dart';

/// What was tracked, delivered, dropped or failed, newest first.
class DeliveryLog extends ChangeNotifier {
  DeliveryLog(BeeSync bee) {
    _sub = bee.events.listen(
      (e) => switch (e) {
        Delivered(:final ids) => add(
          LogKind.delivered,
          'Delivered ${ids.length}',
        ),
        Dropped(:final ids, :final reason) => add(
          LogKind.dropped,
          'Dropped ${ids.length} (${reason.name})',
        ),
        FlushFailed(:final reason, :final retryAt) => add(
          LogKind.failed,
          'Failed: $reason'
          '${retryAt == null ? '' : ', retry ${_inTime(retryAt)}'}',
        ),
      },
    );
  }

  late final StreamSubscription<DeliveryEvent> _sub;
  final entries = <LogEntry>[];

  void add(LogKind kind, String text) {
    entries.insert(0, LogEntry(DateTime.now(), kind, text));
    if (entries.length > 200) entries.removeLast();
    notifyListeners();
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

enum LogKind { tracked, delivered, dropped, failed, info }

class LogEntry {
  const LogEntry(this.at, this.kind, this.text);

  final DateTime at;
  final LogKind kind;
  final String text;
}

/// The testing panel: queue status, settings, actions and the delivery log.
class DeliveryScreen extends StatefulWidget {
  const DeliveryScreen({required this.analytics, required this.log, super.key});

  final Analytics analytics;
  final DeliveryLog log;

  @override
  State<DeliveryScreen> createState() => _DeliveryScreenState();
}

class _DeliveryScreenState extends State<DeliveryScreen> {
  final _bee = BeeSync.instance;
  late final Timer _tick;
  late final StreamSubscription<QueueStats> _statsSub;
  QueueStats? _stats;
  int _testCount = 0;

  @override
  void initState() {
    super.initState();
    _statsSub = _bee.stats.listen((s) => setState(() => _stats = s));
    _bee.getStats().then((s) {
      if (mounted) setState(() => _stats ??= s);
    });
    // Keeps "retry in …" and "… ago" current.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick.cancel();
    _statsSub.cancel();
    super.dispose();
  }

  Future<void> _trackTest(
    int count, {
    Priority priority = Priority.normal,
  }) async {
    for (var i = 0; i < count; i++) {
      await widget.analytics.track(
        'test_event',
        properties: {'n': ++_testCount},
        priority: priority,
      );
    }
  }

  Future<void> _run(String label, Future<Object?> Function() action) async {
    final result = await action();
    widget.log.add(LogKind.info, result == null ? label : '$label: $result');
  }

  @override
  Widget build(BuildContext context) {
    final stats = _stats;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        if (stats == null)
          const LinearProgressIndicator()
        else
          _StatusCard(stats: stats),
        const SizedBox(height: 12),
        _section(context, 'Generate events'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton(
              onPressed: () => _trackTest(1),
              child: const Text('Track 1'),
            ),
            FilledButton(
              onPressed: () => _trackTest(10),
              child: const Text('Track 10'),
            ),
            FilledButton.tonal(
              onPressed: () => _trackTest(1, priority: Priority.immediate),
              child: const Text('Track immediate'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _section(context, 'Deliver'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              icon: const Icon(Icons.send),
              label: const Text('Flush now'),
              onPressed: () => _run('Flush', _bee.flush),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.restart_alt),
              label: const Text('Reset backoff'),
              onPressed: () => _run('Backoff reset', () async {
                await _bee.resetBackoff();
                return null;
              }),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.bug_report_outlined),
              label: const Text('Inspector'),
              onPressed: () => BeeSyncInspector.show(context),
            ),
          ],
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Simulate offline'),
          subtitle: const Text('This app\'s uploads fail as if offline'),
          value: _bee.debugSimulateOffline,
          onChanged: (on) => setState(() => _bee.debugSimulateOffline = on),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Tracking consent'),
          subtitle: const Text('Turning it off deletes the queue'),
          value: _bee.consent == ConsentState.granted,
          onChanged: (on) async {
            await _bee.setConsent(
              on ? ConsentState.granted : ConsentState.denied,
              purge: !on,
            );
            setState(() {});
          },
        ),
        const _SettingsCard(),
        const SizedBox(height: 16),
        _section(context, 'Log'),
        ListenableBuilder(
          listenable: widget.log,
          builder: (context, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.log.entries.isEmpty)
                const Text('Nothing yet. Use the app or the buttons above.'),
              for (final e in widget.log.entries.take(80)) _LogRow(entry: e),
            ],
          ),
        ),
      ],
    );
  }

  Widget _section(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(title, style: Theme.of(context).textTheme.titleSmall),
  );
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.stats});

  final QueueStats stats;

  @override
  Widget build(BuildContext context) {
    final s = stats;
    final theme = Theme.of(context);
    final backoff = s.backoffUntil;
    final waiting = backoff != null && backoff.isAfter(DateTime.now());
    final (label, color, icon) = s.pending + s.inFlight == 0
        ? ('All delivered', Colors.green, Icons.check_circle)
        : waiting
        ? ('Waiting to retry', Colors.red, Icons.schedule)
        : ('Queued', Colors.amber.shade800, Icons.pending);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color),
                const SizedBox(width: 8),
                Text(label, style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                _Metric('Pending', s.pending),
                _Metric('In flight', s.inFlight),
                _Metric('Sent', s.sent),
                _Metric('Dropped', s.droppedTotal),
              ],
            ),
            const SizedBox(height: 12),
            if (s.droppedTotal > 0)
              Text(
                'Dropped: ${[for (final e in s.dropped.entries)
                  if (e.value > 0) '${e.key.name} ${e.value}'].join(', ')}',
                style: theme.textTheme.bodySmall,
              ),
            if (waiting)
              Text(
                'Next retry ${_inTime(backoff)}',
                style: theme.textTheme.bodySmall,
              ),
            if (s.lastSuccessAt != null)
              Text(
                'Last delivery ${_ago(s.lastSuccessAt!)}',
                style: theme.textTheme.bodySmall,
              ),
            if (s.lastError != null && s.pending > 0)
              Text(
                'Last error: ${s.lastError}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric(this.label, this.value);

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      children: [
        Text('$value', style: Theme.of(context).textTheme.headlineSmall),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard();

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Settings', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Text('Endpoint: ${DemoConfig.endpoint}', style: style),
            Text(
              'Batch: ${DemoConfig.flushAt} events or every '
              '${DemoConfig.flushIntervalSeconds} s',
              style: style,
            ),
            Text(
              'Max attempts: ${DemoConfig.maxAttempts} '
              '(network failures don\'t count)',
              style: style,
            ),
            Text(
              'Background delivery: '
              '${BeeSync.instance.backgroundEnabled ? 'on' : 'off'}',
              style: style,
            ),
          ],
        ),
      ),
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.entry});

  final LogEntry entry;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (entry.kind) {
      LogKind.tracked => (Icons.add_circle_outline, Colors.blueGrey),
      LogKind.delivered => (Icons.check_circle, Colors.green),
      LogKind.dropped => (Icons.delete_outline, Colors.deepOrange),
      LogKind.failed => (Icons.error_outline, Colors.red),
      LogKind.info => (Icons.info_outline, Colors.indigo),
    };
    final t = entry.at;
    String two(int v) => v.toString().padLeft(2, '0');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${two(t.hour)}:${two(t.minute)}:${two(t.second)}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 8),
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              entry.text,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

String _inTime(DateTime at) {
  final d = at.difference(DateTime.now());
  if (d.inSeconds <= 0) return 'now';
  if (d.inMinutes < 1) return 'in ${d.inSeconds}s';
  return 'in ${d.inMinutes}m ${d.inSeconds % 60}s';
}

String _ago(DateTime at) {
  final d = DateTime.now().difference(at);
  if (d.inSeconds < 60) return '${d.inSeconds}s ago';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  return '${d.inHours}h ago';
}
