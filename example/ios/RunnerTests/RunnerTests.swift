import XCTest

@testable import bee_sync

// Native uploader tests against spec/fixtures land with the iOS uploader
// (v0.2 step 4).
class RunnerTests: XCTestCase {
  func testConfigureStoresDatabasePath() throws {
    let plugin = BeeSyncPlugin()
    let warnings = try plugin.configure(
      setup: BackgroundSetup(databasePath: "/tmp/bee_sync.db", enabled: true))
    XCTAssertEqual(warnings, [])
    XCTAssertEqual(
      UserDefaults.standard.string(forKey: BeeSyncPlugin.databasePathKey), "/tmp/bee_sync.db")
  }
}
