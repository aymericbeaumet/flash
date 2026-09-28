import AppKit
import FlashCore
import FlashTerminal
import XCTest

@testable import flash

/// A weak reference both Swift 6.1 (no `weak let`) and 6.3 (no `weak var`
/// that is never reassigned) accept under `-warnings-as-errors`.
private final class WeakReference<Object: AnyObject> {
  weak var object: Object?
  init(_ object: Object?) { self.object = object }
}

/// The built-in `terminal` popup: fresh, one instance at a time, prewarmed
/// when a mapping opens it.
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

  private func registry(shell: String = "/bin/sh", prewarm: Bool = true) -> StatusTerminalRegistry {
    let registry = StatusTerminalRegistry(
      environment: FlashProcessEnvironment(seed: [
        "SHELL": shell, "HOME": NSTemporaryDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
      ]))
    let config = Config()
    registry.apply(
      style: config.popupStyle, terminals: config.terminalPopups,
      prewarm: prewarm ? [Config.defaultPopupName] : [])
    return registry
  }

  private func show(_ controller: StatusPopupController) {
    controller.show(
      name: Config.defaultPopupName, visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
      style: .init(), font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
  }

  func testShellExitQuitKillAndHideRetirePresentationAndHistory() throws {
    let name = Config.defaultPopupName
    for action in ["exit", "quit", "kill", "hide"] {
      let registry = registry()
      defer { registry.shutdown() }
      let controller = StatusPopupController(terminals: registry, windowActionsEnabled: false)
      var dismissals = 0
      var focusDismissalReasons: [String] = []
      controller.didDismissFocus = { focusDismissalReasons.append($0) }
      controller.didDismiss = { _ in dismissals += 1 }
      var session = try XCTUnwrap(registry.open(name)) as TerminalSession?
      let retired = WeakReference(session)
      show(controller)
      waitUntil("shell running") {
        if case .running = session?.state { return true }
        return false
      }
      guard case .running(let pid) = session?.state else { return XCTFail("Missing child") }
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
      waitUntil("child and presentation retired after \(action)") {
        registry.session(named: name) !== retired.object && !controller.isVisible
          && kill(pid, 0) == -1
      }
      waitUntil("retired session released") { retired.object == nil }
      XCTAssertEqual(dismissals, 1)
      XCTAssertEqual(
        focusDismissalReasons, [action == "hide" ? "terminal_closed" : "terminal_removed"])
      XCTAssertTrue(controller.terminalView.terminalFrame == nil)
      // The next showing attaches to a new prewarmed process with no history.
      waitUntil("next shell prewarmed after \(action)") {
        registry.prewarmedNames.contains(name)
      }
      let next = try XCTUnwrap(registry.open(name))
      show(controller)
      waitUntil("fresh frame") { controller.terminalView.terminalFrame != nil }
      XCTAssertFalse(
        controller.terminalView.terminalFrame?.text.contains("one-shot-output") == true)
      controller.dismiss()
      XCTAssertFalse(registry.session(named: name) === next)
    }
  }

  func testExplicitRestartKeepsTheShellVisibleButQuitStillRetiresIt() throws {
    let name = Config.defaultPopupName
    let registry = registry(prewarm: false)
    defer { registry.shutdown() }
    let controller = StatusPopupController(terminals: registry, windowActionsEnabled: false)
    let session = try XCTUnwrap(registry.open(name))
    show(controller)
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
    XCTAssertTrue(registry.session(named: name) === session)
    XCTAssertNotEqual(registry.inputGenerations[name], generation)
    registry.quit(name: name)
    XCTAssertNil(registry.session(named: name))
    XCTAssertFalse(controller.isVisible)
  }

  func testFailedShellDisappearsWithoutRetry() throws {
    let name = Config.defaultPopupName
    let registry = registry(shell: "/missing/flash-test-shell", prewarm: false)
    defer { registry.shutdown() }
    let controller = StatusPopupController(terminals: registry, windowActionsEnabled: false)
    XCTAssertNotNil(registry.open(name))
    show(controller)
    waitUntil("failed shell removed") {
      registry.session(named: name) == nil && !controller.isVisible
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    XCTAssertNil(registry.session(named: name))
  }
}
