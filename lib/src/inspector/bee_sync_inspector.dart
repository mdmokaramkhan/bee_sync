import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../api/bee_sync.dart';
import '../api/models.dart';

/// A debug screen for bee_sync: queue status, the stored events, recent
/// requests and the native background log, plus actions to flush, simulate
/// an outage, reset backoff and purge.
///
/// ```dart
/// if (kDebugMode) BeeSyncInspector.show(context);
/// ```
///
/// Event properties can contain personal data; they are only shown when an
/// event is tapped. Keep the inspector out of release builds.
class BeeSyncInspector extends StatefulWidget {
  const BeeSyncInspector({super.key, this.bee});

  /// Defaults to `BeeSync.instance`.
  final BeeSync? bee;

  /// Opens the inspector as a full-screen page.
  static Future<void> show(BuildContext context, {BeeSync? bee}) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => BeeSyncInspector(bee: bee),
        ),
      );

  /// How many stored events the Queue tab lists.
  static const queueLimit = 200;

  @override
  State<BeeSyncInspector> createState() => _BeeSyncInspectorState();
}

class _BeeSyncInspectorState extends State<BeeSyncInspector> {
  BeeSync get _bee => widget.bee ?? BeeSync.instance;

  QueueStats? _stats;
  List<QueuedEvent> _queue = const [];
  List<BackgroundLogEntry> _backgroundLog = const [];
  Object? _error;
  bool _busy = false;

  final List<StreamSubscription<Object?>> _subscriptions = [];
  Timer? _poll;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _subscriptions
      ..add(_bee.stats.listen((_) => _scheduleRefresh()))
      ..add(_bee.events.listen((_) => _scheduleRefresh()));
    // Leases expire and native runs happen without any event in this app.
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
    _refresh();
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    _poll?.cancel();
    _debounce?.cancel();
    super.dispose();
  }

  void _scheduleRefresh() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), _refresh);
  }

  Future<void> _refresh() async {
    try {
      final stats = await _bee.getStats();
      final queue = await _bee.debugQueue(limit: BeeSyncInspector.queueLimit);
      final log = await _bee.backgroundLog(limit: 50);
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _queue = queue;
        _backgroundLog = log;
        _error = null;
      });
    } catch (e) {
      // e.g. BeeSync was closed while the inspector is open.
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _run(String label, Future<String> Function() action) async {
    setState(() => _busy = true);
    String message;
    try {
      message = await action();
    } catch (e) {
      message = '$label failed: $e';
    }
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
    await _refresh();
  }

  Future<void> _confirmPurge() async {
    final pending = _stats?.pending ?? 0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Purge queue?'),
        content: Text(
          'Deletes all $pending queued event(s) on this device. '
          'They will never be sent.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const Key('bee_inspector_purge_confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Purge'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _run('Purge', () async {
        final n = await _bee.purgeQueue();
        return 'Purged $n event(s)';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('bee_sync inspector'),
          actions: [
            IconButton(
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh),
              onPressed: _refresh,
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Status'),
              Tab(text: 'Queue'),
              Tab(text: 'Activity'),
            ],
          ),
        ),
        body: _error != null && _stats == null
            ? Center(child: Text('Cannot read bee_sync: $_error'))
            : TabBarView(children: [_statusTab(), _queueTab(), _activityTab()]),
      ),
    );
  }

  // ---- Status ----------------------------------------------------------------

  Widget _statusTab() {
    final s = _stats;
    if (s == null) return const Center(child: CircularProgressIndicator());
    final dropped = s.dropped.entries.toList()
      ..sort((a, b) => a.key.name.compareTo(b.key.name));
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _section('Queue', [
          _row('Pending', '${s.pending}'),
          _row('In flight', '${s.inFlight}'),
          _row('Stored size', _bytes(s.queuedBytes)),
        ]),
        _section('Delivery', [
          _row('Sent', '${s.sent}'),
          _row('Dropped', '${s.droppedTotal}'),
          for (final e in dropped) _row('  ${e.key.name}', '${e.value}'),
          _row(
            'Last success',
            s.lastSuccessAt == null ? '—' : _time(s.lastSuccessAt!),
          ),
          _row(
            'Backing off until',
            s.backoffUntil == null ? '—' : _time(s.backoffUntil!),
          ),
          if (s.lastError != null) _row('Last error', s.lastError!),
        ]),
        _section('Settings', [
          _row('Consent', s.consent.name),
          _row('Background delivery', _bee.backgroundEnabled ? 'on' : 'off'),
        ]),
        const SizedBox(height: 8),
        FilledButton.icon(
          key: const Key('bee_inspector_flush'),
          onPressed: _busy
              ? null
              : () => _run('Flush', () async {
                  final r = await _bee.flush();
                  return 'Flush: ${r.status.name}, ${r.delivered} delivered'
                      '${r.error == null ? '' : ' (${r.error})'}';
                }),
          icon: const Icon(Icons.send),
          label: const Text('Flush now'),
        ),
        SwitchListTile(
          key: const Key('bee_inspector_offline'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Simulate offline'),
          subtitle: const Text(
            "This app's uploads fail as network errors. "
            'The native background uploader is not affected.',
          ),
          value: _bee.debugSimulateOffline,
          onChanged: (v) => setState(() => _bee.debugSimulateOffline = v),
        ),
        OutlinedButton.icon(
          key: const Key('bee_inspector_reset'),
          onPressed: _busy
              ? null
              : () => _run('Reset backoff', () async {
                  await _bee.resetBackoff();
                  return 'Backoff cleared';
                }),
          icon: const Icon(Icons.restart_alt),
          label: const Text('Reset backoff'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const Key('bee_inspector_purge'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: _busy ? null : _confirmPurge,
          icon: const Icon(Icons.delete_forever),
          label: const Text('Purge queue'),
        ),
      ],
    );
  }

  Widget _section(String title, List<Widget> rows) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          ...rows,
        ],
      ),
    ),
  );

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Text(label)),
        const SizedBox(width: 12),
        Flexible(child: Text(value, textAlign: TextAlign.end)),
      ],
    ),
  );

  // ---- Queue -----------------------------------------------------------------

  Widget _queueTab() {
    if (_queue.isEmpty) return const Center(child: Text('Queue is empty'));
    final now = DateTime.now();
    return ListView.separated(
      itemCount: _queue.length + 1,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        if (i == _queue.length) {
          return Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              _queue.length == BeeSyncInspector.queueLimit
                  ? 'Showing the oldest ${BeeSyncInspector.queueLimit} events.'
                  : '${_queue.length} event(s). Tap one to see its properties.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          );
        }
        final e = _queue[i];
        final next = e.nextAttemptAt;
        return ListTile(
          leading: Icon(
            e.priority == Priority.immediate ? Icons.bolt : Icons.schedule,
          ),
          title: Text(e.name),
          subtitle: Text(
            [
              e.priority.name,
              '${e.attempts} failed attempt(s)',
              if (next != null)
                'retry in ${_duration(next.difference(now.toUtc()))}',
              _bytes(e.sizeBytes),
            ].join(' · '),
          ),
          trailing: e.inFlight
              ? const Tooltip(
                  message: 'Being sent',
                  child: Icon(Icons.cloud_upload),
                )
              : null,
          onTap: () => _showEvent(e),
        );
      },
    );
  }

  void _showEvent(QueuedEvent e) {
    final properties = e.properties;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(e.name),
        content: SingleChildScrollView(
          child: SelectableText(
            'id: ${e.id}\n'
            'tracked: ${_time(e.createdAt)}\n\n'
            '${properties == null ? '(unreadable payload)' : const JsonEncoder.withIndent('  ').convert(properties)}',
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  // ---- Activity --------------------------------------------------------------

  Widget _activityTab() {
    final activity = _bee.debugActivity;
    final theme = Theme.of(context);
    return ListView(
      children: [
        _header('This app'),
        if (activity.isEmpty) const ListTile(title: Text('No requests yet')),
        for (final a in activity) _activityTile(a, theme),
        _header('Background (native)'),
        if (_backgroundLog.isEmpty)
          const ListTile(title: Text('No background runs recorded')),
        for (final b in _backgroundLog)
          ListTile(
            dense: true,
            leading: Icon(
              b.level == 'error' || b.level == 'warn'
                  ? Icons.warning_amber
                  : Icons.nightlight_round,
            ),
            title: Text(b.message),
            subtitle: Text('${b.source} · ${b.level} · ${_time(b.at)}'),
          ),
      ],
    );
  }

  Widget _activityTile(ActivityEntry a, ThemeData theme) => switch (a) {
    RequestActivity() => ListTile(
      dense: true,
      leading: Icon(
        a.succeeded ? Icons.check_circle : Icons.error,
        color: a.succeeded ? Colors.green : theme.colorScheme.error,
      ),
      title: Text(
        a.succeeded
            ? 'Sent ${a.events} event(s)'
            : 'Request failed (${a.events} event(s))',
      ),
      subtitle: Text(
        '${a.outcome} · ${a.elapsed.inMilliseconds} ms · ${_time(a.at)}',
      ),
    ),
    DropActivity() => ListTile(
      dense: true,
      leading: const Icon(Icons.delete_outline),
      title: Text('Dropped ${a.events} event(s)'),
      subtitle: Text('${a.reason.name} · ${_time(a.at)}'),
    ),
  };

  Widget _header(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );

  // ---- Formatting ------------------------------------------------------------

  static String _time(DateTime t) {
    final l = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
  }

  static String _duration(Duration d) {
    if (d.isNegative) return '0s';
    if (d.inMinutes >= 1) return '${d.inMinutes}m ${d.inSeconds % 60}s';
    return '${d.inSeconds}s';
  }

  static String _bytes(int n) =>
      n < 1024 ? '$n B' : '${(n / 1024).toStringAsFixed(1)} KB';
}
