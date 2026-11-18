import AppKit
import XCTest

@testable import flash

/// What keeps the main thread, which also runs the keyboard tap, free to
/// answer a key at once.
final class MainThreadResponsivenessTests: XCTestCase {
  func testABusyStretchIsAHitchFromThreeFramesAndAStallFromAQuarterSecond() {
    XCTAssertNil(MainRunLoopStallObserver.severity(ms: 49.9))
    XCTAssertEqual(MainRunLoopStallObserver.severity(ms: 50), .hitch)
    XCTAssertEqual(MainRunLoopStallObserver.severity(ms: 249), .hitch)
    XCTAssertEqual(MainRunLoopStallObserver.severity(ms: 250), .stall)
  }

  /// App Nap stays off, and the Mac still sleeps.
  func testTheResidentActivityKeepsAppNapOffWithoutHoldingSleep() {
    let options = ResidentActivity.options
    XCTAssertTrue(options.contains(.userInitiatedAllowingIdleSystemSleep))
    XCTAssertFalse(options.contains(.idleSystemSleepDisabled))
    XCTAssertFalse(options.contains(.idleDisplaySleepDisabled))
    XCTAssertFalse(options.contains(.latencyCritical), "timer slack must keep coalescing")
  }

  /// A mode change repaints the cached stroke and reads the window list
  /// only when a window event followed the cached read.
  func testAModeChangeReadsTheWindowListOnlyAfterAWindowEvent() {
    var border = ActiveWindowBorderState()
    let pid: pid_t = 4242
    XCTAssertTrue(border.needsRead(.unlessFresh, of: pid), "nothing cached")
    XCTAssertTrue(border.needsRead(.onlyWithoutCache, of: pid))
    border.frames[pid] = CGRect(x: 10, y: 20, width: 300, height: 200)
    XCTAssertTrue(border.needsRead(.unlessFresh, of: pid), "the cache came from an AX event")
    border.noteRead(of: pid)
    XCTAssertFalse(border.needsRead(.unlessFresh, of: pid))
    XCTAssertTrue(border.needsRead(.nextTurn, of: pid))
    border.noteWindowEvent()
    XCTAssertTrue(border.needsRead(.unlessFresh, of: pid), "an event followed the read")
    XCTAssertFalse(border.needsRead(.onlyWithoutCache, of: pid))
    border.forget(pid)
    border.frames[pid] = .zero
    XCTAssertTrue(border.needsRead(.unlessFresh, of: pid), "a forgotten app's read is forgotten")
  }

  /// Reads queued within one turn collapse into the latest, and a read an
  /// update superseded is dropped.
  func testTheBordersQueuedReadIsTheLatestAndDropsOnceSuperseded() {
    var border = ActiveWindowBorderState()
    func read(_ pid: pid_t) -> ActiveWindowBorderRead {
      ActiveWindowBorderRead(
        pid: pid, reason: "test", generation: border.updateGeneration, reconciles: false)
    }
    XCTAssertTrue(border.queue(read(1)), "the first one schedules the turn")
    XCTAssertFalse(border.queue(read(2)))
    XCTAssertEqual(border.takePendingRead()?.pid, 2)
    XCTAssertNil(border.takePendingRead())

    XCTAssertTrue(border.queue(read(3)))
    border.updateGeneration &+= 1
    XCTAssertNil(border.takePendingRead(), "superseded")
    XCTAssertNil(border.pendingRead, "and not kept")
  }
}
