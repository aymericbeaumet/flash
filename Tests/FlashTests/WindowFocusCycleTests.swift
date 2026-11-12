import CoreGraphics
import XCTest

@testable import flash

final class WindowFocusCycleTests: XCTestCase {
  private let windows = [
    WindowFocusCandidate(id: "a", frame: CGRect(x: 0, y: 0, width: 400, height: 400)),
    WindowFocusCandidate(id: "b", frame: CGRect(x: 200, y: 200, width: 400, height: 400)),
    WindowFocusCandidate(id: "c", frame: CGRect(x: 1000, y: 0, width: 300, height: 300)),
    WindowFocusCandidate(id: "d", frame: CGRect(x: 100, y: 100, width: 400, height: 400)),
  ]
  private let pids: [String: pid_t] = ["a": 1, "b": 2, "c": 3, "d": 1]

  private func ordered(_ zOrder: [WindowFocusZEntry]) -> [String] {
    WindowFocusPlanner.zOrdered(windows, zOrder: zOrder) { pids[$0] ?? 0 }
  }

  func testZOrderMatchesCatalogWindowsByPidAndFrameWithinTolerance() {
    let zOrder = [
      WindowFocusZEntry(pid: 2, frame: CGRect(x: 201, y: 199, width: 401, height: 400)),
      WindowFocusZEntry(pid: 9, frame: CGRect(x: 0, y: 0, width: 400, height: 400)),
      WindowFocusZEntry(pid: 1, frame: CGRect(x: 0, y: 0, width: 400, height: 400)),
      WindowFocusZEntry(pid: 3, frame: CGRect(x: 1000, y: 0, width: 300, height: 300)),
      WindowFocusZEntry(pid: 1, frame: CGRect(x: 100, y: 100, width: 400, height: 400)),
      WindowFocusZEntry(pid: 1, frame: CGRect(x: 100, y: 100, width: 400, height: 400)),
    ]
    XCTAssertEqual(
      ordered(zOrder), ["b", "a", "c", "d"], "a second identical entry claims nothing")
    XCTAssertEqual(
      ordered([WindowFocusZEntry(pid: 1, frame: CGRect(x: 0, y: 0, width: 400, height: 410))]),
      [], "a frame off by more than the tolerance is another window")
  }

  func testNextAndPreviousWrapThroughTheStackingOrder() {
    let order = ["b", "a", "c", "d"]
    let frames = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.frame) })
    XCTAssertEqual(WindowFocusPlanner.cycle(.next, from: "b", ordered: order, frames: frames), "a")
    XCTAssertEqual(WindowFocusPlanner.cycle(.next, from: "d", ordered: order, frames: frames), "b")
    XCTAssertEqual(
      WindowFocusPlanner.cycle(.previous, from: "b", ordered: order, frames: frames), "d")
    XCTAssertEqual(
      WindowFocusPlanner.cycle(.previous, from: "a", ordered: order, frames: frames), "b")
    XCTAssertNil(WindowFocusPlanner.cycle(.next, from: "zz", ordered: order, frames: frames))
    XCTAssertNil(WindowFocusPlanner.cycle(.next, from: "a", ordered: ["a"], frames: frames))
  }

  private func step(
    _ cycle: WindowAppCycle, focused: String, ordered: [String],
    run: WindowAppCycleRun<String>?
  ) -> WindowAppCycleRun<String>? {
    WindowFocusPlanner.appCycle(cycle, focused: focused, ordered: ordered, run: run)
  }

  func testAppWindowsCycleThroughEveryWindowNotJustTheTopTwo() throws {
    // Raising a window lifts it to the top, so each press sees a new
    // stacking order; the run keeps the order its first press read.
    var run = try XCTUnwrap(step(.next, focused: "a", ordered: ["a", "b", "c"], run: nil))
    XCTAssertEqual(run.selected, "b")
    run = run.observing("b")
    run = try XCTUnwrap(step(.next, focused: "b", ordered: ["b", "a", "c"], run: run))
    XCTAssertEqual(run.selected, "c")
    run = run.observing("c")
    run = try XCTUnwrap(step(.next, focused: "c", ordered: ["c", "b", "a"], run: run))
    XCTAssertEqual(run.selected, "a", "wraps after the last window")
    run = run.observing("a")
    run = try XCTUnwrap(step(.previous, focused: "a", ordered: ["a", "c", "b"], run: run))
    XCTAssertEqual(run.selected, "c")
  }

  func testPressesFasterThanFocusReportsKeepAdvancing() throws {
    var run = try XCTUnwrap(step(.next, focused: "a", ordered: ["a", "b", "c"], run: nil))
    XCTAssertEqual(run.selected, "b")
    // Focus still reports `a`: the raise of `b` has not been observed yet.
    run = try XCTUnwrap(step(.next, focused: "a", ordered: ["a", "b", "c"], run: run))
    XCTAssertEqual(run.selected, "c")
    // The stale `b` report arrives before the current one.
    run = run.observing("b")
    run = try XCTUnwrap(step(.next, focused: "a", ordered: ["b", "a", "c"], run: run))
    XCTAssertEqual(run.selected, "a", "focus has not reached c, so the run continues from it")
  }

  func testACycleFollowsTheWindowTheUserFocusedThemselves() throws {
    var run = try XCTUnwrap(step(.next, focused: "a", ordered: ["a", "b", "c", "d"], run: nil))
    run = run.observing("b")
    // The user clicks `d`; the next press continues from it in the run's order.
    run = run.observing("d")
    run = try XCTUnwrap(step(.next, focused: "d", ordered: ["d", "b", "a", "c"], run: run))
    XCTAssertEqual(run.selected, "a")
    // Clicking back on the window a press started from, once its raise was
    // observed, is not a stale report: the run continues from that window.
    run = try XCTUnwrap(step(.next, focused: "a", ordered: ["a", "d", "b", "c"], run: nil))
    XCTAssertEqual(run.selected, "d")
    run = run.observing("d").observing("a")
    run = try XCTUnwrap(step(.next, focused: "a", ordered: ["a", "d", "b", "c"], run: run))
    XCTAssertEqual(run.selected, "d")
  }

  func testAChangedWindowSetStartsAFreshRun() throws {
    var run = try XCTUnwrap(step(.next, focused: "a", ordered: ["a", "b", "c"], run: nil))
    run = run.observing("b")
    run = try XCTUnwrap(step(.next, focused: "b", ordered: ["b", "d", "a", "c"], run: run))
    XCTAssertEqual(run.selected, "d", "a new window: the stacking order is read again")
    run = run.observing("d")
    run = try XCTUnwrap(step(.next, focused: "d", ordered: ["d", "b"], run: run))
    XCTAssertEqual(run.selected, "b", "closed windows leave the run")
  }

  func testAFocusedWindowTheStackingOrderMissedStillCycles() throws {
    let run = try XCTUnwrap(step(.next, focused: "x", ordered: ["a", "b"], run: nil))
    XCTAssertEqual(run.selected, "a")
    XCTAssertNil(step(.next, focused: "a", ordered: ["a"], run: nil), "one window: nothing to do")
    XCTAssertNil(step(.next, focused: "a", ordered: [], run: nil))
  }

  func testBehindIsTheFrontmostOverlappingWindowBelowTheFocusedOne() {
    let order = ["b", "c", "a", "d"]
    let frames = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.frame) })
    XCTAssertEqual(
      WindowFocusPlanner.cycle(.behind, from: "b", ordered: order, frames: frames), "a",
      "c does not overlap b, a is the first that does")
    XCTAssertEqual(
      WindowFocusPlanner.cycle(.behind, from: "a", ordered: order, frames: frames), "d")
    XCTAssertNil(
      WindowFocusPlanner.cycle(.behind, from: "d", ordered: order, frames: frames),
      "nothing below the last window")
    XCTAssertNil(WindowFocusPlanner.cycle(.behind, from: "c", ordered: order, frames: frames))
  }
}
