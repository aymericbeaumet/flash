import CoreGraphics
import FlashCore
import XCTest

@testable import flash

final class ActionDispatcherTests: XCTestCase {
  func testPlainTargetUsesAccessibilityBeforeHostClick() {
    XCTAssertEqual(
      ActionDispatcher.dispatchRoute(for: target(), action: .leftClick, modifiers: []),
      .accessibilityThenHostClick)
  }

  func testPreferHostClickTargetSkipsAccessibilityRoute() {
    XCTAssertEqual(
      ActionDispatcher.dispatchRoute(
        for: target(preferHostClick: true), action: .leftClick, modifiers: []),
      .hostClick)
  }

  func testModifiedClickUsesHostClickRoute() {
    XCTAssertEqual(
      ActionDispatcher.dispatchRoute(for: target(), action: .leftClick, modifiers: [.command]),
      .hostClick)
  }

  func testRightClickAlwaysUsesHostClickSoTheMenuOpensAtTheClickPoint() {
    // A genuine right-mouse-down anchors the context menu at the cursor; the AX
    // `AXShowMenu` fallback would open the same menu at the element's default
    // (top-left) spot instead. Force the host-click route for every right-click,
    // even an unmodified one on a plain accessibility target. Left / double keep
    // the AX-first route.
    XCTAssertEqual(
      ActionDispatcher.dispatchRoute(for: target(), action: .rightClick, modifiers: []),
      .hostClick)
    XCTAssertEqual(
      ActionDispatcher.dispatchRoute(for: target(), action: .doubleClick, modifiers: []),
      .accessibilityThenHostClick)
  }

  private func target(preferHostClick: Bool = false) -> JumpTarget {
    JumpTarget(
      id: "target",
      frame: CGRect(x: 10, y: 20, width: 30, height: 40),
      role: "AXButton",
      pid: 42,
      preferHostClick: preferHostClick,
      providerID: "test")
  }
}
