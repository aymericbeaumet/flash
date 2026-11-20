import AppKit
import FlashCore
import XCTest

@testable import flash

/// The built `processes` plugin, spawned under its sandbox profile by a real
/// `PluginManager`. It reads no process: its profile denies it every one but
/// its own, and every figure asserted here reached it through
/// `host.process_table`. The table is this suite's: the test runner and the
/// children it spawned, read live (`OwnProcessKernel`), and a scripted
/// dozen beside them, so no test reads a process that is not its own. The
/// plugin signals nothing either: `process kill` and a picked row reach
/// `host.process_signal`, whose mechanism is this suite's
/// (`ChildProcessSignals`), so the only process a test here ever signals is
/// a child it spawned.
final class BundledProcessesPluginTests: XCTestCase {
  private var manager: PluginManager!
  private var dataDir: URL!
  private var children: [Process] = []
  /// The scripted part of the table.
  private let scripted = BundledProcessesPluginTests.scriptedTable()
  private lazy var kernel = OwnProcessKernel(scripted: scripted)

  private static let finder = "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"

  /// Twelve idle processes and Finder with one helper, none of them real:
  /// pids no process of this user holds are not needed, since no read of
  /// them reaches the machine.
  private static func scriptedTable() -> ProcessKernelStub {
    let table = ProcessKernelStub(clock: 1)
    for index in 0..<12 {
      table.spawn(
        pid_t(3_000_000 + index), path: "/usr/libexec/scripted-\(index)",
        start: UInt64(1_000 + index), residentBytes: UInt64(index + 1) << 20)
    }
    table.spawn(3_100_000, path: finder, start: 5_000, residentBytes: 64 << 20) {
      $0.threads = 7
      $0.sockets = 2
      $0.startTime = Int(Date().timeIntervalSince1970) - 3_600
    }
    table.spawn(
      3_100_001, parent: 3_100_000, path: "/usr/libexec/scripted-helper", start: 5_001,
      residentBytes: 8 << 20)
    return table
  }

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
  /// mechanism and this suite's table as its process table: both wired
  /// before any plugin starts. `shown` is what a surface has on screen:
  /// every value the configuration reads, unless a test says otherwise.
  private func start(
    _ toml: String = "", signals: (any ProcessSignalling)? = nil, shown: Set<String>? = nil
  ) throws {
    let config = try Self.config(toml)
    dataDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-processes-plugin-\(UUID().uuidString)")
    manager = PluginManager(baseDataDir: dataDir)
    manager.hostRPC.processSignals = signals
    manager.hostRPC.processTable = HostProcessTable(kernel: kernel)
    if let shown {
      manager.setShownStatusSegments(shown)
    } else {
      manager.showEverySegment(readBy: config)
    }
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
    kernel.allow(child)
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
    // The kernel's answer for a pid that names no process.
    let gone = ProcessSignalStub()
    gone.failure = "No such process"
    try start(signals: gone)
    XCTAssertEqual(status?.activation, "on_demand")
    XCTAssertNil(status?.pid, "nothing runs at launch")
    XCTAssertEqual(
      manager.ownCommandConfirmation(command: "process", subcommand: "kill"),
      "Kill this process?")
    XCTAssertEqual(
      run(["--pid=1"], confirmed: true),
      PluginCommandResult(
        ok: false, error: "unknown command or invalid arguments: process kill --pid=1"))
    XCTAssertNil(status?.pid, "a pid the declaration refuses starts nothing")
    XCTAssertEqual(
      run(["--pid=2147483646"], confirmed: true),
      PluginCommandResult(ok: false, error: "no process with pid 2147483646"))
    XCTAssertNotNil(status?.pid, "the first command spawned it")
    XCTAssertEqual(gone.sent.map(\.pid), [2_147_483_646], "the kernel was asked, off main")
    XCTAssertEqual(gone.sent.map(\.onMainThread), [false])
  }

  /// The rows are the host's table: under the plugin's own profile, which
  /// reads no process, a scoped query lists every process the host reports
  /// with its name and shares. The test runner and a child it spawned are
  /// two of them.
  func testProcessRowsAreTheHostsTablePulledLive() throws {
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
    XCTAssertFalse(scripted.askedOnMain, "the host reads off the main thread")
    XCTAssertEqual(
      Set(rows.compactMap { $0.sourcePayload?.split(separator: ":").first.map(String.init) }),
      Set(kernel.pids().map(String.init)), "every process of the table, whatever was typed")
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
    let idle = try XCTUnwrap(row(rows, pid: 3_000_003), "a scripted process is listed")
    XCTAssertEqual(idle.title, "scripted-3")
    XCTAssertEqual(idle.sourcePayload, "3000003:1003", "its pid and its start")
    XCTAssertTrue(idle.subtitle.hasPrefix("pid 3000003 · 0.0% CPU · "), idle.subtitle)
  }

  /// The status values: shown by a bar and, once it opens, a text popup,
  /// the tables and the focused app's tree are sampled through the host, on
  /// the host's clock, at the configured row count. The popup's value is
  /// sampled only while the popup is open.
  func testObservedValuesAreSampledThroughTheHost() throws {
    let child = try spawnChild()
    let tables: Set<String> = ["processes.top_mem", "processes.top_cpu"]
    try start(
      """
      [statusbar]
      enabled = true
      template = "#{flash.plugin.processes.top_mem} #{flash.plugin.processes.top_cpu}"

      [popup.app]
      text = "#{flash.plugin.processes.focused_app_details}"

      [plugins.processes]
      top_count = 3
      """, shown: tables)
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
    // the child. Its popup is closed: the focus is tracked and nothing is
    // read for it.
    manager.emit(
      PluginEvent(
        .focusChanged,
        payload: [
          "bundle_id": "com.example.tests", "localized_name": "Tests", "pid": Int(getpid()),
        ],
        bundleID: "com.example.tests"))
    settleRunLoop(0.6)
    XCTAssertEqual(status?.statusSegments["focused_app_details"] ?? "", "", "the popup is closed")

    // The popup opens: the app's identity at once, its figures a first
    // read later.
    let pid = status?.pid
    let opened = DispatchTime.now()
    func sinceOpened() -> Int {
      Int((DispatchTime.now().uptimeNanoseconds - opened.uptimeNanoseconds) / 1_000_000)
    }
    manager.setShownStatusSegments(tables.union(["processes.focused_app_details"]))
    waitUntilTrue("the placeholder was published") {
      (self.status?.statusSegments["focused_app_details"] ?? "").contains("com.example.tests")
    }
    let placeholderMs = sinceOpened()
    waitUntilTrue("the focused app's figures were published") {
      (self.status?.statusSegments["focused_app_details"] ?? "").contains("Resources")
    }
    print("processes popup opened: placeholder \(placeholderMs) ms, figures \(sinceOpened()) ms")
    XCTAssertEqual(status?.pid, pid, "opening the popup spawned nothing")
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

    // The popup closes: the plugin stops reading the app and clears the
    // value, which the host keeps for the next opening; the tables stay.
    func kept() -> Set<String> {
      manager.statusBarInfos().first { $0.id == "processes" }?.heldStatusSegments ?? []
    }
    manager.setShownStatusSegments(tables)
    waitUntilTrue("the closed popup's value is the last one published") {
      kept() == ["focused_app_details"]
    }
    XCTAssertEqual(status?.statusSegments["focused_app_details"], details)
    XCTAssertEqual(lines("top_mem").count, 3)
    XCTAssertEqual(status?.pid, pid)

    // It opens again: the kept figures stay until the plugin publishes.
    manager.setShownStatusSegments(tables.union(["processes.focused_app_details"]))
    XCTAssertFalse((status?.statusSegments["focused_app_details"] ?? "").isEmpty)
    waitUntilTrue("the plugin published the value again") { kept().isEmpty }
    XCTAssertTrue(
      (status?.statusSegments["focused_app_details"] ?? "").contains("com.example.tests"))
  }

  /// The app's version and its bundle path come from its `Info.plist`,
  /// which the plugin reads itself: a file, not a process, and its profile
  /// reads files. The focused app here is the scripted Finder, whose bundle
  /// is the real one on disk; its figures are the host's.
  func testTheFocusedAppsBundleIsReadInsideTheSandboxAndItsTreeByTheHost() throws {
    try start(
      """
      [statusbar]
      enabled = true
      template = "#{flash.plugin.processes.focused_app_details}"
      """)
    // An event reaches a plugin once it runs: a spawned child that has not
    // answered `initialize` yet is sent none.
    waitUntilTrue("the plugin runs while its value is shown") { self.status?.state == "running" }
    manager.emit(
      PluginEvent(
        .focusChanged,
        payload: ["bundle_id": "com.apple.finder", "localized_name": "Finder", "pid": 3_100_000],
        bundleID: "com.apple.finder"))
    var details: String { status?.statusSegments["focused_app_details"] ?? "" }
    waitUntilTrue("the focused app's figures were published") { details.contains("Resources") }
    XCTAssertTrue(details.hasPrefix("#[bold]Finder#[nobold]\nVersion       "), details)
    XCTAssertNotNil(
      details.range(
        of: #"\nVersion       \d[^\n]*\nBundle        com\.apple\.finder\nPID           3100000\n"#,
        options: .regularExpression), details)
    XCTAssertTrue(details.contains("Memory        72 MiB ("), details)
    XCTAssertTrue(
      details.contains(
        "Processes     2 · 8 threads\nSockets       2\nRunning       1h 0m · main process"),
      details)
    XCTAssertTrue(details.contains("#[bold]Busiest helpers · 1 of 1#[nobold]"), details)
    XCTAssertNotNil(
      details.range(of: #"scripted-helper +3100001 +0\.0% +8\.0 MiB"#, options: .regularExpression),
      details)
    XCTAssertTrue(
      details.hasSuffix(
        "Bundle path   /System/Library/CoreServices/Finder.app\nExecutable    \(Self.finder)"),
      details)
    XCTAssertFalse(scripted.askedOnMain)
  }

  /// A popup is all that reads the plugin: it runs, since the configuration
  /// refers to its value, and reads nothing until the popup opens. Opening
  /// it shows the focused app's identity at once and its figures one first
  /// read later (a 150 ms wait on the host's clock for pids it has not
  /// measured yet).
  func testAPopupOpenedColdShowsThePlaceholderThenTheFigures() throws {
    try start(
      """
      [statusbar]
      enabled = true
      template = "#[popup=app]app#[nopopup]"

      [popup.app]
      text = "#{flash.plugin.processes.focused_app_details}"
      """, shown: [])
    XCTAssertEqual(status?.activation, "resident", "the configuration refers to its value")
    waitUntilTrue("the plugin runs") { self.status?.state == "running" }
    manager.emit(
      PluginEvent(
        .focusChanged,
        payload: [
          "bundle_id": "com.example.tests", "localized_name": "Tests", "pid": Int(getpid()),
        ],
        bundleID: "com.example.tests"))
    settleRunLoop(0.6)
    XCTAssertEqual(status?.statusSegments["focused_app_details"] ?? "", "", "the popup is closed")

    var details: String { status?.statusSegments["focused_app_details"] ?? "" }
    func wait(_ what: String, _ condition: () -> Bool) -> Double {
      let started = DispatchTime.now()
      let deadline = Date().addingTimeInterval(8)
      while !condition(), Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.002))
      }
      XCTAssertTrue(condition(), what)
      return Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
    }
    let pid = status?.pid
    manager.setShownStatusSegments(["processes.focused_app_details"])
    let placeholder = wait("the placeholder") { details.contains("Collecting metrics…") }
    XCTAssertTrue(details.contains("Bundle        com.example.tests"), details)
    let figures = placeholder + wait("the figures") { details.contains("Resources") }
    print(
      "processes popup opened cold: placeholder \(Int(placeholder)) ms, "
        + "figures \(Int(figures)) ms")
    XCTAssertEqual(status?.pid, pid, "opening the popup spawned nothing")
    XCTAssertLessThan(figures, 2_000)
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

    // It is gone: the kernel says so, in the plugin's words.
    XCTAssertEqual(
      run([pid], confirmed: true),
      PluginCommandResult(ok: false, error: "no process with pid \(child.processIdentifier)"))
  }

  /// What no confirmation reaches: arguments the command's declaration
  /// refuses, launchd among them, which never reach the plugin, and the
  /// resident itself, which here is the test runner.
  func testAKillTheHostOrThePluginRefusesSignalsNothing() throws {
    let child = try spawnChild()
    let signals = ChildProcessSignals(child: child)
    try start(signals: signals)
    for args in [
      [], ["4242"], ["--pid=sleep"], ["--pid=\(child.processIdentifier)", "--force"],
      ["--pid=1"], ["--pid=0"], ["--pid=-\(child.processIdentifier)"],
    ] {
      XCTAssertEqual(
        run(args, confirmed: true),
        PluginCommandResult(
          ok: false,
          error: "unknown command or invalid arguments: "
            + (["process", "kill"] + args).joined(separator: " ")), "\(args)")
    }
    XCTAssertNil(status?.pid, "refused arguments start no plugin")
    XCTAssertEqual(
      run(["--pid=\(getpid())"], confirmed: true),
      PluginCommandResult(ok: false, error: "process kill failed: refusing to signal Flash itself"))
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
    resident.hostRPC.processTable = HostProcessTable(kernel: kernel)
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
