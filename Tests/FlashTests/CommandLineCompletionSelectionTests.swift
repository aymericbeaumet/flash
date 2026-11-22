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

  // MARK: The list

  private typealias Completion = NormalModeDispatcher.CommandLineCompletion

  private func context(
    _ query: String, _ labels: [String], selected: String? = nil, prefix: String = ":"
  ) -> NormalModeDispatcher.CommandLineCompletionContext {
    .init(
      prefix: prefix, query: query,
      items: labels.map { Completion(label: $0, insertion: "\($0) ", kind: .acceptsArgs) },
      selectedLabel: selected, ambiguous: false)
  }

  func testTheEmptyPromptListsEveryItemByFrecencyThenName() {
    var list = CommandLineCompletionList()
    list.update(context: context("", ["tab", "help", "quit"])) { $0 == "quit" ? 40 : 0 }
    XCTAssertEqual(list.matches.map(\.completion.label), ["quit", "help", "tab"])
    XCTAssertEqual(list.selection, .none, "nothing typed selects nothing")
    XCTAssertNil(list.selected)
    XCTAssertTrue(list.isTopLevelEmpty)
  }

  func testTheWordTheQuerySelectsRanksFirstAndIsHighlightedNotChosen() throws {
    var list = CommandLineCompletionList()
    // Frecency favours `qall`; `:q` still means `quit`.
    list.update(context: context("q", ["qall", "quit", "tab"], selected: "quit")) {
      $0 == "qall" ? 40 : 0
    }
    XCTAssertEqual(list.matches.map(\.completion.label), ["quit", "qall"], "`tab` has no q")
    XCTAssertEqual(list.selection, .implied(0))
    XCTAssertEqual(list.selected?.label, "quit")
    XCTAssertEqual(list.buffer(inserting: try XCTUnwrap(list.selected)), ":quit ")
    XCTAssertFalse(list.isTopLevelEmpty)
    XCTAssertEqual(list.displayItems(windowSize: 5).map(\.isSelected), [true, false])

    // The next keystroke recomputes the highlight: a moved row does not stick.
    list.selection = list.selection.moved(by: 1, count: list.matches.count)
    XCTAssertEqual(list.selected?.label, "qall")
    list.update(context: context("qa", ["qall", "quit", "tab"], selected: "qall")) { _ in 0 }
    XCTAssertEqual(list.selection, .implied(0))
    XCTAssertEqual(list.selected?.label, "qall")
  }

  func testTheDisplayedWindowFollowsTheSelection() {
    var list = CommandLineCompletionList()
    list.update(context: context("", ["a", "b", "c", "d", "e"])) { _ in 0 }
    XCTAssertEqual(list.displayItems(windowSize: 2).map(\.title), ["a", "b"])
    list.selection = .chosen(4)
    let shown = list.displayItems(windowSize: 2)
    XCTAssertEqual(shown.last?.title, "e")
    XCTAssertEqual(shown.filter(\.isSelected).map(\.title), ["e"])
    XCTAssertTrue(CommandLineCompletionList().displayItems(windowSize: 2).isEmpty)
  }
}
