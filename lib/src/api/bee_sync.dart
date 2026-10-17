import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../core/delivery_settings.dart';
import '../core/flush_controller.dart';
import '../diagnostics/logger.dart';
import '../platform/background.dart';
import '../platform/pigeon_background.dart';
import '../platform/signals.dart';
import '../store/event_store.dart';
import '../store/sqflite_store.dart';
import '../transport/event_transport.dart';
import '../transport/http_transport.dart';
import 'config.dart';
import 'errors.dart';
import 'models.dart';

/// Durable event delivery. See doc/DESIGN.md.
///
/// ```dart
/// final bee = await BeeSync.initialize(BeeSyncConfig(
///   transport: HttpTransport(endpoint: Uri.parse('https://example.com/events')),
/// ));
/// await bee.track(
///   'purchase',
///   properties: {'order_id': 'A1'},
///   priority: Priority.immediate,
/// );
/// ```
class BeeSync implements FlushListener {
  BeeSync._(
    this.config,
    this._store,
    this._signals,
    this._random,
    this._background,
  ) : _owner = 'dart:${const Uuid().v4()}';

  /// Opens the queue and starts automatic flushing.
  ///
  /// [store], [signals], [random] and [background] replace the defaults
  /// (SQLite in the app-support directory, Flutter lifecycle + connectivity,
  /// a secure random, native background scheduling); they exist for tests and
  /// advanced setups. Background delivery needs the native uploader to find
  /// the database, so a custom [store] only gets it when it reports a
  /// `databasePath` and a [background] scheduler is passed.
  ///
  /// `BeeSync.instance` is usable as soon as this is called: events tracked
  /// before initialization completes are written once the store is open.
  static Future<BeeSync> initialize(
    BeeSyncConfig config, {
    EventStore? store,
    PlatformSignals? signals,
    Random? random,
    BackgroundScheduler? background,
  }) async {
    if (_instance != null) {
      throw StateError('BeeSync is already initialized; call close() first');
    }
    final bee = BeeSync._(
      config,
      store ?? SqfliteEventStore(path: await _defaultDatabasePath()),
      signals ?? FlutterPlatformSignals(),
      random ?? Random.secure(),
      background ??
          (store == null
              ? PigeonBackgroundScheduler()
              : const NoopBackgroundScheduler()),
    );
    _instance = bee;
    try {
      await bee._start();
    } catch (e, st) {
      _instance = null;
      try {
        await bee._store.close();
      } on Object catch (_) {}
      bee._ready.completeError(e, st);
      bee._ready.future.ignore();
      bee._signals.dispose();
      rethrow;
    }
    return bee;
  }

  static BeeSync? _instance;

  /// The instance created by [initialize].
  static BeeSync get instance =>
      _instance ??
      (throw StateError('Call BeeSync.initialize() before BeeSync.instance'));

  static Future<String> _defaultDatabasePath() async {
    final dir = Directory(
      p.join((await getApplicationSupportDirectory()).path, 'bee_sync'),
    );
    await dir.create(recursive: true);
    return p.join(dir.path, 'bee_sync.db');
  }

  final BeeSyncConfig config;
  final EventStore _store;
  final PlatformSignals _signals;
  final Random _random;
  final BackgroundScheduler _background;
  final String _owner;
  static const _uuid = Uuid();
  static const _immediateDebounce = Duration(milliseconds: 50);
  static const _statsDebounce = Duration(milliseconds: 100);

  final _ready = Completer<void>();
  final _statsController = StreamController<QueueStats>.broadcast();
  final _eventsController = StreamController<DeliveryEvent>.broadcast();
  final List<StreamSubscription<void>> _subscriptions = [];
  late final FlushController _flusher;

  Timer? _intervalTimer;
  Timer? _immediateTimer;
  Timer? _statsTimer;
  Future<FlushResult>? _runningFlush;
  bool _flushAgain = false;
  bool _closed = false;
  bool _backgroundEnabled = false;

  late ConsentState _consent;
  DateTime? _lastSuccessAt;
  String? _lastError;
  final _activity = ListQueue<ActivityEntry>();
  static const _activityLimit = 50;
  bool _simulateOffline = false;

  BeeLogger get _log => config.logger;

  /// Queue snapshots, emitted (debounced) whenever something changes.
  Stream<QueueStats> get stats => _statsController.stream;

  /// Delivery, drop and failure notifications.
  ///
  /// Covers this process only; deliveries made by the native background
  /// uploader show up in [getStats] counters and [backgroundLog].
  Stream<DeliveryEvent> get events => _eventsController.stream;

  ConsentState get consent => _consent;

  /// Whether native background delivery is active.
  bool get backgroundEnabled => _backgroundEnabled;

  // ---- Lifecycle -----------------------------------------------------------

  Future<void> _start() async {
    _flusher = FlushController(
      store: _store,
      transport: _SwitchableTransport(config.transport, () => _simulateOffline),
      settings: DeliverySettings.fromConfig(config),
      owner: _owner,
      random: _random,
      listener: this,
      logger: config.logger,
    );
    await _store.open();
    await _loadConsent();
    await _persistTransportConfig();
    await _store.setMeta(
      MetaKeys.deliveryConfig,
      jsonEncode(DeliverySettings.fromConfig(config).toJson()),
    );
    await _enforceRetention();
    await _configureBackground();

    _subscriptions
      ..add(_signals.appBackgrounded.listen((_) => _onBackgrounded()))
      ..add(_signals.connectivityRestored.listen((_) => _onConnectivity()));
    _intervalTimer = Timer.periodic(
      config.batching.flushInterval,
      (_) => _onInterval(),
    );
    _ready.complete();
    _log.log(
      LogLevel.info,
      'bee_sync started (consent: ${_consent.name}, '
      'background: $_backgroundEnabled)',
    );
    _requestFlush();
    _scheduleStats();
  }

  Future<void> _loadConsent() async {
    final consent = await _store.getMeta(MetaKeys.consent);
    _consent = ConsentState.values.firstWhere(
      (c) => c.name == consent,
      orElse: () => config.consent.initial,
    );
    if (consent == null) {
      await _store.setMeta(MetaKeys.consent, _consent.name);
    }
  }

  Future<void> _configureBackground() async {
    final path = _store.databasePath;
    final wanted = config.background.enabled;
    final httpTransport = config.transport is HttpTransport;
    if (wanted && !httpTransport) {
      _log.log(
        LogLevel.warn,
        'Background delivery needs HttpTransport; it is off for '
        '${config.transport.runtimeType}.',
      );
    }
    _backgroundEnabled = wanted && httpTransport && path != null;
    try {
      final warnings = await _background.configure(
        databasePath: path ?? '',
        enabled: _backgroundEnabled,
      );
      for (final w in warnings) {
        _log.log(LogLevel.warn, w);
      }
      if (!_backgroundEnabled) await _background.cancel();
    } catch (e, st) {
      // A missing native side (e.g. unit tests, unsupported platform) must not
      // stop foreground delivery.
      _backgroundEnabled = false;
      _log.log(
        LogLevel.warn,
        'Background delivery unavailable',
        error: e,
        stackTrace: st,
      );
    }
  }

  /// Stops flushing, waits for an in-progress flush and closes the store.
  /// Undelivered events stay on disk for the next launch (and for the native
  /// background uploader).
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _intervalTimer?.cancel();
    _immediateTimer?.cancel();
    _statsTimer?.cancel();
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    _signals.dispose();
    await _runningFlush;
    await _store.close();
    await _statsController.close();
    await _eventsController.close();
    if (identical(_instance, this)) _instance = null;
  }

  // ---- Tracking ------------------------------------------------------------

  /// Persists an event and returns its id once it is durable on disk.
  ///
  /// Throws [InvalidEventException] for an empty [name], non-JSON
  /// [properties], or a payload over `maxEventBytes`. Events refused by
  /// consent or the overflow policy are not stored; they are reported on
  /// [events] as [Dropped] and still get an id.
  Future<String> track(
    String name, {
    Map<String, Object?> properties = const {},
    Priority priority = Priority.normal,
  }) async {
    if (!_ready.isCompleted) await _ready.future;
    _checkOpen();
    if (name.isEmpty) throw const InvalidEventException('Event name is empty');

    final List<int> payload;
    try {
      payload = utf8.encode(jsonEncode(properties));
    } on JsonUnsupportedObjectError catch (e) {
      throw InvalidEventException(
        'Properties of "$name" are not JSON-encodable: ${e.unsupportedObject}',
      );
    }
    if (payload.length > config.maxEventBytes) {
      throw InvalidEventException(
        'Event "$name" is ${payload.length} bytes; '
        'maxEventBytes is ${config.maxEventBytes}',
      );
    }

    final id = _uuid.v7();
    if (!_acceptsNewEvents) {
      await _recordDropped([id], DropReason.noConsent);
      return id;
    }

    final now = clock.now().millisecondsSinceEpoch;
    final retention = config.retention;
    if (retention.overflow == OverflowPolicy.dropNewest) {
      final t = await _store.totals(now);
      if (t.total + 1 > retention.maxEvents ||
          t.bytes + payload.length > retention.maxBytes) {
        await _recordDropped([id], DropReason.overflow);
        return id;
      }
    }

    await _store.insert(
      NewEvent(
        id: id,
        name: name,
        payload: Uint8List.fromList(payload),
        priority: priority,
        createdAt: now,
      ),
    );
    _log.log(LogLevel.trace, 'Tracked $name $id ${utf8.decode(payload)}');

    if (retention.overflow == OverflowPolicy.dropOldest) {
      final evicted = await _store.evict(
        now: now,
        maxEvents: retention.maxEvents,
        maxBytes: retention.maxBytes,
      );
      if (evicted.isNotEmpty) {
        await _recordDropped(evicted, DropReason.overflow);
      }
    }

    if (priority == Priority.immediate) {
      _immediateTimer ??= Timer(_immediateDebounce, () {
        _immediateTimer = null;
        _requestFlush(immediateOnly: true);
      });
    } else if ((await _store.totals(now)).pending >= config.batching.flushAt) {
      _requestFlush();
    }
    _scheduleStats();
    return id;
  }

  bool get _acceptsNewEvents => switch (_consent) {
    ConsentState.granted => true,
    ConsentState.denied => false,
    ConsentState.unknown =>
      config.consent.whileUnknown == UnknownConsentBehavior.hold,
  };

  // ---- Flushing ------------------------------------------------------------

  /// Sends everything that is ready now.
  ///
  /// Unlike automatic flushes, this ignores the global backoff and a previous
  /// auth failure. Per-event backoff still applies, and nothing is sent unless
  /// consent is granted.
  Future<FlushResult> flush() async {
    if (!_ready.isCompleted) await _ready.future;
    _checkOpen();
    return _flush(manual: true);
  }

  void _requestFlush({bool immediateOnly = false}) {
    if (_closed) return;
    unawaited(_flush(immediateOnly: immediateOnly));
  }

  Future<FlushResult> _flush({
    bool manual = false,
    bool immediateOnly = false,
  }) {
    final running = _runningFlush;
    if (running != null) {
      // Coalesce: one more pass after the current one picks up new events.
      _flushAgain = true;
      return running;
    }
    final future = _doFlush(manual: manual, immediateOnly: immediateOnly);
    _runningFlush = future;
    return future.whenComplete(() {
      _runningFlush = null;
      if (_flushAgain && !_closed) {
        _flushAgain = false;
        _requestFlush();
      }
    });
  }

  Future<FlushResult> _doFlush({
    required bool manual,
    required bool immediateOnly,
  }) async {
    try {
      final result = await _flusher.run(
        manual: manual,
        immediateOnly: immediateOnly,
        shouldContinue: () => !_closed && _consent == ConsentState.granted,
      );
      if (result.delivered > 0) _lastSuccessAt = clock.now();
      switch (result.status) {
        case FlushStatus.backingOff:
          _reportFailure(result.error ?? 'retryable failure', result.retryAt);
        case FlushStatus.authBlocked:
          _reportFailure(result.error ?? 'auth failure', null);
        case FlushStatus.drained || FlushStatus.skipped:
          break;
      }
      return result;
    } catch (e, st) {
      // Storage errors: leased events are released when the lease expires.
      _log.log(LogLevel.error, 'Flush failed', error: e, stackTrace: st);
      _reportFailure('$e', null);
      return FlushResult(FlushStatus.skipped, error: '$e');
    } finally {
      _scheduleStats();
    }
  }

  void _reportFailure(String reason, DateTime? retryAt) {
    _lastError = reason;
    _emit(FlushFailed(reason, retryAt: retryAt));
  }

  Future<void> _onBackgrounded() async {
    if (_closed) return;
    await _flush();
    if (!_backgroundEnabled || _closed) return;
    try {
      final remaining = await _store.totals(clock.now().millisecondsSinceEpoch);
      if (remaining.total > 0) {
        await _background.schedule();
      } else {
        await _background.cancel();
      }
    } catch (e, st) {
      _log.log(
        LogLevel.warn,
        'Background scheduling failed',
        error: e,
        stackTrace: st,
      );
    }
  }

  Future<void> _onInterval() async {
    if (_closed) return;
    try {
      await _enforceRetention();
    } catch (e, st) {
      _log.log(
        LogLevel.warn,
        'Retention sweep failed',
        error: e,
        stackTrace: st,
      );
    }
    _requestFlush();
  }

  Future<void> _onConnectivity() async {
    if (_closed) return;
    try {
      // The outage was probably why we were backing off; try again now.
      await _resetBackoff();
    } catch (e, st) {
      _log.log(LogLevel.warn, 'Backoff reset failed', error: e, stackTrace: st);
    }
    _requestFlush();
  }

  Future<void> _enforceRetention() async {
    final now = clock.now().millisecondsSinceEpoch;
    final expired = await _store.deleteExpired(
      createdBefore: now - config.retention.maxAge.inMilliseconds,
      now: now,
    );
    if (expired.isNotEmpty) await _recordDropped(expired, DropReason.expired);
    final evicted = await _store.evict(
      now: now,
      maxEvents: config.retention.maxEvents,
      maxBytes: config.retention.maxBytes,
    );
    if (evicted.isNotEmpty) await _recordDropped(evicted, DropReason.overflow);
  }

  // ---- Settings ------------------------------------------------------------

  /// Replaces the [HttpTransport] headers (e.g. a refreshed auth token),
  /// persists them for background delivery, and resumes flushing if it was
  /// paused by an auth failure (here or in the background).
  Future<void> setHeaders(Map<String, String> headers) async {
    if (!_ready.isCompleted) await _ready.future;
    _checkOpen();
    final transport = config.transport;
    if (transport is! HttpTransport) {
      throw UnsupportedError('setHeaders requires HttpTransport');
    }
    transport.headers = headers;
    await _persistTransportConfig();
    await _store.setMeta(MetaKeys.authBlocked, '0');
    _requestFlush();
  }

  /// Updates and persists consent; the background uploader honours it too.
  ///
  /// [ConsentState.denied] stops capture and delivery; with [purge] it also
  /// deletes queued events. [ConsentState.granted] releases held events.
  Future<void> setConsent(ConsentState state, {bool purge = false}) async {
    if (!_ready.isCompleted) await _ready.future;
    _checkOpen();
    _consent = state;
    await _store.setMeta(MetaKeys.consent, state.name);
    if (purge) {
      final ids = await _store.purge();
      if (ids.isNotEmpty) await _recordDropped(ids, DropReason.noConsent);
    }
    _log.log(LogLevel.info, 'Consent set to ${state.name}');
    if (state == ConsentState.granted) _requestFlush();
    _scheduleStats();
  }

  /// Mirrors [HttpTransport] settings for the native uploader. With any other
  /// transport the key is removed, which tells native not to upload.
  Future<void> _persistTransportConfig() async {
    final transport = config.transport;
    if (transport is HttpTransport) {
      await _store.setMeta(
        MetaKeys.transportConfig,
        jsonEncode(transport.toConfigJson()),
      );
    } else {
      await _store.deleteMeta(MetaKeys.transportConfig);
    }
  }

  /// Makes every queued event eligible for delivery now and clears the global
  /// backoff (also the one set by a background run). Does not flush.
  Future<void> resetBackoff() async {
    if (!_ready.isCompleted) await _ready.future;
    _checkOpen();
    await _resetBackoff();
    _scheduleStats();
  }

  Future<void> _resetBackoff() async {
    await _store.resetBackoff();
    await _store.setMeta(MetaKeys.flushNotBefore, '0');
  }

  /// Deletes every queued event, including ones a background upload may be
  /// sending right now. Reported as [Dropped] with [DropReason.purged].
  /// Returns how many were removed.
  Future<int> purgeQueue() async {
    if (!_ready.isCompleted) await _ready.future;
    _checkOpen();
    final ids = await _store.purge();
    if (ids.isNotEmpty) await _recordDropped(ids, DropReason.purged);
    return ids.length;
  }

  // ---- Diagnostics (used by BeeSyncInspector) ---------------------------------

  /// Stored events, oldest first, read without claiming them.
  Future<List<QueuedEvent>> debugQueue({int limit = 200}) async {
    if (!_ready.isCompleted) await _ready.future;
    _checkOpen();
    return _store.inspect(
      now: clock.now().millisecondsSinceEpoch,
      limit: limit,
    );
  }

  /// The last 50 requests and drops made by this app, newest first. Native
  /// background runs are in [backgroundLog] instead.
  List<ActivityEntry> get debugActivity => List.unmodifiable(_activity);

  /// When true, this app's uploads fail as if offline (a retryable network
  /// error), so backoff and retries can be watched without a real outage.
  /// The native background uploader is not affected.
  bool get debugSimulateOffline => _simulateOffline;

  set debugSimulateOffline(bool value) {
    _simulateOffline = value;
    _log.log(LogLevel.info, 'Simulated offline: $value');
    if (!value) _requestFlush();
  }

  void _recordActivity(ActivityEntry entry) {
    _activity.addFirst(entry);
    while (_activity.length > _activityLimit) {
      _activity.removeLast();
    }
  }

  static String _describe(TransportResult result, int events) =>
      switch (result) {
        Success(:final rejectedIds) when rejectedIds.isEmpty =>
          '2xx: $events accepted',
        Success(:final rejectedIds) =>
          '2xx: ${events - rejectedIds.length} accepted, '
              '${rejectedIds.length} rejected',
        RetryableFailure(:final reason, :final retryAfter) =>
          retryAfter == null
              ? reason
              : '$reason, retry after ${retryAfter.inSeconds}s',
        AuthFailure(:final reason) => '$reason (auth refused)',
        PayloadTooLarge() => 'HTTP 413 (too large)',
        PermanentFailure(:final reason) => '$reason (refused)',
      };

  // ---- Stats & notifications -----------------------------------------------

  /// Current queue snapshot. Counters include deliveries and drops made by
  /// the native background uploader.
  Future<QueueStats> getStats() async {
    if (!_ready.isCompleted) await _ready.future;
    _checkOpen();
    final now = clock.now();
    final t = await _store.totals(now.millisecondsSinceEpoch);
    final counters = await _store.counters();
    final notBefore =
        int.tryParse(await _store.getMeta(MetaKeys.flushNotBefore) ?? '') ?? 0;
    return QueueStats(
      pending: t.pending,
      inFlight: t.inFlight,
      queuedBytes: t.bytes,
      sent: counters[CounterKeys.sent] ?? 0,
      dropped: Map.unmodifiable({
        for (final reason in DropReason.values)
          if ((counters[CounterKeys.dropped(reason)] ?? 0) > 0)
            reason: counters[CounterKeys.dropped(reason)]!,
      }),
      consent: _consent,
      lastSuccessAt: _lastSuccessAt,
      lastError: _lastError,
      backoffUntil: notBefore > now.millisecondsSinceEpoch
          ? DateTime.fromMillisecondsSinceEpoch(notBefore)
          : null,
    );
  }

  /// What the native background uploader did while the app was not running,
  /// newest first.
  Future<List<BackgroundLogEntry>> backgroundLog({int limit = 50}) async {
    if (!_ready.isCompleted) await _ready.future;
    _checkOpen();
    return _store.backgroundLog(limit);
  }

  /// Called by the flush controller; not part of the public API.
  @override
  void onDelivered(List<String> ids) {
    _emit(Delivered(List.unmodifiable(ids)));
    _scheduleStats();
  }

  /// Called by the flush controller; not part of the public API.
  @override
  void onDropped(List<String> ids, DropReason reason) {
    _log.log(LogLevel.debug, 'Dropped ${ids.length} event(s): ${reason.name}');
    _recordActivity(
      DropActivity(clock.now(), events: ids.length, reason: reason),
    );
    _emit(Dropped(List.unmodifiable(ids), reason));
    _scheduleStats();
  }

  /// Called by the flush controller; not part of the public API.
  @override
  void onRequest(EventBatch batch, TransportResult result, Duration elapsed) {
    _recordActivity(
      RequestActivity(
        clock.now(),
        batchId: batch.batchId,
        events: batch.events.length,
        succeeded: result is Success,
        outcome: _describe(result, batch.events.length),
        elapsed: elapsed,
      ),
    );
    _scheduleStats();
  }

  /// Drops decided here (consent, retention), as opposed to by an uploader,
  /// which counts its own drops.
  Future<void> _recordDropped(List<String> ids, DropReason reason) async {
    await _store.incrementCounters({CounterKeys.dropped(reason): ids.length});
    onDropped(ids, reason);
  }

  void _emit(DeliveryEvent event) {
    if (!_eventsController.isClosed) _eventsController.add(event);
  }

  void _scheduleStats() {
    if (_closed || _statsTimer != null) return;
    _statsTimer = Timer(_statsDebounce, () async {
      _statsTimer = null;
      if (_closed) return;
      try {
        final s = await getStats();
        if (!_statsController.isClosed) _statsController.add(s);
      } catch (e, st) {
        _log.log(
          LogLevel.warn,
          'Stats update failed',
          error: e,
          stackTrace: st,
        );
      }
    });
  }

  void _checkOpen() {
    if (_closed) throw StateError('BeeSync is closed');
  }
}

/// Lets `debugSimulateOffline` fail uploads without touching the real
/// transport.
class _SwitchableTransport implements EventTransport {
  _SwitchableTransport(this._inner, this._offline);

  final EventTransport _inner;
  final bool Function() _offline;

  @override
  Future<TransportResult> send(EventBatch batch) async => _offline()
      ? const RetryableFailure('Simulated offline')
      : _inner.send(batch);
}
