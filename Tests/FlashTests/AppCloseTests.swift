import XCTest

@testable import flash

/// `app close`, vim's `:q`: the tab, else the window, and the app with its
/// last window (`AppClose`).
final class AppCloseTests: XCTestCase {
  func testOnlyAnAppWithoutTheTabCommandGoesOnToItsWindows() {
    XCTAssertTrue(AppClose.continuesToWindows(after: .unavailable))
    for outcome in [NormalModeCommandOutcome.performed, .chordSent, .failed, .noTarget, .refused] {
      XCTAssertFalse(AppClose.continuesToWindows(after: outcome), "\(outcome)")
    }
  }

  func testTheLastWindowQuitsTheAppWhileOthersClose() {
    XCTAssertEqual(AppClose.step(standardWindows: 3), .closeWindow)
    XCTAssertEqual(AppClose.step(standardWindows: 2), .closeWindow)
    XCTAssertEqual(AppClose.step(standardWindows: 1), .quitApp)
    XCTAssertEqual(AppClose.step(standardWindows: 0), .quitApp)
    XCTAssertEqual(AppClose.step(standardWindows: nil), .quitApp)
  }

  /// Flash composes the command itself: it is no binding key, its words
  /// round-trip, and quitting the app may move the keyboard focus.
  func testAppCloseIsFlashsOwnComposite() throws {
    let command = try XCTUnwrap(URLEventHandler.parse(words: ["app", "close"]))
    XCTAssertEqual(command, .appClose)
    XCTAssertNil(command.sourceCommand)
    XCTAssertEqual(command.argv, ["flash", "app", "close"])
    XCTAssertTrue(AppDelegate.normalModeCommandMayChangeKeyboardFocus(.appClose))
  }

  /// `:q` and `:wq` run it; `:bd` and `:tabc` stay the tab alone.
  func testTheQuitAliasesRunAppClose() {
    let specs = NormalModeDispatcher.commandLineSpecs
    func commands(_ word: String) -> [URLCommand]? {
      specs.first { $0.matches(word) }?.commands
    }
    XCTAssertEqual(commands("q"), [.appClose])
    XCTAssertEqual(commands("quit"), [.appClose])
    XCTAssertEqual(commands("wq"), [.save, .appClose])
    XCTAssertEqual(commands("x"), [.save, .appClose])
    XCTAssertEqual(commands("bd"), [.tabClose])
    XCTAssertEqual(commands("tabc"), [.tabClose])
    XCTAssertEqual(commands("qa"), [.quitApp(force: false)])
  }
}
