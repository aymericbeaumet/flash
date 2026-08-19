import CoreGraphics
import FlashCore
import XCTest

@testable import flash

final class ActionDispatcherTests: XCTestCase {
  func testCurrentContextNativeLinkHintIsAPlainClick() {
    let modifiers = ActionDispatcher.hintClickModifiers(
      for: target(role: "AXLink"),
      bundleIdentifier: "com.apple.Safari",
      requested: [])

    XCTAssertEqual(modifiers, [])
  }

  func testNewContextNativeLinkHintCarriesCommandAndShift() {
    let modifiers = ActionDispatcher.hintClickModifiers(
      for: target(role: "AXLink"),
      bundleIdentifier: "com.apple.Safari",
      requested: [.command, .shift])

    XCTAssertEqual(modifiers, [.command, .shift])
  }

  func testCurrentContextFirefoxLinkHintAddsCommand() {
    let modifiers = ActionDispatcher.hintClickModifiers(
      for: target(role: "AXLink"),
      bundleIdentifier: "org.mozilla.firefox",
      requested: [])

    XCTAssertEqual(modifiers, [.command])
  }

  func testNewContextFirefoxLinkHintCarriesCommandAndShift() {
    let modifiers = ActionDispatcher.hintClickModifiers(
      for: target(role: "AXLink"),
      bundleIdentifier: "org.mozilla.firefox",
      requested: [.command, .shift])

    XCTAssertEqual(modifiers, [.command, .shift])
  }

  func testCurrentContextTerminalLinkHintAddsShift() {
    let modifiers = ActionDispatcher.hintClickModifiers(
      for: target(role: JumpTarget.terminalLinkRole),
      bundleIdentifier: "org.alacritty",
      requested: [])

    XCTAssertEqual(modifiers, [.shift])
  }

  func testNewContextTerminalLinkHintCarriesCommandAndShift() {
    let modifiers = ActionDispatcher.hintClickModifiers(
      for: target(role: JumpTarget.terminalLinkRole),
      bundleIdentifier: "org.alacritty",
      requested: [.command, .shift])

    XCTAssertEqual(modifiers, [.command, .shift])
  }

  func testEveryNonLinkHintIsAnUnmodifiedClick() {
    for role in ["tmux-pane", "AXButton", "AXTextField", "AXTab"] {
      let modifiers = ActionDispatcher.hintClickModifiers(
        for: target(role: role),
        bundleIdentifier: "org.mozilla.firefox",
        requested: .all)

      XCTAssertEqual(modifiers, [], "\(role) should receive a simple click")
    }
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
