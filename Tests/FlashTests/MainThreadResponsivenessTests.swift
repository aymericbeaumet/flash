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
    func needsRead(
      _ timing: ActiveWindowBorderReadTiming, cached: Bool = true, read: UInt64? = 7,
      event: UInt64 = 7
    ) -> Bool {
      AppDelegate.activeWindowBorderNeedsRead(
        timing, cached: cached, readEpoch: read, eventEpoch: event)
    }
    XCTAssertFalse(needsRead(.unlessFresh))
    XCTAssertTrue(needsRead(.unlessFresh, event: 8), "an event followed the read")
    XCTAssertTrue(needsRead(.unlessFresh, read: nil), "the cache came from an AX event")
    XCTAssertTrue(needsRead(.unlessFresh, cached: false))
    XCTAssertTrue(needsRead(.nextTurn))
    XCTAssertFalse(needsRead(.onlyWithoutCache, event: 8))
    XCTAssertTrue(needsRead(.onlyWithoutCache, cached: false))
  }
}
