import XCTest

@testable import flash

/// Up and down on the command line: past inputs, most recent first, and the
/// buffer the recall started from.
final class CommandLineHistoryTests: XCTestCase {
  func testUpRecallsNewestFirstAndDownRestoresTheBufferBeingTyped() {
    var history = CommandLineHistory(entries: [":tab new", ":window move --position=lefthalf"])
    XCTAssertFalse(history.isRecalling)
    XCTAssertNil(history.step(1, buffer: ":"), "down before any recall does nothing")
    XCTAssertEqual(history.step(-1, buffer: ":"), ":window move --position=lefthalf")
    XCTAssertTrue(history.isRecalling)
    XCTAssertEqual(history.step(-1, buffer: "ignored"), ":tab new")
    XCTAssertEqual(history.step(-1, buffer: "ignored"), ":tab new", "the oldest stays")
    XCTAssertEqual(history.step(1, buffer: "ignored"), ":window move --position=lefthalf")
    XCTAssertEqual(history.step(1, buffer: "ignored"), ":", "past the newest: the stash")
    XCTAssertFalse(history.isRecalling)
    XCTAssertNil(history.step(1, buffer: ":"))
  }

  func testAnEditOrASubmissionEndsTheRecall() {
    var history = CommandLineHistory(entries: ["a", "b"])
    _ = history.step(-1, buffer: "")
    history.endRecall()
    XCTAssertFalse(history.isRecalling)
    XCTAssertEqual(history.step(-1, buffer: ":"), "b", "a new recall starts from the newest")
    XCTAssertTrue(history.record("c"))
    XCTAssertFalse(history.isRecalling)
  }

  func testRecordingTrimsDropsRepeatsAndKeepsTheNewestCapacity() {
    var history = CommandLineHistory()
    XCTAssertNil(history.step(-1, buffer: ""), "nothing to recall")
    XCTAssertTrue(history.record("  tab next \n"))
    XCTAssertFalse(history.record("tab next"), "a consecutive repeat is not recorded")
    XCTAssertFalse(history.record("   "))
    XCTAssertEqual(history.entries, ["tab next"])
    for index in 0..<CommandLineHistory.capacity { _ = history.record("c\(index)") }
    XCTAssertEqual(history.entries.count, CommandLineHistory.capacity)
    XCTAssertEqual(history.entries.first, "c0")
    XCTAssertEqual(
      CommandLineHistory(entries: (0...CommandLineHistory.capacity).map(String.init)).entries.first,
      "1", "a loaded file keeps the newest entries")
  }
}
