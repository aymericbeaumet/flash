import XCTest

@testable import flash

final class StatusTerminalRegistryTests: XCTestCase {
  private func waitUntil(_ condition: @escaping () -> Bool) {
    let ready = expectation(for: NSPredicate { _, _ in condition() }, evaluatedWith: nil)
    wait(for: [ready], timeout: 6)
  }

  func testProcessCleanupDiagnosticsForwardOnlyPhasePIDAndHashedName() {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    var records: [FlashLog.Record] = []
    let sink = FlashLog.addSink { record in
      if record.source == "core:StatusTerminalRegistry.process" { records.append(record) }
    }
    defer { FlashLog.removeSink(sink) }
    let name = "private-terminal-name"
    registry.apply(
      .init(), terminals: [name: .init(command: ["/bin/sleep", "30"], persistent: true)])
    let diagnostic = registry.sessions[name]?.onDiagnostic
    diagnostic?(.reapDeferred(pid: 123))
    diagnostic?(.reaped(pid: 123))
    XCTAssertEqual(records.map { $0.fields["phase"] }, ["reap_deferred", "reaped"])
    for record in records {
      XCTAssertEqual(
        Set(record.fields.keys), Set(["popup_id", "child_pid", "phase"]))
      XCTAssertEqual(record.fields["child_pid"], "123")
      XCTAssertEqual(record.fields["popup_id"], StatusFormatDocument.stableID(name))
      XCTAssertFalse((record.message + record.fields.values.joined()).contains(name))
    }
  }

  func testImmediateExitStormBacksOffAndUserQuitsAfterOneSecondRestartPromptly() {
    var backoff = TerminalRestartBackoff()
    XCTAssertEqual((0..<8).map { _ in backoff.nextDelay(at: 0) }, [0.1, 1, 2, 4, 8, 16, 30, 30])
    backoff.running(at: 100)
    XCTAssertEqual(backoff.nextDelay(at: 100.9), 30)
    for time in 200...203 {
      backoff.running(at: TimeInterval(time))
      XCTAssertEqual(backoff.nextDelay(at: TimeInterval(time + 1)), 0.1)
    }
  }

  func testStandalonePersistentReopensSameChildWhileEphemeralOpensFreshAndReleases() {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    var config = Config()
    let process = Config.Terminal(command: ["/bin/sleep", "30"])
    var persistentProcess = process
    persistentProcess.persistent = true
    config.terminals["persistent"] = persistentProcess
    config.terminals["temporary"] = process
    registry.apply(config.statusBar, terminals: config.terminals)
    XCTAssertNotNil(registry.sessions["persistent"])
    XCTAssertEqual(registry.sessions.count, 1)
    let persistent = registry.openTerminal(name: "persistent", configuration: config)!
    let persistentSession = registry.sessions[persistent]
    let first = registry.openTerminal(name: "temporary", configuration: config)!
    let firstSession = registry.sessions[first]
    XCTAssertEqual(registry.prepareTerminal(name: "temporary", configuration: config), first)
    XCTAssertTrue(registry.sessions[first] === firstSession)
    XCTAssertEqual(registry.terminalKey(named: "temporary", focusedName: first), first)
    XCTAssertNil(registry.terminalKey(named: "unrelated", focusedName: first))
    XCTAssertEqual(registry.terminalKey(named: "temporary", focusedName: nil), first)
    XCTAssertEqual(registry.terminalKey(named: "persistent", focusedName: first), persistent)
    waitUntil {
      [persistent, first].allSatisfy {
        if case .running = registry.sessions[$0]?.state { return true }
        return false
      }
    }
    guard case .running(let firstPID) = firstSession?.state else {
      return XCTFail("Expected a running ephemeral child")
    }
    registry.releaseTerminal(name: persistent)
    XCTAssertEqual(registry.openTerminal(name: "persistent", configuration: config), persistent)
    XCTAssertTrue(registry.sessions[persistent] === persistentSession)
    registry.apply(config.statusBar, terminals: config.terminals)
    XCTAssertNotNil(registry.sessions[first])
    registry.releaseTerminal(name: first)
    XCTAssertNil(registry.sessions[first])
    waitUntil { kill(firstPID, 0) == -1 && errno == ESRCH }
    let second = registry.prepareTerminal(name: "temporary", configuration: config)!
    XCTAssertEqual(second, first)
    XCTAssertFalse(registry.sessions[second] === firstSession)
    waitUntil {
      if case .running = registry.sessions[second]?.state { return true }
      return false
    }
    guard case .running(let secondPID) = registry.sessions[second]?.state else { return }
    XCTAssertNotEqual(firstPID, secondPID)
    let secondSession = registry.sessions[second]
    XCTAssertEqual(registry.openTerminal(name: "temporary", configuration: config), second)
    XCTAssertFalse(registry.sessions[second] === secondSession)
    config.terminals.removeValue(forKey: "temporary")
    registry.apply(config.statusBar, terminals: config.terminals)
    XCTAssertNil(registry.sessions[second])
    XCTAssertNotNil(registry.sessions[persistent])
  }

  func testUnnamedShellStartsInHomeAndLiteralStatusNameResolves() {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    var config = Config()
    config.terminals["system"] = .init(command: ["/bin/sleep", "30"], persistent: true)
    registry.apply(config.statusBar, terminals: config.terminals)
    let shell = registry.openTerminal(name: nil, configuration: config)!
    XCTAssertEqual(registry.definitions[shell]?.workingDirectory, NSHomeDirectory())
    XCTAssertEqual(registry.definitions[shell]?.columns, 100)
    XCTAssertEqual(registry.definitions[shell]?.rows, 28)
    XCTAssertEqual(registry.terminalKey(named: "system", focusedName: shell), "system")
    registry.releaseTerminal(name: shell)
    XCTAssertNil(registry.terminalKey(named: shell, focusedName: shell))
  }

  func testCleanPersistentAndEphemeralExitsBothRestart() {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    var config = Config()
    let process = Config.Terminal(command: ["/bin/sh", "-c", "exit 0"])
    var persistentProcess = process
    persistentProcess.persistent = true
    config.terminals["persistent"] = persistentProcess
    config.terminals["temporary"] = process
    registry.apply(config.statusBar, terminals: config.terminals)
    let generation = registry.inputGenerations["persistent"]
    let temporary = registry.openTerminal(name: "temporary", configuration: config)!
    let temporaryGeneration = registry.inputGenerations[temporary]
    waitUntil {
      registry.inputGenerations["persistent"] != generation
        && registry.inputGenerations[temporary] != temporaryGeneration
    }
    XCTAssertTrue(registry.automaticallyRestarts(name: temporary))
    registry.releaseTerminal(name: temporary)
    XCTAssertNil(registry.sessions[temporary])
  }

  func testEphemeralRestartPreservesSessionWithNewPIDAndReleaseCancelsNextRetry() {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    var config = Config()
    config.terminals["temporary"] = .init(command: ["/bin/sh", "-c", "sleep 0.2; exit 0"])
    let name = registry.openTerminal(name: "temporary", configuration: config)!
    let session = registry.sessions[name]
    let initialGeneration = registry.inputGenerations[name]
    var pids: Set<Int32> = []
    let released = expectation(description: "second child exits then presentation releases it")
    registry.didChange = {
      switch registry.sessions[name]?.state {
      case .running(let pid):
        pids.insert(pid)
        XCTAssertTrue(registry.sessions[name] === session)
      case .exited where pids.count >= 2:
        XCTAssertNotEqual(registry.inputGenerations[name], initialGeneration)
        registry.didChange = nil
        registry.releaseTerminal(name: name)
        released.fulfill()
      default: break
      }
    }
    wait(for: [released], timeout: 6)
    XCTAssertEqual(pids.count, 2)
    RunLoop.current.run(until: Date().addingTimeInterval(1.2))
    XCTAssertNil(registry.sessions[name])
    for pid in pids { XCTAssertEqual(kill(pid, 0), -1) }
  }

  func testKilledPersistentChildRestartsAndRemovalCancelsPendingRestart() {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    var config = Config()
    config.terminals["system"] = .init(command: ["/bin/sleep", "30"], persistent: true)
    registry.apply(
      config.statusBar, terminals: config.terminals,
      invalidTerminalNames: config.invalidTerminalNames)
    waitUntil {
      if case .running = registry.sessions["system"]?.state { return true }
      return false
    }
    guard case .running(let originalPID) = registry.sessions["system"]?.state else { return }
    let originalGeneration = registry.inputGenerations["system"]
    var replacements = 0
    registry.willChange = { if $0.contains(.replace("system")) { replacements += 1 } }
    kill(originalPID, SIGKILL)
    waitUntil {
      if case .running(let pid) = registry.sessions["system"]?.state { return pid != originalPID }
      return false
    }
    XCTAssertEqual(replacements, 1)
    XCTAssertNotEqual(registry.inputGenerations["system"], originalGeneration)
    XCTAssertEqual(kill(originalPID, 0), -1)
    guard case .running(let replacementPID) = registry.sessions["system"]?.state else { return }
    let removed = expectation(description: "remove terminal while restart is pending")
    registry.didChange = {
      guard case .exited = registry.sessions["system"]?.state else { return }
      registry.didChange = nil
      config.terminals.removeAll()
      registry.apply(config.statusBar, terminals: config.terminals)
      removed.fulfill()
    }
    kill(replacementPID, SIGKILL)
    wait(for: [removed], timeout: 6)
    RunLoop.current.run(until: Date().addingTimeInterval(1.2))
    XCTAssertTrue(registry.sessions.isEmpty)
    XCTAssertEqual(replacements, 1)
  }

  func testHiddenTerminalLifecycleLogsPIDAndExitWithoutPrivateContent() {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    var records: [FlashLog.Record] = []
    let sink = FlashLog.addSink { record in
      if record.source == "core:StatusTerminalRegistry.lifecycle" { records.append(record) }
    }
    defer { FlashLog.removeSink(sink) }
    var config = Config()
    let name = "private-terminal-name"
    config.terminals[name] = .init(
      command: ["/bin/sh", "-c", "printf private-terminal-output; exit 7"],
      environment: ["PRIVATE_TOKEN": "private-terminal-secret"], persistent: true)
    registry.apply(
      config.statusBar, terminals: config.terminals,
      invalidTerminalNames: config.invalidTerminalNames)
    let exited = expectation(
      for: NSPredicate { _, _ in registry.sessions[name]?.state == .exited(code: 7) },
      evaluatedWith: nil)
    wait(for: [exited], timeout: 5)
    let running = records.first { $0.fields["state"] == "running" }
    let exit = records.first { $0.fields["state"] == "exited" }
    XCTAssertGreaterThan(Int(running?.fields["pid"] ?? "") ?? 0, 0)
    XCTAssertEqual(exit?.fields["pid"], running?.fields["pid"])
    XCTAssertEqual(exit?.fields["exit_code"], "7")
    XCTAssertEqual(exit?.level, .warn)
    XCTAssertEqual(exit?.fields["popup_id"], StatusFormatDocument.stableID(name))
    for record in records {
      let details = record.message + record.fields.keys.joined() + record.fields.values.joined()
      for privateValue in [
        name, "private-terminal-output", "PRIVATE_TOKEN", "private-terminal-secret",
      ] {
        XCTAssertFalse(details.contains(privateValue))
      }
    }
  }

  func testFailedTerminalStartLogsCategoryAndRemovalLogsStop() {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    var records: [FlashLog.Record] = []
    let sink = FlashLog.addSink { record in
      if record.source == "core:StatusTerminalRegistry.lifecycle" { records.append(record) }
    }
    defer { FlashLog.removeSink(sink) }
    var config = Config()
    config.terminals["invalid"] = .init(command: [], persistent: true)
    registry.apply(
      config.statusBar, terminals: config.terminals,
      invalidTerminalNames: config.invalidTerminalNames)
    let failed = expectation(
      for: NSPredicate { _, _ in
        if case .failed = registry.sessions["invalid"]?.state { return true }
        return false
      }, evaluatedWith: nil)
    wait(for: [failed], timeout: 5)
    let failure = records.first { $0.fields["state"] == "failed" }
    XCTAssertEqual(failure?.fields["failure_category"], "startup_failed")
    XCTAssertEqual(failure?.fields["failure_reason"], "Invalid terminal command or environment")
    XCTAssertEqual(failure?.level, .warn)
    XCTAssertNil(failure?.fields["pid"])
    config.terminals.removeAll()
    registry.apply(
      config.statusBar, terminals: config.terminals,
      invalidTerminalNames: config.invalidTerminalNames)
    let stopped = expectation(
      for: NSPredicate { _, _ in records.contains { $0.fields["state"] == "stopped" } },
      evaluatedWith: nil)
    wait(for: [stopped], timeout: 5)
  }

  func testOnlyExecutionChangesReplaceSessions() {
    let original = Config.Terminal(command: ["ytop"])
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
    let current = ["system": Config.Terminal(command: ["ytop"])]
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
    var config = Config()
    config.statusBar.enabled = false
    config.terminals["system"] = .init(command: ["/bin/sleep", "30"], persistent: true)
    registry.apply(
      config.statusBar, terminals: config.terminals,
      invalidTerminalNames: config.invalidTerminalNames)
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

    config.statusBar.enabled = true
    config.statusBar.popupStyle.padding += 4
    config.terminals["system"]?.columns = 120
    registry.apply(
      config.statusBar, terminals: config.terminals,
      invalidTerminalNames: config.invalidTerminalNames)
    XCTAssertTrue(registry.sessions["system"] === original)
    XCTAssertEqual(original?.state, .running(pid: originalPID))
    XCTAssertEqual(registry.inputGenerations["system"], originalGeneration)

    config.terminals.removeAll()
    config.invalidTerminalNames = ["system"]
    registry.apply(
      config.statusBar, terminals: config.terminals,
      invalidTerminalNames: config.invalidTerminalNames)
    XCTAssertTrue(registry.sessions["system"] === original)
    XCTAssertEqual(registry.inputGenerations["system"], originalGeneration)

    config.invalidTerminalNames = []
    config.terminals["system"] = .init(command: ["/bin/sleep", "31"], persistent: true)
    registry.apply(
      config.statusBar, terminals: config.terminals,
      invalidTerminalNames: config.invalidTerminalNames)
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
    config.terminals.removeAll()
    registry.apply(
      config.statusBar, terminals: config.terminals,
      invalidTerminalNames: config.invalidTerminalNames)
    XCTAssertTrue(registry.sessions.isEmpty)
    XCTAssertTrue(registry.inputGenerations.isEmpty)
  }

  func testShutdownAwaitsAChildAlreadyRemovedByReload() {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    var config = Config()
    config.terminals["system"] = .init(
      command: ["/bin/sh", "-c", "trap '' HUP TERM; printf ready; while :; do sleep 1; done"],
      persistent: true)
    registry.apply(
      config.statusBar, terminals: config.terminals,
      invalidTerminalNames: config.invalidTerminalNames)
    let ready = expectation(
      for: NSPredicate { _, _ in
        registry.sessions["system"]?.frame?.text.contains("ready") == true
      }, evaluatedWith: nil)
    wait(for: [ready], timeout: 5)
    guard case .running(let pid) = registry.sessions["system"]?.state else {
      return XCTFail("Expected a running child")
    }
    config.terminals.removeAll()
    registry.apply(
      config.statusBar, terminals: config.terminals,
      invalidTerminalNames: config.invalidTerminalNames)
    registry.shutdown()
    XCTAssertEqual(kill(pid, 0), -1)
    XCTAssertEqual(errno, ESRCH)
  }

  func testHiddenSessionReceivesConfiguredColorsBeforePresentation() {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    var config = Config()
    config.statusBar.popupStyle.foreground = "#123456"
    config.statusBar.popupStyle.background = "#654321"
    config.terminals["system"] = .init(command: ["/bin/sleep", "30"], persistent: true)
    registry.apply(
      config.statusBar, terminals: config.terminals,
      invalidTerminalNames: config.invalidTerminalNames)
    let ready = expectation(
      for: NSPredicate { _, _ in
        registry.sessions["system"]?.frame != nil
      }, evaluatedWith: nil)
    wait(for: [ready], timeout: 5)
    let session = registry.sessions["system"]
    XCTAssertEqual(session?.frame?.foreground.red, 0x12)
    XCTAssertEqual(session?.frame?.background.red, 0x65)

    config.statusBar.popupStyle.foreground = "#abcdef"
    registry.apply(
      config.statusBar, terminals: config.terminals,
      invalidTerminalNames: config.invalidTerminalNames)
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
