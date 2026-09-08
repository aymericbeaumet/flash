import XCTest

@testable import flash

final class StatusPopupPresentationTests: XCTestCase {
  func testLeavingAnchorImmediatelyHidesPopup() {
    let preview = StatusPopupPresentation.hidden
      .applying(.anchor(name: "system", point: CGPoint(x: -100, y: 800)))
    XCTAssertEqual(preview.applying(.leaveAnchor), .hidden)
    XCTAssertEqual(StatusPopupPresentation.hidden.applying(.leaveAnchor), .hidden)
  }

  func testFocusedPopupAlsoHidesWhenLeavingAnchor() {
    let focused = StatusPopupPresentation.hidden
      .applying(.anchor(name: "system", point: CGPoint(x: 50, y: 100)))
      .applying(.focus)
    XCTAssertTrue(focused.isFocused)
    XCTAssertEqual(focused.applying(.leaveAnchor), .hidden)
    XCTAssertEqual(focused.applying(.dismiss), .hidden)
  }
}
