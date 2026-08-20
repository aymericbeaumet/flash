import XCTest

@testable import flash

final class DragSynthesisTests: XCTestCase {
  func testDragWaypointsEndExactlyOnDestination() {
    let from = CGPoint(x: 100, y: 100)
    let to = CGPoint(x: 900, y: 500)
    let waypoints = ActionDispatcher.dragWaypoints(from: from, to: to)
    XCTAssertEqual(waypoints.last, to)
    XCTAssertFalse(waypoints.contains(from))
  }

  func testDragWaypointsScaleWithDistanceWithinBounds() {
    // Short drags still produce a movement stream apps can recognise…
    let short = ActionDispatcher.dragWaypoints(
      from: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 0))
    XCTAssertEqual(short.count, 2)
    // …and long ones are clamped so the gesture stays brief.
    let long = ActionDispatcher.dragWaypoints(
      from: CGPoint(x: 0, y: 0), to: CGPoint(x: 4000, y: 3000))
    XCTAssertEqual(long.count, 16)
    // Mid-length drags land ~one waypoint per 40pt.
    let mid = ActionDispatcher.dragWaypoints(
      from: CGPoint(x: 0, y: 0), to: CGPoint(x: 400, y: 0))
    XCTAssertEqual(mid.count, 10)
  }

  func testDragWaypointsProgressMonotonically() {
    let from = CGPoint(x: 50, y: 400)
    let to = CGPoint(x: 650, y: 40)
    let waypoints = ActionDispatcher.dragWaypoints(from: from, to: to)
    var previousDistance: CGFloat = 0
    for point in waypoints {
      let dx = point.x - from.x
      let dy = point.y - from.y
      let distance = (dx * dx + dy * dy).squareRoot()
      XCTAssertGreaterThan(distance, previousDistance)
      previousDistance = distance
    }
  }

  func testDragMouseCommandArgTokensRoundTrip() {
    XCTAssertEqual(MouseCommand.drag(modifiers: []).argTokens, ["--drag"])
    XCTAssertEqual(
      MouseCommand.drag(modifiers: .option).argTokens, ["--drag", "--modifiers=alt"])
    XCTAssertEqual(MouseCommand.select(modifiers: []).argTokens, ["--select"])
  }
}
