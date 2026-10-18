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

  /// Prefix marking a stored path as relative to the app's home directory,
  /// which can move when the app is updated.
  static let homePrefix = "~/"

  private let queue = DispatchQueue(label: "dev.beesync.upload")
  private let log = OSLog(subsystem: "dev.beesync.bee_sync", category: "background")
  private var registrationAttempted = false
  private var observing = false
  /// Identifiers with a launch handler; only these may be scheduled, since
  /// iOS crashes when a scheduled task has no handler.
  private(set) var registeredIds: Set<String> = []
  private var registrationProblems: [String] = []
  var sender: HttpSender = URLSessionSender()

  private var defaults: UserDefaults { .standard }
  private var enabled: Bool { defaults.bool(forKey: Self.enabledKey) }

  /// The database path, resolved against the current home directory.
  var databasePath: String? {
    guard let stored = defaults.string(forKey: Self.databasePathKey) else { return nil }
    return Self.resolve(stored)
  }

  // MARK: Setup

  /// Registers the BGTask handlers. Apple requires this before
  /// `application(_:didFinishLaunchingWithOptions:)` returns; the plugin does
  /// it from `register(with:)`. Safe to call more than once. Identifiers
  /// missing from Info.plist are skipped. A refused registration (e.g. too
  /// late) is reported through `configure` instead of crashing the app.
  func registerTasks() {
    guard !registrationAttempted else { return }
    registrationAttempted = true
    let permitted = Self.permittedIdentifiers()
    for id in [Self.refreshId, Self.processingId] where permitted.contains(id) {
      let problem = BeeSyncRegisterTask(id) { [weak self] task in
        self?.handle(task, source: "ios_bgtask")
      }
      if let problem = problem {
        registrationProblems.append(
          "bee_sync: background task \"\(id)\" was not registered (\(problem)). If your app "
            + "registers plugins after launch, call BeeSyncPlugin.registerBackgroundTasks() in "
            + "application(_:didFinishLaunchingWithOptions:).")
        os_log("bee_sync: cannot register %{public}@: %{public}@", log: log, type: .error, id, problem)
      } else {
        registeredIds.insert(id)
      }
    }
    observeBackgrounding()
  }

  /// Stores where the database is and whether background work is wanted.
  /// Returns setup problems worth surfacing in the Dart log.
  func configure(databasePath: String, enabled: Bool) -> [String] {
    defaults.set(Self.storable(databasePath), forKey: Self.databasePathKey)
    defaults.set(enabled, forKey: Self.enabledKey)
    if !enabled {
      cancel()
      return []
    }
    return Self.setupWarnings() + registrationProblems
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

  /// Paths inside the app's home directory are stored relative to it: the
  /// container path can change across app updates.
  static func storable(_ path: String, home: String = NSHomeDirectory()) -> String {
    let prefix = home.hasSuffix("/") ? home : home + "/"
    return path.hasPrefix(prefix) ? homePrefix + path.dropFirst(prefix.count) : path
  }

  static func resolve(_ stored: String, home: String = NSHomeDirectory()) -> String {
    guard stored.hasPrefix(homePrefix) else { return stored }
    return (home as NSString).appendingPathComponent(String(stored.dropFirst(homePrefix.count)))
  }

  // MARK: Scheduling

  /// Submits the registered task requests, not before `earliest` (the
  /// backoff end).
  func schedule(earliest: Date? = nil) {
    guard enabled else { return }
    if registeredIds.contains(Self.refreshId) {
      let refresh = BGAppRefreshTaskRequest(identifier: Self.refreshId)
      refresh.earliestBeginDate = earliest ?? Date(timeIntervalSinceNow: 15 * 60)
      submit(refresh)
    }
    if registeredIds.contains(Self.processingId) {
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

  /// What one background run did, deciding what to schedule next.
  enum RunOutcome {
    /// Not configured, or the database doesn't exist yet: nothing to do.
    case idle
    /// The database has another schema version; the app migrates on launch.
    case waitingForMigration
    /// The run threw (e.g. the database was busy); try again later.
    case failed
    /// `nextRunAt` (ms): when to run again if events remain, or nil for the
    /// default interval.
    case ran(RunResult, remaining: Int64, nextRunAt: Int64?)
  }

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
    let sender = self.sender
    var taskId = UIBackgroundTaskIdentifier.invalid
    let end = {
      if taskId != .invalid {
        app.endBackgroundTask(taskId)
        taskId = .invalid
      }
    }
    taskId = app.beginBackgroundTask(withName: "bee_sync.flush") {
      // Out of time: abort the request and stop; leases release the rows.
      stopped.set()
      sender.cancel()
      end()
    }
    guard taskId != .invalid else { return }
    queue.async { [weak self] in
      let outcome = self?.runOnce(source: "ios_bg_exit", shouldContinue: { !stopped.value })
      if let outcome = outcome { self?.scheduleFollowUp(outcome) }
      DispatchQueue.main.async(execute: end)
    }
  }

  /// Layers 2 and 3.
  private func handle(_ task: BGTask, source: String) {
    let completed = Flag()
    let complete: (Bool) -> Void = { success in
      // setTaskCompleted must be called exactly once.
      if completed.setIfUnset() { task.setTaskCompleted(success: success) }
    }
    guard enabled else {
      complete(true)
      return
    }
    let stopped = Flag()
    let sender = self.sender
    task.expirationHandler = {
      // Out of time: abort the request and report now, before iOS kills us.
      stopped.set()
      sender.cancel()
      complete(false)
    }
    queue.async { [weak self] in
      guard let self = self else { return complete(false) }
      let outcome = self.runOnce(source: source, shouldContinue: { !stopped.value })
      self.scheduleFollowUp(outcome)
      if case .ran(let run, _, _) = outcome {
        complete(run.status == .drained)
      } else {
        complete(false)
      }
    }
  }

  /// Plans the next background run: none once the queue is empty, otherwise
  /// at the backoff end (or the default interval).
  private func scheduleFollowUp(_ outcome: RunOutcome) {
    switch outcome {
    case .idle, .waitingForMigration:
      break
    case .failed:
      schedule()
    case .ran(let run, let remaining, let nextRunAt):
      if remaining == 0 {
        cancel()
      } else if run.status == .skipped, run.error == "auth" || run.error == "consent" {
        // Only the app can clear these; it reschedules when it next runs.
        break
      } else {
        schedule(earliest: nextRunAt.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) })
      }
    }
  }

  /// Opens the database, runs the uploader once and logs to bg_log.
  func runOnce(source: String, shouldContinue: @escaping () -> Bool) -> RunOutcome {
    guard let path = databasePath else { return .idle }
    do {
      guard let store = try BeeSyncStore.open(path: path) else { return .idle }
      let now = Int64(Date().timeIntervalSince1970 * 1000)
      let version = try store.schemaVersion()
      guard version == Sql.schemaVersion else {
        // Dart migrates on the app's next launch; until then, do nothing.
        try store.log(
          at: now, source: source, level: "warn",
          message: "Schema v\(version), expected v\(Sql.schemaVersion); waiting for app launch")
        try store.trimLog(keep: Self.logKeep)
        return .waitingForMigration
      }
      let result = try NativeUploader(store: store, sender: sender, source: source)
        .run(shouldContinue: shouldContinue)
      try Self.logResult(store, source: source, result)
      let remaining = try store.countEvents()
      var nextRunAt = result.retryAt
      if nextRunAt == nil, result.status == .drained, remaining > 0 {
        // Events remain but none was claimable: another uploader holds them,
        // typically the app, suspended or killed mid-request. Come back once
        // that lease has expired.
        let leaseMs = DeliverySettings.parse(try store.getMeta(MetaKeys.deliveryConfig)).leaseMs
        nextRunAt = Int64(Date().timeIntervalSince1970 * 1000) + leaseMs
      }
      return .ran(result, remaining: remaining, nextRunAt: nextRunAt)
    } catch {
      os_log("bee_sync: background upload failed: %{public}@", log: log, type: .error,
             String(describing: error))
      // Best effort: the contract asks for an error line in bg_log.
      if let store = try? BeeSyncStore.open(path: path) {
        try? store.log(
          at: Int64(Date().timeIntervalSince1970 * 1000), source: source, level: "error",
          message: "Upload failed: \(error)")
        try? store.trimLog(keep: Self.logKeep)
      }
      return .failed
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

  /// Sets the flag; true only for the caller that set it first.
  func setIfUnset() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if isSet { return false }
    isSet = true
    return true
  }
}
