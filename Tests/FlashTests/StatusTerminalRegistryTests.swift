import FlashCore
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

  func testRestartsParkAfterRepeatedImmediateExits() {
    var backoff = TerminalRestartBackoff()
    let delays = (0..<TerminalRestartBackoff.maxAttempts).map { _ in backoff.nextDelay(at: 0) }
    XCTAssertEqual(delays.compactMap { $0 }.count, TerminalRestartBackoff.maxAttempts)
    XCTAssertNil(backoff.nextDelay(at: 0), "parks after \(TerminalRestartBackoff.maxAttempts)")
    XCTAssertNil(backoff.nextDelay(at: 0))
    backoff.running(at: 100)
    XCTAssertEqual(backoff.nextDelay(at: 101.5), 0.1, "a run of one second resets the count")
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

  func testWarmSpareShellIsHandedToTheNextUnnamedOpenAndReplaced() throws {
    let registry = StatusTerminalRegistry(
      environment: FlashProcessEnvironment(seed: [
        "SHELL": "/bin/sh", "HOME": NSTemporaryDirectory(),
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
      ]))
    defer { registry.shutdown() }
    let config = Config()
    registry.warmFreshShell(configuration: config)
    let spare = try XCTUnwrap(registry.spareShellKey)
    registry.warmFreshShell(configuration: config)
    XCTAssertEqual(registry.spareShellKey, spare, "one spare at a time")
    XCTAssertEqual(registry.definitions[spare]?.command, ["/bin/sh", "-l"])
    XCTAssertFalse(registry.automaticallyRestarts(name: spare))
    waitUntil {
      if case .running = registry.sessions[spare]?.state { return true }
      return false
    }
    // Opening the unnamed shell attaches to the warm process and warms another.
    XCTAssertEqual(registry.openTerminal(name: nil, configuration: config), spare)
    let next = try XCTUnwrap(registry.spareShellKey)
    XCTAssertNotEqual(next, spare)
    XCTAssertNotNil(registry.sessions[spare])
    XCTAssertNotNil(registry.sessions[next])
    // Releasing the opened shell leaves the spare waiting; losing the spare
    // process forgets it so the next open spawns directly.
    registry.releaseTerminal(name: spare)
    XCTAssertNil(registry.sessions[spare])
    XCTAssertEqual(registry.spareShellKey, next)
    registry.releaseTerminal(name: next)
    XCTAssertNil(registry.spareShellKey)
    let direct = try XCTUnwrap(registry.openTerminal(name: nil, configuration: config))
    XCTAssertNotEqual(direct, next)
    XCTAssertNotNil(registry.spareShellKey)
    XCTAssertNotEqual(registry.spareShellKey, direct)
  }

  func testShownTerminalPopupIsPreloadedShownAsIsAndReplacedOnceDismissed() throws {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    var config = Config()
    config.terminals["feed"] = .init(command: ["/bin/sleep", "30"])
    config.terminals["top"] = .init(command: ["/bin/sleep", "30"], persistent: true)
    registry.preloadPopups(named: ["feed", "top", "date"], configuration: config)
    // Persistent terminals run from startup and text popups have no process.
    XCTAssertEqual(registry.preloadedNames, ["feed"])
    XCTAssertEqual(Set(registry.sessions.keys), ["feed"])
    let preloaded = registry.sessions["feed"]
    waitUntil {
      if case .running = registry.sessions["feed"]?.state { return true }
      return false
    }
    guard case .running(let firstPID) = preloaded?.state else { return XCTFail("not running") }

    // Hovering shows the running process; nothing new starts.
    XCTAssertEqual(registry.prepareTerminal(name: "feed", configuration: config), "feed")
    XCTAssertTrue(registry.sessions["feed"] === preloaded)
    XCTAssertTrue(registry.preloadedNames.isEmpty)

    // Dismissal stops it and preloads a fresh process once it is gone.
    registry.releaseTerminal(name: "feed")
    waitUntil { registry.preloadedNames.contains("feed") }
    XCTAssertFalse(registry.sessions["feed"] === preloaded)
    XCTAssertTrue(kill(firstPID, 0) == -1 && errno == ESRCH, "the shown process is gone first")
    waitUntil {
      if case .running = registry.sessions["feed"]?.state { return true }
      return false
    }

    // `terminal_show --name=feed` takes the preloaded process too.
    let next = registry.sessions["feed"]
    XCTAssertEqual(registry.openTerminal(name: "feed", configuration: config), "feed")
    XCTAssertTrue(registry.sessions["feed"] === next)
    registry.releaseTerminal(name: "feed")
    waitUntil { registry.preloadedNames.contains("feed") }

    // A bar that stops showing it stops the unshown process.
    registry.preloadPopups(named: [], configuration: config)
    XCTAssertNil(registry.sessions["feed"])
    XCTAssertTrue(registry.preloadedNames.isEmpty)
  }

  func testPreloadedPopupThatExitsAtOnceBacksOffInsteadOfSpinning() {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    var starts = 0
    let sink = FlashLog.addSink { record in
      if record.message == "Status popup preloaded" { starts += 1 }
    }
    defer { FlashLog.removeSink(sink) }
    var config = Config()
    config.terminals["broken"] = .init(command: ["/usr/bin/true"])
    registry.preloadPopups(named: ["broken"], configuration: config)
    // The first retry waits 100 ms and the next one second.
    let deadline = Date().addingTimeInterval(5)
    while starts < 2, Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    XCTAssertEqual(starts, 2)
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    XCTAssertEqual(starts, 2, "no retry storm")
  }

  func testPopupPagerPromptDrawsNothingInsteadOfAStandoutBlock() throws {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    _ = registry.preparePopup(
      name: "details", data: Data("Last good details".utf8), columns: 50, rows: 4,
      colors: StatusPopupColors(.init()))
    let command = try XCTUnwrap(registry.definitions["details"]?.command)
    let prompt = try XCTUnwrap(command.first { $0.hasPrefix("-Ps") })
    // `less` renders its short prompt in reverse video, so a blank prompt
    // still paints a light block at the foot of every preview. Leading with
    // "exit reverse" (passed through by -R) leaves the row genuinely empty.
    XCTAssertEqual(prompt, "-Ps\u{1B}[27m")
    XCTAssertTrue(command.contains("-R"))
  }

  func testInvalidTerminalOverridePreservesTheExistingPopupPager() {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    let pager = registry.preparePopup(
      name: "details", data: Data("Last good details".utf8), columns: 50, rows: 4,
      colors: StatusPopupColors(.init()))
    var config = Config()
    config.invalidTerminalNames.insert("details")
    XCTAssertEqual(registry.prepareTerminal(name: "details", configuration: config), "details")
    XCTAssertTrue(registry.sessions["details"] === pager)
    XCTAssertTrue(registry.isPopupPager(name: "details"))
    config.invalidTerminalNames.remove("details")
    config.terminals["details"] = .init(command: ["/bin/sleep", "30"])
    XCTAssertEqual(registry.prepareTerminal(name: "details", configuration: config), "details")
    XCTAssertFalse(registry.sessions["details"] === pager)
    XCTAssertFalse(registry.isPopupPager(name: "details"))
  }

  func testFreshShellIsWarmedOnlyWhenAMappingOpensIt() {
    var mode = Config.Mode()
    XCTAssertFalse(AppDelegate.bindsFreshShell(mode))
    mode.all = [
      ModeMapping(key: "alt+space", action: .flashCommand(.terminalShow(name: "bonsai")))
    ]
    XCTAssertFalse(AppDelegate.bindsFreshShell(mode))
    mode.terminal = [ModeMapping(key: "alt+space", action: .flashCommand(.terminalShow(name: nil)))]
    XCTAssertTrue(AppDelegate.bindsFreshShell(mode))
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

  func testCleanExitRestartsPersistentSessionsAndReleasesNonpersistentOnes() {
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
    XCTAssertFalse(registry.automaticallyRestarts(name: temporary))
    XCTAssertTrue(registry.automaticallyRestarts(name: "persistent"))
    var removed: [String] = []
    registry.willChange = { changes in
      for change in changes {
        if case .remove(let name) = change { removed.append(name) }
      }
    }
    waitUntil {
      registry.inputGenerations["persistent"] != generation && registry.sessions[temporary] == nil
    }
    XCTAssertEqual(removed, [temporary])
    XCTAssertNil(registry.definitions[temporary])
    XCTAssertNotNil(registry.sessions["persistent"])
  }

  func testQuitReapsChildAndAutomaticallyRestartsSamePersistentSession() {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    var config = Config()
    config.terminals["process"] = .init(command: ["/bin/sleep", "30"], persistent: true)
    let name = registry.openTerminal(name: "process", configuration: config)!
    let session = registry.sessions[name]
    waitUntil {
      if case .running = session?.state { return true }
      return false
    }
    guard case .running(let originalPID) = session?.state else { return }
    let generation = registry.inputGenerations[name]
    var sawStopped = false
    registry.didChange = {
      if case .stopped = session?.state { sawStopped = true }
    }
    registry.quit(name: name)
    XCTAssertNotEqual(registry.inputGenerations[name], generation)
    waitUntil {
      if case .running(let pid) = session?.state { return pid != originalPID }
      return false
    }
    XCTAssertTrue(sawStopped)
    XCTAssertTrue(registry.sessions[name] === session)
    XCTAssertTrue(registry.automaticallyRestarts(name: name))
    XCTAssertEqual(kill(originalPID, 0), -1)
    XCTAssertEqual(errno, ESRCH)
  }

  func testQuitReleasesNonpersistentTemplateTerminal() {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    var config = Config()
    config.terminals["process"] = .init(command: ["/bin/sleep", "30"])
    let name = registry.openTerminal(name: "process", configuration: config)!
    let session = registry.sessions[name]
    waitUntil {
      if case .running = session?.state { return true }
      return false
    }
    guard case .running(let pid) = session?.state else { return }
    registry.quit(name: name)
    XCTAssertNil(registry.sessions[name])
    XCTAssertNil(registry.definitions[name])
    waitUntil { kill(pid, 0) == -1 }
  }

  func testDismissalDuringQuitCancelsAutomaticRestart() {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    var config = Config()
    config.terminals["process"] = .init(command: ["/bin/sleep", "30"])
    let name = registry.openTerminal(name: "process", configuration: config)!
    waitUntil {
      if case .running = registry.sessions[name]?.state { return true }
      return false
    }
    guard case .running(let pid) = registry.sessions[name]?.state else { return }
    registry.quit(name: name)
    registry.releaseTerminal(name: name)
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    XCTAssertNil(registry.sessions[name])
    XCTAssertNil(registry.inputGenerations[name])
    XCTAssertEqual(kill(pid, 0), -1)
  }

  func testNonpersistentExitReleasesTheSessionWithoutRetry() {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    var config = Config()
    config.terminals["temporary"] = .init(command: ["/bin/sh", "-c", "sleep 0.2; exit 0"])
    let name = registry.openTerminal(name: "temporary", configuration: config)!
    var pids: Set<Int32> = []
    var removed: [String] = []
    registry.willChange = { changes in
      for change in changes {
        if case .remove(let name) = change { removed.append(name) }
      }
    }
    registry.didChange = {
      if case .running(let pid) = registry.sessions[name]?.state { pids.insert(pid) }
    }
    waitUntil { registry.sessions[name] == nil }
    XCTAssertEqual(pids.count, 1)
    XCTAssertEqual(removed, [name])
    XCTAssertNil(registry.inputGenerations[name])
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
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
      CommandLaunchConfiguration.expand(
        "$HOME/${NAME}/$(echo x)",
        environment: ["HOME": "/tmp", "NAME": "a b"]), "/tmp/a b/$(echo x)")
    XCTAssertEqual(CommandLaunchConfiguration.expand("${UNKNOWN}", environment: [:]), "${UNKNOWN}")
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
    registry.sessions["system"]?.setWantsFrames(true)
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
    waitUntil {
      if case .running = registry.sessions["system"]?.state { return true }
      return false
    }
    XCTAssertNil(registry.sessions["system"]?.frame)
    registry.sessions["system"]?.setWantsFrames(true)
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
