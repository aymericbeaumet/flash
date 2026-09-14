import CoreGraphics
import FlashCore
import XCTest

@testable import flash

final class ActionDispatcherTests: XCTestCase {
  func testCurrentContextHintIsPlainAcrossTargets() {
    for role in ["AXLink", "AXButton", "AXTextField", "AXTab", "tmux-pane"] {
      let modifiers = ActionDispatcher.hintClickModifiers(
        for: target(role: role), requested: [])

      XCTAssertEqual(modifiers, [], "\(role) should receive a plain click")
    }
  }

  func testNewContextHintCarriesCommandAndShiftAcrossTargets() {
    for role in ["AXLink", "AXButton", "AXTextField", "AXTab", "tmux-pane"] {
      let modifiers = ActionDispatcher.hintClickModifiers(
        for: target(role: role), requested: [.command, .shift])

      XCTAssertEqual(
        modifiers, [.command, .shift], "\(role) should receive the new-context gesture")
    }
  }

  func testEveryRequestedModifierIsPreservedAcrossTargets() {
    for role in ["AXLink", "AXButton", "AXTextField", "AXTab", "tmux-pane"] {
      let modifiers = ActionDispatcher.hintClickModifiers(
        for: target(role: role), requested: .all)

      XCTAssertEqual(modifiers, .all, "\(role) should preserve requested modifiers")
    }
  }

  func testCurrentContextTerminalLinkHintAddsShift() {
    let modifiers = ActionDispatcher.hintClickModifiers(
      for: target(role: JumpTarget.terminalLinkRole),
      requested: [])

    XCTAssertEqual(modifiers, [.shift])
  }

  func testNewContextTerminalLinkHintCarriesCommandAndShift() {
    let modifiers = ActionDispatcher.hintClickModifiers(
      for: target(role: JumpTarget.terminalLinkRole),
      requested: [.command, .shift])

    XCTAssertEqual(modifiers, [.command, .shift])
  }

  /// A committed hint clicks the target without relocating the pointer: the
  /// dispatcher warps to the target, clicks, and warps back to where the user
  /// left it.
  func testCommittedClicksReturnThePointerToWhereTheUserLeftIt() {
    let origin = CGPoint(x: 100, y: 200)
    XCTAssertEqual(
      ActionDispatcher.cursorRestorePoint(
        from: origin, to: CGPoint(x: 800, y: 450), preserveCursor: true),
      origin)
  }

  /// Clicking where the pointer already sits skips the round trip, so a
  /// forwarded physical click never blinks the cursor.
  func testClickUnderThePointerDoesNotWarp() {
    let origin = CGPoint(x: 100, y: 200)
    XCTAssertNil(
      ActionDispatcher.cursorRestorePoint(from: origin, to: origin, preserveCursor: true))
    XCTAssertNil(
      ActionDispatcher.cursorRestorePoint(
        from: origin, to: CGPoint(x: 100.4, y: 199.7), preserveCursor: true))
  }

  /// The verbs whose purpose is moving the pointer keep it where they put it.
  func testPointerMovingVerbsLeaveThePointerAtTheClickPoint() {
    XCTAssertNil(
      ActionDispatcher.cursorRestorePoint(
        from: CGPoint(x: 100, y: 200), to: CGPoint(x: 800, y: 450), preserveCursor: false))
  }

  private func target(role: String) -> JumpTarget {
    JumpTarget(
      id: "target",
      frame: CGRect(x: 10, y: 20, width: 30, height: 40),
      role: role,
      pid: 42,
      providerID: "test")
  }
}
