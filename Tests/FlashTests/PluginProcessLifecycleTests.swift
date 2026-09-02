import FlashCore
import Foundation
import XCTest

@testable import flash

// MARK: - Shared fixture kit

/// Fixture factory shared by the host-side lifecycle and manager suites:
/// tiny `/bin/sh` scripts speaking protocol v1 over NDJSON, written into a
/// temp plugin root next to a temp base data dir. The scripts append one
/// line per spawn (and per ping) into the plugin's data dir, so tests can
/// count restarts without racing the process table.
enum PluginFixtureKit {
  struct Fixture {
    let root: URL
    let baseDataDir: URL
    let pluginID: String
    var dataDir: URL { baseDataDir.appendingPathComponent(pluginID) }

    /// One line per spawn, appended by the script prologue.
    func spawnCount() -> Int { lineCount("spawns") }
    /// One line per `ping` request the fixture observed.
    func pingCount() -> Int { lineCount("pings") }

    private func lineCount(_ name: String) -> Int {
      guard
        let text = try? String(
          contentsOf: dataDir.appendingPathComponent(name), encoding: .utf8)
      else { return 0 }
      return text.split(separator: "\n").count
    }

    func cleanup() {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: baseDataDir)
    }
  }

  static let initializeOK =
    #"printf '{"id":%s,"result":{"ok":true,"protocol_version":1}}\n' "$id""#
  static let pingOK =
    #"printf 'ping\n' >> "$D/pings"; printf '{"id":%s,"result":{"ok":true}}\n' "$id""#
  static let performOK =
    #"printf '{"id":%s,"result":{"ok":true,"message":"fixture-done"}}\n' "$id""#

  /// The standard fixture skeleton: read NDJSON lines, extract the request
  /// id with sed, dispatch on the method substring, exit 0 on stdin EOF
  /// (EOF IS the shutdown signal). Notifications and unknown methods are
  /// ignored, exactly like a minimal conformant plugin.
  static func script(
    prologue: String = "",
    onInitialize: String = initializeOK,
    onPing: String = pingOK,
    onPerform: String = performOK
  ) -> String {
    """
    #!/bin/sh
    D="$FLASH_PLUGIN_DATA_DIR"
    printf 'spawn\\n' >> "$D/spawns"
    \(prologue)
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
      case "$line" in
      *'"method":"initialize"'*)
        \(onInitialize)
        ;;
      *'"method":"ping"'*)
        \(onPing)
        ;;
      *'"method":"perform"'*)
        \(onPerform)
        ;;
      esac
    done
    exit 0
    """
  }

  /// A minimal valid manifest with `exec ["./run.sh"]`; `extra` appends
  /// surfaces (and thereby selects the activation mode).
  static func manifest(id: String, extra: String = #""status": ["state"]"#) -> String {
    """
    {
      "id": "\(id)",
      "name": "Fixture \(id)",
      "version": "1.0.0",
      "description": "lifecycle fixture",
      "exec": ["./run.sh"],
      \(extra)
    }
    """
  }

  /// Pass `baseDataDir` when several fixtures share one manager (the manager
  /// owns a single base data dir; each plugin's data dir is `base/<id>`).
  static func make(
    id: String, manifest: String, script: String, baseDataDir: URL? = nil
  ) throws -> Fixture {
    let fm = FileManager.default
    let base = fm.temporaryDirectory
      .appendingPathComponent("flash-plugin-fixture-\(id)-\(UUID().uuidString)")
    let root = base.appendingPathComponent("root")
    let dataRoot = baseDataDir ?? base.appendingPathComponent("data")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    try fm.createDirectory(at: dataRoot, withIntermediateDirectories: true)
    try manifest.write(
      to: root.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    let scriptURL = root.appendingPathComponent("run.sh")
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    return Fixture(root: root, baseDataDir: dataRoot, pluginID: id)
  }
}

extension XCTestCase {
  /// Poll `condition` on the main run loop until it holds or `timeout`
  /// elapses (deadline polling, never fixed sleeps). Fails the test with
  /// `what` on expiry.
  @discardableResult
  func waitUntilTrue(
    timeout: TimeInterval = 8,
    _ what: String,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    if condition() { return true }
    XCTFail("timed out waiting for \(what)", file: file, line: line)
    return false
  }

  /// Run the main run loop for a short settle window (used only for
  /// "X must NOT happen" assertions, after the positive signal already
  /// arrived through a deadline poll).
  func settleRunLoop(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
  }
}

// MARK: - Lifecycle suite

/// Drives a real `PluginProcess` against sh fixture scripts through the full
/// five-state machine: crash coercion, bounded restart parking, initialize
/// NAKs, idle-ping liveness, publish/status intake, EOF shutdown, and lazy
/// activation. Every mutated static seam is restored before the test ends.
final class PluginProcessLifecycleTests: XCTestCase {
  private let immediateRestartDelay: (Int) -> Int = { _ in 0 }

  private func makeProcess(
    _ fixture: PluginFixtureKit.Fixture,
    store: PluginCatalogStore? = nil
  ) throws -> PluginProcess {
    let manifest = try PluginManifest.load(from: fixture.root)
    let process = PluginProcess(
      root: fixture.root,
      manifest: manifest,
      origin: .official,
      baseDataDir: fixture.baseDataDir,
      watchFiles: false)
    process.catalogStore = store
    return process
  }

  /// Shrinks the lifecycle seams for the duration of `body` and restores the
  /// exact previous values afterwards, including the FlashTunables-backed
  /// startup timeout (computed, not cached, so this takes effect
  /// immediately).
  private func withSeams(
    attempts: Int? = nil,
    windowSeconds: TimeInterval? = nil,
    idleBeforePingMs: Int? = nil,
    pingTimeoutMs: Int? = nil,
    restartDelay: ((Int) -> Int)? = nil,
    startupTimeoutSeconds: Int? = nil,
    _ body: () throws -> Void
  ) rethrows {
    let originalAttempts = PluginProcess.restartWindowAttempts
    let originalWindow = PluginProcess.restartWindowSeconds
    let originalIdle = PluginProcess.idleBeforePingMs
    let originalPing = PluginProcess.pingTimeoutMs
    let originalDelay = PluginProcess.restartDelaySeconds
    let originalStartup = FlashTunables.pluginStartupTimeoutSeconds
    defer {
      PluginProcess.restartWindowAttempts = originalAttempts
      PluginProcess.restartWindowSeconds = originalWindow
      PluginProcess.idleBeforePingMs = originalIdle
      PluginProcess.pingTimeoutMs = originalPing
      PluginProcess.restartDelaySeconds = originalDelay
      FlashTunables.pluginStartupTimeoutSeconds = originalStartup
    }
    if let attempts { PluginProcess.restartWindowAttempts = attempts }
    if let windowSeconds { PluginProcess.restartWindowSeconds = windowSeconds }
    if let idleBeforePingMs { PluginProcess.idleBeforePingMs = idleBeforePingMs }
    if let pingTimeoutMs { PluginProcess.pingTimeoutMs = pingTimeoutMs }
    if let restartDelay { PluginProcess.restartDelaySeconds = restartDelay }
    if let startupTimeoutSeconds {
      FlashTunables.pluginStartupTimeoutSeconds = startupTimeoutSeconds
    }
    try body()
  }

  // MARK: 1. Crash mid-request

  func testCrashDuringPerformSettlesFailedNeverUnhandledAndRestarts() throws {
    // A plugin that dies mid-`perform` was DISPATCHED: the pending request
    // settles as the failed case (the host must NOT fall back — the action
    // may have landed before the crash) and the child is restarted.
    let fixture = try PluginFixtureKit.make(
      id: "crashmid",
      manifest: PluginFixtureKit.manifest(id: "crashmid"),
      script: PluginFixtureKit.script(
        onPerform: """
          if [ ! -f "$D/performed" ]; then : > "$D/performed"; exit 3; fi
          \(PluginFixtureKit.performOK)
          """))
    defer { fixture.cleanup() }
    try withSeams(restartDelay: immediateRestartDelay) {
      let process = try makeProcess(fixture)
      process.start()
      waitUntilTrue("running") { process.runtimeStateSnapshot() == .running }

      let settled = expectation(description: "perform settles")
      process.perform(kind: "command", params: [:]) { outcome in
        guard case .failed = outcome else {
          XCTFail(
            "crash mid-perform must settle failed (got \(outcome)) — unhandled would let the host double-fire a fallback"
          )
          settled.fulfill()
          return
        }
        settled.fulfill()
      }
      wait(for: [settled], timeout: 8)

      // Restart scheduling: the crash is a plain teardown, not a park.
      waitUntilTrue("respawn after crash") { fixture.spawnCount() >= 2 }
      waitUntilTrue("running again") { process.runtimeStateSnapshot() == .running }
      process.stopAndWait(reason: "test")
    }
  }

  // MARK: 2. Restart parking + re-arm

  func testRestartLoopParksInFailedAndReloadRearms() throws {
    // A crash-looping plugin restarts `restartWindowAttempts` times within
    // the window, then parks in `.failed` and stops restarting. A
    // user-initiated reload() re-arms the bounded loop.
    let fixture = try PluginFixtureKit.make(
      id: "crashloop",
      manifest: PluginFixtureKit.manifest(id: "crashloop"),
      script: """
        #!/bin/sh
        printf 'spawn\\n' >> "$FLASH_PLUGIN_DATA_DIR/spawns"
        exit 7
        """)
    defer { fixture.cleanup() }
    try withSeams(attempts: 2, windowSeconds: 60, restartDelay: immediateRestartDelay) {
      let process = try makeProcess(fixture)
      process.start()
      waitUntilTrue("park in failed") { process.runtimeStateSnapshot() == .failed }
      // attempts=2 → initial spawn + 2 restarts, then the 3rd schedule parks.
      XCTAssertEqual(fixture.spawnCount(), 3)
      XCTAssertTrue(
        process.statusSnapshot().lastError?.contains("restart loop exhausted") == true)
      // Parked means parked: no further spawns.
      settleRunLoop(0.3)
      XCTAssertEqual(fixture.spawnCount(), 3)
      XCTAssertEqual(process.runtimeStateSnapshot(), .failed)

      // The public re-arm API: reload() clears the restart window and starts
      // the resident process again.
      let before = fixture.spawnCount()
      process.reload(reason: "test_rearm")
      waitUntilTrue("respawn after reload") { fixture.spawnCount() > before }
      // Let the (still crashing) fixture park again so the test ends quiescent.
      waitUntilTrue("re-park") { process.runtimeStateSnapshot() == .failed }
      process.stopAndWait(reason: "test")
    }
  }

  // MARK: 3. Never-initialize

  func testNeverInitializingPluginTearsDownAndBackoffRestartsNotFatalPark() throws {
    // No initialize reply within the startup deadline: teardown + backoff
    // restart — unlike a version NAK, a hung binary may recover on relaunch.
    let fixture = try PluginFixtureKit.make(
      id: "neverinit",
      manifest: PluginFixtureKit.manifest(id: "neverinit"),
      script: """
        #!/bin/sh
        printf 'spawn\\n' >> "$FLASH_PLUGIN_DATA_DIR/spawns"
        while IFS= read -r line; do :; done
        exit 0
        """)
    defer { fixture.cleanup() }
    try withSeams(
      attempts: 5, restartDelay: immediateRestartDelay, startupTimeoutSeconds: 1
    ) {
      let process = try makeProcess(fixture)
      process.start()
      waitUntilTrue(timeout: 6, "respawn after startup timeout") { fixture.spawnCount() >= 2 }
      XCTAssertNotEqual(
        process.runtimeStateSnapshot(), .failed,
        "a startup timeout must schedule a backoff restart, not a fatal park")
      XCTAssertTrue(
        process.statusSnapshot().lastError?.contains("initialize timed out") == true)
      process.stopAndWait(reason: "test")
    }
  }

  // MARK: 4. Initialize NAK / protocol mismatch → fatal park

  func testInitializeNakParksFailedWithoutRestartAndDropsCatalog() throws {
    // A publish is accepted any time after spawn — even before `running` —
    // and an {ok:false} initialize reply is terminal: park in .failed, drop
    // the published catalog, never auto-restart.
    let fixture = try PluginFixtureKit.make(
      id: "initnak",
      manifest: PluginFixtureKit.manifest(
        id: "initnak", extra: #""sources": [{ "name": "fix.items" }]"#),
      script: PluginFixtureKit.script(
        prologue:
          #"printf '{"method":"publish","params":{"rows":[{"source":"fix.items","title":"Early"}]}}\n'"#,
        onInitialize: """
          sleep 0.3
          printf '{"id":%s,"result":{"ok":false,"protocol_version":1,"error":"nope"}}\\n' "$id"
          """))
    defer { fixture.cleanup() }
    let store = PluginCatalogStore()
    let process = try makeProcess(fixture, store: store)
    process.start()
    // Undocumented-but-real: the catalog store accepts a publish while the
    // plugin is still `launching` (validation runs on the reader queue,
    // independent of lifecycle state).
    waitUntilTrue("publish accepted while launching") {
      store.rows(for: "initnak").map(\.title) == ["Early"]
    }
    waitUntilTrue("park in failed") { process.runtimeStateSnapshot() == .failed }
    XCTAssertNil(
      store.entry(for: "initnak"),
      "a failed park drops the published catalog — a parked plugin could never serve its rows")
    settleRunLoop(0.3)
    XCTAssertEqual(fixture.spawnCount(), 1, "an initialize NAK must not auto-restart")
    process.stopAndWait(reason: "test")
  }

  func testWrongProtocolVersionEchoParksFailedWithoutRestart() throws {
    let fixture = try PluginFixtureKit.make(
      id: "wrongver",
      manifest: PluginFixtureKit.manifest(id: "wrongver"),
      script: PluginFixtureKit.script(
        onInitialize:
          #"printf '{"id":%s,"result":{"ok":true,"protocol_version":2}}\n' "$id""#))
    defer { fixture.cleanup() }
    let process = try makeProcess(fixture)
    process.start()
    waitUntilTrue("park in failed") { process.runtimeStateSnapshot() == .failed }
    XCTAssertTrue(
      process.statusSnapshot().lastError?.contains("protocol_version") == true)
    settleRunLoop(0.3)
    XCTAssertEqual(fixture.spawnCount(), 1, "a version mismatch must not auto-restart")
    process.stopAndWait(reason: "test")
  }

  // MARK: 5. Idle ping

  func testHealthyPluginAnswersIdlePingsAndStaysRunning() throws {
    let fixture = try PluginFixtureKit.make(
      id: "pinger",
      manifest: PluginFixtureKit.manifest(id: "pinger"),
      script: PluginFixtureKit.script())
    defer { fixture.cleanup() }
    try withSeams(idleBeforePingMs: 150, pingTimeoutMs: 1_000) {
      let process = try makeProcess(fixture)
      process.start()
      waitUntilTrue("running") { process.runtimeStateSnapshot() == .running }
      // Survives several idle windows: each answered ping re-arms the next.
      waitUntilTrue("two idle pings answered") { fixture.pingCount() >= 2 }
      XCTAssertEqual(process.runtimeStateSnapshot(), .running)
      XCTAssertEqual(fixture.spawnCount(), 1, "answered pings never restart the plugin")
      process.stopAndWait(reason: "test")
    }
  }

  func testMissedIdlePingTearsDownAndRestarts() throws {
    // ONE missed ping tears down and restarts. The fixture ignores only the
    // first ping ever (global counter in the data dir), so the restarted
    // incarnation stays healthy and the test ends quiescent.
    let fixture = try PluginFixtureKit.make(
      id: "pingmiss",
      manifest: PluginFixtureKit.manifest(id: "pingmiss"),
      script: PluginFixtureKit.script(
        onPing: """
          printf 'ping\\n' >> "$D/pings"
          if [ "$(wc -l < "$D/pings")" -gt 1 ]; then
            printf '{"id":%s,"result":{"ok":true}}\\n' "$id"
          fi
          """))
    defer { fixture.cleanup() }
    try withSeams(
      idleBeforePingMs: 150, pingTimeoutMs: 200, restartDelay: immediateRestartDelay
    ) {
      let process = try makeProcess(fixture)
      process.start()
      waitUntilTrue("restart after missed ping") { fixture.spawnCount() >= 2 }
      waitUntilTrue("running after restart") {
        process.runtimeStateSnapshot() == .running && fixture.pingCount() >= 2
      }
      process.stopAndWait(reason: "test")
    }
  }

  // MARK: 6. Publish intake

  func testPublishIntakeKeepsLastGoodOnMalformedPublish() throws {
    // Two valid rows land in the store; a following malformed publish (row
    // missing the required `source`) is rejected whole: the store keeps the
    // previous rows and the entry generation does not change.
    let fixture = try PluginFixtureKit.make(
      id: "publisher",
      manifest: PluginFixtureKit.manifest(
        id: "publisher",
        extra: #""sources": [{ "name": "fix.items" }], "status": ["done"]"#),
      script: PluginFixtureKit.script(
        onInitialize: """
          \(PluginFixtureKit.initializeOK)
          printf '{"method":"publish","params":{"rows":[{"source":"fix.items","title":"One"},{"source":"fix.items","title":"Two"}]}}\\n'
          printf '{"method":"publish","params":{"rows":[{"title":"NoSource"}]}}\\n'
          printf '{"method":"status","params":{"segments":{"done":"1"}}}\\n'
          """))
    defer { fixture.cleanup() }
    let store = PluginCatalogStore()
    let process = try makeProcess(fixture, store: store)
    process.start()
    // The status frame arrives after both publishes on the same reader
    // queue, so once it lands the malformed publish has been processed.
    waitUntilTrue("marker segment") {
      process.statusBarInfo().statusSegments["done"] == "1"
    }
    XCTAssertEqual(store.rows(for: "publisher").map(\.title), ["One", "Two"])
    let entry = try XCTUnwrap(store.entry(for: "publisher"))
    XCTAssertEqual(
      entry.generation, 1,
      "a rejected publish never reaches the store: generation stays at the last accepted publish")
    // The catalog survives a plain stop (only failed park / unload drop it).
    process.stopAndWait(reason: "test")
    XCTAssertEqual(store.rows(for: "publisher").map(\.title), ["One", "Two"])
  }

  // MARK: 7. Status segments over the wire

  func testStatusSegmentBurstsMergeDeclaredOnlyAndClearOnTeardown() throws {
    let fixture = try PluginFixtureKit.make(
      id: "statusfix",
      manifest: PluginFixtureKit.manifest(
        id: "statusfix",
        extra: #""sources": [{ "name": "fix.items" }], "status": ["alpha", "beta"]"#),
      script: PluginFixtureKit.script(
        onInitialize: """
          \(PluginFixtureKit.initializeOK)
          i=0
          while [ "$i" -lt 30 ]; do
            i=$((i+1))
            printf '{"method":"status","params":{"segments":{"alpha":"a%s"}}}\\n' "$i"
            printf '{"method":"publish","params":{"rows":[{"source":"fix.items","title":"row%s"}]}}\\n' "$i"
          done
          printf '{"method":"status","params":{"segments":{"undeclared":"x","beta":"done"}}}\\n'
          printf '{"method":"status","params":{"segments":{"alpha":""}}}\\n'
          """))
    defer { fixture.cleanup() }
    let store = PluginCatalogStore()
    let process = try makeProcess(fixture, store: store)
    process.start()
    waitUntilTrue("burst fully applied") {
      process.statusBarInfo().statusSegments["beta"] == "done"
        && process.statusBarInfo().statusSegments["alpha"] == nil
    }
    // Declared-only, "" clears, and no frame in the interleaved burst was
    // lost: the final store row and generation match the frame count.
    XCTAssertEqual(process.statusBarInfo().statusSegments, ["beta": "done"])
    XCTAssertEqual(store.rows(for: "statusfix").map(\.title), ["row30"])
    XCTAssertEqual(store.entry(for: "statusfix")?.generation, 30)
    process.stopAndWait(reason: "test")
    // Segments are live state (unlike catalogs): cleared on any teardown.
    XCTAssertEqual(process.statusBarInfo().statusSegments, [:])
    XCTAssertEqual(store.rows(for: "statusfix").map(\.title), ["row30"])
  }

  // MARK: 8. EOF shutdown

  func testStdinEOFShutdownIsCleanWithoutSignalEscalation() throws {
    let fixture = try PluginFixtureKit.make(
      id: "eofclean",
      manifest: PluginFixtureKit.manifest(id: "eofclean"),
      script: PluginFixtureKit.script())
    defer { fixture.cleanup() }
    let process = try makeProcess(fixture)
    process.start()
    waitUntilTrue("running") { process.runtimeStateSnapshot() == .running }
    let pid = try XCTUnwrap(process.statusSnapshot().pid)
    let started = CFAbsoluteTimeGetCurrent()
    process.stopAndWait(reason: "test")
    let elapsed = CFAbsoluteTimeGetCurrent() - started
    // The fixture exits on EOF; a clean stop returns well inside the 1 s
    // shutdown grace — reaching SIGTERM/SIGKILL escalation would take ≥1 s.
    XCTAssertLessThan(elapsed, 0.9, "stdin EOF alone must end a conformant plugin")
    XCTAssertEqual(process.runtimeStateSnapshot(), .stopped)
    waitUntilTrue("child reaped") { kill(pid_t(pid), 0) != 0 }
  }

  func testLingeringPluginIsKilledByEscalationWithinTwoSeconds() throws {
    // Ignores EOF and SIGTERM: the host escalates stdin-close → (1 s)
    // SIGTERM → (+0.5 s) SIGKILL and stopAndWait returns once the kill is
    // sent — bounded, never a hang.
    let fixture = try PluginFixtureKit.make(
      id: "eoflinger",
      manifest: PluginFixtureKit.manifest(id: "eoflinger"),
      script: """
        #!/bin/sh
        D="$FLASH_PLUGIN_DATA_DIR"
        printf 'spawn\\n' >> "$D/spawns"
        trap '' TERM
        IFS= read -r line
        id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
        printf '{"id":%s,"result":{"ok":true,"protocol_version":1}}\\n' "$id"
        while :; do sleep 0.05; done
        """)
    defer { fixture.cleanup() }
    let process = try makeProcess(fixture)
    process.start()
    waitUntilTrue("running") { process.runtimeStateSnapshot() == .running }
    let pid = try XCTUnwrap(process.statusSnapshot().pid)
    let started = CFAbsoluteTimeGetCurrent()
    process.stopAndWait(reason: "test")
    let elapsed = CFAbsoluteTimeGetCurrent() - started
    XCTAssertGreaterThan(elapsed, 1.0, "escalation waits the full shutdown grace first")
    XCTAssertLessThan(elapsed, 2.5, "SIGKILL bounds a linger to ~1.5 s")
    XCTAssertEqual(process.runtimeStateSnapshot(), .stopped)
    waitUntilTrue("child killed") { kill(pid_t(pid), 0) != 0 }
  }

  // MARK: 9. Manifest-only

  func testManifestOnlyPluginNeverSpawnsAndReportsStaticState() throws {
    let manifestJSON = """
      {
        "id": "manifestonly",
        "name": "Manifest only",
        "version": "1.0.0",
        "description": "fixture",
        "verbs": [{ "name": "noop", "keystrokes": { "": "cmd+s" } }]
      }
      """
    let fixture = try PluginFixtureKit.make(
      id: "manifestonly", manifest: manifestJSON, script: "#!/bin/sh\nexit 0\n")
    defer { fixture.cleanup() }
    let process = try makeProcess(fixture)
    process.start()
    settleRunLoop(0.3)
    let status = process.statusSnapshot()
    XCTAssertEqual(status.state, "manifest_only", "static label, not a misleading \"stopped\"")
    XCTAssertNil(status.pid)
    XCTAssertEqual(process.runtimeStateSnapshot(), .stopped, "never enters the process machine")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: fixture.dataDir.path),
      "no process ever spawned — the data dir is never even created")
    process.stopAndWait(reason: "test")
  }

  // MARK: 10. Lazy activation

  func testOnDemandPluginSpawnsOnFirstPerformAndReusesTheProcess() throws {
    let fixture = try PluginFixtureKit.make(
      id: "ondemand",
      manifest: PluginFixtureKit.manifest(
        id: "ondemand",
        extra: #""commands": [{ "command": "ondemand", "subcommand": "run", "description": "x" }]"#),
      script: PluginFixtureKit.script())
    defer { fixture.cleanup() }
    let process = try makeProcess(fixture)
    XCTAssertEqual(process.manifest.activation, .onDemand)
    process.start()
    settleRunLoop(0.3)
    XCTAssertEqual(fixture.spawnCount(), 0, "on-demand: no child after start()")
    XCTAssertEqual(process.runtimeStateSnapshot(), .stopped)

    // First perform spawns, initializes, dispatches, and returns the
    // fixture's reply (the perform deadline absorbs the startup budget).
    let first = expectation(description: "first perform")
    process.perform(kind: "command", params: ["command": "ondemand", "subcommand": "run"]) {
      outcome in
      XCTAssertEqual(outcome, .performed(pid: nil, navigationURL: nil, message: "fixture-done"))
      first.fulfill()
    }
    wait(for: [first], timeout: 8)
    XCTAssertEqual(fixture.spawnCount(), 1)
    XCTAssertEqual(process.runtimeStateSnapshot(), .running, "stays running after the perform")

    // Second perform reuses the running process — no second spawn.
    let second = expectation(description: "second perform")
    process.perform(kind: "command", params: [:]) { outcome in
      XCTAssertEqual(outcome, .performed(pid: nil, navigationURL: nil, message: "fixture-done"))
      second.fulfill()
    }
    wait(for: [second], timeout: 8)
    XCTAssertEqual(fixture.spawnCount(), 1, "the second perform must not respawn")
    process.stopAndWait(reason: "test")
  }

  // MARK: 11. Perform against a parked plugin

  func testPerformAgainstParkedPluginSettlesUnhandledImmediately() throws {
    let fixture = try PluginFixtureKit.make(
      id: "parked",
      manifest: PluginFixtureKit.manifest(id: "parked"),
      script: PluginFixtureKit.script(
        onInitialize:
          #"printf '{"id":%s,"result":{"ok":false,"protocol_version":1,"error":"nope"}}\n' "$id""#))
    defer { fixture.cleanup() }
    let process = try makeProcess(fixture)
    process.start()
    waitUntilTrue("park in failed") { process.runtimeStateSnapshot() == .failed }

    let settled = expectation(description: "unhandled immediately")
    let started = CFAbsoluteTimeGetCurrent()
    process.perform(kind: "command", params: [:]) { outcome in
      XCTAssertEqual(
        outcome, .unhandled,
        "nothing was dispatched to the parked plugin, so fallback is safe")
      XCTAssertLessThan(
        CFAbsoluteTimeGetCurrent() - started, 1.0,
        "must settle without burning the perform deadline")
      settled.fulfill()
    }
    wait(for: [settled], timeout: 2)
    process.stopAndWait(reason: "test")
  }
}
