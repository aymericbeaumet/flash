import AppKit
import FlashCore
import XCTest

@testable import flash

/// The built `processes` plugin, spawned under its sandbox profile by a real
/// `PluginManager`. It reads the process table itself, through libproc,
/// which its profile opens for other processes with the `process_info`
/// capability: every figure asserted here was read inside the sandbox. It
/// signals nothing: `process kill` and a picked row reach
/// `host.process_signal`, whose mechanism is this suite's
/// (`ChildProcessSignals`), so the only process a test here ever signals is
/// a child it spawned.
final class BundledProcessesPluginTests: XCTestCase {
  private var manager: PluginManager!
  private var dataDir: URL!
  private var children: [Process] = []

  private static func config(_ toml: String = "") throws -> Config {
    let roots = PluginRepository.officialPluginRoots()
    let root = try XCTUnwrap(roots.first { $0.lastPathComponent == "processes" })
    let binary = root.appendingPathComponent("flash-plugin-processes").path
    guard FileManager.default.isExecutableFile(atPath: binary) else {
      if ProcessInfo.processInfo.environment["FLASH_REQUIRE_PLUGIN_BINARIES"] == "1" {
        XCTFail("the processes plugin must be built")
      }
      throw XCTSkip("processes is not built: run `mise run build:plugins`")
    }
    var config = ConfigLoader.parse(toml)
    config.plugins.disabled = Set(roots.compactMap { (try? PluginManifest.load(from: $0))?.id })
      .subtracting(["processes"])
    config.plugins.watchingEnabled = false
    return config
  }

  /// Start the plugin set under `toml`, with `signals` as the host's signal
  /// mechanism: wired before any plugin starts.
  private func start(_ toml: String = "", signals: (any ProcessSignalling)? = nil) throws {
    let config = try Self.config(toml)
    dataDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-processes-plugin-\(UUID().uuidString)")
    manager = PluginManager(baseDataDir: dataDir)
    manager.hostRPC.processSignals = signals
    manager.start(config: config)
    waitUntilTrue("processes loaded") { self.status != nil }
  }

  override func tearDown() {
    manager?.stop()
    for child in children where child.isRunning {
      child.terminate()
      child.waitUntilExit()
    }
    if let dataDir { try? FileManager.default.removeItem(at: dataDir) }
  }

  private var status: PluginStatus? {
    manager.pluginStatuses().first { $0.id == "processes" }
  }

  /// A process of this test's own, which sleeps until it is terminated.
  private func spawnChild() throws -> Process {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["600"]
    try child.run()
    children.append(child)
    return child
  }

  private func run(_ args: [String], confirmed: Bool) -> PluginCommandResult {
    let answered = expectation(description: "process kill \(args)")
    var result = PluginCommandResult.unhandled
    XCTAssertTrue(
      manager.invoke(command: "process", subcommand: "kill", args: args, confirmed: confirmed) {
        result = $0
        answered.fulfill()
      })
    wait(for: [answered], timeout: 15)
    return result
  }

  private func registry(_ manager: PluginManager) -> SourceRegistry {
    SourceRegistry(
      descriptors: [], runningApplications: [], pluginSourcesProvider: { manager.sources })
  }

  /// The `@processes` rows, as a scoped query pulls them.
  private func rows(_ registry: SourceRegistry, query: String = "") throws -> [Candidate] {
    let source = try XCTUnwrap(registry.liveCandidateSources(matching: .type("processes")).first)
    let listed = expectation(description: "rows")
    var rows: [Candidate] = []
    source.liveCandidates(matching: query, in: registry.environment, scope: .all) {
      rows = CandidateFinder.prepare($0)
      listed.fulfill()
    }
    wait(for: [listed], timeout: 15)
    return rows
  }

  private func row(_ rows: [Candidate], pid: pid_t) -> Candidate? {
    rows.first { $0.sourcePayload?.hasPrefix("\(pid):") == true }
  }

  private func resolve(
    _ registry: SourceRegistry, _ row: Candidate, confirmed: Bool
  ) -> CandidateResolution {
    let resolved = expectation(description: "resolve \(row.title)")
    var resolution = CandidateResolution.unresolved
    registry.resolveCandidate(row, confirmed: confirmed) {
      resolution = $0
      resolved.fulfill()
    }
    wait(for: [resolved], timeout: 15)
    return resolution
  }

  private func waitForExit(_ child: Process, _ message: String) {
    waitUntilTrue(message) { !child.isRunning }
    XCTAssertEqual(child.terminationReason, .uncaughtSignal, message)
    XCTAssertEqual(child.terminationStatus, SIGTERM, message)
  }

  /// Status segments nobody shows, a live source and one command: no
  /// process until one of them is used.
  func testThePluginCostsNothingUntilItIsUsed() throws {
    try start()
    XCTAssertEqual(status?.activation, "on_demand")
    XCTAssertNil(status?.pid, "nothing runs at launch")
    XCTAssertEqual(
      manager.ownCommandConfirmation(command: "process", subcommand: "kill"),
      "Kill this process?")
    XCTAssertEqual(
      run(["--pid=1"], confirmed: true),
      PluginCommandResult(ok: false, error: "refusing pid 1"))
    XCTAssertNotNil(status?.pid, "the first command spawned it")
  }

  /// The sandbox proof for the table: under the plugin's own profile, a
  /// scoped query lists other processes with their names and shares. The
  /// test runner and a child it spawned are two of them.
  func testProcessRowsAreReadInsideTheSandboxAndPulledLive() throws {
    try start()
    let child = try spawnChild()
    let manager = try XCTUnwrap(self.manager)
    let registry = registry(manager)
    let source = try XCTUnwrap(registry.liveCandidateSources(matching: .type("processes")).first)
    XCTAssertTrue(source.liveCandidatesDependOnText, "asked again as the query changes")
    XCTAssertNil(status?.pid, "listing the type starts nothing")

    let rows = try rows(registry, query: "sle")
    XCTAssertNotNil(status?.pid, "the first scoped query spawned it")
    XCTAssertEqual(manager.catalogStore.publishedPluginIDs(), [], "live rows are never stored")
    XCTAssertGreaterThan(rows.count, 10, "every visible process, whatever was typed")
    XCTAssertTrue(
      rows.allSatisfy {
        $0.source == "processes.processes" && $0.sourceID == "plugin:processes"
          && $0.kind == .plugin("process") && !$0.finishesCommand && $0.confirm != nil
      })
    XCTAssertEqual(registry.resourceTypesBySource()["processes.processes"], "processes")

    let sleep = try XCTUnwrap(row(rows, pid: child.processIdentifier), "the child is listed")
    XCTAssertEqual(sleep.title, "sleep")
    XCTAssertEqual(sleep.searchAliases, "\(child.processIdentifier)")
    XCTAssertEqual(sleep.confirm, "Kill sleep (pid \(child.processIdentifier))?")
    let subtitle = try XCTUnwrap(sleep.subtitle)
    XCTAssertNotNil(
      subtitle.range(
        of: #"^pid \#(child.processIdentifier) · \d+\.\d% CPU · \d+\.\d% MEM$"#,
        options: .regularExpression), subtitle)

    let runner = try XCTUnwrap(row(rows, pid: getpid()), "the test runner is listed")
    XCTAssertFalse(runner.title.isEmpty)
    XCTAssertEqual(runner.confirm, "Kill \(runner.title) (pid \(getpid()))?")
    let plugin = try XCTUnwrap(status?.pid)
    XCTAssertNotNil(row(rows, pid: pid_t(plugin)), "and so is the plugin itself")
  }

  /// The sandbox proof for the status values: observed by a bar and a text
  /// popup, the tables and the focused app's tree are sampled inside the
  /// sandbox, on the host's clock, at the configured row count.
  func testObservedValuesAreSampledInsideTheSandbox() throws {
    let child = try spawnChild()
    try start(
      """
      [statusbar]
      enabled = true
      template = "#{flash.plugin.processes.top_mem} #{flash.plugin.processes.top_cpu}"

      [popup.app]
      text = "#{flash.plugin.processes.focused_app_details}"

      [plugins.processes]
      top_count = 3
      """)
    XCTAssertEqual(status?.activation, "resident", "its values are shown")
    waitUntilTrue("the plugin runs while its values are shown") { self.status?.pid != nil }

    func lines(_ segment: String) -> [String] {
      (status?.statusSegments[segment] ?? "").split(separator: "\n").map(String.init)
    }
    waitUntilTrue("both tables were published") {
      lines("top_mem").count == 3 && lines("top_cpu").count == 3
    }
    for line in lines("top_mem") {
      XCTAssertNotNil(
        line.range(of: #"^.{15}  +\d+(\.\d)? (B|KiB|MiB|GiB)$"#, options: .regularExpression),
        line)
    }
    for line in lines("top_cpu") {
      XCTAssertNotNil(
        line.range(of: #"^.{15}  +\d+\.\d%$"#, options: .regularExpression), line)
    }

    // The focused app: this test runner, whose tree holds the plugin and
    // the child.
    manager.emit(
      PluginEvent(
        .focusChanged,
        payload: [
          "bundle_id": "com.example.tests", "localized_name": "Tests", "pid": Int(getpid()),
        ],
        bundleID: "com.example.tests"))
    waitUntilTrue("the focused app's figures were published") {
      (self.status?.statusSegments["focused_app_details"] ?? "").contains("Resources")
    }
    let details = try XCTUnwrap(status?.statusSegments["focused_app_details"])
    XCTAssertTrue(details.contains("Bundle        com.example.tests\nPID           \(getpid())"))
    XCTAssertNotNil(
      details.range(
        of: #"Processes     \d+ · \d+ threads\nSockets       \d+\nRunning       "#,
        options: .regularExpression), details)
    XCTAssertTrue(details.contains("#[bold]Busiest helpers · "), details)
    XCTAssertNotNil(
      details.range(
        of: "sleep +\(child.processIdentifier) +\\d+\\.\\d% ", options: .regularExpression),
      details)
    XCTAssertTrue(details.contains("Executable    /"), details)
  }

  /// A kill reaches the host only as a request, and the host sends the
  /// signal only once the user said yes: unconfirmed, the child keeps
  /// running; confirmed, SIGTERM ends it.
  func testTheCommandTerminatesAProcessOnlyOnceTheUserConfirmedIt() throws {
    let child = try spawnChild()
    let signals = ChildProcessSignals(child: child)
    try start(signals: signals)
    let pid = "--pid=\(child.processIdentifier)"

    let refused = run([pid], confirmed: false)
    XCTAssertEqual(
      refused,
      PluginCommandResult(
        ok: false, error: "process kill failed: requires a perform the user confirmed"))
    XCTAssertEqual(refused.failureAlert, refused.error, "short enough to show")
    XCTAssertTrue(child.isRunning, "an unconfirmed kill signals nothing")

    XCTAssertEqual(run([pid], confirmed: true), PluginCommandResult(ok: true))
    waitForExit(child, "the confirmed kill ended the child")
    XCTAssertEqual(signals.refused, [], "only the child was ever signalled")

    // It is gone: the same command now says so, and asks the host nothing.
    XCTAssertEqual(
      run([pid], confirmed: true),
      PluginCommandResult(ok: false, error: "no process with pid \(child.processIdentifier)"))
  }

  /// What no confirmation reaches: a malformed pid, launchd and the
  /// resident itself, which here is the test runner.
  func testAKillTheHostOrThePluginRefusesSignalsNothing() throws {
    let child = try spawnChild()
    let signals = ChildProcessSignals(child: child)
    try start(signals: signals)
    for (args, error) in [
      ([], "usage: process kill --pid=<pid>"),
      (["4242"], "usage: process kill --pid=<pid>"),
      (["--pid=sleep"], "usage: process kill --pid=<pid>"),
      (["--pid=\(child.processIdentifier)", "--force"], "usage: process kill --pid=<pid>"),
      (["--pid=1"], "refusing pid 1"),
      (["--pid=0"], "refusing pid 0"),
      (["--pid=\(getpid())"], "process kill failed: refusing to signal Flash itself"),
    ] {
      XCTAssertEqual(
        run(args, confirmed: true), PluginCommandResult(ok: false, error: error), "\(args)")
    }
    XCTAssertTrue(child.isRunning)
    XCTAssertEqual(signals.refused, [], "no refusal reached the mechanism")
  }

  /// A picked row terminates the process it listed, after its own question.
  func testAPickedRowTerminatesItsProcessOnlyOnceConfirmed() throws {
    let child = try spawnChild()
    let signals = ChildProcessSignals(child: child)
    try start(signals: signals)
    let registry = registry(try XCTUnwrap(manager))
    let listed = try XCTUnwrap(row(try rows(registry), pid: child.processIdentifier))

    let refused = resolve(registry, listed, confirmed: false)
    XCTAssertFalse(refused.didResolve)
    XCTAssertEqual(
      refused.failureReason, "process kill failed: requires a perform the user confirmed")
    XCTAssertTrue(child.isRunning)

    XCTAssertTrue(resolve(registry, listed, confirmed: true).didResolve)
    waitForExit(child, "the confirmed row ended the child")
    XCTAssertEqual(signals.refused, [])

    // The next query reads the table afresh: the row is gone.
    XCTAssertNil(row(try rows(registry, query: "s"), pid: child.processIdentifier))
    let again = resolve(registry, listed, confirmed: true)
    XCTAssertEqual(again.failureReason, "no process with pid \(child.processIdentifier)")
  }

  /// The whole path the user takes, in a real resident: `flash process kill
  /// --pid=<pid>` asks, any other key signals nothing, and `y` terminates
  /// the process. A `@processes` row asks by name the same way.
  func testTheResidentAsksBeforeItTerminatesAProcess() throws {
    let child = try spawnChild()
    let other = try spawnChild()
    _ = NSApplication.shared
    let delegate = AppDelegate()
    let resident = delegate.pluginManager
    // The seam, before anything can call through it: these two children
    // and nothing else.
    resident.hostRPC.processSignals = ChildProcessSignals(children: [child, other])
    let config = try Self.config()
    delegate.config = config
    delegate.registry = registry(resident)
    delegate.monitor = AppMonitor(registry: delegate.registry, config: config)
    delegate.overlay = OverlayPanel()
    addTeardownBlock {
      resident.stop()
      delegate.overlay.dismissAlert()
      delegate.overlay.orderOut(nil)
    }
    resident.start(config: config)
    waitUntilTrue("processes loaded") {
      resident.pluginStatuses().contains { $0.id == "processes" }
    }

    let kill = URLCommand.pluginCommand(
      command: "process", subcommand: "kill", args: ["--pid=\(child.processIdentifier)"])
    XCTAssertTrue(delegate.handleURLCommand(kill))
    XCTAssertEqual(
      delegate.hintSession.confirmation,
      HintSession.Confirmation(prompt: "Kill this process?", command: kill))
    delegate.overlayDidConfirm(accepted: false)
    XCTAssertNil(delegate.hintSession.confirmation)
    settleRunLoop(0.5)
    XCTAssertTrue(child.isRunning, "n signals nothing")

    XCTAssertTrue(delegate.handleURLCommand(kill))
    delegate.overlayDidConfirm(accepted: true)
    waitForExit(child, "the confirmed command ended the child")

    XCTAssertTrue(other.isRunning, "one confirmation, one process")

    // The other child's row, as the flashlight lists it.
    let listed = try XCTUnwrap(row(try rows(delegate.registry), pid: other.processIdentifier))
    delegate.openSourceItem(listed, recordMovement: false)
    XCTAssertEqual(
      delegate.hintSession.confirmation?.prompt, "Kill sleep (pid \(other.processIdentifier))?")
    delegate.overlayDidConfirm(accepted: false)
    settleRunLoop(0.5)
    XCTAssertTrue(other.isRunning, "a cancelled row signals nothing")

    delegate.openSourceItem(listed, recordMovement: false)
    delegate.overlayDidConfirm(accepted: true)
    waitForExit(other, "the confirmed row ended the other child")
  }
}
