import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';

/// App and device events that should trigger a flush.
abstract interface class PlatformSignals {
  /// The app moved to the background (lifecycle `paused` / `hidden`).
  Stream<void> get appBackgrounded;

  /// Connectivity came back after being offline. A hint only: the request is
  /// the real test of reachability.
  Stream<void> get connectivityRestored;

  void dispose();
}

/// [PlatformSignals] from Flutter's lifecycle and `connectivity_plus`.
class FlutterPlatformSignals implements PlatformSignals {
  FlutterPlatformSignals({Connectivity? connectivity})
    : _connectivity = connectivity ?? Connectivity() {
    WidgetsFlutterBinding.ensureInitialized();
    _lifecycle = AppLifecycleListener(onHide: () => _backgrounded.add(null));
    _connectivitySub = _connectivity.onConnectivityChanged.listen((results) {
      final online = results.any((r) => r != ConnectivityResult.none);
      if (online && _wasOffline) _restored.add(null);
      _wasOffline = !online;
    }, onError: (Object _) {});
  }

  final Connectivity _connectivity;
  late final AppLifecycleListener _lifecycle;
  late final StreamSubscription<List<ConnectivityResult>> _connectivitySub;
  final _backgrounded = StreamController<void>.broadcast();
  final _restored = StreamController<void>.broadcast();
  bool _wasOffline = false;

  @override
  Stream<void> get appBackgrounded => _backgrounded.stream;

  @override
  Stream<void> get connectivityRestored => _restored.stream;

  @override
  void dispose() {
    _lifecycle.dispose();
    _connectivitySub.cancel();
    _backgrounded.close();
    _restored.close();
  }
}
