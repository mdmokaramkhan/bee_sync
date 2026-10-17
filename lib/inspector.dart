/// Debug screen for bee_sync. Import separately so apps that don't use it
/// don't ship it:
///
/// ```dart
/// import 'package:bee_sync/inspector.dart';
///
/// if (kDebugMode) BeeSyncInspector.show(context);
/// ```
library;

export 'src/inspector/bee_sync_inspector.dart' show BeeSyncInspector;
