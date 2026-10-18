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
