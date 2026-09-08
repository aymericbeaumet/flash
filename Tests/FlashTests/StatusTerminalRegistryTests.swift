import XCTest

@testable import flash

final class StatusTerminalRegistryTests: XCTestCase {
  func testOnlyExecutionChangesReplaceSessions() {
    let original = Config.StatusBar.TerminalPopup(command: ["ytop"])
    var resized = original
    resized.rows = 40
    var changed = original
    changed.environment = ["LANG": "C"]
    XCTAssertEqual(
      StatusTerminalChange.reconcile(
        current: ["a": original, "b": original],
        desired: ["a": resized, "b": changed, "c": original], invalid: []),
      [.resize("a"), .replace("b"), .start("c")])
    XCTAssertEqual(
      StatusTerminalChange.reconcile(
        current: ["a": original],
        desired: ["a": original], invalid: []), [])
  }

  func testInvalidReplacementPreservesLastGoodUntilRemoval() {
    let current = ["system": Config.StatusBar.TerminalPopup(command: ["ytop"])]
    XCTAssertEqual(
      StatusTerminalChange.reconcile(
        current: current, desired: [:],
        invalid: ["system"]), [])
    XCTAssertEqual(
      StatusTerminalChange.reconcile(
        current: current, desired: [:],
        invalid: []), [.remove("system")])
  }

  func testArgumentExpansionDoesNotEvaluateShellCode() {
    XCTAssertEqual(
      StatusTerminalRegistry.expand(
        "$HOME/${NAME}/$(echo x)",
        environment: ["HOME": "/tmp", "NAME": "a b"]), "/tmp/a b/$(echo x)")
    XCTAssertEqual(StatusTerminalRegistry.expand("${UNKNOWN}", environment: [:]), "${UNKNOWN}")
  }

  func testHiddenSessionSurvivesPresentationChangesAndReapsReplacedChild() {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    var config = Config.StatusBar()
    config.enabled = false
    config.terminalPopups["system"] = .init(command: ["/bin/sleep", "30"])
    registry.apply(config)
    let started = expectation(
      for: NSPredicate { _, _ in
        if case .running = registry.sessions["system"]?.state { return true }
        return false
      }, evaluatedWith: nil)
    wait(for: [started], timeout: 5)
    let original = registry.sessions["system"]
    let originalGeneration = registry.inputGenerations["system"]
    guard case .running(let originalPID) = original?.state else {
      return XCTFail("The disabled bar must still start its declared terminal")
    }

    config.enabled = true
    config.popupStyle.padding += 4
    config.terminalPopups["system"]?.columns = 100
    registry.apply(config)
    XCTAssertTrue(registry.sessions["system"] === original)
    XCTAssertEqual(original?.state, .running(pid: originalPID))
    XCTAssertEqual(registry.inputGenerations["system"], originalGeneration)

    config.terminalPopups.removeAll()
    config.invalidTerminalPopupNames = ["system"]
    registry.apply(config)
    XCTAssertTrue(registry.sessions["system"] === original)
    XCTAssertEqual(registry.inputGenerations["system"], originalGeneration)

    config.invalidTerminalPopupNames = []
    config.terminalPopups["system"] = .init(command: ["/bin/sleep", "31"])
    registry.apply(config)
    XCTAssertFalse(registry.sessions["system"] === original)
    XCTAssertNotEqual(registry.inputGenerations["system"], originalGeneration)
    let replaced = expectation(
      for: NSPredicate { _, _ in
        guard case .running(let replacementPID) = registry.sessions["system"]?.state else {
          return false
        }
        return replacementPID != originalPID && kill(originalPID, 0) == -1 && errno == ESRCH
      }, evaluatedWith: nil)
    wait(for: [replaced], timeout: 5)
    let replacement = registry.sessions["system"]
    let replacementGeneration = registry.inputGenerations["system"]
    registry.restart(name: "system")
    XCTAssertTrue(registry.sessions["system"] === replacement)
    XCTAssertNotEqual(registry.inputGenerations["system"], replacementGeneration)
    config.terminalPopups.removeAll()
    registry.apply(config)
    XCTAssertTrue(registry.sessions.isEmpty)
    XCTAssertTrue(registry.inputGenerations.isEmpty)
  }

  func testShutdownAwaitsAChildAlreadyRemovedByReload() {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    var config = Config.StatusBar()
    config.terminalPopups["system"] = .init(
      command: ["/bin/sh", "-c", "trap '' HUP TERM; printf ready; while :; do sleep 1; done"])
    registry.apply(config)
    let ready = expectation(
      for: NSPredicate { _, _ in
        registry.sessions["system"]?.frame?.text.contains("ready") == true
      }, evaluatedWith: nil)
    wait(for: [ready], timeout: 5)
    guard case .running(let pid) = registry.sessions["system"]?.state else {
      return XCTFail("Expected a running child")
    }
    config.terminalPopups.removeAll()
    registry.apply(config)
    registry.shutdown()
    XCTAssertEqual(kill(pid, 0), -1)
    XCTAssertEqual(errno, ESRCH)
  }

  func testHiddenSessionReceivesConfiguredColorsBeforePresentation() {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    var config = Config.StatusBar()
    config.popupStyle.foreground = "#123456"
    config.popupStyle.background = "#654321"
    config.terminalPopups["system"] = .init(command: ["/bin/sleep", "30"])
    registry.apply(config)
    let ready = expectation(
      for: NSPredicate { _, _ in
        registry.sessions["system"]?.frame != nil
      }, evaluatedWith: nil)
    wait(for: [ready], timeout: 5)
    let session = registry.sessions["system"]
    XCTAssertEqual(session?.frame?.foreground.red, 0x12)
    XCTAssertEqual(session?.frame?.background.red, 0x65)

    config.popupStyle.foreground = "#abcdef"
    registry.apply(config)
    XCTAssertTrue(registry.sessions["system"] === session)
    let updated = expectation(
      for: NSPredicate { _, _ in
        session?.frame?.foreground.red == 0xab
      }, evaluatedWith: nil)
    wait(for: [updated], timeout: 5)
    guard case .running(let originalPID) = session?.state else {
      return XCTFail("Expected a running terminal")
    }
    registry.restart(name: "system")
    let restarted = expectation(
      for: NSPredicate { _, _ in
        if case .running(let pid) = session?.state { return pid != originalPID }
        return false
      }, evaluatedWith: nil)
    wait(for: [restarted], timeout: 5)
    XCTAssertEqual(session?.frame?.foreground.red, 0xab)
    XCTAssertEqual(session?.frame?.background.red, 0x65)
  }
}
