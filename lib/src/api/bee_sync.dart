import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../core/flush_controller.dart';
import '../diagnostics/logger.dart';
import '../platform/signals.dart';
import '../store/event_store.dart';
import '../store/sqflite_store.dart';
import '../transport/http_transport.dart';
import 'config.dart';
import 'errors.dart';
import 'models.dart';

/// Durable event delivery. See docs/DESIGN.md.
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
  BeeSync._(this.config, this._store, this._signals, this._random)
    : _owner = 'dart:${const Uuid().v4()}';

  /// Opens the queue and starts automatic flushing.
  ///
  /// [store], [signals] and [random] replace the defaults (SQLite in the
  /// app-support directory, Flutter lifecycle + connectivity, a secure
  /// random); they exist for tests and advanced setups.
  ///
  /// `BeeSync.instance` is usable as soon as this is called: events tracked
  /// before initialization completes are written once the store is open.
  static Future<BeeSync> initialize(
    BeeSyncConfig config, {
    EventStore? store,
    PlatformSignals? signals,
    Random? random,
  }) async {
    if (_instance != null) {
      throw StateError('BeeSync is already initialized; call close() first');
    }
    final bee = BeeSync._(
      config,
      store ?? SqfliteEventStore(path: await _defaultDatabasePath()),
      signals ?? FlutterPlatformSignals(),
      random ?? Random.secure(),
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

  late ConsentState _consent;
  bool _authBlocked = false;
  DateTime? _backoffUntil;
  DateTime? _lastSuccessAt;
  String? _lastError;
  int _sent = 0;
  final Map<DropReason, int> _dropped = {};

  BeeLogger get _log => config.logger;

  /// Queue snapshots, emitted (debounced) whenever something changes.
  Stream<QueueStats> get stats => _statsController.stream;

  /// Delivery, drop and failure notifications.
  Stream<DeliveryEvent> get events => _eventsController.stream;

  ConsentState get consent => _consent;

  // ---- Lifecycle -----------------------------------------------------------

  Future<void> _start() async {
    _flusher = FlushController(
      store: _store,
      transport: config.transport,
      config: config,
      owner: _owner,
      random: _random,
      listener: this,
    );
    await _store.open();
    await _loadMeta();
    await _persistTransportConfig();
    await _enforceRetention();

    _subscriptions
      ..add(_signals.appBackgrounded.listen((_) => _requestFlush()))
      ..add(_signals.connectivityRestored.listen((_) => _onConnectivity()));
    _intervalTimer = Timer.periodic(
      config.batching.flushInterval,
      (_) => _onInterval(),
    );
    _ready.complete();
    _log.log(LogLevel.info, 'bee_sync started (consent: ${_consent.name})');
    _requestFlush();
    _scheduleStats();
  }

  Future<void> _loadMeta() async {
    final consent = await _store.getMeta(_MetaKeys.consent);
    _consent = ConsentState.values.firstWhere(
      (c) => c.name == consent,
      orElse: () => config.consent.initial,
    );
    if (consent == null) {
      await _store.setMeta(_MetaKeys.consent, _consent.name);
    }

    final backoff = int.tryParse(
      await _store.getMeta(_MetaKeys.flushNotBefore) ?? '',
    );
    if (backoff != null && backoff > clock.now().millisecondsSinceEpoch) {
      _backoffUntil = DateTime.fromMillisecondsSinceEpoch(backoff);
    }

    final counters = await _store.getMeta(_MetaKeys.counters);
    if (counters != null) {
      try {
        final json = jsonDecode(counters) as Map<String, Object?>;
        _sent = json['sent'] as int? ?? 0;
        final dropped = json['dropped'] as Map<String, Object?>? ?? const {};
        for (final reason in DropReason.values) {
          final n = dropped[reason.name];
          if (n is int && n > 0) _dropped[reason] = n;
        }
      } on Object catch (e) {
        _log.log(LogLevel.warn, 'Ignoring corrupt counters', error: e);
      }
    }
  }

  /// Stops flushing, waits for an in-progress flush and closes the store.
  /// Undelivered events stay on disk for the next launch.
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
    await _persistCounters();
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
      onDropped([id], DropReason.noConsent);
      return id;
    }

    final now = clock.now().millisecondsSinceEpoch;
    final retention = config.retention;
    if (retention.overflow == OverflowPolicy.dropNewest) {
      final t = await _store.totals(now);
      if (t.total + 1 > retention.maxEvents ||
          t.bytes + payload.length > retention.maxBytes) {
        onDropped([id], DropReason.overflow);
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
      if (evicted.isNotEmpty) onDropped(evicted, DropReason.overflow);
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
    if (_consent != ConsentState.granted) {
      return const FlushResult(FlushStatus.skipped, error: 'consent');
    }
    if (!manual) {
      if (_authBlocked) {
        return const FlushResult(FlushStatus.skipped, error: 'auth');
      }
      final backoff = _backoffUntil;
      if (backoff != null && clock.now().isBefore(backoff)) {
        return FlushResult(FlushStatus.skipped, retryAt: backoff);
      }
    }

    try {
      final result = await _flusher.run(
        immediateOnly: immediateOnly,
        shouldContinue: () => !_closed && _consent == ConsentState.granted,
      );
      if (result.delivered > 0) _lastSuccessAt = clock.now();
      switch (result.status) {
        case FlushStatus.drained:
          _authBlocked = false;
          if (_backoffUntil != null) await _setBackoff(null);
        case FlushStatus.backingOff:
          await _setBackoff(result.retryAt);
          _reportFailure(result.error ?? 'retryable failure', result.retryAt);
        case FlushStatus.authBlocked:
          _authBlocked = true;
          _reportFailure(result.error ?? 'auth failure', null);
        case FlushStatus.skipped:
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

  Future<void> _setBackoff(DateTime? until) async {
    _backoffUntil = until;
    await _store.setMeta(
      _MetaKeys.flushNotBefore,
      '${until?.millisecondsSinceEpoch ?? 0}',
    );
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
      await _store.resetBackoff();
      await _setBackoff(null);
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
    if (expired.isNotEmpty) onDropped(expired, DropReason.expired);
    final evicted = await _store.evict(
      now: now,
      maxEvents: config.retention.maxEvents,
      maxBytes: config.retention.maxBytes,
    );
    if (evicted.isNotEmpty) onDropped(evicted, DropReason.overflow);
  }

  // ---- Settings ------------------------------------------------------------

  /// Replaces the [HttpTransport] headers (e.g. a refreshed auth token),
  /// persists them for background delivery, and resumes flushing if it was
  /// paused by an auth failure.
  Future<void> setHeaders(Map<String, String> headers) async {
    if (!_ready.isCompleted) await _ready.future;
    _checkOpen();
    final transport = config.transport;
    if (transport is! HttpTransport) {
      throw UnsupportedError('setHeaders requires HttpTransport');
    }
    transport.headers = headers;
    await _persistTransportConfig();
    _authBlocked = false;
    _requestFlush();
  }

  /// Updates and persists consent.
  ///
  /// [ConsentState.denied] stops capture and delivery; with [purge] it also
  /// deletes queued events. [ConsentState.granted] releases held events.
  Future<void> setConsent(ConsentState state, {bool purge = false}) async {
    if (!_ready.isCompleted) await _ready.future;
    _checkOpen();
    _consent = state;
    await _store.setMeta(_MetaKeys.consent, state.name);
    if (purge) {
      final ids = await _store.purge();
      if (ids.isNotEmpty) onDropped(ids, DropReason.noConsent);
    }
    _log.log(LogLevel.info, 'Consent set to ${state.name}');
    if (state == ConsentState.granted) _requestFlush();
    _scheduleStats();
  }

  Future<void> _persistTransportConfig() async {
    final transport = config.transport;
    if (transport is HttpTransport) {
      await _store.setMeta(
        _MetaKeys.transportConfig,
        jsonEncode(transport.toConfigJson()),
      );
    }
  }

  // ---- Stats & notifications -----------------------------------------------

  /// Current queue snapshot.
  Future<QueueStats> getStats() async {
    if (!_ready.isCompleted) await _ready.future;
    _checkOpen();
    final t = await _store.totals(clock.now().millisecondsSinceEpoch);
    return QueueStats(
      pending: t.pending,
      inFlight: t.inFlight,
      queuedBytes: t.bytes,
      sent: _sent,
      dropped: Map.unmodifiable(_dropped),
      consent: _consent,
      lastSuccessAt: _lastSuccessAt,
      lastError: _lastError,
      backoffUntil: _backoffUntil,
    );
  }

  /// Called by the flush controller; not part of the public API.
  @override
  void onDelivered(List<String> ids) {
    _sent += ids.length;
    _emit(Delivered(List.unmodifiable(ids)));
    _scheduleStats();
  }

  /// Called by the flush controller; not part of the public API.
  @override
  void onDropped(List<String> ids, DropReason reason) {
    _dropped[reason] = (_dropped[reason] ?? 0) + ids.length;
    _log.log(LogLevel.debug, 'Dropped ${ids.length} event(s): ${reason.name}');
    _emit(Dropped(List.unmodifiable(ids), reason));
    _scheduleStats();
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
        await _persistCounters();
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

  Future<void> _persistCounters() => _store.setMeta(
    _MetaKeys.counters,
    jsonEncode({
      'sent': _sent,
      'dropped': {for (final e in _dropped.entries) e.key.name: e.value},
    }),
  );

  void _checkOpen() {
    if (_closed) throw StateError('BeeSync is closed');
  }
}

/// Keys in the `meta` table. Shared with the native uploaders.
abstract final class _MetaKeys {
  static const consent = 'consent_state';
  static const flushNotBefore = 'flush_not_before';
  static const counters = 'counters';
  static const transportConfig = 'transport_config';
}
