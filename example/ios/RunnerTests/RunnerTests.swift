import Compression
import SQLite3
import XCTest

@testable import bee_sync

/// spec/ in the repo; the Simulator can read host paths.
private let specDir = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()  // RunnerTests
  .deletingLastPathComponent()  // ios
  .deletingLastPathComponent()  // example
  .deletingLastPathComponent()  // repo root
  .appendingPathComponent("spec")

// MARK: - Helpers

/// `-- name: x` sections of a spec SQL file, normalized like the Dart and
/// Kotlin conformance tests.
private func parseSpec(_ file: String) throws -> [String: String] {
  var statements: [String: String] = [:]
  var name: String?
  var buffer = ""
  func finish() {
    if let n = name { statements[n] = normalize(buffer) }
    buffer = ""
  }
  let text = try String(contentsOf: specDir.appendingPathComponent(file), encoding: .utf8)
  for line in text.components(separatedBy: "\n") {
    if line.hasPrefix("-- name: ") {
      finish()
      name = String(line.dropFirst("-- name: ".count)).trimmingCharacters(in: .whitespaces)
    } else if !line.trimmingCharacters(in: .whitespaces).hasPrefix("--") {
      buffer += line + "\n"
    }
  }
  finish()
  return statements
}

private func normalize(_ s: String) -> String {
  var out = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    .trimmingCharacters(in: .whitespaces)
  if out.hasSuffix(";") { out.removeLast() }
  return out
}

private func json(_ file: String) throws -> [String: Any] {
  let data = try Data(contentsOf: specDir.appendingPathComponent(file))
  return try JSONSerialization.jsonObject(with: data) as! [String: Any]
}

/// A v2 database created the way Dart creates it.
private final class TestDb {
  let dir: URL
  let path: String
  let store: BeeSyncStore

  init(version: Int32 = Sql.schemaVersion) throws {
    dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    path = dir.appendingPathComponent("bee_sync.db").path
    var handle: OpaquePointer?
    sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
    sqlite3_exec(handle, "PRAGMA journal_mode = WAL", nil, nil, nil)
    for sql in Sql.schemaStatements.values { sqlite3_exec(handle, sql, nil, nil, nil) }
    sqlite3_exec(handle, "PRAGMA user_version = \(version)", nil, nil, nil)
    sqlite3_close(handle)
    store = try BeeSyncStore.open(path: path)!
  }

  deinit { try? FileManager.default.removeItem(at: dir) }

  func insert(
    id: String, payload: Data, name: String = "evt", priority: Int = 0, createdAt: Int64 = 0,
    attempts: Int = 0, nextAttemptAt: Int64 = 0, leaseOwner: String? = nil, leaseUntil: Int64? = nil
  ) throws {
    try store.execute(
      """
      INSERT INTO events (id, name, payload, encrypted, priority, created_at, size_bytes,
        attempts, next_attempt_at, lease_owner, lease_until)
      VALUES (?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?)
      """,
      [id, name, payload, Int64(priority), createdAt, Int64(payload.count), Int64(attempts),
       nextAttemptAt, leaseOwner, leaseUntil])
  }

  func transport(gzip: Bool = false, headers: [String: String] = [:]) throws {
    let config: [String: Any] = [
      "endpoint": "https://example.test/events", "headers": headers, "gzip": gzip,
      "timeout_ms": 5000,
    ]
    let data = try JSONSerialization.data(withJSONObject: config)
    try store.setMeta(MetaKeys.transportConfig, String(data: data, encoding: .utf8)!)
  }

  func logLines() throws -> [String] {
    var lines: [String] = []
    try store.query(Sql.selectBgLog, [Int64(10)]) { s in
      lines.append(
        "\(String(cString: sqlite3_column_text(s, 1)))/\(String(cString: sqlite3_column_text(s, 2))): \(String(cString: sqlite3_column_text(s, 3)))"
      )
    }
    return lines
  }
}

/// Answers URLSession requests from a script, so the real URLSessionSender
/// is exercised.
final class StubProtocol: URLProtocol {
  enum Reply {
    case http(status: Int, headers: [String: String], body: Data)
    case networkError
    /// A real redirect, as a server's 302 would produce.
    case redirect(to: URL)
  }

  static var reply: ((URLRequest, Data) -> Reply)?

  static func configuration() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    return config
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  override func startLoading() {
    var body = request.httpBody ?? Data()
    if body.isEmpty, let stream = request.httpBodyStream {
      stream.open()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while stream.hasBytesAvailable {
        let n = stream.read(&buffer, maxLength: buffer.count)
        if n <= 0 { break }
        body.append(buffer, count: n)
      }
      stream.close()
    }
    switch Self.reply?(request, body) ?? .networkError {
    case .networkError:
      client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    case .redirect(let target):
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
        headerFields: ["Location": target.absoluteString])!
      client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocolDidFinishLoading(self)
    case .http(let status, let headers, let data):
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    }
  }
}

private func eventIds(_ body: Data) -> [String] {
  let o = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
  return (o["events"] as! [[String: Any]]).map { $0["id"] as! String }
}

// MARK: - Tests

class SqlConformanceTests: XCTestCase {
  func testSchemaMatchesSpec() throws {
    XCTAssertEqual(try parseSpec("schema.sql"), Sql.schemaStatements.mapValues(normalize))
  }

  func testClaimProtocolMatchesSpec() throws {
    XCTAssertEqual(try parseSpec("claim_protocol.sql"), Sql.protocolStatements.mapValues(normalize))
  }
}

/// Runs spec/fixtures/uploader through the iOS uploader, as the Dart and
/// Kotlin suites do.
class UploaderFixtureTests: XCTestCase {
  override func tearDown() {
    StubProtocol.reply = nil
  }

  func testAllFixtures() throws {
    let files = try FileManager.default
      .contentsOfDirectory(atPath: specDir.appendingPathComponent("fixtures/uploader").path)
      .filter { $0.hasSuffix(".json") }
      .sorted()
    XCTAssertFalse(files.isEmpty)
    for file in files {
      for seed: UInt64 in [0, 1, 2] {
        try XCTContext.runActivity(named: "\(file) seed \(seed)") { _ in
          try runFixture(file, seed: seed)
        }
      }
    }
  }

  private func runFixture(_ file: String, seed: UInt64) throws {
    let fixture = try json("fixtures/uploader/\(file)")
    let label = "\(file) seed \(seed)"
    let now = (fixture["now"] as! NSNumber).int64Value
    let db = try TestDb()

    for e in fixture["events"] as! [[String: Any]] {
      let payload: Data
      if let raw = e["payload_raw"] as? String {
        payload = Data(raw.utf8)
      } else {
        payload = try JSONSerialization.data(withJSONObject: e["properties"]!)
      }
      try db.insert(
        id: e["id"] as! String, payload: payload, name: e["name"] as! String,
        priority: (e["priority"] as! String) == "immediate" ? 1 : 0,
        createdAt: (e["created_at"] as! NSNumber).int64Value,
        attempts: (e["attempts"] as! NSNumber).intValue,
        nextAttemptAt: (e["next_attempt_at"] as! NSNumber).int64Value,
        leaseOwner: e["lease_owner"] as? String,
        leaseUntil: (e["lease_until"] as? NSNumber)?.int64Value)
    }
    try db.store.setMeta(MetaKeys.consent, "granted")
    for (key, value) in (fixture["meta"] as? [String: String]) ?? [:] {
      try db.store.setMeta(key, value)
    }
    try db.transport()
    if let delivery = fixture["delivery_config"] {
      let data = try JSONSerialization.data(withJSONObject: delivery)
      try db.store.setMeta(MetaKeys.deliveryConfig, String(data: data, encoding: .utf8)!)
    }

    let responses = fixture["responses"] as! [[String: Any]]
    var requests: [[String]] = []
    var unexpected: [String]?
    StubProtocol.reply = { _, body in
      let ids = eventIds(body)
      requests.append(ids)
      guard requests.count <= responses.count else {
        unexpected = ids
        return .http(status: 500, headers: [:], body: Data())
      }
      let r = responses[requests.count - 1]
      if r["network_error"] as? Bool == true { return .networkError }
      return .http(
        status: (r["status"] as! NSNumber).intValue,
        headers: (r["headers"] as? [String: String]) ?? [:],
        body: Data(((r["body"] as? String) ?? "").utf8))
    }

    let result = try NativeUploader(
      store: db.store, sender: URLSessionSender(configuration: StubProtocol.configuration()), source: "test",
      clock: { now }, seed: seed
    ).run(
      manual: (fixture["manual"] as? Bool) ?? false,
      networkAvailable: (fixture["network_available"] as? Bool) ?? false)

    let expect = fixture["expect"] as! [String: Any]
    XCTAssertNil(unexpected, "\(label): unexpected request")
    XCTAssertEqual(result.status.rawValue, expect["status"] as? String, "\(label): status")
    XCTAssertEqual(requests, expect["requests"] as? [[String]], "\(label): requests")

    var rows: [(id: String, attempts: Int64, next: Int64, owner: String?)] = []
    try db.store.query("SELECT id, attempts, next_attempt_at, lease_owner FROM events ORDER BY seq", []) { s in
      rows.append(
        (String(cString: sqlite3_column_text(s, 0)), sqlite3_column_int64(s, 1),
         sqlite3_column_int64(s, 2), sqlite3_column_text(s, 3).map { String(cString: $0) }))
    }
    let remaining = expect["remaining"] as! [[String: Any]]
    XCTAssertEqual(rows.map(\.id), remaining.map { $0["id"] as! String }, "\(label): remaining ids")
    for (row, exp) in zip(rows, remaining) {
      XCTAssertFalse(row.owner?.hasPrefix("ios:") ?? false, "\(label): \(row.id) still leased")
      if let attempts = exp["attempts"] as? NSNumber {
        XCTAssertEqual(row.attempts, attempts.int64Value, "\(label): \(row.id).attempts")
      }
      if let next = exp["next_attempt_at"] {
        assertValue(next, row.next, "\(label): \(row.id).next_attempt_at")
      }
    }

    let counters = try db.store.counters().filter { $0.value != 0 }
    let expectedCounters = ((expect["counters"] as? [String: NSNumber]) ?? [:]).mapValues(\.int64Value)
    XCTAssertEqual(counters, expectedCounters, "\(label): counters")

    for (key, value) in (expect["meta"] as? [String: Any]) ?? [:] {
      let actual = try db.store.getMeta(key)
      if key == MetaKeys.flushNotBefore {
        assertValue(value, Int64(actual ?? "0") ?? 0, "\(label): meta.\(key)")
      } else {
        XCTAssertEqual(actual, value as? String, "\(label): meta.\(key)")
      }
    }
  }

  /// `expected` is a number (exact) or {"min","max"} (inclusive).
  private func assertValue(_ expected: Any, _ actual: Int64, _ what: String) {
    if let range = expected as? [String: NSNumber] {
      let lo = range["min"]!.int64Value
      let hi = range["max"]!.int64Value
      XCTAssertTrue((lo...hi).contains(actual), "\(what) = \(actual) not in [\(lo), \(hi)]")
    } else {
      XCTAssertEqual(actual, (expected as! NSNumber).int64Value, what)
    }
  }
}

class NativeUploaderTests: XCTestCase {
  override func tearDown() {
    StubProtocol.reply = nil
  }

  func testWireFormatMatchesSpec() throws {
    let fixture = try json("fixtures/wire_format.json")
    let db = try TestDb()
    for e in fixture["events"] as! [[String: Any]] {
      try db.insert(
        id: e["id"] as! String, payload: Data((e["payload"] as! String).utf8),
        name: e["name"] as! String, priority: (e["priority"] as! NSNumber).intValue,
        createdAt: (e["created_at"] as! NSNumber).int64Value,
        attempts: (e["attempts"] as! NSNumber).intValue)
    }
    try db.store.setMeta(MetaKeys.consent, "granted")
    try db.transport(headers: ["Authorization": "Bearer t"])

    var captured: (URLRequest, Data)?
    StubProtocol.reply = { request, body in
      captured = (request, body)
      return .http(status: 200, headers: [:], body: Data())
    }
    let sentAt = (fixture["sent_at"] as! NSNumber).int64Value
    let result = try NativeUploader(
      store: db.store, sender: URLSessionSender(configuration: StubProtocol.configuration()),
      source: "ios_bg_exit", clock: { sentAt }
    ).run()
    XCTAssertEqual(result.status, .drained)

    let (request, body) = try XCTUnwrap(captured)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    let sdk = try XCTUnwrap(request.value(forHTTPHeaderField: "X-BeeSync-Sdk"))
    XCTAssertTrue(sdk.hasPrefix("bee_sync/") && sdk.hasSuffix("(ios; ios_bg_exit)"), sdk)

    var actual = try JSONSerialization.jsonObject(with: body) as! [String: Any]
    XCTAssertEqual(actual["batch_id"] as? String, request.value(forHTTPHeaderField: "X-BeeSync-Batch-Id"))
    actual["batch_id"] = nil
    var expected = fixture["expected_body"] as! [String: Any]
    expected["batch_id"] = nil
    XCTAssertEqual(NSDictionary(dictionary: actual), NSDictionary(dictionary: expected))
  }

  func testGzipIsValid() {
    XCTAssertEqual(crc32(Data("123456789".utf8)), 0xCBF4_3926)  // standard check value

    let input = Data(String(repeating: "bee_sync ", count: 200).utf8)
    let gz = try! XCTUnwrap(gzip(input))
    XCTAssertEqual(Array(gz.prefix(3)), [0x1f, 0x8b, 0x08])
    let trailer = gz.suffix(8)
    let crc = trailer.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    let size = trailer.suffix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    XCTAssertEqual(UInt32(littleEndian: crc), crc32(input))
    XCTAssertEqual(Int(UInt32(littleEndian: size)), input.count)

    let deflated = gz.dropFirst(10).dropLast(8)
    var out = [UInt8](repeating: 0, count: input.count + 64)
    let n = Data(deflated).withUnsafeBytes {
      compression_decode_buffer(
        &out, out.count, $0.bindMemory(to: UInt8.self).baseAddress!, deflated.count, nil,
        COMPRESSION_ZLIB)
    }
    XCTAssertEqual(Data(out.prefix(n)), input)
  }

  func testSendsGzipWhenConfigured() throws {
    let db = try TestDb()
    try db.insert(id: "a", payload: Data(#"{"k":1}"#.utf8))
    try db.store.setMeta(MetaKeys.consent, "granted")
    try db.transport(gzip: true)
    var encoding: String?
    StubProtocol.reply = { request, _ in
      encoding = request.value(forHTTPHeaderField: "Content-Encoding")
      return .http(status: 200, headers: [:], body: Data())
    }
    _ = try NativeUploader(
      store: db.store, sender: URLSessionSender(configuration: StubProtocol.configuration()), source: "test"
    ).run()
    XCTAssertEqual(encoding, "gzip")
  }

  func testSkipsWithoutTransportConfig() throws {
    let db = try TestDb()
    try db.insert(id: "a", payload: Data("{}".utf8))
    try db.store.setMeta(MetaKeys.consent, "granted")
    let result = try NativeUploader(
      store: db.store, sender: URLSessionSender(configuration: StubProtocol.configuration()), source: "test"
    ).run()
    XCTAssertEqual(result.status, .skipped)
    XCTAssertEqual(result.error, "transport")
  }

  func testDoesNotFollowRedirects() throws {
    let db = try TestDb()
    try db.insert(id: "a", payload: Data("{}".utf8))
    try db.store.setMeta(MetaKeys.consent, "granted")
    try db.transport()
    var requests: [String] = []
    StubProtocol.reply = { request, _ in
      requests.append("\(request.httpMethod ?? "?") \(request.url!.path)")
      if request.url!.path == "/events" {
        return .redirect(to: URL(string: "https://example.test/elsewhere")!)
      }
      return .http(status: 200, headers: [:], body: Data())  // would mark events sent
    }
    let result = try NativeUploader(
      store: db.store, sender: URLSessionSender(configuration: StubProtocol.configuration()),
      source: "test"
    ).run()

    XCTAssertEqual(requests, ["POST /events"])
    XCTAssertEqual(result.status, .backingOff)
    XCTAssertEqual(try db.store.countEvents(), 1)
  }

  func testRetryAfterIsCappedWithoutOverflow() {
    let now: Int64 = 1_760_000_000_000
    let day: Int64 = 86_400_000
    XCTAssertEqual(NativeUploader.parseRetryAfter("86401", now: now), day)
    XCTAssertEqual(NativeUploader.parseRetryAfter("99999999999999999999999", now: now), day)
    XCTAssertEqual(NativeUploader.parseRetryAfter("9223372036854775807", now: now), day)
    XCTAssertEqual(
      NativeUploader.parseRetryAfter("Thu, 01 Jan 2099 00:00:00 GMT", now: now), day)
  }

  func testParsesRetryAfter() {
    let now: Int64 = 1_760_000_000_000
    XCTAssertEqual(NativeUploader.parseRetryAfter("5", now: now), 5_000)
    XCTAssertEqual(
      NativeUploader.parseRetryAfter("Thu, 09 Oct 2025 08:42:00 GMT", now: 1_759_999_200_000), 120_000)
    XCTAssertEqual(NativeUploader.parseRetryAfter("Thu, 01 Jan 1970 00:00:00 GMT", now: now), 0)
    XCTAssertNil(NativeUploader.parseRetryAfter("soon", now: now))
    XCTAssertNil(NativeUploader.parseRetryAfter("-3", now: now))
    XCTAssertNil(NativeUploader.parseRetryAfter(nil, now: now))
  }
}

class BackgroundDeliveryTests: XCTestCase {
  private let delivery = BackgroundDelivery.shared

  override func tearDown() {
    StubProtocol.reply = nil
    delivery.sender = URLSessionSender()
  }

  func testConfigureStoresPathAndReportsMissingPlistEntries() throws {
    let warnings = delivery.configure(databasePath: "/tmp/bee_sync.db", enabled: true)
    XCTAssertEqual(UserDefaults.standard.string(forKey: BeeSyncPlugin.databasePathKey), "/tmp/bee_sync.db")
    // The test host is the example app, whose Info.plist has every entry.
    XCTAssertEqual(warnings, [])
    XCTAssertEqual(BackgroundDelivery.setupWarnings(info: [:]).count, 4)
    XCTAssertEqual(
      BackgroundDelivery.setupWarnings(info: [
        "BGTaskSchedulerPermittedIdentifiers": ["dev.beesync.refresh", "dev.beesync.processing"],
        "UIBackgroundModes": ["fetch"],
      ]),
      ["bee_sync: add \"processing\" to UIBackgroundModes in Info.plist for iOS background delivery."])
  }

  func testTaskRegistrationRefusalDoesNotCrash() {
    // The test host registered both tasks at launch; registering again (and
    // after launch) makes BGTaskScheduler raise, which must not crash.
    let problem = BeeSyncRegisterTask(BackgroundDelivery.refreshId) { _ in }
    XCTAssertNotNil(problem)
    XCTAssertEqual(delivery.registeredIds, [BackgroundDelivery.refreshId, BackgroundDelivery.processingId])
  }

  func testDatabasePathIsStoredRelativeToHome() {
    let stored = BackgroundDelivery.storable("/old/home/Library/bee_sync.db", home: "/old/home")
    XCTAssertEqual(stored, "~/Library/bee_sync.db")
    // After an app update the container moves; the path follows it.
    XCTAssertEqual(BackgroundDelivery.resolve(stored, home: "/new/home"), "/new/home/Library/bee_sync.db")
    XCTAssertEqual(BackgroundDelivery.storable("/tmp/x.db", home: "/old/home"), "/tmp/x.db")
    XCTAssertEqual(BackgroundDelivery.resolve("/tmp/x.db", home: "/new/home"), "/tmp/x.db")
  }

  func testRunOnceDeliversAndLogs() throws {
    let db = try TestDb()
    try db.insert(id: "a", payload: Data("{}".utf8))
    try db.insert(id: "b", payload: Data("{}".utf8))
    try db.store.setMeta(MetaKeys.consent, "granted")
    try db.transport()
    _ = delivery.configure(databasePath: db.path, enabled: true)
    StubProtocol.reply = { _, _ in .http(status: 200, headers: [:], body: Data()) }
    delivery.sender = URLSessionSender(configuration: StubProtocol.configuration())

    guard case .ran(let run, let remaining, _) = delivery.runOnce(source: "ios_bg_exit", shouldContinue: { true })
    else { return XCTFail("expected a run") }

    XCTAssertEqual(run.status, .drained)
    XCTAssertEqual(remaining, 0)
    XCTAssertEqual(try db.logLines(), ["ios_bg_exit/info: drained: sent 2, dropped 0"])
  }

  func testEventsLeasedElsewhereAreRetriedWhenTheLeaseExpires() throws {
    let db = try TestDb()
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    // The app was suspended or killed mid-request: its lease hides the event.
    try db.insert(id: "a", payload: Data("{}".utf8), leaseOwner: "dart:killed", leaseUntil: now + 60_000)
    try db.store.setMeta(MetaKeys.consent, "granted")
    try db.transport()
    _ = delivery.configure(databasePath: db.path, enabled: true)
    var requests = 0
    StubProtocol.reply = { _, _ in
      requests += 1
      return .http(status: 200, headers: [:], body: Data())
    }
    delivery.sender = URLSessionSender(configuration: StubProtocol.configuration())

    guard case .ran(let run, let remaining, let nextRunAt) = delivery.runOnce(source: "ios_bgtask", shouldContinue: { true })
    else { return XCTFail("expected a run") }
    XCTAssertEqual(requests, 0)
    XCTAssertEqual(run.status, .drained)
    XCTAssertEqual(remaining, 1)
    let next = try XCTUnwrap(nextRunAt)
    XCTAssertTrue((now + 59_000...now + 61_000).contains(next), "next run at \(next - now) ms")
  }

  func testRunOnceWaitsForMigrationOfOlderSchema() throws {
    let db = try TestDb(version: 1)
    try db.insert(id: "a", payload: Data("{}".utf8))
    _ = delivery.configure(databasePath: db.path, enabled: true)
    var requests = 0
    StubProtocol.reply = { _, _ in
      requests += 1
      return .http(status: 200, headers: [:], body: Data())
    }
    delivery.sender = URLSessionSender(configuration: StubProtocol.configuration())

    guard case .waitingForMigration = delivery.runOnce(source: "ios_bgtask", shouldContinue: { true })
    else { return XCTFail("expected to wait for migration") }
    XCTAssertEqual(requests, 0)
    XCTAssertTrue(try db.logLines().first?.contains("expected v2") ?? false)
  }
}
