import Foundation

/// Keep in sync with `version` in pubspec.yaml.
let beeSyncVersion = "0.2.0"

enum MetaKeys {
  static let consent = "consent_state"
  static let transportConfig = "transport_config"
  static let deliveryConfig = "delivery_config"
  static let flushNotBefore = "flush_not_before"
  static let authBlocked = "auth_blocked"
}

enum CounterKeys {
  static let sent = "sent"
  static func dropped(_ reason: String) -> String { "dropped.\(reason)" }
}

/// `meta.delivery_config`; missing keys use the contract defaults (§1.2).
struct DeliverySettings {
  var maxBatchSize = 100
  var maxBatchBytes = 512 * 1024
  var leaseMs: Int64 = 60_000
  var retryBaseMs: Int64 = 2_000
  var retryMaxMs: Int64 = 600_000
  var maxAttempts = 12

  static func parse(_ json: String?) -> DeliverySettings {
    var s = DeliverySettings()
    guard let o = jsonObject(json) else { return s }
    if let v = o["max_batch_size"] as? NSNumber { s.maxBatchSize = v.intValue }
    if let v = o["max_batch_bytes"] as? NSNumber { s.maxBatchBytes = v.intValue }
    if let v = o["lease_ms"] as? NSNumber { s.leaseMs = v.int64Value }
    if let v = o["retry_base_ms"] as? NSNumber { s.retryBaseMs = v.int64Value }
    if let v = o["retry_max_ms"] as? NSNumber { s.retryMaxMs = v.int64Value }
    if let v = o["max_attempts"] as? NSNumber { s.maxAttempts = v.intValue }
    return s
  }
}

/// `meta.transport_config` (§1.1).
struct TransportConfig {
  let endpoint: URL
  let headers: [String: String]
  let gzip: Bool
  let timeoutMs: Int

  static func parse(_ json: String?) -> TransportConfig? {
    guard let o = jsonObject(json), let s = o["endpoint"] as? String, let url = URL(string: s)
    else { return nil }
    return TransportConfig(
      endpoint: url,
      headers: (o["headers"] as? [String: String]) ?? [:],
      gzip: (o["gzip"] as? Bool) ?? false,
      timeoutMs: (o["timeout_ms"] as? NSNumber)?.intValue ?? 30_000)
  }
}

private func jsonObject(_ json: String?) -> [String: Any]? {
  guard let data = json?.data(using: .utf8) else { return nil }
  return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

enum RunStatus: String {
  case drained, backingOff, authBlocked, skipped
}

struct RunResult {
  let status: RunStatus
  var delivered = 0
  var dropped = 0
  var retryAt: Int64?
  /// For skipped: consent, transport, auth, backoff; otherwise the failure.
  var error: String?
}

/// splitmix64; deterministic in tests, seeded from the system otherwise.
struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

/// The native uploader: spec/uploader_contract.md §2–4, step for step. The
/// Dart reference is lib/src/core/flush_controller.dart; both run
/// spec/fixtures.
final class NativeUploader {
  private let store: BeeSyncStore
  private let sender: HttpSender
  private let source: String
  private let clock: () -> Int64
  private var random: SeededGenerator
  private let owner = "ios:\(UUID().uuidString.lowercased())"
  private var dropped = 0

  init(
    store: BeeSyncStore,
    sender: HttpSender,
    source: String,
    clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
    seed: UInt64 = UInt64.random(in: 0...UInt64.max)
  ) {
    self.store = store
    self.sender = sender
    self.source = source
    self.clock = clock
    self.random = SeededGenerator(seed: seed)
  }

  /// One run. Background runs are never `manual`; it exists so the shared
  /// fixtures run unchanged. `shouldContinue` is checked before each batch
  /// (the OS can end background time at any point).
  func run(manual: Bool = false, shouldContinue: () -> Bool = { true }) throws -> RunResult {
    guard try store.getMeta(MetaKeys.consent) == "granted" else {
      return RunResult(status: .skipped, error: "consent")
    }
    guard let transport = TransportConfig.parse(try store.getMeta(MetaKeys.transportConfig)) else {
      return RunResult(status: .skipped, error: "transport")
    }
    let settings = DeliverySettings.parse(try store.getMeta(MetaKeys.deliveryConfig))
    let notBefore = Int64(try store.getMeta(MetaKeys.flushNotBefore) ?? "") ?? 0
    if !manual {
      if try store.getMeta(MetaKeys.authBlocked) == "1" {
        return RunResult(status: .skipped, error: "auth")
      }
      if clock() < notBefore {
        return RunResult(status: .skipped, retryAt: notBefore, error: "backoff")
      }
    }

    let result = try drain(transport, settings, shouldContinue)
    switch result.status {
    case .drained:
      if notBefore != 0 { try store.setMeta(MetaKeys.flushNotBefore, "0") }
      if manual { try store.setMeta(MetaKeys.authBlocked, "0") }
    case .backingOff:
      try store.setMeta(MetaKeys.flushNotBefore, "\(result.retryAt!)")
    case .authBlocked:
      try store.setMeta(MetaKeys.authBlocked, "1")
    case .skipped:
      break
    }
    return result
  }

  private struct Outcome {
    var delivered = 0
    var stop: RunStatus?
    var retryAt: Int64?
    var error: String?
  }

  private enum SendResult {
    case success(rejected: Set<String>)
    case retryable(reason: String, retryAfterMs: Int64?)
    case auth(reason: String)
    case tooLarge
    case permanent(reason: String)
  }

  private func drain(
    _ transport: TransportConfig, _ settings: DeliverySettings, _ shouldContinue: () -> Bool
  ) throws -> RunResult {
    var delivered = 0
    while shouldContinue() {
      let now = clock()
      let claimed = try store.claim(
        owner: owner, now: now, leaseUntil: now + settings.leaseMs, limit: settings.maxBatchSize)
      if claimed.isEmpty {
        return RunResult(status: .drained, delivered: delivered, dropped: dropped)
      }

      let batch = trimToBytes(claimed, settings)
      if batch.count < claimed.count {
        try store.release(owner: owner, ids: claimed.dropFirst(batch.count).map(\.id))
      }

      let outcome = try send(batch, transport, settings)
      delivered += outcome.delivered
      if let stop = outcome.stop {
        return RunResult(
          status: stop, delivered: delivered, dropped: dropped, retryAt: outcome.retryAt,
          error: outcome.error)
      }
    }
    return RunResult(status: .skipped, delivered: delivered, dropped: dropped)
  }

  private func trimToBytes(_ events: [StoredEvent], _ settings: DeliverySettings) -> [StoredEvent] {
    var bytes = 0
    for (i, e) in events.enumerated() {
      bytes += e.sizeBytes
      // Always send at least one event, even if it alone exceeds the limit.
      if i > 0 && bytes > settings.maxBatchBytes { return Array(events.prefix(i)) }
    }
    return events
  }

  private func send(
    _ events: [StoredEvent], _ transport: TransportConfig, _ settings: DeliverySettings
  ) throws -> Outcome {
    var readable: [(StoredEvent, [String: Any])] = []
    var unreadable: [String] = []
    for e in events {
      if let properties = decode(e) { readable.append((e, properties)) } else { unreadable.append(e.id) }
    }
    if !unreadable.isEmpty { try drop(unreadable, "unreadable") }
    if readable.isEmpty { return Outcome() }
    let rows = readable.map(\.0)

    switch post(readable, transport) {
    case .success(let rejected):
      let ids = rows.map(\.id)
      let rejectedIds = ids.filter { rejected.contains($0) }
      let accepted = ids.count - rejectedIds.count
      try store.deleteLeased(
        owner: owner, ids: ids,
        counters: [
          CounterKeys.sent: accepted, CounterKeys.dropped("rejectedByServer"): rejectedIds.count,
        ])
      dropped += rejectedIds.count
      return Outcome(delivered: accepted)
    case .retryable(let reason, let retryAfterMs):
      return try retry(rows, settings, reason, retryAfterMs)
    case .auth(let reason):
      try store.release(owner: owner, ids: rows.map(\.id))
      return Outcome(stop: .authBlocked, error: reason)
    case .tooLarge:
      return try splitOrDrop(rows, "tooLarge", transport, settings)
    case .permanent:
      return try splitOrDrop(rows, "rejectedByServer", transport, settings)
    }
  }

  private func splitOrDrop(
    _ events: [StoredEvent], _ reason: String, _ transport: TransportConfig,
    _ settings: DeliverySettings
  ) throws -> Outcome {
    if events.count == 1 {
      try drop([events[0].id], reason)
      return Outcome()
    }
    let mid = events.count / 2
    let first = try send(Array(events[..<mid]), transport, settings)
    if first.stop != nil {
      try store.release(owner: owner, ids: events[mid...].map(\.id))
      return first
    }
    var second = try send(Array(events[mid...]), transport, settings)
    second.delivered += first.delivered
    return second
  }

  private func retry(
    _ events: [StoredEvent], _ settings: DeliverySettings, _ reason: String, _ retryAfterMs: Int64?
  ) throws -> Outcome {
    let now = clock()
    var exhausted: [String] = []
    var retry: [String] = []
    var maxAttempt = 1
    for e in events {
      let attempt = e.attempts + 1
      if attempt >= settings.maxAttempts {
        exhausted.append(e.id)
      } else {
        retry.append(e.id)
        maxAttempt = max(maxAttempt, attempt)
      }
    }
    var delay = backoffDelay(maxAttempt, settings)
    if let after = retryAfterMs, after > delay { delay = after }
    let retryAt = now + delay

    if !exhausted.isEmpty { try drop(exhausted, "maxAttempts") }
    try store.releaseRetry(owner: owner, ids: retry, nextAttemptAt: retryAt)
    return Outcome(stop: .backingOff, retryAt: retryAt, error: reason)
  }

  /// §3.1: equal jitter in [cap/2, cap].
  private func backoffDelay(_ attempt: Int, _ settings: DeliverySettings) -> Int64 {
    let exp = Int64(min(max(attempt - 1, 0), 30))
    let cap = min(settings.retryMaxMs, settings.retryBaseMs * (Int64(1) << exp))
    let half = cap / 2
    return half + Int64.random(in: 0...(cap - half), using: &random)
  }

  private func drop(_ ids: [String], _ reason: String) throws {
    try store.deleteLeased(owner: owner, ids: ids, counters: [CounterKeys.dropped(reason): ids.count])
    dropped += ids.count
  }

  private func decode(_ e: StoredEvent) -> [String: Any]? {
    if e.encrypted { return nil }  // Encryption arrives in v0.3.
    return (try? JSONSerialization.jsonObject(with: e.payload, options: [.fragmentsAllowed]))
      as? [String: Any]
  }

  private func post(_ events: [(StoredEvent, [String: Any])], _ transport: TransportConfig)
    -> SendResult
  {
    let batchId = UUID().uuidString.lowercased()
    let body: [String: Any] = [
      "batch_id": batchId,
      "sent_at": clock(),
      "events": events.map { e, properties -> [String: Any] in
        [
          "id": e.id,
          "name": e.name,
          "timestamp": e.createdAt,
          "priority": e.priority == 1 ? "immediate" : "normal",
          "attempt": e.attempts + 1,
          "properties": properties,
        ]
      },
    ]
    guard var data = try? JSONSerialization.data(withJSONObject: body) else {
      return .retryable(reason: "Encoding failed", retryAfterMs: nil)
    }
    var headers = transport.headers
    headers["Content-Type"] = "application/json"
    headers["X-BeeSync-Batch-Id"] = batchId
    headers["X-BeeSync-Sdk"] = "bee_sync/\(beeSyncVersion) (ios; \(source))"
    if transport.gzip {
      data = gzip(data)
      headers["Content-Encoding"] = "gzip"
    }

    let response: HttpResponse
    do {
      response = try sender.post(
        url: transport.endpoint, headers: headers, body: data,
        timeout: TimeInterval(transport.timeoutMs) / 1000)
    } catch {
      return .retryable(reason: "Network error: \((error as NSError).code)", retryAfterMs: nil)
    }
    return classify(response)
  }

  private func classify(_ response: HttpResponse) -> SendResult {
    let status = response.status
    let reason = "HTTP \(status)"
    switch status {
    case 200...299: return .success(rejected: Self.rejectedIds(response.body))
    case 401, 403: return .auth(reason: reason)
    case 413: return .tooLarge
    case 408, 429, 500...:
      return .retryable(
        reason: reason, retryAfterMs: Self.parseRetryAfter(response.headers["retry-after"], now: clock()))
    case 400...: return .permanent(reason: reason)
    default: return .retryable(reason: "Unexpected \(reason)", retryAfterMs: nil)  // 1xx/3xx
    }
  }

  private static func rejectedIds(_ body: Data) -> Set<String> {
    guard let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
      let rejected = o["rejected"] as? [Any]
    else { return [] }
    return Set(rejected.compactMap { $0 as? String })
  }

  private static let httpDate: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "GMT")
    f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return f
  }()

  /// `Retry-After`: delay-seconds or an HTTP-date, in ms. Nil when absent or invalid.
  static func parseRetryAfter(_ value: String?, now: Int64) -> Int64? {
    guard let raw = value?.trimmingCharacters(in: .whitespaces) else { return nil }
    if let seconds = Int64(raw) { return seconds < 0 ? nil : seconds * 1000 }
    guard let date = httpDate.date(from: raw) else { return nil }
    return max(0, Int64(date.timeIntervalSince1970 * 1000) - now)
  }
}
