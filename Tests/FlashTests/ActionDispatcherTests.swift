import CoreGraphics
import FlashCore
import XCTest

@testable import flash

final class ActionDispatcherTests: XCTestCase {
  func testPlainTargetUsesAccessibilityBeforeHostClick() {
    XCTAssertEqual(
      ActionDispatcher.dispatchRoute(for: target(), modifiers: []),
      .accessibilityThenHostClick)
  }

  func testPreferHostClickTargetSkipsAccessibilityRoute() {
    XCTAssertEqual(
      ActionDispatcher.dispatchRoute(for: target(preferHostClick: true), modifiers: []),
      .hostClick)
  }

  func testModifiedClickUsesHostClickRoute() {
    XCTAssertEqual(
      ActionDispatcher.dispatchRoute(for: target(), modifiers: [.command]),
      .hostClick)
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
