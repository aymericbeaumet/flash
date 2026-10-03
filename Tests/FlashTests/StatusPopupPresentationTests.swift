import XCTest

@testable import flash

final class StatusPopupPresentationTests: XCTestCase {
  func testLeavingAnchorImmediatelyHidesPopup() {
    let preview = StatusPopupPresentation.hidden.applying(.anchor(name: "system"))
    XCTAssertEqual(preview, .preview(name: "system"))
    XCTAssertEqual(preview.applying(.leaveAnchor), .hidden)
    XCTAssertEqual(StatusPopupPresentation.hidden.applying(.leaveAnchor), .hidden)
  }

  func testFocusedPopupRemainsUntilExplicitDismissal() {
    let focused = StatusPopupPresentation.hidden
      .applying(.anchor(name: "system"))
      .applying(.focus)
    XCTAssertEqual(focused, .focused(name: "system"))
    XCTAssertTrue(focused.isFocused)
    XCTAssertEqual(focused.applying(.focus), focused)
    XCTAssertEqual(focused.applying(.leaveAnchor), focused)
    XCTAssertEqual(focused.applying(.anchor(name: "battery")), focused)
    XCTAssertEqual(focused.applying(.dismiss), .hidden)
  }

  func testStandalonePopupHasFocusWithoutALabelAndIgnoresHover() {
    let terminal = StatusPopupPresentation.hidden.applying(.standalone(name: "shell"))
    XCTAssertEqual(terminal, .standalone(name: "shell"))
    XCTAssertTrue(terminal.isFocused)
    XCTAssertTrue(terminal.isStandalone)
    XCTAssertEqual(terminal.name, "shell")
    XCTAssertEqual(terminal.applying(.leaveAnchor), terminal)
    XCTAssertEqual(terminal.applying(.focus), terminal)
    XCTAssertEqual(terminal.applying(.anchor(name: "system")), terminal)
    XCTAssertEqual(terminal.applying(.dismiss), .hidden)
  }

}
