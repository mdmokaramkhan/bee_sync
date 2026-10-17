import BackgroundTasks
import Foundation
import UIKit
import os.log

/// iOS background delivery (doc/DESIGN.md §7.2), most reliable first:
/// 1. Background exit: when the app enters the background, ask for extra
///    time (`beginBackgroundTask`) and run the uploader.
/// 2. `BGAppRefreshTask` (`dev.beesync.refresh`), at or after the backoff.
/// 3. `BGProcessingTask` (`dev.beesync.processing`, needs network) for
///    larger backlogs.
/// iOS decides when 2 and 3 run, and runs neither after a user force-quit.
final class BackgroundDelivery {
  static let shared = BackgroundDelivery()

  static let refreshId = "dev.beesync.refresh"
  static let processingId = "dev.beesync.processing"
  static let databasePathKey = "dev.beesync.database_path"
  static let enabledKey = "dev.beesync.background_enabled"
  static let logKeep = 200

  private let queue = DispatchQueue(label: "dev.beesync.upload")
  private let log = OSLog(subsystem: "dev.beesync.bee_sync", category: "background")
  private var registered = false
  private var observing = false
  var sender: HttpSender = URLSessionSender()

  private var defaults: UserDefaults { .standard }
  private var databasePath: String? { defaults.string(forKey: Self.databasePathKey) }
  private var enabled: Bool { defaults.bool(forKey: Self.enabledKey) }

  // MARK: Setup

  /// Registers the BGTask handlers. Apple requires this before
  /// `application(_:didFinishLaunchingWithOptions:)` returns; the plugin does
  /// it from `register(with:)`. Safe to call more than once. Identifiers
  /// missing from Info.plist are skipped (registering them would crash).
  func registerTasks() {
    guard !registered else { return }
    registered = true
    let permitted = Self.permittedIdentifiers()
    if permitted.contains(Self.refreshId) {
      BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshId, using: nil) {
        [weak self] task in self?.handle(task, source: "ios_bgtask")
      }
    }
    if permitted.contains(Self.processingId) {
      BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.processingId, using: nil) {
        [weak self] task in self?.handle(task, source: "ios_bgtask")
      }
    }
    observeBackgrounding()
  }

  /// Stores where the database is and whether background work is wanted.
  /// Returns Info.plist problems worth surfacing in the Dart log.
  func configure(databasePath: String, enabled: Bool) -> [String] {
    defaults.set(databasePath, forKey: Self.databasePathKey)
    defaults.set(enabled, forKey: Self.enabledKey)
    if !enabled {
      cancel()
      return []
    }
    return Self.setupWarnings()
  }

  /// Info.plist entries background delivery needs (see README).
  static func setupWarnings(info: [String: Any]? = Bundle.main.infoDictionary) -> [String] {
    var warnings: [String] = []
    let ids = (info?["BGTaskSchedulerPermittedIdentifiers"] as? [String]) ?? []
    for id in [refreshId, processingId] where !ids.contains(id) {
      warnings.append(
        "bee_sync: add \"\(id)\" to BGTaskSchedulerPermittedIdentifiers in Info.plist for iOS background delivery."
      )
    }
    let modes = (info?["UIBackgroundModes"] as? [String]) ?? []
    for mode in ["fetch", "processing"] where !modes.contains(mode) {
      warnings.append("bee_sync: add \"\(mode)\" to UIBackgroundModes in Info.plist for iOS background delivery.")
    }
    return warnings
  }

  private static func permittedIdentifiers() -> [String] {
    (Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]) ?? []
  }

  // MARK: Scheduling

  /// Submits both task requests, not before `earliest` (the backoff end).
  func schedule(earliest: Date? = nil) {
    guard enabled else { return }
    let permitted = Self.permittedIdentifiers()
    if permitted.contains(Self.refreshId) {
      let refresh = BGAppRefreshTaskRequest(identifier: Self.refreshId)
      refresh.earliestBeginDate = earliest ?? Date(timeIntervalSinceNow: 15 * 60)
      submit(refresh)
    }
    if permitted.contains(Self.processingId) {
      let processing = BGProcessingTaskRequest(identifier: Self.processingId)
      processing.requiresNetworkConnectivity = true
      processing.requiresExternalPower = false
      processing.earliestBeginDate = earliest
      submit(processing)
    }
  }

  func cancel() {
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshId)
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.processingId)
  }

  private func submit(_ request: BGTaskRequest) {
    do {
      try BGTaskScheduler.shared.submit(request)
    } catch {
      // Expected on the Simulator (BGTaskScheduler is unavailable there).
      os_log("bee_sync: cannot schedule %{public}@: %{public}@", log: log, type: .info,
             request.identifier, String(describing: error))
    }
  }

  // MARK: Running

  private func observeBackgrounding() {
    guard !observing else { return }
    observing = true
    NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.flushOnBackgroundExit() }
  }

  /// Layer 1: upload within the extra time iOS grants on entering background.
  func flushOnBackgroundExit() {
    guard enabled, databasePath != nil else { return }
    let app = UIApplication.shared
    let stopped = Flag()
    var taskId = UIBackgroundTaskIdentifier.invalid
    let end = {
      if taskId != .invalid {
        app.endBackgroundTask(taskId)
        taskId = .invalid
      }
    }
    taskId = app.beginBackgroundTask(withName: "bee_sync.flush") {
      // Out of time: stop between batches; leases release anything in flight.
      stopped.set()
      end()
    }
    guard taskId != .invalid else { return }
    queue.async { [weak self] in
      let result = self?.runOnce(source: "ios_bg_exit", shouldContinue: { !stopped.value })
      self?.scheduleFollowUp(result)
      DispatchQueue.main.async(execute: end)
    }
  }

  /// Layers 2 and 3.
  private func handle(_ task: BGTask, source: String) {
    let stopped = Flag()
    task.expirationHandler = { stopped.set() }
    queue.async { [weak self] in
      let result = self?.runOnce(source: source, shouldContinue: { !stopped.value })
      self?.scheduleFollowUp(result)
      task.setTaskCompleted(success: result?.0.status == .drained)
    }
  }

  /// Plans the next background run: none once the queue is empty, otherwise
  /// at the backoff end (or the default interval).
  private func scheduleFollowUp(_ result: (RunResult, remaining: Int64)?) {
    guard let (run, remaining) = result else { return }
    if remaining == 0 {
      cancel()
    } else {
      schedule(earliest: run.retryAt.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) })
    }
  }

  /// Opens the database, runs the uploader once and logs to bg_log. Nil when
  /// there is nothing to run against.
  func runOnce(source: String, shouldContinue: () -> Bool) -> (RunResult, remaining: Int64)? {
    guard let path = databasePath else { return nil }
    do {
      guard let store = try BeeSyncStore.open(path: path) else { return nil }
      let now = Int64(Date().timeIntervalSince1970 * 1000)
      let version = try store.schemaVersion()
      guard version == Sql.schemaVersion else {
        // Dart migrates on the app's next launch; until then, do nothing.
        try store.log(
          at: now, source: source, level: "warn",
          message: "Schema v\(version), expected v\(Sql.schemaVersion); waiting for app launch")
        try store.trimLog(keep: Self.logKeep)
        return nil
      }
      let result = try NativeUploader(store: store, sender: sender, source: source)
        .run(shouldContinue: shouldContinue)
      try Self.logResult(store, source: source, result)
      return (result, try store.countEvents())
    } catch {
      os_log("bee_sync: background upload failed: %{public}@", log: log, type: .error,
             String(describing: error))
      return nil
    }
  }

  static func logResult(_ store: BeeSyncStore, source: String, _ result: RunResult) throws {
    let at = Int64(Date().timeIntervalSince1970 * 1000)
    let summary = "\(result.status.rawValue): sent \(result.delivered), dropped \(result.dropped)"
    switch result.status {
    case .drained:
      try store.log(at: at, source: source, level: "info", message: summary)
    case .backingOff, .authBlocked:
      try store.log(at: at, source: source, level: "warn", message: "\(summary) (\(result.error ?? ""))")
    case .skipped:
      // Routine (consent, auth block, backoff, or the app's own flush won).
      try store.log(at: at, source: source, level: "debug", message: "skipped: \(result.error ?? "stopped")")
    }
    try store.trimLog(keep: logKeep)
  }
}

/// A thread-safe one-way flag set by expiration handlers.
final class Flag {
  private let lock = NSLock()
  private var isSet = false
  var value: Bool {
    lock.lock()
    defer { lock.unlock() }
    return isSet
  }
  func set() {
    lock.lock()
    isSet = true
    lock.unlock()
  }
}
