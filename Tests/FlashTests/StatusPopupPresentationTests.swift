import XCTest

@testable import flash

final class StatusPopupPresentationTests: XCTestCase {
  func testLeavingAnchorImmediatelyHidesPopup() {
    let preview = StatusPopupPresentation.hidden
      .applying(.anchor(name: "system", point: CGPoint(x: -100, y: 800)))
    XCTAssertEqual(preview.applying(.leaveAnchor), .hidden)
    XCTAssertEqual(StatusPopupPresentation.hidden.applying(.leaveAnchor), .hidden)
  }

  func testFocusedPopupRemainsUntilExplicitDismissal() {
    let focused = StatusPopupPresentation.hidden
      .applying(.anchor(name: "system", point: CGPoint(x: 50, y: 100)))
      .applying(.focus)
    XCTAssertTrue(focused.isFocused)
    XCTAssertEqual(focused.applying(.leaveAnchor), focused)
    XCTAssertEqual(
      focused.applying(.anchor(name: "battery", point: CGPoint(x: 200, y: 100))), focused)
    XCTAssertEqual(focused.applying(.dismiss), .hidden)
  }

  func testStandaloneTerminalHasFocusWithoutAnAnchorAndIgnoresHover() {
    let terminal = StatusPopupPresentation.hidden.applying(.terminal(name: "terminal:shell"))
    XCTAssertEqual(terminal, .terminal(name: "terminal:shell"))
    XCTAssertTrue(terminal.isFocused)
    XCTAssertTrue(terminal.isStandalone)
    XCTAssertEqual(terminal.identity?.name, "terminal:shell")
    XCTAssertNil(terminal.identity?.anchor)
    XCTAssertEqual(terminal.applying(.leaveAnchor), terminal)
    XCTAssertEqual(terminal.applying(.focus), terminal)
    XCTAssertEqual(
      terminal.applying(.anchor(name: "system", point: CGPoint(x: 40, y: 80))), terminal)
    XCTAssertEqual(terminal.applying(.dismiss), .hidden)
  }

}
