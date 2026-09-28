import FlashCore
import FlashTerminal
import XCTest

@testable import flash

final class StatusTerminalRegistryTests: XCTestCase {
  private func waitUntil(_ condition: @escaping () -> Bool) {
    let ready = expectation(for: NSPredicate { _, _ in condition() }, evaluatedWith: nil)
    wait(for: [ready], timeout: 6)
  }

  private func running(_ session: TerminalSession?) -> Int32? {
    if case .running(let pid)? = session?.state { return pid }
    return nil
  }

  private func terminal(
    _ command: [String], persistent: Bool = false, size: Config.PopupSize = .default,
    environment: [String: String] = [:]
  ) -> Config.Terminal {
    Config.Terminal(
      command: command, environment: environment, size: size,
      lifecycle: persistent ? .persistent : .fresh)
  }

  private func apply(
    _ registry: StatusTerminalRegistry, _ terminals: [String: Config.Terminal],
    invalid: Set<String> = [], prewarm: Set<String> = [], style: Config.PopupStyle = .init()
  ) {
    registry.apply(style: style, terminals: terminals, invalid: invalid, prewarm: prewarm)
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
    apply(registry, [name: terminal(["/bin/sleep", "30"], persistent: true)])
    let diagnostic = registry.session(named: name)?.onDiagnostic
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

  func testPersistentKeepsItsProcessAcrossShowingsWhileFreshRunsOnePerShowing() throws {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    var terminals = [
      "persistent": terminal(["/bin/sleep", "30"], persistent: true),
      "fresh": terminal(["/bin/sleep", "30"]),
    ]
    apply(registry, terminals)
    // Persistent popups start with the environment; fresh ones on a showing.
    XCTAssertEqual(Set(registry.sessions.keys), ["persistent"])
    let persistent = try XCTUnwrap(registry.session(named: "persistent"))
    XCTAssertTrue(registry.open("persistent") === persistent)
    registry.hide("persistent")
    XCTAssertTrue(registry.open("persistent") === persistent, "hiding keeps the process")

    let first = try XCTUnwrap(registry.open("fresh"))
    XCTAssertTrue(registry.open("fresh") === first, "one instance per name")
    XCTAssertEqual(registry.sessions.count, 2)
    waitUntil { self.running(first) != nil }
    let firstPID = try XCTUnwrap(running(first))
    registry.hide("fresh")
    XCTAssertNil(registry.session(named: "fresh"), "a fresh process ends with its showing")
    waitUntil { kill(firstPID, 0) == -1 && errno == ESRCH }
    let second = try XCTUnwrap(registry.open("fresh"))
    XCTAssertFalse(second === first)
    waitUntil { self.running(second) != nil }
    XCTAssertNotEqual(running(second), firstPID)

    terminals.removeValue(forKey: "fresh")
    apply(registry, terminals)
    XCTAssertNil(registry.session(named: "fresh"))
    XCTAssertTrue(registry.session(named: "persistent") === persistent)
    XCTAssertNil(registry.open("fresh"), "only configured terminal popups open")
  }

  func testBuiltInTerminalRunsTheLoginShellInHomeAtTheDefaultGrid() throws {
    let shell = try XCTUnwrap(Config().terminalPopups[Config.defaultPopupName])
    XCTAssertEqual(shell.lifecycle, .fresh)
    XCTAssertEqual(shell.size, .default)
    let launch = StatusTerminalRegistry.configuration(
      for: shell, environment: ["SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin"])
    XCTAssertEqual(launch.command, ["/bin/zsh", "-l"])
    XCTAssertEqual(launch.workingDirectory, NSHomeDirectory())
    XCTAssertEqual(launch.columns, 100)
    XCTAssertEqual(launch.rows, 28)
    XCTAssertEqual(launch.scrollbackLines, StatusTerminalRegistry.freshScrollbackLines)
  }

  func testPrewarmedPopupIsShownAsIsAndTheNextStartsOnceTheShownOneIsGone() throws {
    let registry = StatusTerminalRegistry(
      environment: FlashProcessEnvironment(seed: [
        "SHELL": "/bin/sh", "HOME": NSTemporaryDirectory(),
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
      ]))
    defer { registry.shutdown() }
    var config = Config()
    config.popups["top"] = .terminal(terminal(["/bin/sleep", "30"], persistent: true))
    config.mode.all = [
      ModeMapping(key: "alt+space", action: .flashCommand(.terminalMode(name: nil))),
      ModeMapping(key: "alt+t", action: .flashCommand(.terminalMode(name: "top"))),
    ]
    // Persistent popups run anyway; only fresh ones are prewarmed.
    XCTAssertEqual(config.prewarmedPopupNames, ["terminal"])
    registry.apply(
      style: config.popupStyle, terminals: config.terminalPopups,
      invalid: config.invalidPopupNames, prewarm: config.prewarmedPopupNames)
    XCTAssertEqual(registry.prewarmedNames, ["terminal"])
    XCTAssertEqual(Set(registry.sessions.keys), ["terminal", "top"])
    let prewarmed = try XCTUnwrap(registry.session(named: "terminal"))
    XCTAssertEqual(prewarmed.configuration.command, ["/bin/sh", "-l"])
    waitUntil { self.running(prewarmed) != nil }
    let firstPID = try XCTUnwrap(running(prewarmed))

    // Showing attaches to the running process; nothing new starts.
    XCTAssertTrue(registry.open("terminal") === prewarmed)
    XCTAssertTrue(registry.prewarmedNames.isEmpty)

    // Dismissal stops it and prewarms a fresh process once it is gone.
    registry.hide("terminal")
    waitUntil { registry.prewarmedNames.contains("terminal") }
    XCTAssertTrue(kill(firstPID, 0) == -1 && errno == ESRCH, "the shown process is gone first")
    let next = try XCTUnwrap(registry.session(named: "terminal"))
    XCTAssertFalse(next === prewarmed)
    waitUntil { self.running(next) != nil }

    // A configuration that stops referencing it stops the unshown process.
    registry.apply(style: config.popupStyle, terminals: config.terminalPopups)
    XCTAssertNil(registry.session(named: "terminal"))
    XCTAssertTrue(registry.prewarmedNames.isEmpty)
  }

  func testUnrelatedReloadKeepsAPrewarmedPopupProcess() throws {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    let terminals = ["feed": terminal(["/bin/sleep", "30"])]
    apply(registry, terminals, prewarm: ["feed"])
    let prewarmed = try XCTUnwrap(registry.session(named: "feed"))
    waitUntil { self.running(prewarmed) != nil }
    let pid = try XCTUnwrap(running(prewarmed))
    var style = Config.PopupStyle()
    style.foreground = "#FFFFFF"
    apply(registry, terminals, prewarm: ["feed"], style: style)
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    XCTAssertTrue(registry.session(named: "feed") === prewarmed, "the prewarmed session is kept")
    XCTAssertEqual(registry.prewarmedNames, ["feed"])
    XCTAssertEqual(running(prewarmed), pid, "the command is not run again")
  }

  func testPrewarmedPopupThatExitsAtOnceBacksOffInsteadOfSpinning() {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    var starts = 0
    let sink = FlashLog.addSink { record in
      if record.message == "Status popup prewarmed" { starts += 1 }
    }
    defer { FlashLog.removeSink(sink) }
    apply(registry, ["broken": terminal(["/usr/bin/true"])], prewarm: ["broken"])
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
    let pager = registry.preparePager(
      name: "details", data: Data("Last good details".utf8), columns: 50, rows: 4)
    let command = pager.configuration.command
    let prompt = try XCTUnwrap(command.first { $0.hasPrefix("-Ps") })
    // `less` renders its short prompt in reverse video, so a blank prompt
    // still paints a light block at the foot of every preview. Leading with
    // "exit reverse" (passed through by -R) leaves the row genuinely empty.
    XCTAssertEqual(prompt, "-Ps\u{1B}[27m")
    XCTAssertTrue(command.contains("-R"))
    XCTAssertTrue(registry.isPager("details"))
  }

  func testScrollbackIsSizedByKind() {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    apply(
      registry,
      [
        "persistent": terminal(["/bin/sleep", "30"], persistent: true),
        "fresh": terminal(["/bin/sleep", "30"]),
      ])
    registry.open("fresh")
    let pager = registry.preparePager(
      name: "details", data: Data("x".utf8), columns: 10, rows: 2)
    XCTAssertEqual(
      registry.session(named: "persistent")?.configuration.scrollbackLines,
      TerminalConfiguration.defaultScrollbackLines)
    XCTAssertEqual(
      registry.session(named: "fresh")?.configuration.scrollbackLines,
      StatusTerminalRegistry.freshScrollbackLines)
    XCTAssertLessThan(
      StatusTerminalRegistry.freshScrollbackLines, TerminalConfiguration.defaultScrollbackLines)
    XCTAssertEqual(pager.configuration.scrollbackLines, 0, "less pages on the alternate screen")
  }

  func testTextPopupBecomingATerminalReplacesItsPager() {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    let pager = registry.preparePager(
      name: "details", data: Data("Last good details".utf8), columns: 50, rows: 4)
    var removed: [String] = []
    registry.willChange = { changes in
      for case .remove(let name) in changes { removed.append(name) }
    }
    apply(registry, ["details": terminal(["/bin/sleep", "30"], persistent: true)])
    XCTAssertEqual(removed, ["details"], "whatever showed the pager closes")
    XCTAssertFalse(registry.session(named: "details") === pager)
    XCTAssertFalse(registry.isPager("details"))
    XCTAssertNotNil(registry.session(named: "details"))
  }

  func testCleanExitRestartsPersistentSessionsAndReleasesFreshOnes() {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    apply(
      registry,
      [
        "persistent": terminal(["/bin/sh", "-c", "exit 0"], persistent: true),
        "fresh": terminal(["/bin/sh", "-c", "exit 0"]),
      ])
    let generation = registry.inputGenerations["persistent"]
    registry.open("fresh")
    var removed: [String] = []
    registry.willChange = { changes in
      for case .remove(let name) in changes { removed.append(name) }
    }
    waitUntil {
      registry.inputGenerations["persistent"] != generation
        && registry.session(named: "fresh") == nil
    }
    XCTAssertEqual(removed, ["fresh"])
    XCTAssertNotNil(registry.session(named: "persistent"))
  }

  func testQuitReapsChildAndAutomaticallyRestartsSamePersistentSession() throws {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    apply(registry, ["process": terminal(["/bin/sleep", "30"], persistent: true)])
    let session = try XCTUnwrap(registry.open("process"))
    waitUntil { self.running(session) != nil }
    let originalPID = try XCTUnwrap(running(session))
    let generation = registry.inputGenerations["process"]
    var sawStopped = false
    registry.didChange = {
      if case .stopped = session.state { sawStopped = true }
    }
    registry.quit(name: "process")
    XCTAssertNotEqual(registry.inputGenerations["process"], generation)
    waitUntil { self.running(session).map { $0 != originalPID } ?? false }
    XCTAssertTrue(sawStopped)
    XCTAssertTrue(registry.session(named: "process") === session)
    XCTAssertEqual(kill(originalPID, 0), -1)
    XCTAssertEqual(errno, ESRCH)
  }

  func testQuitReleasesAFreshPopupWithoutAnAutomaticRestart() throws {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    apply(registry, ["process": terminal(["/bin/sleep", "30"])])
    let session = try XCTUnwrap(registry.open("process"))
    waitUntil { self.running(session) != nil }
    let pid = try XCTUnwrap(running(session))
    registry.quit(name: "process")
    XCTAssertNil(registry.session(named: "process"))
    XCTAssertNil(registry.inputGenerations["process"])
    registry.hide("process")
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    XCTAssertNil(registry.session(named: "process"), "an unreferenced popup is not prewarmed")
    XCTAssertEqual(kill(pid, 0), -1)
  }

  func testFreshExitReleasesTheSessionWithoutRetry() throws {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    apply(registry, ["fresh": terminal(["/bin/sh", "-c", "sleep 0.2; exit 0"])])
    let session = try XCTUnwrap(registry.open("fresh"))
    var pids: Set<Int32> = []
    var removed: [String] = []
    registry.willChange = { changes in
      for case .remove(let name) in changes { removed.append(name) }
    }
    registry.didChange = {
      if let pid = self.running(registry.session(named: "fresh")) { pids.insert(pid) }
    }
    waitUntil { registry.session(named: "fresh") == nil }
    XCTAssertTrue(pids.count <= 1)
    XCTAssertEqual(removed, ["fresh"])
    XCTAssertNil(registry.inputGenerations["fresh"])
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    XCTAssertNil(registry.session(named: "fresh"))
    XCTAssertNotEqual(session.state, .idle)
  }

  func testKilledPersistentChildRestartsAndRemovalCancelsPendingRestart() throws {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    apply(registry, ["system": terminal(["/bin/sleep", "30"], persistent: true)])
    waitUntil { self.running(registry.session(named: "system")) != nil }
    let originalPID = try XCTUnwrap(running(registry.session(named: "system")))
    let originalGeneration = registry.inputGenerations["system"]
    var replacements = 0
    registry.willChange = { if $0.contains(.replace("system")) { replacements += 1 } }
    kill(originalPID, SIGKILL)
    waitUntil {
      self.running(registry.session(named: "system")).map { $0 != originalPID } ?? false
    }
    XCTAssertEqual(replacements, 1)
    XCTAssertNotEqual(registry.inputGenerations["system"], originalGeneration)
    XCTAssertEqual(kill(originalPID, 0), -1)
    let replacementPID = try XCTUnwrap(running(registry.session(named: "system")))
    let removed = expectation(description: "remove terminal while restart is pending")
    registry.didChange = {
      guard case .exited = registry.session(named: "system")?.state else { return }
      registry.didChange = nil
      self.apply(registry, [:])
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
    let name = "private-terminal-name"
    apply(
      registry,
      [
        name: terminal(
          ["/bin/sh", "-c", "printf private-terminal-output; exit 7"], persistent: true,
          environment: ["PRIVATE_TOKEN": "private-terminal-secret"])
      ])
    let exited = expectation(
      for: NSPredicate { _, _ in registry.session(named: name)?.state == .exited(code: 7) },
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
    apply(registry, ["invalid": terminal([], persistent: true)])
    let failed = expectation(
      for: NSPredicate { _, _ in
        if case .failed = registry.session(named: "invalid")?.state { return true }
        return false
      }, evaluatedWith: nil)
    wait(for: [failed], timeout: 5)
    let failure = records.first { $0.fields["state"] == "failed" }
    XCTAssertEqual(failure?.fields["failure_category"], "startup_failed")
    XCTAssertEqual(failure?.fields["failure_reason"], "Invalid terminal command or environment")
    XCTAssertEqual(failure?.level, .warn)
    XCTAssertNil(failure?.fields["pid"])
    apply(registry, [:])
    let stopped = expectation(
      for: NSPredicate { _, _ in records.contains { $0.fields["state"] == "stopped" } },
      evaluatedWith: nil)
    wait(for: [stopped], timeout: 5)
  }

  func testOnlyExecutionChangesReplaceSessions() {
    let original = terminal(["ytop"])
    var resized = original
    resized.size = Config.PopupSize(columns: .percent(90), rows: .cells(40))
    var changed = original
    changed.environment = ["LANG": "C"]
    var persistent = original
    persistent.lifecycle = .persistent
    XCTAssertEqual(
      StatusTerminalChange.reconcile(
        current: ["a": original, "b": original, "d": original],
        desired: ["a": resized, "b": changed, "c": original, "d": persistent], invalid: []),
      [.resize("a"), .replace("b"), .start("c"), .replace("d")])
    XCTAssertEqual(
      StatusTerminalChange.reconcile(
        current: ["a": original],
        desired: ["a": original], invalid: []), [])
  }

  func testInvalidReplacementPreservesLastGoodUntilRemoval() {
    let current = ["system": terminal(["ytop"])]
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

  func testSessionsExportAColorTerminal() throws {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    apply(
      registry,
      [
        "env": terminal(
          // Flash expands `$VAR` in argv itself, so the child reads its own
          // environment.
          [
            "/bin/sh", "-c",
            "echo \"$(printenv TERM)/$(printenv COLORTERM)/\"; exec /bin/sleep 30",
          ],
          persistent: true, environment: ["TERM": "dumb"])
      ])
    let session = try XCTUnwrap(registry.session(named: "env"))
    session.setWantsFrames(true)
    waitUntil { session.frame?.text.contains("xterm-256color/truecolor/") == true }
  }

  func testHiddenSessionSurvivesPresentationChangesAndReapsReplacedChild() throws {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    var terminals = ["system": terminal(["/bin/sleep", "30"], persistent: true)]
    apply(registry, terminals)
    waitUntil { self.running(registry.session(named: "system")) != nil }
    let original = registry.session(named: "system")
    let originalGeneration = registry.inputGenerations["system"]
    let originalPID = try XCTUnwrap(running(original))

    var style = Config.PopupStyle()
    style.padding += 4
    terminals["system"]?.size = Config.PopupSize(columns: .cells(120), rows: .cells(28))
    apply(registry, terminals, style: style)
    XCTAssertTrue(registry.session(named: "system") === original)
    XCTAssertEqual(original?.state, .running(pid: originalPID))
    XCTAssertEqual(registry.inputGenerations["system"], originalGeneration)

    apply(registry, [:], invalid: ["system"])
    XCTAssertTrue(registry.session(named: "system") === original)
    XCTAssertEqual(registry.inputGenerations["system"], originalGeneration)

    apply(registry, ["system": terminal(["/bin/sleep", "31"], persistent: true)])
    XCTAssertFalse(registry.session(named: "system") === original)
    XCTAssertNotEqual(registry.inputGenerations["system"], originalGeneration)
    waitUntil {
      guard let replacementPID = self.running(registry.session(named: "system")) else {
        return false
      }
      return replacementPID != originalPID && kill(originalPID, 0) == -1 && errno == ESRCH
    }
    let replacement = registry.session(named: "system")
    let replacementGeneration = registry.inputGenerations["system"]
    registry.restart(name: "system")
    XCTAssertTrue(registry.session(named: "system") === replacement)
    XCTAssertNotEqual(registry.inputGenerations["system"], replacementGeneration)
    apply(registry, [:])
    XCTAssertTrue(registry.sessions.isEmpty)
    XCTAssertTrue(registry.inputGenerations.isEmpty)
  }

  func testShutdownAwaitsAChildAlreadyRemovedByReload() throws {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    apply(
      registry,
      [
        "system": terminal(
          ["/bin/sh", "-c", "trap '' HUP TERM; printf ready; while :; do sleep 1; done"],
          persistent: true)
      ])
    registry.session(named: "system")?.setWantsFrames(true)
    waitUntil { registry.session(named: "system")?.frame?.text.contains("ready") == true }
    let pid = try XCTUnwrap(running(registry.session(named: "system")))
    apply(registry, [:])
    registry.shutdown()
    XCTAssertEqual(kill(pid, 0), -1)
    XCTAssertEqual(errno, ESRCH)
  }

  func testShutdownStopsEverySessionAtOnce() throws {
    let registry = StatusTerminalRegistry()
    let stubborn = terminal(["/bin/sh", "-c", "trap '' HUP TERM; sleep 30"], persistent: true)
    let names = (0..<4).map { "stubborn\($0)" }
    apply(registry, Dictionary(uniqueKeysWithValues: names.map { ($0, stubborn) }))
    waitUntil { names.allSatisfy { self.running(registry.session(named: $0)) != nil } }
    let pids = names.compactMap { running(registry.session(named: $0)) }
    let before = Date()
    registry.shutdown()
    // Each child ignores hangup and termination and waits out its 200 ms
    // grace period; one after another would take 800 ms.
    XCTAssertLessThan(Date().timeIntervalSince(before), 0.6)
    for pid in pids {
      XCTAssertEqual(kill(pid, 0), -1)
      XCTAssertEqual(errno, ESRCH)
    }
  }

  func testHiddenSessionsSizedByTheScreenRefitWhenItChanges() throws {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    var screen = CGSize(width: 800, height: 480)
    registry.gridResolver = { size in
      size.grid(visible: screen, cell: CGSize(width: 8, height: 16), inset: 0)
    }
    let half = Config.PopupSize(columns: .percent(50), rows: .percent(50))
    apply(
      registry,
      [
        "half": terminal(["/bin/sleep", "30"], persistent: true, size: half),
        "fixed": terminal(["/bin/sleep", "30"], persistent: true),
      ])
    let session = try XCTUnwrap(registry.session(named: "half"))
    let fixed = try XCTUnwrap(registry.session(named: "fixed"))
    XCTAssertEqual(session.configuration.columns, 50)
    XCTAssertEqual(session.configuration.rows, 15)
    session.setWantsFrames(true)
    fixed.setWantsFrames(true)
    waitUntil { session.frame != nil && fixed.frame != nil }
    screen = CGSize(width: 1600, height: 800)
    registry.refitHidden(except: nil)
    waitUntil { session.frame?.columns == 100 && session.frame?.rows == 25 }
    XCTAssertEqual(fixed.frame?.columns, 100)
    XCTAssertEqual(fixed.frame?.rows, 28, "a size in cells ignores the screen")
  }

  func testHiddenSessionReceivesConfiguredColorsBeforePresentation() throws {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    let terminals = ["system": terminal(["/bin/sleep", "30"], persistent: true)]
    var style = Config.PopupStyle()
    style.foreground = "#123456"
    style.background = "#654321"
    apply(registry, terminals, style: style)
    waitUntil { self.running(registry.session(named: "system")) != nil }
    let session = try XCTUnwrap(registry.session(named: "system"))
    XCTAssertNil(session.frame)
    session.setWantsFrames(true)
    waitUntil { session.frame != nil }
    XCTAssertEqual(session.frame?.foreground.red, 0x12)
    XCTAssertEqual(session.frame?.background.red, 0x65)

    style.foreground = "#abcdef"
    apply(registry, terminals, style: style)
    XCTAssertTrue(registry.session(named: "system") === session)
    waitUntil { session.frame?.foreground.red == 0xab }
    let originalPID = try XCTUnwrap(running(session))
    registry.restart(name: "system")
    waitUntil { self.running(session).map { $0 != originalPID } ?? false }
    XCTAssertEqual(session.frame?.foreground.red, 0xab)
    XCTAssertEqual(session.frame?.background.red, 0x65)
  }
}
