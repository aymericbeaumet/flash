import CoreGraphics
import XCTest

@testable import flash

final class PositionHistoryTests: XCTestCase {
  func testSaveKeepsNewestLastAndRefreshesASavedPlace() {
    var history = PositionHistory()
    history.save(CGPoint(x: 10, y: 10), app: "a", scope: .global, maxSize: 16)
    history.save(CGPoint(x: 100, y: 100), app: "a", scope: .global, maxSize: 16)
    XCTAssertEqual(
      history.save(CGPoint(x: 12, y: 8), app: "b", scope: .global, maxSize: 16), 2,
      "a nearby point is the same place, saved again")
    XCTAssertEqual(
      history.positions(app: nil, scope: .global), [CGPoint(x: 100, y: 100), CGPoint(x: 12, y: 8)])
  }

  func testSaveDropsTheOldestPastTheSize() {
    var history = PositionHistory()
    for index in 0..<5 {
      history.save(CGPoint(x: CGFloat(index) * 100, y: 0), app: nil, scope: .global, maxSize: 3)
    }
    XCTAssertEqual(
      history.positions(app: nil, scope: .global).map(\.x), [200, 300, 400])
  }

  func testAppScopeKeepsOneListPerApp() {
    var history = PositionHistory()
    history.save(CGPoint(x: 1, y: 1), app: "editor", scope: .app, maxSize: 2)
    history.save(CGPoint(x: 2, y: 2), app: "browser", scope: .app, maxSize: 2)
    history.save(CGPoint(x: 300, y: 300), app: "editor", scope: .app, maxSize: 2)
    history.save(CGPoint(x: 600, y: 600), app: "editor", scope: .app, maxSize: 2)
    XCTAssertEqual(
      history.positions(app: "editor", scope: .app),
      [CGPoint(x: 300, y: 300), CGPoint(x: 600, y: 600)])
    XCTAssertEqual(history.positions(app: "browser", scope: .app), [CGPoint(x: 2, y: 2)])
    XCTAssertEqual(history.positions(app: "other", scope: .app), [])
    history.clear(app: "editor", scope: .app)
    XCTAssertEqual(history.positions(app: "editor", scope: .app), [])
    XCTAssertEqual(history.positions(app: "browser", scope: .app), [CGPoint(x: 2, y: 2)])
    XCTAssertEqual(
      history.positions(app: nil, scope: .global), [CGPoint(x: 2, y: 2)],
      "every list is visible to the global scope")
  }

  func testNextAndPreviousCycleFromTheSavedPlaceThePointerIsOn() {
    var history = PositionHistory()
    let points = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 200, y: 0)]
    for point in points { history.save(point, app: nil, scope: .global, maxSize: 16) }
    XCTAssertEqual(history.next(from: CGPoint(x: 50, y: 50), app: nil, scope: .global), points[0])
    XCTAssertEqual(
      history.previous(from: CGPoint(x: 50, y: 50), app: nil, scope: .global), points[2])
    XCTAssertEqual(history.next(from: CGPoint(x: 104, y: 3), app: nil, scope: .global), points[2])
    XCTAssertEqual(history.next(from: points[2], app: nil, scope: .global), points[0])
    XCTAssertEqual(history.previous(from: points[0], app: nil, scope: .global), points[2])
    XCTAssertNil(PositionHistory().next(from: .zero, app: nil, scope: .global))
  }

  func testUnsaveForgetsOnlyThePlaceThePointerIsOn() {
    var history = PositionHistory()
    history.save(CGPoint(x: 0, y: 0), app: nil, scope: .global, maxSize: 16)
    history.save(CGPoint(x: 100, y: 0), app: nil, scope: .global, maxSize: 16)
    XCTAssertFalse(history.unsave(near: CGPoint(x: 50, y: 0), app: nil, scope: .global))
    XCTAssertTrue(history.unsave(near: CGPoint(x: 97, y: 4), app: nil, scope: .global))
    XCTAssertEqual(history.positions(app: nil, scope: .global), [CGPoint(x: 0, y: 0)])
  }

  func testSaveIgnoresNonFinitePoints() {
    var history = PositionHistory()
    history.save(CGPoint(x: CGFloat.nan, y: 0), app: nil, scope: .global, maxSize: 16)
    XCTAssertEqual(history.entries, [])
  }
}
