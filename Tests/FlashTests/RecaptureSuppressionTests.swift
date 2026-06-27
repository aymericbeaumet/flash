import Foundation
import XCTest

@testable import flash

final class RecaptureSuppressionTests: XCTestCase {
  private let now = Date(timeIntervalSinceReferenceDate: 1_000)

  func testActivePredicateMatchesTheOldInlineLogic() {
    XCTAssertFalse(RecaptureSuppression.active(nil, now: now))
    XCTAssertTrue(RecaptureSuppression.active(now.addingTimeInterval(0.5), now: now))
    // Boundary: `now < until`, so an expiry exactly at `now` is NOT active.
    XCTAssertFalse(RecaptureSuppression.active(now, now: now))
    XCTAssertFalse(RecaptureSuppression.active(now.addingTimeInterval(-0.5), now: now))
  }

  func testAnyActiveReflectsEachReasonIndependently() {
    XCTAssertFalse(RecaptureSuppression().anyActive(now: now))

    var s = RecaptureSuppression()
    s.menuBarUntil = now.addingTimeInterval(1)
    XCTAssertTrue(s.anyActive(now: now))
    XCTAssertTrue(s.menuBarActive(now: now))
    XCTAssertFalse(s.contextMenuActive(now: now))

    s = RecaptureSuppression(
      menuBarUntil: nil,
      contextMenuUntil: nil,
      pointerInsertHandoffUntil: now.addingTimeInterval(1))
    XCTAssertTrue(s.anyActive(now: now))
    XCTAssertTrue(s.pointerInsertHandoffActive(now: now))
  }

  func testPruneExpiredClearsOnlyElapsedWindows() {
    var s = RecaptureSuppression(
      menuBarUntil: now.addingTimeInterval(-1),  // elapsed
      contextMenuUntil: now.addingTimeInterval(1),  // still active
      pointerInsertHandoffUntil: now)  // exactly now → elapsed (<=)
    s.pruneExpired(now: now)
    XCTAssertNil(s.menuBarUntil)
    XCTAssertEqual(s.contextMenuUntil, now.addingTimeInterval(1))
    XCTAssertNil(s.pointerInsertHandoffUntil)
  }
}
