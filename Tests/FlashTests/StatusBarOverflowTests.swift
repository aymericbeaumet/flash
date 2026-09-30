import XCTest

@testable import flash

/// The bar's overflow arithmetic, free of AppKit: lane widths in, the width
/// each truncatable span ends at out.
final class StatusBarOverflowTests: XCTestCase {
  /// A 100-column bar with a 24-column housing, 2-column gutters, a 1-column
  /// notch margin, and 8 columns a lane always keeps.
  private let bar = StatusBarOverflow.Geometry(
    columns: 100, housingColumns: 24, gutterColumns: 2, marginColumns: 1,
    minimumLaneColumns: 8)

  private func budgets(
    _ spans: [(StatusBarOverflow.Lane, Int)], fixed: [StatusBarOverflow.Lane: Int] = [:],
    columns: Int? = nil, leftColumns: Int? = nil
  ) -> [Int] {
    var geometry = bar
    geometry.columns = columns ?? bar.columns
    geometry.leftColumns = leftColumns
    return StatusBarOverflow.budgets(
      spans.map { .init(lane: $0.0, width: $0.1) }, fixed: fixed, in: geometry)
  }

  /// The recess is the housing for a short label and grows with a long one,
  /// up to the columns that leave each lane its minimum.
  func testTheReservationHugsLongContentButNeverNarrowsBelowTheHousing() {
    XCTAssertEqual(StatusBarOverflow.reserve(centre: 6, in: bar), 38..<62)
    XCTAssertEqual(StatusBarOverflow.reserve(centre: 45, in: bar), 25..<74)
    XCTAssertEqual(StatusBarOverflow.reserve(centre: 200, in: bar), 8..<92)
    XCTAssertTrue(StatusBarOverflow.reserve(centre: 0, in: bar).isEmpty)
    var narrow = bar
    narrow.columns = 16
    XCTAssertTrue(
      StatusBarOverflow.reserve(centre: 6, in: narrow).isEmpty,
      "a bar too narrow for the reservation drops it instead of starving a lane")
  }

  func testAFittingBarKeepsEveryWidth() {
    XCTAssertEqual(budgets([(.left, 20), (.absoluteCentre, 40)], fixed: [.right: 10]), [20, 40])
  }

  /// The centred label is wider than the lane group, so it gives way first;
  /// it frees a column for each lane at once.
  func testALongerCentreContractsBeforeAShorterLaneGroup() {
    XCTAssertEqual(
      budgets([(.left, 20), (.absoluteCentre, 45)], fixed: [.left: 10, .right: 30]), [20, 34])
  }

  /// The widest group contracts first; once it is level with the next, they
  /// alternate in template order.
  func testTheLongestGroupContractsFirstAndTiesAlternateInTemplateOrder() {
    XCTAssertEqual(
      budgets(
        [(.left, 50), (.absoluteCentre, 30)], fixed: [.left: 2, .right: 20], columns: 90),
      [26, 27])
  }

  /// A centre no wider than the housing frees nothing by narrowing further.
  func testTheCentreStopsGivingWayAtTheHousing() {
    XCTAssertEqual(budgets([(.absoluteCentre, 30)], fixed: [.left: 40], columns: 60), [20])
  }

  /// A centre wider than the bar can reserve contracts to the cap on its own.
  func testACentreBeyondTheCapContractsToIt() {
    XCTAssertEqual(budgets([(.absoluteCentre, 100)]), [80])
  }

  /// Each lane frees only itself; both side lanes end `marginColumns` short
  /// of the centred reservation.
  func testSideLanesContractIndependentlyToTheirOwnLimit() {
    XCTAssertEqual(
      budgets([(.left, 60), (.right, 45)], fixed: [.absoluteCentre: 6]), [37, 37])
    XCTAssertEqual(
      budgets([(.left, 60), (.right, 30)], fixed: [.absoluteCentre: 6]), [37, 30],
      "a right lane inside its limit is untouched")
  }

  /// Without a centre only the physical notch and the bar width bind.
  func testWithoutACentreOnlyThePhysicalNotchAndTheBarWidthBind() {
    XCTAssertEqual(
      budgets([(.left, 50), (.right, 40)], fixed: [.left: 5], leftColumns: 30), [25, 40])
    XCTAssertEqual(budgets([(.left, 50), (.centre, 30), (.right, 40)]), [35, 30, 35])
  }

  /// A section ranks by its whole width, pill included, but never cuts into
  /// the part it cannot cut; the centre then gives way instead.
  func testASectionRanksByItsWholeWidthButKeepsItsUncuttablePart() {
    let geometry = StatusBarOverflow.Geometry(
      columns: 40, gutterColumns: 2, marginColumns: 1, minimumLaneColumns: 8)
    let sections: [StatusBarOverflow.Span] = [
      .init(lane: .left, width: 15, minimum: 11), .init(lane: .absoluteCentre, width: 6),
    ]
    XCTAssertEqual(StatusBarOverflow.budgets(sections, fixed: [:], in: geometry), [14, 6])
    var narrow = geometry
    narrow.columns = 30
    XCTAssertEqual(StatusBarOverflow.budgets(sections, fixed: [:], in: narrow), [11, 2])
  }

  func testEverySpanKeepsOneCell() {
    XCTAssertEqual(
      budgets([(.left, 10), (.right, 10)], fixed: [.left: 5, .right: 5], columns: 10), [1, 1])
  }
}
