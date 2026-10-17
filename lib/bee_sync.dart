/// Durable, offline-first event delivery for Flutter.
///
/// See doc/DESIGN.md for the architecture and delivery guarantees.
library;

export 'src/api/bee_sync.dart' show BeeSync;
export 'src/api/config.dart';
export 'src/api/errors.dart';
export 'src/api/models.dart';
export 'src/core/flush_controller.dart' show FlushResult, FlushStatus;
export 'src/diagnostics/logger.dart';
export 'src/platform/background.dart' show BackgroundScheduler;
export 'src/platform/signals.dart' show PlatformSignals;
export 'src/store/event_store.dart' show CounterKeys, EventStore, MetaKeys;
export 'src/transport/event_transport.dart';
export 'src/transport/http_transport.dart';
