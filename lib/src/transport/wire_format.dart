import '../api/models.dart';

/// JSON body sent by `HttpTransport` and, in v0.2, by the native uploaders.
/// See doc/DESIGN.md §10.
Map<String, Object?> encodeBatch(
  EventBatch batch, {
  required DateTime sentAt,
}) => {
  'batch_id': batch.batchId,
  'sent_at': sentAt.millisecondsSinceEpoch,
  'events': [
    for (final e in batch.events)
      {
        'id': e.id,
        'name': e.name,
        'timestamp': e.timestamp.millisecondsSinceEpoch,
        'priority': e.priority.wireName,
        'attempt': e.attempt,
        'properties': e.properties,
      },
  ],
};

/// Reads the optional `{"rejected": [ids]}` from a 2xx response body.
/// Anything unparseable means "all accepted".
Set<String> parseRejectedIds(Object? decodedBody) {
  if (decodedBody is! Map) return const {};
  final rejected = decodedBody['rejected'];
  if (rejected is! List) return const {};
  return {
    for (final id in rejected)
      if (id is String) id,
  };
}
