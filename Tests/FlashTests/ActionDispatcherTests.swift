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

  private func target(role: String) -> JumpTarget {
    JumpTarget(
      id: "target",
      frame: CGRect(x: 10, y: 20, width: 30, height: 40),
      role: role,
      pid: 42,
      providerID: "test")
  }
}
