import FlashCore
import XCTest

@testable import flash

/// `@windows`: the switcher's catalog searched from the flashlight, as
/// Contexts, Witch or Raycast's window search do. No real window is read:
/// the rows and the focus come from fakes.
final class WindowListSourceTests: XCTestCase {
  private func key(_ index: Int32) -> WindowSwitcherKey {
    WindowSwitcherKey(pid: 80_000 + index, element: AXApp.make(pid: 80_000 + index))
  }

  private func row(_ index: Int32, _ title: String, app: String, badge: String? = nil)
    -> WindowListSource.Row
  {
    WindowListSource.Row(key: key(index), title: title, app: app, badge: badge)
  }

  func testRowsKeepRecencyWithTheCurrentWindowLast() {
    let rows = [
      row(1, "Inbox", app: "Mail"), row(2, "flash — zsh", app: "Ghostty"),
      row(3, "", app: "Finder", badge: "minimized"),
    ]
    let built = WindowListSource.candidates(rows, current: key(1))
    XCTAssertEqual(built.candidates.map(\.title), ["Inbox", "flash — zsh", "Finder"])
    XCTAssertEqual(built.candidates.map(\.sourceOrder), [3, 1, 2], "the current window goes last")
    XCTAssertEqual(built.candidates[2].subtitle, "Finder · minimized")
    XCTAssertEqual(built.candidates[1].searchAliases, "Ghostty", "found by its app's name")
    XCTAssertEqual(built.candidates[0].source, WindowListSource.label)
    XCTAssertEqual(built.keys.count, 3)
    for candidate in built.candidates {
      XCTAssertNotNil(candidate.sourcePayload.flatMap { built.keys[$0] })
    }
  }

  func testSelectingARowFocusesItsWindowAndAStaleRowNothing() {
    var focused: [WindowSwitcherKey] = []
    let source = WindowListSource(
      rows: { ([self.row(1, "Inbox", app: "Mail"), self.row(2, "Notes", app: "Notes")], nil) },
      focus: { focused.append($0) })
    let listed = expectation(description: "rows")
    var candidates: [Candidate] = []
    source.liveCandidates(
      matching: "", in: FlashSourceEnvironment(runningApplications: []), scope: .all
    ) {
      candidates = $0
      listed.fulfill()
    }
    wait(for: [listed], timeout: 2)
    XCTAssertEqual(candidates.count, 2)

    let chosen = expectation(description: "resolved")
    source.resolveCandidate(candidates[1], in: FlashSourceEnvironment(runningApplications: [])) {
      XCTAssertTrue($0.didResolve)
      XCTAssertNil($0.targetPID, "the window's focus activates its app")
      chosen.fulfill()
    }
    wait(for: [chosen], timeout: 2)
    XCTAssertEqual(focused, [key(2)])

    var stale = candidates[0]
    stale.metadata[CandidateMetadataKey.payload] = "1:99"
    let refused = expectation(description: "unresolved")
    source.resolveCandidate(stale, in: FlashSourceEnvironment(runningApplications: [])) {
      XCTAssertFalse($0.didResolve)
      refused.fulfill()
    }
    wait(for: [refused], timeout: 2)
    XCTAssertEqual(focused, [key(2)], "a row the list no longer has focuses nothing")
  }

  func testTheRegistryListsWindowsOnlyWhenGivenTheCatalog() {
    let source = WindowListSource(rows: { ([], nil) }, focus: { _ in })
    let with = SourceRegistry(runningApplications: [], windows: source)
    let without = SourceRegistry(runningApplications: [])
    XCTAssertTrue(with.sources.contains { $0.identifier == WindowListSource.sourceID })
    XCTAssertFalse(without.sources.contains { $0.identifier == WindowListSource.sourceID })
    XCTAssertTrue(source.servesLiveCandidates)
    XCTAssertFalse(source.liveCandidatesDependOnText, "pulled once per scope")
  }
}
