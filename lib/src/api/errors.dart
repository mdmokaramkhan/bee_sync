/// Base class for errors thrown by bee_sync.
class BeeSyncException implements Exception {
  const BeeSyncException(this.message);

  final String message;

  @override
  String toString() => 'BeeSyncException: $message';
}

/// Thrown by `track()` when an event can never be delivered as given: an
/// empty name, properties that are not JSON-encodable, or a payload larger
/// than `BeeSyncConfig.maxEventBytes`.
class InvalidEventException extends BeeSyncException {
  const InvalidEventException(super.message);

  @override
  String toString() => 'InvalidEventException: $message';
}
