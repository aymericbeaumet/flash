import XCTest

@testable import flash

/// Which completion row is highlighted, and whether Return runs it: only a row
/// the user moved or tabbed to is chosen; the resolver's pick is only shown.
final class CommandLineCompletionSelectionTests: XCTestCase {
  private typealias Selection = CommandLineCompletionSelection

  func testOnlyAMovedOrTabbedRowIsChosen() {
    XCTAssertNil(Selection.none.index)
    XCTAssertFalse(Selection.implied(2).isChosen)
    XCTAssertEqual(Selection.implied(2).index, 2)
    XCTAssertEqual(Selection.implied(2).moved(by: 1, count: 5), .chosen(3))
    XCTAssertEqual(Selection.implied(2).tabbed(count: 5), .chosen(2), "Tab keeps the pick")
    XCTAssertTrue(Selection.chosen(0).isChosen)
  }

  func testMovingStartsAtTheFirstRowAndStaysInTheList() {
    XCTAssertEqual(Selection.none.moved(by: 1, count: 3), .chosen(0))
    XCTAssertEqual(Selection.chosen(2).moved(by: 1, count: 3), .chosen(2))
    XCTAssertEqual(Selection.chosen(0).moved(by: -1, count: 3), .chosen(0))
    XCTAssertEqual(Selection.chosen(1).moved(by: 1, count: 0), .none)
    XCTAssertEqual(Selection.none.tabbed(count: 3), .chosen(0), "Tab with none takes the first")
    XCTAssertEqual(Selection.implied(7).tabbed(count: 3), .chosen(2))
  }

  func testUpFromTheTopOrFromNoRowEntersHistory() {
    XCTAssertTrue(Selection.none.entersHistory(movingBy: -1))
    XCTAssertTrue(Selection.chosen(0).entersHistory(movingBy: -1))
    XCTAssertFalse(Selection.chosen(2).entersHistory(movingBy: -1))
    XCTAssertFalse(Selection.none.entersHistory(movingBy: 1))
  }
}
