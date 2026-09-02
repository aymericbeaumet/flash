import XCTest

@testable import flash

final class CommandHistoryStoreTests: XCTestCase {
  private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-command-history-\(UUID().uuidString)")
      .appendingPathComponent("command-history.json")
  }

  func testSavedHistorySurvivesAcrossStoreInstances() throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let writer = try XCTUnwrap(CommandHistoryStore(fileURL: url))
    writer.save([":reload", ":flashlight safari", ":plugins"])
    writer.drain()

    // A fresh instance (as after a restart/reinstall) loads what was persisted.
    let reader = try XCTUnwrap(CommandHistoryStore(fileURL: url))
    XCTAssertEqual(reader.load(), [":reload", ":flashlight safari", ":plugins"])
  }

  func testLoadReturnsEmptyWhenNoFileYet() throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try XCTUnwrap(CommandHistoryStore(fileURL: url))
    XCTAssertEqual(store.load(), [])
  }
}
