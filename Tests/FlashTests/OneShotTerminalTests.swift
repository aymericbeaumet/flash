import AppKit
import FlashCore
import FlashTerminal
import XCTest

@testable import flash

final class OneShotTerminalTests: XCTestCase {
  override func setUp() {
    super.setUp()
    _ = NSApplication.shared
  }

  private func waitUntil(_ description: String, _ condition: @escaping () -> Bool) {
    let ready = expectation(for: NSPredicate { _, _ in condition() }, evaluatedWith: nil)
    ready.expectationDescription = description
    wait(for: [ready], timeout: 5)
  }

  private func registry(shell: String = "/bin/sh") -> StatusTerminalRegistry {
    StatusTerminalRegistry(
      environment: FlashProcessEnvironment(seed: [
        "SHELL": shell, "HOME": NSTemporaryDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
      ]))
  }

  private func show(_ controller: StatusPopupController, name: String) {
    controller.showTerminal(
      name: name, visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 800), style: .init(),
      font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
  }

  func testUnnamedTerminalExitQuitKillAndHideRetirePresentationAndHistory() throws {
    for action in ["exit", "quit", "kill", "hide"] {
      let registry = registry()
      defer { registry.shutdown() }
      let controller = StatusPopupController(terminals: registry, windowActionsEnabled: false)
      var dismissals = 0
      var focusDismissalReasons: [String] = []
      controller.didDismissFocus = { focusDismissalReasons.append($0) }
      controller.didDismiss = {
        dismissals += 1
        registry.releaseTerminal(name: $0)
      }
      let name = try XCTUnwrap(registry.openTerminal(name: nil, configuration: Config()))
      var session = try XCTUnwrap(registry.sessions[name]) as TerminalSession?
      weak let retired = session
      show(controller, name: name)
      waitUntil("unnamed shell running") {
        if case .running = session?.state { return true }
        return false
      }
      guard case .running(let pid) = session?.state else { return XCTFail("Missing child") }
      XCTAssertFalse(registry.automaticallyRestarts(name: name))
      session?.send(Data("printf one-shot-output\r".utf8))
      waitUntil("terminal has scrollback") {
        controller.terminalView.terminalFrame?.text.contains("one-shot-output") == true
      }
      switch action {
      case "exit": session?.send(Data("exit 0\r".utf8))
      case "quit": registry.quit(name: name)
      case "kill": XCTAssertEqual(kill(pid, SIGKILL), 0)
      default: controller.dismiss(reason: "terminal_closed")
      }
      session = nil
      waitUntil("one-shot child and presentation retired after \(action)") {
        registry.sessions[name] == nil && !controller.isVisible && kill(pid, 0) == -1
      }
      waitUntil("retired session released") { retired == nil }
      XCTAssertEqual(dismissals, 1)
      XCTAssertEqual(
        focusDismissalReasons, [action == "hide" ? "terminal_closed" : "terminal_removed"])
      XCTAssertTrue(registry.definitions.isEmpty)
      XCTAssertTrue(registry.inputGenerations.isEmpty)
      XCTAssertTrue(controller.terminalView.terminalFrame == nil)
      registry.restart(name: name)
      registry.apply(.init())
      XCTAssertTrue(registry.sessions.isEmpty)
      let next = try XCTUnwrap(registry.openTerminal(name: nil, configuration: Config()))
      XCTAssertNotEqual(next, name)
      show(controller, name: next)
      waitUntil("fresh frame") { controller.terminalView.terminalFrame != nil }
      XCTAssertFalse(
        controller.terminalView.terminalFrame?.text.contains("one-shot-output") == true)
      controller.dismiss()
      XCTAssertNil(registry.sessions[next])
    }
  }

  func testExplicitRestartKeepsOneShotVisibleButQuitStillRetiresIt() throws {
    let registry = registry()
    defer { registry.shutdown() }
    let controller = StatusPopupController(terminals: registry, windowActionsEnabled: false)
    controller.didDismiss = { registry.releaseTerminal(name: $0) }
    let name = try XCTUnwrap(registry.openTerminal(name: nil, configuration: Config()))
    let session = try XCTUnwrap(registry.sessions[name])
    show(controller, name: name)
    waitUntil("initial child") {
      if case .running = session.state { return true }
      return false
    }
    guard case .running(let pid) = session.state else { return XCTFail("Missing child") }
    let generation = registry.inputGenerations[name]
    registry.restart(name: name)
    waitUntil("deliberate replacement") {
      if case .running(let replacement) = session.state { return replacement != pid }
      return false
    }
    XCTAssertEqual(controller.focusedName, name)
    XCTAssertTrue(registry.sessions[name] === session)
    XCTAssertNotEqual(registry.inputGenerations[name], generation)
    XCTAssertFalse(registry.automaticallyRestarts(name: name))
    registry.quit(name: name)
    XCTAssertNil(registry.sessions[name])
    XCTAssertFalse(controller.isVisible)
  }

  func testFailedUnnamedShellDisappearsWithoutRetry() throws {
    let registry = registry(shell: "/missing/flash-test-shell")
    defer { registry.shutdown() }
    let controller = StatusPopupController(terminals: registry, windowActionsEnabled: false)
    controller.didDismiss = { registry.releaseTerminal(name: $0) }
    let name = try XCTUnwrap(registry.openTerminal(name: nil, configuration: Config()))
    show(controller, name: name)
    waitUntil("failed one-shot removed") { registry.sessions[name] == nil && !controller.isVisible }
    XCTAssertNil(registry.definitions[name])
  }
}
