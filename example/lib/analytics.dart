import 'dart:math';

import 'package:bee_sync/bee_sync.dart';
import 'package:flutter/widgets.dart';

/// App analytics on top of bee_sync, the way a real app would wrap it:
/// sessions, app foreground/background, screen views and widget views.
///
/// Every event carries `session_id` and `seq` (1, 2, 3, … within a session),
/// so the server can check that no event of a session is missing.
class Analytics {
  Analytics(this._bee, {this.autoEvents = true});

  final BeeSync _bee;

  /// Whether sessions, screens and widget views are tracked. When false,
  /// only explicit [track] calls create events.
  final bool autoEvents;
  final _random = Random();

  /// A session ends after this long in the background.
  static const sessionTimeout = Duration(minutes: 30);

  late String _sessionId;
  int _seq = 0;
  DateTime _foregroundSince = DateTime.now();
  DateTime? _backgroundSince;
  AppLifecycleListener? _lifecycle;

  String? _screen;
  DateTime _screenSince = DateTime.now();
  final _viewedOnScreen = <String>{};

  String get sessionId => _sessionId;
  String? get currentScreen => _screen;

  /// Starts the first session and follows the app lifecycle.
  void start() {
    _startSession('cold_start');
    _lifecycle = AppLifecycleListener(onShow: _onShow, onHide: _onHide);
  }

  void dispose() => _lifecycle?.dispose();

  /// Called after each tracked event, for the example's log.
  void Function(String name, Priority priority)? onTracked;

  /// Tracks [name] with the session properties added.
  Future<String> track(
    String name, {
    Map<String, Object?> properties = const {},
    Priority priority = Priority.normal,
  }) async {
    final id = await _bee.track(
      name,
      properties: {
        ...properties,
        'session_id': _sessionId,
        'seq': ++_seq,
        if (_screen != null) 'screen': _screen,
      },
      priority: priority,
    );
    onTracked?.call(name, priority);
    return id;
  }

  /// A new screen is showing: a tab, or a pushed route.
  void screenView(String screen) {
    if (screen == _screen) return;
    final now = DateTime.now();
    final previous = _screen;
    final previousMs = now.difference(_screenSince).inMilliseconds;
    _screen = screen;
    _screenSince = now;
    _viewedOnScreen.clear();
    if (!autoEvents) return;
    track(
      'screen_view',
      properties: {
        'previous_screen': previous,
        if (previous != null) 'previous_screen_ms': previousMs,
      },
    );
  }

  /// [widget] (identified by [id]) came into view; tracked once per visit to
  /// the current screen.
  void widgetViewed(
    String widget,
    String id, [
    Map<String, Object?> properties = const {},
  ]) {
    if (!autoEvents || !_viewedOnScreen.add('$widget/$id')) return;
    track(
      'widget_viewed',
      properties: {'widget': widget, 'item_id': id, ...properties},
    );
  }

  void _startSession(String reason) {
    _sessionId =
        '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}-'
        '${_random.nextInt(1 << 32).toRadixString(36)}';
    _seq = 0;
    if (autoEvents) track('session_start', properties: {'reason': reason});
  }

  void _onHide() {
    final now = DateTime.now();
    _backgroundSince = now;
    if (!autoEvents) return;
    track(
      'app_background',
      properties: {
        'foreground_ms': now.difference(_foregroundSince).inMilliseconds,
      },
    );
  }

  void _onShow() {
    final now = DateTime.now();
    final away = _backgroundSince == null
        ? Duration.zero
        : now.difference(_backgroundSince!);
    _foregroundSince = now;
    if (away >= sessionTimeout) _startSession('timeout');
    if (!autoEvents) return;
    track('app_foreground', properties: {'background_ms': away.inMilliseconds});
  }
}

/// Reports pushed and popped routes as screen views. Routes need a name
/// (`RouteSettings.name`); popping back to an unnamed root reports
/// [rootScreen], the tab that is showing.
class AnalyticsRouteObserver extends NavigatorObserver {
  AnalyticsRouteObserver(this._analytics, {required this.rootScreen});

  final Analytics _analytics;
  final String Function() rootScreen;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    final name = route.settings.name;
    if (route is PageRoute && name != null && name != '/') {
      _analytics.screenView(name);
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is! PageRoute) return;
    final name = previousRoute?.settings.name;
    _analytics.screenView(name == null || name == '/' ? rootScreen() : name);
  }
}

/// Tracks `widget_viewed` when [child] is first built. Inside a lazy list
/// (`ListView.builder` with `cacheExtent: 0`) that is when it scrolls into
/// view.
class ViewTracker extends StatefulWidget {
  const ViewTracker({
    required this.analytics,
    required this.widgetName,
    required this.id,
    required this.child,
    this.properties = const {},
    super.key,
  });

  final Analytics analytics;
  final String widgetName;
  final String id;
  final Map<String, Object?> properties;
  final Widget child;

  @override
  State<ViewTracker> createState() => _ViewTrackerState();
}

class _ViewTrackerState extends State<ViewTracker> {
  @override
  void initState() {
    super.initState();
    widget.analytics.widgetViewed(
      widget.widgetName,
      widget.id,
      widget.properties,
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
