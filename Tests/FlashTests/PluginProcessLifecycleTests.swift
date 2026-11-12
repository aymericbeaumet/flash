import AppKit
import FlashCore
import Foundation
import XCTest
import os

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
  /// surfaces (and thereby selects the activation mode). The shell script
  /// forks `sed` and friends, which the deny-default profile refuses, so the
  /// fixture declares `"sandbox": false` unless `sandboxed` keeps it under
  /// the profile.
  static func manifest(
    id: String, extra: String = #""status": ["state"]"#, sandboxed: Bool = false
  ) -> String {
    let sandbox = sandboxed ? "" : #""sandbox": false,"#
    return """
      {
        "id": "\(id)",
        "name": "Fixture \(id)",
        "version": "1.0.0",
        "description": "lifecycle fixture",
        "exec": ["./run.sh"],
        \(sandbox)
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
    store: PluginCatalogStore? = nil,
    statusObserved: Bool = true,
    environment: FlashProcessEnvironment = .shared,
    scheduler: PollScheduler = .shared
  ) throws -> PluginProcess {
    let manifest = try PluginManifest.load(from: fixture.root)
    let process = PluginProcess(
      root: fixture.root,
      manifest: manifest,
      origin: .official,
      baseDataDir: fixture.baseDataDir,
      watchFiles: false,
      statusObserved: statusObserved,
      environment: environment,
      installLogDirectory: fixture.baseDataDir.appendingPathComponent("install-logs"),
      scheduler: scheduler)
    process.catalogStore = store
    return process
  }

  /// A child inherits the environment in effect when it spawns, for its
  /// whole life: a resident plugin started while the login shell is still
  /// being read waits for it, then spawns once with the resolved `PATH`.
  func testChildSpawnsOnlyOnceTheLoginEnvironmentResolved() throws {
    let fixture = try PluginFixtureKit.make(
      id: "envgate",
      manifest: PluginFixtureKit.manifest(id: "envgate"),
      script: PluginFixtureKit.script(prologue: #"printf '%s\n' "$PATH" >> "$D/path""#))
    defer { fixture.cleanup() }
    let release = DispatchSemaphore(value: 0)
    let environment = FlashProcessEnvironment(seed: ["PATH": "/usr/bin:/bin"]) { _, _ in
      release.wait()
      return ["PATH": "/flash/resolved:/usr/bin:/bin"]
    }
    environment.refresh()
    let process = try makeProcess(fixture, environment: environment)
    defer { process.stopAndWait(reason: "test") }
    process.start()
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    XCTAssertEqual(fixture.spawnCount(), 0, "no child before the environment resolved")
    XCTAssertEqual(process.runtimeStateSnapshot(), .installing)
    release.signal()
    waitUntilTrue("running") { process.runtimeStateSnapshot() == .running }
    XCTAssertEqual(fixture.spawnCount(), 1)
    let path = try String(
      contentsOf: fixture.dataDir.appendingPathComponent("path"), encoding: .utf8)
    XCTAssertTrue(path.hasPrefix("/flash/resolved:"), "the child got the resolved PATH: \(path)")
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
    queryDeadlineMs: Int? = nil,
    restartDelay: ((Int) -> Int)? = nil,
    startupTimeoutSeconds: Int? = nil,
    _ body: () throws -> Void
  ) rethrows {
    let originalAttempts = PluginProcess.restartWindowAttempts
    let originalWindow = PluginProcess.restartWindowSeconds
    let originalIdle = PluginProcess.idleBeforePingMs
    let originalPing = PluginProcess.pingTimeoutMs
    let originalQuery = PluginProcess.queryDeadlineMs
    let originalDelay = PluginProcess.restartDelaySeconds
    let originalStartup = FlashTunables.pluginStartupTimeoutSeconds
    defer {
      PluginProcess.restartWindowAttempts = originalAttempts
      PluginProcess.restartWindowSeconds = originalWindow
      PluginProcess.idleBeforePingMs = originalIdle
      PluginProcess.pingTimeoutMs = originalPing
      PluginProcess.queryDeadlineMs = originalQuery
      PluginProcess.restartDelaySeconds = originalDelay
      FlashTunables.pluginStartupTimeoutSeconds = originalStartup
    }
    if let attempts { PluginProcess.restartWindowAttempts = attempts }
    if let windowSeconds { PluginProcess.restartWindowSeconds = windowSeconds }
    if let idleBeforePingMs { PluginProcess.idleBeforePingMs = idleBeforePingMs }
    if let pingTimeoutMs { PluginProcess.pingTimeoutMs = pingTimeoutMs }
    if let queryDeadlineMs { PluginProcess.queryDeadlineMs = queryDeadlineMs }
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

  // MARK: 1b. Text grid

  /// `text_grid` carries the focused-app context and settles once with the
  /// decoded grid; a reply off its own grid settles nil, as does a stopped
  /// plugin, at once.
  func testTextGridRequestsCarryTheContextAndSettleOnceWithTheDecodedGrid() throws {
    let script = #"""
      #!/bin/sh
      D="$FLASH_PLUGIN_DATA_DIR"
      printf 'spawn\n' >> "$D/spawns"
      while IFS= read -r line; do
        id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
        case "$line" in
        *'"method":"initialize"'*)
          printf '{"id":%s,"result":{"ok":true,"protocol_version":1}}\n' "$id"
          ;;
        *'"method":"text_grid"'*)
          printf '%s\n' "$line" >> "$D/requests"
          if [ -f "$D/answered" ]; then
            printf '{"id":%s,"result":{"ok":true,"columns":4,"rows":2,"lines":[{"row":2,"column":0,"text":"a"}]}}\n' "$id"
          else
            : > "$D/answered"
            printf '{"id":%s,"result":{"ok":true,"columns":20,"rows":6,"lines":[{"row":2,"column":10,"text":"xa"},{"row":0,"column":0,"width":20,"format":"za"}]}}\n' "$id"
          fi
          ;;
        esac
      done
      exit 0
      """#
    let fixture = try PluginFixtureKit.make(
      id: "textgrid", manifest: PluginFixtureKit.manifest(id: "textgrid"), script: script)
    defer { fixture.cleanup() }
    let process = try makeProcess(fixture)
    process.start()
    waitUntilTrue("running") { process.runtimeStateSnapshot() == .running }
    let context = AppContext(
      bundleIdentifier: "com.example.term", processID: 4242,
      runningApp: NSRunningApplication.current,
      frontWindowFrame: CGRect(x: 10, y: 20, width: 800, height: 400), allScreensFrame: .null,
      displays: [.init(frame: CGRect(x: 0, y: 0, width: 1000, height: 800), scale: 2)])

    func request() -> [PluginTextGrid?] {
      let settled = expectation(description: "text_grid settles")
      let lock = NSLock()
      var replies: [PluginTextGrid?] = []
      process.textGrid(context: context) { grid in
        lock.lock()
        replies.append(grid)
        lock.unlock()
        settled.fulfill()
      }
      wait(for: [settled], timeout: 8)
      lock.lock()
      defer { lock.unlock() }
      return replies
    }
    XCTAssertEqual(
      request(),
      [
        PluginTextGrid(
          columns: 20, rows: 6,
          lines: [
            .text(row: 2, column: 10, text: "xa"),
            .format(row: 0, column: 0, width: 20, format: "za"),
          ])
      ])
    XCTAssertEqual(request(), [nil], "a line below the grid rejects the reply")
    let requests = try String(
      contentsOf: fixture.dataDir.appendingPathComponent("requests"), encoding: .utf8)
    let first = try XCTUnwrap(
      try JSONSerialization.jsonObject(
        with: Data(try XCTUnwrap(requests.split(separator: "\n").first).utf8))
        as? [String: Any])
    let params = try XCTUnwrap(first["params"] as? [String: Any])
    XCTAssertEqual(params["bundle_id"] as? String, "com.example.term")
    XCTAssertEqual(params["pid"] as? Int, 4242)
    XCTAssertEqual(params["display_scale"] as? Double, 2)
    XCTAssertEqual(
      params["front_window_frame"] as? [String: Double],
      ["x": 10, "y": 20, "width": 800, "height": 400])
    XCTAssertNotNil(first["deadline_ms"])

    process.stopAndWait(reason: "test")
    var stopped: [PluginTextGrid?] = []
    process.textGrid(context: context) { stopped.append($0) }
    XCTAssertEqual(stopped, [nil])
  }

  // MARK: 1c. Wire fields

  /// Records the child's environment, every event it receives and every
  /// `evaluate` request, answering each evaluation with one answer, `2`,
  /// only once the request is on disk.
  private func wireRecorder(id: String) throws -> PluginFixtureKit.Fixture {
    let script = #"""
      #!/bin/sh
      D="$FLASH_PLUGIN_DATA_DIR"
      env > "$D/env"
      while IFS= read -r line; do
        id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
        case "$line" in
        *'"method":"initialize"'*)
          printf '{"id":%s,"result":{"ok":true,"protocol_version":1}}\n' "$id"
          ;;
        *'"method":"event"'*)
          printf '%s\n' "$line" >> "$D/events"
          ;;
        *'"method":"evaluate"'*)
          printf '%s\n' "$line" >> "$D/evaluations"
          printf '{"id":%s,"result":{"ok":true,"answers":[{"title":"2","effect":{"type":"copy_text","text":"2"}}]}}\n' "$id"
          ;;
        esac
      done
      exit 0
      """#
    return try PluginFixtureKit.make(
      id: id, manifest: PluginFixtureKit.manifest(id: id), script: script)
  }

  /// The frames the recorder appended to `name` so far: nil while the file
  /// is missing or its last line is still being written, so a deadline poll
  /// can call it without recording a failure.
  private func recordedFrames(_ fixture: PluginFixtureKit.Fixture, _ name: String)
    -> [[String: Any]]?
  {
    guard
      let text = try? String(
        contentsOf: fixture.dataDir.appendingPathComponent(name), encoding: .utf8)
    else { return nil }
    var frames: [[String: Any]] = []
    for line in text.split(separator: "\n") {
      guard let frame = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
      else { return nil }
      frames.append(frame)
    }
    return frames
  }

  /// A child learns the host is gone from stdin EOF, so its environment
  /// names the plugin and no parent pid.
  func testChildEnvironmentCarriesNoParentPID() throws {
    let fixture = try wireRecorder(id: "wireenv")
    defer { fixture.cleanup() }
    let process = try makeProcess(fixture)
    defer { process.stopAndWait(reason: "test") }
    process.start()
    waitUntilTrue("running") { process.runtimeStateSnapshot() == .running }
    let variables = try String(
      contentsOf: fixture.dataDir.appendingPathComponent("env"), encoding: .utf8
    ).split(separator: "\n")
    XCTAssertTrue(variables.contains("FLASH_PLUGIN_ID=wireenv"))
    XCTAssertFalse(variables.contains { $0.hasPrefix("FLASH_PLUGIN_PARENT_PID=") })
  }

  /// The `core:apps.changed` every child gets after initialize carries the
  /// running-applications snapshot and nothing else.
  func testFirstAppsChangedCarriesOnlyTheRunningApplications() throws {
    let fixture = try wireRecorder(id: "wireapps")
    defer { fixture.cleanup() }
    let process = try makeProcess(fixture)
    defer { process.stopAndWait(reason: "test") }
    let app: [String: Any] = [
      "bundle_id": "com.example.app", "localized_name": "Example", "pid": 4242,
    ]
    process.runningApplicationsProvider = { [app] }
    process.start()
    var appsChanged: [String: Any]?
    waitUntilTrue("apps.changed delivered") {
      appsChanged = self.recordedFrames(fixture, "events")?
        .compactMap { $0["params"] as? [String: Any] }
        .first { $0["name"] as? String == "core:apps.changed" }
      return appsChanged != nil
    }
    let payload = try XCTUnwrap(appsChanged?["payload"] as? [String: Any])
    XCTAssertEqual(Set(payload.keys), ["running_applications"])
    let apps = try XCTUnwrap(payload["running_applications"] as? [[String: Any]])
    XCTAssertEqual(apps.map { Set($0.keys) }, [["bundle_id", "localized_name", "pid"]])
  }

  /// `evaluate` hands the plugin the exact input and nothing else. The
  /// per-keystroke 50 ms deadline is a seam here: a fork-per-line shell on a
  /// busy Mac misses it, and a host queue that gets the CPU late drops the
  /// request unsent, so at that deadline neither the reply (`[]` either
  /// way) nor the recorded frame is an event to wait on. With the deadline
  /// the test owns, the answer is the signal: the fixture records the
  /// request before it answers.
  func testEvaluateSendsOnlyTheQuery() throws {
    let fixture = try wireRecorder(id: "wireeval")
    defer { fixture.cleanup() }
    try withSeams(queryDeadlineMs: 8_000) {
      let process = try makeProcess(fixture)
      defer { process.stopAndWait(reason: "test") }
      process.start()
      waitUntilTrue("running") { process.runtimeStateSnapshot() == .running }
      let answered = expectation(description: "evaluate answered")
      process.evaluate(QueryEvaluationRequest(surface: .flashlight, text: "1+1")) { answers in
        XCTAssertEqual(answers.map(\.title), ["2"], "the fixture's answer, not a deadline")
        answered.fulfill()
      }
      wait(for: [answered], timeout: 8)
      let request = try XCTUnwrap(recordedFrames(fixture, "evaluations")?.first)
      let params = try XCTUnwrap(request["params"] as? [String: Any])
      XCTAssertEqual(Set(params.keys), ["query"])
      XCTAssertEqual(params["query"] as? String, "1+1")
    }
  }

  /// A window focus change names the app whose window changed; the
  /// subscriber reads the rest itself.
  func testWindowFocusChangedCarriesOnlyTheApp() throws {
    let frame = try XCTUnwrap(
      PluginProcess.encodedEventFrame(
        .windowFocusChanged(pid: 4242, bundleID: "com.example.app")))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: frame) as? [String: Any])
    let params = try XCTUnwrap(object["params"] as? [String: Any])
    XCTAssertEqual(params["name"] as? String, "core:window.focus.changed")
    let payload = try XCTUnwrap(params["payload"] as? [String: Any])
    XCTAssertEqual(Set(payload.keys), ["pid", "bundle_id"])
    XCTAssertEqual(payload["pid"] as? Int, 4242)
    XCTAssertEqual(payload["bundle_id"] as? String, "com.example.app")
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

  func testInitializedCrashLoopStillExhaustsRestartBudget() throws {
    let fixture = try PluginFixtureKit.make(
      id: "initializedcrash",
      manifest: PluginFixtureKit.manifest(id: "initializedcrash"),
      script: PluginFixtureKit.script(
        onInitialize: "\(PluginFixtureKit.initializeOK)\nsleep 0.1\nexit 7"))
    defer { fixture.cleanup() }
    try withSeams(attempts: 2, windowSeconds: 60, restartDelay: immediateRestartDelay) {
      let process = try makeProcess(fixture)
      defer { process.stopAndWait(reason: "test") }
      process.start()
      // Three spawns; each can stall for seconds on a busy Mac.
      waitUntilTrue("initialized crash loop parks") {
        process.runtimeStateSnapshot() == .failed
      }
      XCTAssertEqual(fixture.spawnCount(), 3)
    }
  }

  func testStopDuringBackoffPreventsResurrection() throws {
    let fixture = try PluginFixtureKit.make(
      id: "stopbackoff", manifest: PluginFixtureKit.manifest(id: "stopbackoff"),
      script: "#!/bin/sh\nprintf 'spawn\\n' >> \"$FLASH_PLUGIN_DATA_DIR/spawns\"\nexit 7\n")
    defer { fixture.cleanup() }
    try withSeams(
      restartDelay: { _ in 1 },
      {
        let process = try makeProcess(fixture)
        defer { process.stopAndWait(reason: "test_cleanup") }
        process.start()
        waitUntilTrue("first failure schedules restart") {
          fixture.spawnCount() == 1 && process.statusSnapshot().restartCount == 1
        }
        process.stopAndWait(reason: "test_stop")
        settleRunLoop(1.2)
        XCTAssertEqual(fixture.spawnCount(), 1)
        XCTAssertEqual(process.runtimeStateSnapshot(), .stopped)
      })
  }

  func testHostReplyFromPreviousChildCannotSettleReusedRequestID() throws {
    var script = PluginFixtureKit.script(
      onInitialize: """
        \(PluginFixtureKit.initializeOK)
        printf '{"id":1,"method":"host.ping","params":{}}\\n'
        """)
    script = script.replacingOccurrences(
      of: "  esac",
      with: """
        *'"result":'*) printf '%s\\n' "$line" >> "$D/replies" ;;
        esac
        """)
    let fixture = try PluginFixtureKit.make(
      id: "replygeneration", manifest: PluginFixtureKit.manifest(id: "replygeneration"),
      script: script)
    defer { fixture.cleanup() }
    let process = try makeProcess(fixture)
    defer { process.stopAndWait(reason: "test") }
    let repliesLock = NSLock()
    var replies: [([String: Any]) -> Void] = []
    process.onHostRequest = { _, _, _, _, reply in
      repliesLock.lock()
      replies.append(reply)
      repliesLock.unlock()
    }
    func capturedReplies() -> [([String: Any]) -> Void] {
      repliesLock.lock()
      defer { repliesLock.unlock() }
      return replies
    }
    process.start()
    waitUntilTrue("first child host request") { capturedReplies().count == 1 }
    process.reload(reason: "test")
    waitUntilTrue("replacement child reuses ID") { capturedReplies().count == 2 }
    let completions = capturedReplies()
    guard completions.count == 2 else { return }
    completions[0](["ok": true, "marker": "old"])
    completions[1](["ok": true, "marker": "new"])
    completions[1](["ok": true, "marker": "duplicate"])
    let replyFile = fixture.dataDir.appendingPathComponent("replies")
    waitUntilTrue("replacement receives its reply") {
      (try? String(contentsOf: replyFile).contains("new")) == true
    }
    let received = try String(contentsOf: replyFile)
    XCTAssertFalse(received.contains("old"))
    XCTAssertFalse(received.contains("duplicate"))
    XCTAssertEqual(received.split(separator: "\n").count, 1)
  }

  func testStoppingChildCancelsHostInputAlreadyQueuedOnMain() throws {
    try assertQueuedHostInputAfterRetirement(reload: false)
  }

  func testReloadingChildDropsOldQueuedHostInputAndAcceptsReplacementInput() throws {
    try assertQueuedHostInputAfterRetirement(reload: true)
  }

  private func assertQueuedHostInputAfterRetirement(reload: Bool) throws {
    let fixture = try PluginFixtureKit.make(
      id: "stalehostinput",
      manifest: PluginFixtureKit.manifest(id: "stalehostinput"),
      script: PluginFixtureKit.script(
        onInitialize: PluginFixtureKit.initializeOK + "\n"
          + #"printf '{"id":1,"method":"host.post_keys","params":{"pid":1,"keys":[{"key_code":0,"modifiers":["command"]}]}}\n'"#
      ))
    defer { fixture.cleanup() }
    let process = try makeProcess(fixture)
    defer { process.stopAndWait(reason: "test") }
    let rpc = PluginHostRPC()
    var posted = 0
    rpc.onSyntheticKeysRequested = { _, _, _ in posted += 1 }
    let queued = DispatchSemaphore(value: 0)
    process.onHostRequest = { method, params, pluginID, scope, reply in
      rpc.handleHostRequest(
        method: method, params: params, pluginID: pluginID,
        capabilities: [.accessibility], scope: scope, reply: reply)
      queued.signal()
    }
    process.start()
    // Hold main so the real child can enqueue its input, then retire the
    // transport before main is allowed to commit the queued host action.
    XCTAssertEqual(queued.wait(timeout: .now() + 5), .success)
    if reload {
      process.reload(reason: "test_cancel_queued_input")
      XCTAssertEqual(queued.wait(timeout: .now() + 5), .success)
    } else {
      process.stopAndWait(reason: "test_cancel_queued_input")
    }
    let drained = expectation(description: "queued host input drained")
    DispatchQueue.main.async { drained.fulfill() }
    wait(for: [drained], timeout: 2)
    XCTAssertEqual(
      posted, reload ? 1 : 0,
      "only the current child may post queued input")
  }

  func testOutstandingHostCallsAreBoundedAndExcessCallSettles() throws {
    let limit = PluginProtocol.maxHostRPCs
    var script = PluginFixtureKit.script(
      onInitialize: """
        \(PluginFixtureKit.initializeOK)
        n=1
        while [ "$n" -le \(limit + 1) ]; do
          printf '{"id":%s,"method":"host.ping","params":{}}\\n' "$n"
          n=$((n + 1))
        done
        """)
    script = script.replacingOccurrences(
      of: "  esac",
      with: """
        *'"result":'*) printf '%s\\n' "$line" >> "$D/replies" ;;
        esac
        """)
    let fixture = try PluginFixtureKit.make(
      id: "hostcapacity", manifest: PluginFixtureKit.manifest(id: "hostcapacity"), script: script)
    defer { fixture.cleanup() }
    let process = try makeProcess(fixture)
    defer { process.stopAndWait(reason: "test") }
    let callsLock = NSLock()
    var calls = 0
    process.onHostRequest = { _, _, _, _, _ in
      callsLock.lock()
      calls += 1
      callsLock.unlock()
    }
    process.start()
    let replyFile = fixture.dataDir.appendingPathComponent("replies")
    waitUntilTrue("excess host call settles") {
      (try? String(contentsOf: replyFile).contains(PluginProtocol.hostCallCapacityError)) == true
    }
    callsLock.lock()
    let accepted = calls
    callsLock.unlock()
    XCTAssertEqual(accepted, limit)
    XCTAssertEqual(process.runtimeStateSnapshot(), .running)
    let received = try String(contentsOf: replyFile)
    XCTAssertTrue(received.contains("\"id\":\(limit + 1)"))
  }

  func testStoppingDuringInstallDoesNotWriteStampOrLaunchChild() throws {
    let manifest = PluginFixtureKit.manifest(
      id: "cancelinstall",
      extra:
        #""status":["state"],"install":"touch \"$FLASH_PLUGIN_DATA_DIR/install-started\"; sleep 30""#
    )
    let fixture = try PluginFixtureKit.make(
      id: "cancelinstall", manifest: manifest, script: PluginFixtureKit.script())
    defer { fixture.cleanup() }
    let process = try makeProcess(fixture)
    defer { process.stopAndWait(reason: "test_cleanup") }
    process.start()
    waitUntilTrue("installer started") {
      FileManager.default.fileExists(
        atPath: fixture.dataDir.appendingPathComponent("install-started").path)
    }
    let started = ProcessInfo.processInfo.systemUptime
    process.stopAndWait(reason: "test_cancel")
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.2)
    settleRunLoop(0.8)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: fixture.dataDir.appendingPathComponent(".install-stamp").path))
    XCTAssertEqual(fixture.spawnCount(), 0)
    XCTAssertEqual(process.runtimeStateSnapshot(), .stopped)
  }

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
    // Only initialized children may publish. An {ok:false} initialize reply
    // parks and drops any catalog retained from a previous child.
    let fixture = try PluginFixtureKit.make(
      id: "initnak",
      manifest: PluginFixtureKit.manifest(
        id: "initnak", extra: #""sources": [{ "name": "fix.items", "type": "items" }]"#),
      script: PluginFixtureKit.script(
        prologue:
          #"printf '{"method":"publish","params":{"rows":[{"source":"fix.items","title":"Early"}]}}\n'"#,
        onInitialize: """
          printf '{"id":1,"method":"host.ping","params":{"phase":"before_nak"}}\\n'
          IFS= read -r response || exit 9
          case "$response" in *'"ok":true'*) ;; *) exit 9 ;; esac
          printf '{"id":%s,"result":{"ok":false,"protocol_version":1,"error":"nope"}}\\n' "$id"
          sleep 0.2
          """))
    defer { fixture.cleanup() }
    let store = PluginCatalogStore()
    store.publish(pluginID: "initnak", .rows([Candidate(title: "Previous")]))
    let process = try makeProcess(fixture, store: store)
    defer { process.stopAndWait(reason: "test") }
    let checkedEarlyPublish = expectation(description: "early publish rejected before NAK")
    // The host processes these frames in wire order. Acknowledge directly on
    // the process queue so main-runloop load cannot hold initialize hostage.
    process.onHostRequest = { [weak process] method, params, _, _, reply in
      XCTAssertEqual(method, "host.ping")
      XCTAssertEqual(params["phase"] as? String, "before_nak")
      XCTAssertEqual(process?.runtimeStateSnapshot(), .launching)
      XCTAssertEqual(store.rows(for: "initnak").map(\.title), ["Previous"])
      reply(["ok": true])
      checkedEarlyPublish.fulfill()
    }
    process.start()
    wait(for: [checkedEarlyPublish], timeout: 8)
    waitUntilTrue("park in failed") { process.runtimeStateSnapshot() == .failed }
    XCTAssertNil(
      store.entry(for: "initnak"),
      "a failed park drops the published catalog — a parked plugin could never serve its rows")
    settleRunLoop(0.3)
    XCTAssertEqual(fixture.spawnCount(), 1, "an initialize NAK must not auto-restart")
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

  /// Every plugin's idle probe rides one `.low` sweep on the shared clock,
  /// registered only while a plugin runs — never a timer chain per plugin.
  func testIdleProbesRideOneSharedSweepOnlyWhileAPluginRuns() throws {
    let fixture = try PluginFixtureKit.make(
      id: "sweeper",
      manifest: PluginFixtureKit.manifest(id: "sweeper"),
      script: PluginFixtureKit.script())
    defer { fixture.cleanup() }
    func sweepRegistered() -> Bool {
      let listed = DispatchSemaphore(value: 0)
      var ids: [String] = []
      PollScheduler.shared.registeredIDs {
        ids = $0
        listed.signal()
      }
      listed.wait()
      return ids.contains(PluginLivenessSweep.clientID)
    }
    try withSeams(idleBeforePingMs: 150, pingTimeoutMs: 1_000) {
      let process = try makeProcess(fixture)
      process.start()
      waitUntilTrue("running") { process.runtimeStateSnapshot() == .running }
      waitUntilTrue("sweep registered") { sweepRegistered() }
      waitUntilTrue("idle ping answered") { fixture.pingCount() >= 1 }
      process.stopAndWait(reason: "test")
      waitUntilTrue("sweep released with the last plugin") { !sweepRegistered() }
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
    // missing the required `source`) is rejected whole and a source publish
    // then joins its rows to the kept catalog: the generation counts only
    // the two accepted publishes.
    let fixture = try PluginFixtureKit.make(
      id: "publisher",
      manifest: PluginFixtureKit.manifest(
        id: "publisher",
        extra:
          #""sources": [{ "name": "fix.items", "type": "items" }, { "name": "fix.other", "type": "other" }], "status": ["done"]"#
      ),
      script: PluginFixtureKit.script(
        onInitialize: """
          \(PluginFixtureKit.initializeOK)
          printf '{"method":"publish","params":{"rows":[{"source":"fix.items","title":"One"},{"source":"fix.items","title":"Two"}]}}\\n'
          printf '{"method":"publish","params":{"rows":[{"title":"NoSource"}]}}\\n'
          printf '{"method":"publish","params":{"source":"fix.other","rows":[{"source":"fix.other","title":"Three"}]}}\\n'
          printf '{"method":"status","params":{"segments":{"done":"1"}}}\\n'
          """))
    defer { fixture.cleanup() }
    let store = PluginCatalogStore()
    let process = try makeProcess(fixture, store: store)
    process.start()
    waitUntilTrue("marker segment") {
      process.statusBarInfo().statusSegments["done"] == .text("1")
    }
    // Publishes decode on their own queue, behind no reply: the marker says
    // nothing about them, the last publish landing does.
    waitUntilTrue("the source publish merged") {
      store.rows(for: "publisher").map(\.title) == ["One", "Two", "Three"]
    }
    let entry = try XCTUnwrap(store.entry(for: "publisher"))
    XCTAssertEqual(
      entry.generation, 2,
      "a rejected publish never reaches the store: the generation counts the accepted ones")
    // The catalog survives a plain stop (only failed park / unload drop it).
    process.stopAndWait(reason: "test")
    XCTAssertEqual(store.rows(for: "publisher").map(\.title), ["One", "Two", "Three"])
  }

  /// A reply is waited on; a catalog is not. A large publish ahead of a
  /// reply on the wire decodes on the plugin's catalog queue, so the reply
  /// completes while the publish is still undecoded.
  func testAReplyBehindALargePublishIsNotDelayedByItsDecode() throws {
    let rows = PluginPublishBenchmarkTests.syntheticRows(count: 3_000).map {
      row -> [String: Any] in
      var row = row
      row["source"] = "fix.items"
      return row
    }
    let fixture = try PluginFixtureKit.make(
      id: "bigpublish",
      manifest: PluginFixtureKit.manifest(
        id: "bigpublish",
        extra: #""sources": [{ "name": "fix.items", "type": "items" }], "status": ["done"]"#),
      script: PluginFixtureKit.script(
        prologue: #"ROOT="$(dirname "$0")""#,
        onInitialize: """
          \(PluginFixtureKit.initializeOK)
          cat "$ROOT/publish.ndjson"
          printf '{"method":"status","params":{"segments":{"done":"1"}}}\\n'
          """))
    defer { fixture.cleanup() }
    try PluginPublishBenchmarkTests.publishFrame(rows: rows).write(
      to: fixture.root.appendingPathComponent("publish.ndjson"))
    let store = PluginCatalogStore()
    let process = try makeProcess(fixture, store: store)
    // Hold every catalog decode: the publish is read, but never decoded
    // until the queue resumes.
    process.catalogQueue.suspend()
    var resumed = false
    defer {
      if !resumed { process.catalogQueue.resume() }
      process.stopAndWait(reason: "test")
    }
    process.start()
    waitUntilTrue("the frame after the publish was handled") {
      process.statusBarInfo().statusSegments["done"] == .text("1")
    }
    let replied = expectation(description: "perform replied behind the held publish")
    process.perform(kind: "command", params: ["command": "fix", "subcommand": "go"]) { outcome in
      XCTAssertEqual(outcome, .performed(pid: nil, navigationURL: nil, message: "fixture-done"))
      replied.fulfill()
    }
    wait(for: [replied], timeout: 8)
    XCTAssertTrue(store.rows(for: "bigpublish").isEmpty, "the publish is still undecoded")
    resumed = true
    process.catalogQueue.resume()
    waitUntilTrue("the publish decoded once the queue resumed") {
      store.rows(for: "bigpublish").count == rows.count
    }
  }

  // MARK: 6b. Poll registrations over the wire

  /// A plugin's deadline rides the shared clock and ticks once, even when
  /// the plugin repeats the unchanged set after the tick; its cadence stays
  /// registered at the priority it named; an over-bound set is rejected
  /// whole; and stopping the plugin releases every registration.
  func testPluginDeadlinesTickOnceAndEveryRegistrationLeavesWithThePlugin() throws {
    let set =
      #"{"method":"poll","params":{"registrations":{"d0":{"after":0.05,"priority":"high"},"#
      + #""i0":{"every":3600,"priority":"low"}}}}"#
    var tooMany = (0...PluginProtocol.pollMaxRegistrations).map {
      #""x\#($0)":{"every":1,"priority":"low"}"#
    }.joined(separator: ",")
    tooMany = #"{"method":"poll","params":{"registrations":{"# + tooMany + "}}}"
    let fixture = try PluginFixtureKit.make(
      id: "pollfix",
      manifest: PluginFixtureKit.manifest(id: "pollfix"),
      script: """
        #!/bin/sh
        D="$FLASH_PLUGIN_DATA_DIR"
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
          case "$line" in
          *'"method":"initialize"'*)
            \(PluginFixtureKit.initializeOK)
            printf '%s\\n' '\(set)'
            ;;
          *'core:poll:d0'*)
            printf 'tick\\n' >> "$D/ticks"
            printf '%s\\n' '\(set)'
            printf '%s\\n' '\(tooMany)'
            printf '{"method":"status","params":{"segments":{"state":"ticked"}}}\\n'
            ;;
          esac
        done
        exit 0
        """)
    defer { fixture.cleanup() }
    func registered() -> [String] {
      let listed = DispatchSemaphore(value: 0)
      var ids: [String] = []
      PollScheduler.shared.registeredIDs {
        ids = $0.filter { $0.hasPrefix("plugin:pollfix:") }
        listed.signal()
      }
      listed.wait()
      return ids
    }
    func ticks() -> Int {
      let text = try? String(
        contentsOf: fixture.dataDir.appendingPathComponent("ticks"), encoding: .utf8)
      return text?.split(separator: "\n").count ?? 0
    }
    let process = try makeProcess(fixture)
    process.start()
    waitUntilTrue("the deadline ticked") {
      process.statusBarInfo().statusSegments["state"] == .text("ticked")
    }
    // The fired deadline is dropped from the clock; repeating it unchanged
    // did not re-arm it, and the over-bound set changed nothing.
    waitUntilTrue("only the cadence stays registered") { registered() == ["plugin:pollfix:i0"] }
    settleRunLoop(0.3)
    XCTAssertEqual(ticks(), 1)
    XCTAssertEqual(registered(), ["plugin:pollfix:i0"])
    process.stopAndWait(reason: "test")
    XCTAssertEqual(registered(), [])
  }

  // MARK: 7. Status segments over the wire

  func testStatusSegmentBurstsMergeDeclaredOnlyAndClearOnTeardown() throws {
    let fixture = try PluginFixtureKit.make(
      id: "statusfix",
      manifest: PluginFixtureKit.manifest(
        id: "statusfix",
        extra:
          #""sources": [{ "name": "fix.items", "type": "items" }], "status": ["alpha", "beta"]"#),
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
    // Status frames apply on the process queue at once, while publishes are
    // decoded off it first (utility QoS): the two kinds keep their own order,
    // not each other's, so the burst is applied once both have caught up.
    waitUntilTrue("burst fully applied") {
      process.statusBarInfo().statusSegments["beta"] == .text("done")
        && process.statusBarInfo().statusSegments["alpha"] == nil
        && store.entry(for: "statusfix")?.generation == 30
    }
    // Declared-only, "" clears, and no frame in the interleaved burst was
    // lost: the final store row and generation match the frame count.
    XCTAssertEqual(process.statusBarInfo().statusSegments, ["beta": .text("done")])
    XCTAssertEqual(store.rows(for: "statusfix").map(\.title), ["row30"])
    XCTAssertEqual(store.entry(for: "statusfix")?.generation, 30)
    process.stopAndWait(reason: "test")
    // An explicit stop clears live segments immediately.
    XCTAssertEqual(process.statusBarInfo().statusSegments, [:])
    XCTAssertEqual(store.rows(for: "statusfix").map(\.title), ["row30"])
  }

  func testResidentReloadKeepsStatusUntilReplacementAndHonorsExplicitClears() throws {
    let fixture = try PluginFixtureKit.make(
      id: "statusreload",
      manifest: PluginFixtureKit.manifest(
        id: "statusreload", extra: #""status": ["alpha", "beta"]"#),
      script: PluginFixtureKit.script())
    defer { fixture.cleanup() }
    let process = try makeProcess(fixture)
    defer { process.stopAndWait() }
    process.start()
    waitUntilTrue("initial startup") { process.runtimeStateSnapshot() == .running }
    process.applyStatusSegments(["segments": ["alpha": "CPU 12%", "beta": "MEM 34%"]])

    process.reload(reason: "plugin_files_changed")
    waitUntilTrue("reload finished") {
      fixture.spawnCount() == 2 && process.runtimeStateSnapshot() == .running
    }
    XCTAssertEqual(
      process.statusBarInfo().statusSegments, ["alpha": .text("CPU 12%"), "beta": .text("MEM 34%")])
    process.applyStatusSegments(["segments": ["alpha": "CPU 24%", "beta": ""]])
    XCTAssertEqual(process.statusBarInfo().statusSegments, ["alpha": .text("CPU 24%")])
  }

  func testResidentReloadExpiresOnlySegmentsNotRepublished() throws {
    let fixture = try PluginFixtureKit.make(
      id: "statusexpiry",
      manifest: PluginFixtureKit.manifest(
        id: "statusexpiry", extra: #""status": ["alpha", "beta"]"#),
      script: PluginFixtureKit.script())
    defer { fixture.cleanup() }
    let previousGrace = PluginProcess.statusReloadGraceSeconds
    PluginProcess.statusReloadGraceSeconds = 2
    defer { PluginProcess.statusReloadGraceSeconds = previousGrace }
    let process = try makeProcess(fixture)
    defer { process.stopAndWait() }
    process.start()
    waitUntilTrue("initial startup") { process.runtimeStateSnapshot() == .running }
    process.applyStatusSegments(["segments": ["alpha": "CPU 12%", "beta": "MEM 34%"]])
    process.reload(reason: "plugins_reload")
    waitUntilTrue("reload finished") {
      fixture.spawnCount() == 2 && process.runtimeStateSnapshot() == .running
    }
    XCTAssertEqual(process.statusBarInfo().statusSegments["alpha"], .text("CPU 12%"))
    process.applyStatusSegments(["segments": ["beta": "MEM 56%"]])
    waitUntilTrue("unrefreshed status expires") {
      process.statusBarInfo().statusSegments == ["beta": .text("MEM 56%")]
    }
  }

  /// A second planned reload inside the grace window arms it again: a label
  /// the newest replacement has not republished yet is not blanked by the
  /// deadline the first reload armed.
  func testASecondReloadInsideTheGraceArmsItAgain() throws {
    let fixture = try PluginFixtureKit.make(
      id: "statusrearm",
      manifest: PluginFixtureKit.manifest(id: "statusrearm", extra: #""status": ["alpha"]"#),
      script: PluginFixtureKit.script())
    defer { fixture.cleanup() }
    // The grace runs on a clock of the test's own: a scheduler held
    // suspended on a manual clock fires nothing, and reports when each
    // deadline is due. Spawn stalls and sleeps decide nothing.
    let now = OSAllocatedUnfairLock(initialState: 0)
    let scheduler = PollScheduler(clock: { now.withLock { $0 } })
    scheduler.setSuspended(true, reason: .session)
    func graceDue() -> [Int] {
      let listed = DispatchSemaphore(value: 0)
      var due: [Int] = []
      scheduler.deadlines {
        due = $0.filter { $0.key.hasPrefix("core:plugin_status_grace:statusrearm") }.map(\.value)
        listed.signal()
      }
      listed.wait()
      return due
    }
    let previousGrace = PluginProcess.statusReloadGraceSeconds
    PluginProcess.statusReloadGraceSeconds = 10
    defer { PluginProcess.statusReloadGraceSeconds = previousGrace }
    let process = try makeProcess(fixture, scheduler: scheduler)
    defer { process.stopAndWait() }
    process.start()
    waitUntilTrue("initial startup") { process.runtimeStateSnapshot() == .running }
    process.applyStatusSegments(["segments": ["alpha": "CPU 12%"]])

    // The first reload arms the grace at 0 s.
    process.reload(reason: "plugins_reload")
    waitUntilTrue("first reload finished") {
      fixture.spawnCount() == 2 && process.runtimeStateSnapshot() == .running
    }
    XCTAssertEqual(graceDue(), [10_000])

    // The second, at 6 s, arms it again: the first deadline is replaced.
    now.withLock { $0 = 6_000 }
    process.reload(reason: "plugins_reload")
    waitUntilTrue("second reload finished") {
      fixture.spawnCount() == 3 && process.runtimeStateSnapshot() == .running
    }
    XCTAssertEqual(graceDue(), [16_000], "measured from the newest replacement")
    XCTAssertEqual(process.statusBarInfo().statusSegments["alpha"], .text("CPU 12%"))

    // Past the second deadline, released: the label expires.
    now.withLock { $0 = 16_001 }
    scheduler.setSuspended(false, reason: .session)
    waitUntilTrue("expires after the grace the second reload armed") {
      process.statusBarInfo().statusSegments["alpha"] == nil
    }
    XCTAssertEqual(graceDue(), [])
  }

  func testRejectedReloadClearsRetainedStatusImmediately() throws {
    let fixture = try PluginFixtureKit.make(
      id: "statusfailed",
      manifest: PluginFixtureKit.manifest(id: "statusfailed"),
      script: PluginFixtureKit.script(
        onInitialize: """
          if [ "$(wc -l < "$D/spawns")" -eq 1 ]; then
            \(PluginFixtureKit.initializeOK)
          else
            printf '{"id":%s,"result":{"ok":false,"protocol_version":1,"error":"unavailable"}}\\n' "$id"
          fi
          """))
    defer { fixture.cleanup() }
    let process = try makeProcess(fixture)
    defer { process.stopAndWait() }
    process.start()
    waitUntilTrue("initial startup") { process.runtimeStateSnapshot() == .running }
    process.applyStatusSegments(["segments": ["state": "ready"]])
    process.reload(reason: "plugins_reload")
    waitUntilTrue("reload failed") { process.runtimeStateSnapshot() == .failed }
    XCTAssertEqual(process.statusBarInfo().statusSegments, [:])
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

  /// Where a `perform` goes is a function of the lifecycle state. A
  /// definition not yet started only queues, even on demand: `start` spawns
  /// the child for what waits by then, so a replacement published while its
  /// predecessor still stops never runs beside it.
  func testPerformRouteFollowsTheLifecycleState() {
    typealias Lifecycle = PluginLifecycle
    for onDemand in [false, true] {
      XCTAssertEqual(Lifecycle.performRoute(state: .running, onDemand: onDemand), .dispatch)
      XCTAssertEqual(Lifecycle.performRoute(state: .failed, onDemand: onDemand), .unhandled)
      XCTAssertEqual(Lifecycle.performRoute(state: .stopped, onDemand: onDemand), .unhandled)
      XCTAssertEqual(Lifecycle.performRoute(state: .initial, onDemand: onDemand), .wait)
      XCTAssertEqual(Lifecycle.performRoute(state: .installing, onDemand: onDemand), .wait)
      XCTAssertEqual(Lifecycle.performRoute(state: .launching, onDemand: onDemand), .wait)
      XCTAssertEqual(Lifecycle.performRoute(state: .backoff, onDemand: onDemand), .wait)
    }
    XCTAssertEqual(Lifecycle.performRoute(state: .idle, onDemand: false), .wait)
    XCTAssertEqual(Lifecycle.performRoute(state: .idle, onDemand: true), .waitAndActivate)
  }

  /// A status-bound plugin that stops being observed is torn down without
  /// forgetting its failures: the toggle is not a user's reload, so a
  /// crash-looping plugin parks on the same budget once it is shown again.
  func testDeactivationKeepsTheFailureBudget() {
    var lifecycle = PluginLifecycle()
    let limit = 2
    func step(_ event: PluginLifecycle.Event, at now: TimeInterval) -> [PluginLifecycle.Effect] {
      lifecycle.transition(
        event, now: now, restartLimit: limit, restartWindow: 300, restartDelay: { _ in 1 })
    }
    _ = step(.start(resident: false), at: 0)
    XCTAssertEqual(step(.activate, at: 0), [.start(lifecycle.generation)])
    for attempt in 0..<limit {
      let token = lifecycle.generation
      _ = step(.installed(token), at: TimeInterval(attempt))
      _ = step(.initialized(token), at: TimeInterval(attempt))
      XCTAssertEqual(
        step(.interrupted(token), at: TimeInterval(attempt)),
        [.teardown, .retry(token, 1)], "attempt \(attempt) still retries")
      _ = step(.retry(token), at: TimeInterval(attempt))
    }
    XCTAssertEqual(step(.deactivate, at: 10), [.teardown])
    XCTAssertEqual(lifecycle.state, .idle)
    XCTAssertEqual(step(.activate, at: 11), [.start(lifecycle.generation)])
    let token = lifecycle.generation
    _ = step(.installed(token), at: 11)
    _ = step(.initialized(token), at: 11)
    XCTAssertEqual(
      step(.interrupted(token), at: 12), [.teardown, .park],
      "the budget survived the toggle, so the next failure parks")
    XCTAssertEqual(lifecycle.state, .failed)

    var reloaded = PluginLifecycle()
    _ = reloaded.transition(
      .start(resident: false), now: 0, restartLimit: limit, restartWindow: 300,
      restartDelay: { _ in 1 })
    XCTAssertEqual(
      reloaded.transition(
        .reload(resident: false), now: 0, restartLimit: limit, restartWindow: 300,
        restartDelay: { _ in 1 }), [.teardown], "a reload still tears down to idle")
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

  // MARK: 8b. Publish then exit

  private static let catalogManifestExtra =
    #""sources": [{ "name": "fix.items", "type": "items" }], "lifecycle": "publish_then_exit""#

  /// Answers initialize, publishes `rows` rows in one frame and exits 0 at
  /// once, so the tail of the frame can still be in the pipe when the host
  /// sees the exit. `epilogue` runs instead of the exit when given.
  private static func publishThenExitScript(rows: Int = 2_000, epilogue: String = "exit 0")
    -> String
  {
    let publish =
      #"awk -v rows=\#(rows) 'BEGIN { printf "{\"method\":\"publish\",\"params\":{\"rows\":["; "#
      + #"for (i = 1; i <= rows; i++) { if (i > 1) printf ","; "#
      + #"printf "{\"source\":\"fix.items\",\"title\":\"Row %d\"}", i }; printf "]}}\n" }'"#
    return """
      #!/bin/sh
      D="$FLASH_PLUGIN_DATA_DIR"
      printf 'spawn\\n' >> "$D/spawns"
      IFS= read -r line
      id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
      printf '{"id":%s,"result":{"ok":true,"protocol_version":1}}\\n' "$id"
      \(publish)
      \(epilogue)
      """
  }

  /// A `publish_then_exit` child publishes and exits 0: the host decodes
  /// every byte it wrote before resting the plugin in `published`, keeps
  /// the catalog, counts no restart and no error, and answers a perform
  /// `unhandled` without spawning it again.
  func testPublishThenExitPluginRestsOnceItsCatalogLandedWithoutARestart() throws {
    let fixture = try PluginFixtureKit.make(
      id: "catalogexit",
      manifest: PluginFixtureKit.manifest(id: "catalogexit", extra: Self.catalogManifestExtra),
      script: Self.publishThenExitScript())
    defer { fixture.cleanup() }
    let store = PluginCatalogStore()
    try withSeams(restartDelay: immediateRestartDelay) {
      let process = try makeProcess(fixture, store: store)
      XCTAssertEqual(process.manifest.activation, .publishThenExit)
      process.start()
      waitUntilTrue("published") { process.runtimeStateSnapshot() == .published }
      XCTAssertEqual(
        store.rows(for: "catalogexit").count, 2_000,
        "the whole catalog landed before the plugin rested")
      let status = process.statusSnapshot()
      XCTAssertEqual(status.state, "published")
      XCTAssertEqual(status.activation, "publish_then_exit")
      XCTAssertNil(status.pid)
      XCTAssertNil(status.lastError, "a clean exit is not an error")
      XCTAssertEqual(status.restartCount, 0)
      var outcome: PluginPerformOutcome?
      process.perform(kind: "resolve", params: ["row": ["source": "fix.items", "title": "Row 1"]]) {
        outcome = $0
      }
      waitUntilTrue("perform settles") { outcome != nil }
      XCTAssertEqual(outcome, .unhandled, "rows carry host effects; nothing spawns for one")
      // An immediate restart delay would show a misread exit within this window.
      settleRunLoop(0.5)
      XCTAssertEqual(fixture.spawnCount(), 1, "no restart and no backoff")
      XCTAssertEqual(process.runtimeStateSnapshot(), .published)
      process.stopAndWait(reason: "test")
      XCTAssertEqual(store.rows(for: "catalogexit").count, 2_000, "a stop keeps the catalog")
    }
  }

  /// What runs a published plugin again: a reload (the manager's answer to
  /// `plugins reload`, a settings change and a plugin file change) and a
  /// change to a file one of its `watch_settings` names, created later or
  /// replaced by an editor's atomic save.
  func testPublishThenExitRunsAgainOnReloadAndOnAWatchedFileChange() throws {
    let fixture = try PluginFixtureKit.make(
      id: "catalogwatch",
      manifest: PluginFixtureKit.manifest(
        id: "catalogwatch", extra: Self.catalogManifestExtra + #", "watch_settings": ["file"]"#),
      script: Self.publishThenExitScript(rows: 3))
    defer { fixture.cleanup() }
    let watched = fixture.baseDataDir.appendingPathComponent("snippets.toml")
    let process = PluginProcess(
      root: fixture.root,
      manifest: try PluginManifest.load(from: fixture.root),
      origin: .official,
      baseDataDir: fixture.baseDataDir,
      watchFiles: false,
      settings: ["file": .string(watched.path)],
      installLogDirectory: fixture.baseDataDir.appendingPathComponent("install-logs"))
    defer { process.stopAndWait(reason: "test") }
    process.start()
    waitUntilTrue("published") { process.runtimeStateSnapshot() == .published }
    XCTAssertEqual(fixture.spawnCount(), 1)
    try "unrelated".write(
      to: fixture.baseDataDir.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8
    )
    settleRunLoop(0.5)
    XCTAssertEqual(fixture.spawnCount(), 1, "an unrelated sibling change does not reload a catalog")

    process.reload(reason: "test_reload")
    waitUntilTrue("ran again on reload") { fixture.spawnCount() == 2 }
    waitUntilTrue("published again") { process.runtimeStateSnapshot() == .published }

    try "shrug = \"s\"\n".write(to: watched, atomically: false, encoding: .utf8)
    waitUntilTrue("ran again once the watched file appeared") { fixture.spawnCount() == 3 }
    waitUntilTrue("published after the file appeared") {
      process.runtimeStateSnapshot() == .published
    }

    // An editor's atomic save replaces the file's vnode.
    try "shrug = \"t\"\n".write(to: watched, atomically: true, encoding: .utf8)
    waitUntilTrue("ran again on the replaced file") { fixture.spawnCount() == 4 }
    waitUntilTrue("published after the replacement") {
      process.runtimeStateSnapshot() == .published
    }
    settleRunLoop(0.5)
    XCTAssertEqual(fixture.spawnCount(), 4, "each change runs the plugin once")
  }

  func testPublishThenExitRejectsAChildThatLeavesOutputOpen() throws {
    let fixture = try PluginFixtureKit.make(
      id: "catalogpipe",
      manifest: PluginFixtureKit.manifest(id: "catalogpipe", extra: Self.catalogManifestExtra),
      script: Self.publishThenExitScript(rows: 1, epilogue: "sleep 10 &\nexit 0"))
    defer { fixture.cleanup() }
    let store = PluginCatalogStore()
    try withSeams(attempts: 0, windowSeconds: 60, restartDelay: immediateRestartDelay) {
      let process = try makeProcess(fixture, store: store)
      defer { process.stopAndWait(reason: "test") }
      process.start()
      waitUntilTrue("incomplete output fails") { process.runtimeStateSnapshot() == .failed }
      XCTAssertTrue(store.rows(for: "catalogpipe").isEmpty)
      XCTAssertNotEqual(process.runtimeStateSnapshot(), .published)
    }
  }

  /// Only a clean exit after running completes a run. A `publish_then_exit`
  /// child that exits with a status is a crash like any other: it backs off,
  /// restarts and parks on the same budget.
  func testPublishThenExitCrashStillBacksOffAndParks() throws {
    let fixture = try PluginFixtureKit.make(
      id: "catalogcrash",
      manifest: PluginFixtureKit.manifest(id: "catalogcrash", extra: Self.catalogManifestExtra),
      script: Self.publishThenExitScript(rows: 1, epilogue: "exit 7"))
    defer { fixture.cleanup() }
    let store = PluginCatalogStore()
    try withSeams(attempts: 1, windowSeconds: 60, restartDelay: immediateRestartDelay) {
      let process = try makeProcess(fixture, store: store)
      defer { process.stopAndWait(reason: "test") }
      process.start()
      waitUntilTrue("parks in failed") { process.runtimeStateSnapshot() == .failed }
      XCTAssertEqual(fixture.spawnCount(), 2, "the initial spawn and one restart")
      XCTAssertTrue(
        process.statusSnapshot().lastError?.contains("restart loop exhausted") == true)
      XCTAssertTrue(store.rows(for: "catalogcrash").isEmpty, "a parked plugin's catalog is dropped")
    }
  }

  /// The files a plugin's `watch_settings` name: string settings only, `~`
  /// expanded against the home, a relative path under the plugin root (the
  /// child's working directory), empty and missing settings skipped.
  func testWatchedSettingPathsResolveTildeAndRelativePaths() {
    let root = URL(fileURLWithPath: "/plugins/snippets")
    let paths = PluginProcess.watchedSettingPaths(
      names: ["file", "extra", "blank", "count", "missing"],
      settings: [
        "file": .string("~/snips.toml"), "extra": .string("data/more.json"),
        "blank": .string("  "), "count": .int(3), "other": .string("/never/watched"),
      ],
      root: root, home: "/Users/me")
    XCTAssertEqual(paths.map(\.path), ["/Users/me/snips.toml", "/plugins/snippets/data/more.json"])
    XCTAssertEqual(
      PluginProcess.watchedSettingPaths(
        names: ["file"], settings: ["file": .string("~")], root: root, home: "/Users/me"
      ).map(\.path), ["/Users/me"])
  }

  // MARK: 9. Manifest-only

  func testManifestOnlyPluginNeverSpawnsAndReportsStaticState() throws {
    let manifestJSON = """
      {
        "id": "manifestonly",
        "name": "Manifest only",
        "version": "1.0.0",
        "description": "fixture",
        "bindings": { "app save": { "": "cmd+s" } }
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

  func testRequestsCarryWhatIsLeftOfTheirDeadline() throws {
    let fixture = try PluginFixtureKit.make(
      id: "deadline",
      manifest: PluginFixtureKit.manifest(
        id: "deadline",
        extra: #""commands": [{ "command": "deadline", "subcommand": "run", "description": "x" }]"#),
      script: PluginFixtureKit.script(
        onPerform: #"printf '%s\n' "$line" > "$D/perform"; "# + PluginFixtureKit.performOK))
    defer { fixture.cleanup() }
    let process = try makeProcess(fixture)
    process.start()
    let done = expectation(description: "perform")
    process.perform(
      kind: "command", params: ["command": "deadline", "subcommand": "run"], timeoutMs: 3_000
    ) { _ in done.fulfill() }
    wait(for: [done], timeout: 8)
    let line = try String(
      contentsOf: fixture.dataDir.appendingPathComponent("perform"), encoding: .utf8)
    let frame = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    let deadline = try XCTUnwrap(frame["deadline_ms"] as? Int)
    XCTAssertTrue((1...3_000).contains(deadline), "\(deadline)")
    process.stopAndWait(reason: "test")

    let now = DispatchTime.now()
    XCTAssertEqual(
      PluginProcess.remainingMilliseconds(until: now + .milliseconds(250), now: now), 250)
    XCTAssertEqual(
      PluginProcess.remainingMilliseconds(until: now, now: now + .seconds(1)), 1,
      "a passed deadline still names a positive wait")
  }

  func testStatusBoundPluginSpawnsOnceObservedAndStopsWhenNothingShowsIt() throws {
    let fixture = try PluginFixtureKit.make(
      id: "statusbound",
      manifest: PluginFixtureKit.manifest(id: "statusbound"),
      script: PluginFixtureKit.script())
    defer { fixture.cleanup() }
    let process = try makeProcess(fixture, statusObserved: false)
    XCTAssertEqual(process.activation, .onDemand)
    process.start()
    settleRunLoop(0.3)
    XCTAssertEqual(fixture.spawnCount(), 0, "unobserved status: no child after start()")

    process.setStatusObserved(true)
    XCTAssertEqual(process.activation, .resident)
    waitUntilTrue("spawned once observed") { process.runtimeStateSnapshot() == .running }
    XCTAssertEqual(process.statusSnapshot().activation, "resident")

    process.setStatusObserved(false)
    waitUntilTrue("stopped once unobserved") { process.runtimeStateSnapshot() == .stopped }
    XCTAssertEqual(process.statusSnapshot().activation, "on_demand")
    XCTAssertEqual(fixture.spawnCount(), 1)

    process.setStatusObserved(true)
    waitUntilTrue("respawned when observed again") { process.runtimeStateSnapshot() == .running }
    XCTAssertEqual(fixture.spawnCount(), 2)
    process.stopAndWait(reason: "test")
  }

  func testStatusBoundPluginStartedByACommandOutlivesItsObserver() throws {
    let fixture = try PluginFixtureKit.make(
      id: "statuscommand",
      manifest: PluginFixtureKit.manifest(id: "statuscommand"),
      script: PluginFixtureKit.script())
    defer { fixture.cleanup() }
    let process = try makeProcess(fixture, statusObserved: false)
    process.start()
    let settled = expectation(description: "perform settles")
    process.perform(kind: "command", params: [:]) { _ in settled.fulfill() }
    wait(for: [settled], timeout: 8)
    XCTAssertEqual(process.runtimeStateSnapshot(), .running)

    process.setStatusObserved(true)
    process.setStatusObserved(false)
    settleRunLoop(0.3)
    XCTAssertEqual(process.runtimeStateSnapshot(), .running, "a command started it; keep it")
    XCTAssertEqual(fixture.spawnCount(), 1)
    process.stopAndWait(reason: "test")
  }

  /// A status plugin whose command a mapping runs is warmed while nothing
  /// shows it and keeps its child when the surfaces stop showing it; once no
  /// mapping runs it, it follows its surfaces again.
  func testWarmStatusBoundPluginRunsUnobservedUntilNoMappingRunsIt() throws {
    let fixture = try PluginFixtureKit.make(
      id: "statuswarm",
      manifest: PluginFixtureKit.manifest(
        id: "statuswarm",
        extra: #""status": ["state"], "#
          + #""commands": [{ "command": "statuswarm", "subcommand": "go", "description": "x" }]"#
      ),
      script: PluginFixtureKit.script())
    defer { fixture.cleanup() }
    let process = try makeProcess(fixture, statusObserved: false)
    process.start()
    process.setStatusObserved(true)
    waitUntilTrue("spawned once observed") { process.runtimeStateSnapshot() == .running }
    process.setStatusObserved(false)
    waitUntilTrue("not warm: stopped once unobserved") {
      process.runtimeStateSnapshot() == .stopped
    }

    process.setWarm(true)
    process.prewarm()
    waitUntilTrue("warmed while unobserved") { process.runtimeStateSnapshot() == .running }
    XCTAssertEqual(process.statusSnapshot().activation, "on_demand")
    process.setStatusObserved(true)
    process.setStatusObserved(false)
    settleRunLoop(0.3)
    XCTAssertEqual(process.runtimeStateSnapshot(), .running, "a mapping keeps it warm")
    XCTAssertEqual(fixture.spawnCount(), 2)

    process.setWarm(false)
    waitUntilTrue("stopped once no mapping runs it") {
      process.runtimeStateSnapshot() == .stopped
    }
    XCTAssertEqual(fixture.spawnCount(), 2)
    process.stopAndWait(reason: "test")
  }

  // MARK: 10b. Prewarm

  func testPrewarmSpawnsOnlyAWarmOnDemandPluginBeforeItsFirstPerform() throws {
    let fixture = try PluginFixtureKit.make(
      id: "prewarm",
      manifest: PluginFixtureKit.manifest(
        id: "prewarm",
        extra: #""commands": [{ "command": "prewarm", "subcommand": "run", "description": "x" }]"#),
      script: PluginFixtureKit.script())
    defer { fixture.cleanup() }
    let process = try makeProcess(fixture)
    process.start()
    process.prewarm()
    settleRunLoop(0.3)
    XCTAssertEqual(fixture.spawnCount(), 0, "no mapping runs it: it waits for its first perform")

    process.setWarm(true)
    process.prewarm()
    waitUntilTrue("warmed") { process.runtimeStateSnapshot() == .running }
    XCTAssertEqual(process.statusSnapshot().activation, "on_demand")

    let performed = expectation(description: "perform")
    process.perform(kind: "command", params: ["command": "prewarm", "subcommand": "run"]) {
      outcome in
      XCTAssertEqual(outcome, .performed(pid: nil, navigationURL: nil, message: "fixture-done"))
      performed.fulfill()
    }
    wait(for: [performed], timeout: 8)
    process.prewarm()
    settleRunLoop(0.3)
    XCTAssertEqual(fixture.spawnCount(), 1, "the perform and a second prewarm reuse the child")
    process.stopAndWait(reason: "test")

    process.prewarm()
    settleRunLoop(0.3)
    XCTAssertEqual(process.runtimeStateSnapshot(), .stopped, "a stopped plugin stays stopped")
    XCTAssertEqual(fixture.spawnCount(), 1)
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
