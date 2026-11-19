import AppKit
import FlashCore
import XCTest

@testable import flash

/// The built `system` plugin, spawned under its sandbox profile by a real
/// `PluginManager`: its commands and its `@system` rows cross the wire, reach
/// `host.system_action` and come back as the result the resident presents.
/// The host's mechanisms are a stub (`SystemActionStub`), wired before any
/// plugin starts: no test here locks, sleeps, restarts, shuts down or logs
/// out the Mac, empties the Trash, changes the appearance or starts the
/// screen saver.
final class BundledSystemPluginTests: XCTestCase {
  private var manager: PluginManager!
  private var dataDir: URL!
  private let mechanisms = SystemActionStub()

  private static let restart = SystemActionExecution.appleScript(
    "tell application \"System Events\" to restart", timeout: 10)
  private static let shutdown = SystemActionExecution.appleScript(
    "tell application \"System Events\" to shut down", timeout: 10)
  private static let logout = SystemActionExecution.appleScript(
    "tell application \"System Events\" to log out", timeout: 10)
  private static let emptyTrash = SystemActionExecution.appleScript(
    "tell application \"Finder\" to empty trash", timeout: 30)
  private static let toggleAppearance = SystemActionExecution.appleScript(
    "tell application \"System Events\" to tell appearance preferences to "
      + "set dark mode to not dark mode", timeout: 10)

  /// The four commands nothing undoes, each with the question it asks and
  /// the mechanism it reaches once the user said yes.
  private static let destructive: [(String, String, String, SystemActionExecution)] = [
    ("system", "restart", "Restart this Mac?", restart),
    ("system", "shutdown", "Shut down this Mac?", shutdown),
    ("system", "logout", "Log out of macOS?", logout),
    ("trash", "empty", "Empty the Trash?", emptyTrash),
  ]

  private static func config() throws -> Config {
    let roots = PluginRepository.officialPluginRoots()
    let root = try XCTUnwrap(roots.first { $0.lastPathComponent == "system" })
    let binary = root.appendingPathComponent("flash-plugin-system").path
    guard FileManager.default.isExecutableFile(atPath: binary) else {
      if ProcessInfo.processInfo.environment["FLASH_REQUIRE_PLUGIN_BINARIES"] == "1" {
        XCTFail("the system plugin must be built")
      }
      throw XCTSkip("system is not built: run `mise run build:plugins`")
    }
    var config = Config()
    config.plugins.disabled = Set(roots.compactMap { (try? PluginManifest.load(from: $0))?.id })
      .subtracting(["system"])
    config.plugins.watchingEnabled = false
    return config
  }

  override func setUpWithError() throws {
    let config = try Self.config()
    dataDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-system-plugin-\(UUID().uuidString)")
    manager = PluginManager(baseDataDir: dataDir)
    // The seam, before anything can call through it.
    manager.hostRPC.systemActions = mechanisms
    manager.start(config: config)
    waitUntilTrue("system loaded") { self.status != nil }
  }

  override func tearDown() {
    manager?.stop()
    if let dataDir { try? FileManager.default.removeItem(at: dataDir) }
  }

  private var status: PluginStatus? {
    manager.pluginStatuses().first { $0.id == "system" }
  }

  /// Run the command as `manager.invoke` dispatches it: without the
  /// question the resident asks first, so `confirmed` is the test's to say.
  private func run(
    _ command: String, _ subcommand: String, _ args: [String] = [], confirmed: Bool = false
  ) -> PluginCommandResult {
    let answered = expectation(description: "\(command) \(subcommand)")
    var result = PluginCommandResult.unhandled
    XCTAssertTrue(
      manager.invoke(command: command, subcommand: subcommand, args: args, confirmed: confirmed) {
        result = $0
        answered.fulfill()
      })
    wait(for: [answered], timeout: 15)
    return result
  }

  /// Live sources and commands alone: no process until one of them is used.
  func testThePluginCostsNothingUntilACommandRuns() throws {
    XCTAssertEqual(status?.activation, "on_demand")
    XCTAssertNil(status?.pid, "nothing runs at launch")
    XCTAssertEqual(run("screen", "lock"), PluginCommandResult(ok: true))
    XCTAssertNotNil(status?.pid, "the first command spawned it")
    XCTAssertEqual(mechanisms.executions, [.lockScreenChord])
    XCTAssertEqual(mechanisms.onMainThread, [true], "the lock chord is posted on main")
  }

  func testEachCommandSomethingUndoesRunsAtOnceThroughItsMechanism() {
    XCTAssertEqual(run("system", "sleep"), PluginCommandResult(ok: true))
    XCTAssertEqual(run("display", "sleep"), PluginCommandResult(ok: true))
    XCTAssertEqual(run("screensaver", "start"), PluginCommandResult(ok: true))
    XCTAssertEqual(run("appearance", "toggle"), PluginCommandResult(ok: true))
    XCTAssertEqual(
      mechanisms.executions,
      [.sleepSystem, .sleepDisplays, .startScreensaver, Self.toggleAppearance])
    XCTAssertEqual(mechanisms.onMainThread, [false, false, false, false])
    for (command, subcommand) in [
      ("screen", "lock"), ("system", "sleep"), ("display", "sleep"), ("screensaver", "start"),
      ("appearance", "toggle"),
    ] {
      XCTAssertNil(
        manager.ownCommandConfirmation(command: command, subcommand: subcommand),
        "\(command) \(subcommand) asks nothing")
    }
  }

  /// The plugin cannot restart the Mac unprompted: sent without the user's
  /// yes, each destructive command reaches the host, which refuses it and
  /// asks macOS for nothing. The same command after a yes runs, once.
  func testADestructiveCommandRunsOnlyOnceTheUserConfirmedIt() {
    for (command, subcommand, prompt, _) in Self.destructive {
      XCTAssertEqual(
        manager.ownCommandConfirmation(command: command, subcommand: subcommand), prompt)
      let refused = run(command, subcommand)
      XCTAssertEqual(
        refused,
        PluginCommandResult(
          ok: false,
          error: "\(command) \(subcommand) failed: requires a perform the user confirmed"))
      XCTAssertEqual(refused.failureAlert, refused.error, "short enough to show")
    }
    XCTAssertEqual(mechanisms.executions, [], "nothing was asked of macOS")

    for (index, (command, subcommand, _, execution)) in Self.destructive.enumerated() {
      XCTAssertEqual(run(command, subcommand, confirmed: true), PluginCommandResult(ok: true))
      XCTAssertEqual(mechanisms.executions.count, index + 1)
      XCTAssertEqual(mechanisms.executions.last, execution)
    }
    XCTAssertEqual(mechanisms.onMainThread, [false, false, false, false])
  }

  /// A failure is the plugin's sentence: what failed, and the host's reason.
  func testAFailureAndAStrayArgumentSayWhy() {
    mechanisms.failure = "power management unavailable"
    let failed = run("system", "sleep")
    XCTAssertEqual(
      failed,
      PluginCommandResult(ok: false, error: "system sleep failed: power management unavailable"))
    XCTAssertEqual(failed.failureAlert, "system sleep failed: power management unavailable")
    mechanisms.failure = nil

    XCTAssertEqual(
      run("screen", "lock", ["--now"]),
      PluginCommandResult(
        ok: false, error: "unknown command or invalid arguments: screen lock --now"))
    XCTAssertEqual(
      run("system", "restart", ["now"], confirmed: true),
      PluginCommandResult(
        ok: false, error: "unknown command or invalid arguments: system restart now"))
    XCTAssertEqual(mechanisms.executions, [.sleepSystem], "a refused command reaches no mechanism")
  }

  /// `@system` is a live source: nothing is published, the nine rows are
  /// pulled when a query names the type, and the four destructive ones
  /// carry the question the host asks before it resolves them.
  func testSystemRowsArePulledLiveAndResolveToTheirActions() throws {
    let manager = try XCTUnwrap(self.manager)
    let registry = SourceRegistry(
      descriptors: [], runningApplications: [], pluginSourcesProvider: { manager.sources })
    let source = try XCTUnwrap(registry.liveCandidateSources(matching: .type("system")).first)
    XCTAssertFalse(source.liveCandidatesDependOnText, "pulled once per scope")
    XCTAssertNil(status?.pid, "listing the type starts nothing")

    let listed = expectation(description: "rows")
    var rows: [Candidate] = []
    source.liveCandidates(matching: "rest", in: registry.environment, scope: .all) {
      rows = CandidateFinder.prepare($0)
      listed.fulfill()
    }
    wait(for: [listed], timeout: 15)
    XCTAssertNotNil(status?.pid, "the first scoped query spawned it")
    XCTAssertEqual(manager.catalogStore.publishedPluginIDs(), [], "live rows are never stored")
    XCTAssertEqual(
      rows.map(\.title),
      [
        "Lock screen", "Sleep Mac", "Turn display off", "Restart Mac", "Shut down Mac", "Log out",
        "Empty Trash", "Toggle dark mode", "Start screen saver",
      ])
    XCTAssertTrue(
      rows.allSatisfy {
        $0.source == "system.actions" && $0.sourceID == "plugin:system" && $0.finishesCommand
          && $0.kind == .plugin("system_action")
      })
    let restart = try XCTUnwrap(rows.first { $0.sourcePayload == "system restart" })
    XCTAssertEqual(restart.subtitle, "Ask macOS to restart")
    XCTAssertEqual(restart.searchAliases, "restart reboot system restart")
    XCTAssertEqual(restart.confirm, "Restart this Mac?")
    XCTAssertEqual(
      rows.filter { $0.confirm != nil }.map { "\($0.title): \($0.confirm ?? "")" },
      [
        "Restart Mac: Restart this Mac?", "Shut down Mac: Shut down this Mac?",
        "Log out: Log out of macOS?", "Empty Trash: Empty the Trash?",
      ])
    XCTAssertEqual(registry.resourceTypesBySource()["system.actions"], "system")

    func resolve(_ row: Candidate, confirmed: Bool) -> CandidateResolution {
      let resolved = expectation(description: "resolve \(row.title)")
      var resolution = CandidateResolution.unresolved
      registry.resolveCandidate(row, confirmed: confirmed) {
        resolution = $0
        resolved.fulfill()
      }
      wait(for: [resolved], timeout: 15)
      return resolution
    }
    let lock = try XCTUnwrap(rows.first { $0.title == "Lock screen" })
    XCTAssertTrue(resolve(lock, confirmed: false).didResolve)
    XCTAssertEqual(mechanisms.executions, [.lockScreenChord])

    // A row resolved without the user's yes is refused by the host, and the
    // row says why.
    let refused = resolve(restart, confirmed: false)
    XCTAssertFalse(refused.didResolve)
    XCTAssertEqual(
      refused.failureReason, "system restart failed: requires a perform the user confirmed")
    XCTAssertEqual(mechanisms.executions, [.lockScreenChord], "nothing was asked of macOS")

    XCTAssertTrue(resolve(restart, confirmed: true).didResolve)
    XCTAssertEqual(mechanisms.executions, [.lockScreenChord, Self.restart])
  }

  /// The whole path the user takes, in a real resident: `flash system
  /// shutdown` asks, any other key runs nothing, and `y` reaches the
  /// mechanism once. A `@system` row asks the same way.
  func testTheResidentAsksBeforeADestructiveActionAndRunsItOnlyOnYes() throws {
    manager.stop()
    manager = nil
    _ = NSApplication.shared
    let delegate = AppDelegate()
    let resident = delegate.pluginManager
    // The seam, before anything can call through it.
    resident.hostRPC.systemActions = mechanisms
    let config = try Self.config()
    delegate.config = config
    delegate.registry = SourceRegistry(
      descriptors: [], runningApplications: [], pluginSourcesProvider: { resident.sources })
    delegate.monitor = AppMonitor(registry: delegate.registry, config: config)
    delegate.overlay = OverlayPanel()
    addTeardownBlock {
      resident.stop()
      delegate.overlay.dismissAlert()
      delegate.overlay.orderOut(nil)
    }
    resident.start(config: config)
    waitUntilTrue("system loaded") { resident.pluginStatuses().contains { $0.id == "system" } }

    let shutdown = URLCommand.pluginCommand(command: "system", subcommand: "shutdown", args: [])
    XCTAssertTrue(delegate.handleURLCommand(shutdown))
    XCTAssertEqual(
      delegate.hintSession.confirmation,
      HintSession.Confirmation(prompt: "Shut down this Mac?", command: shutdown))
    delegate.overlayDidConfirm(accepted: false)
    XCTAssertNil(delegate.hintSession.confirmation)
    settleRunLoop(0.5)
    XCTAssertEqual(mechanisms.executions, [], "n runs nothing")

    XCTAssertTrue(delegate.handleURLCommand(shutdown))
    delegate.overlayDidConfirm(accepted: true)
    waitUntilTrue("the confirmed shutdown reached its mechanism") {
      self.mechanisms.executions == [Self.shutdown]
    }

    // A command that asks nothing runs at once.
    XCTAssertTrue(
      delegate.handleURLCommand(.pluginCommand(command: "screen", subcommand: "lock", args: [])))
    XCTAssertNil(delegate.hintSession.confirmation)
    waitUntilTrue("the lock chord was asked for") {
      self.mechanisms.executions == [Self.shutdown, .lockScreenChord]
    }

    // The `Empty Trash` row, as the flashlight lists it.
    let source = try XCTUnwrap(
      delegate.registry.liveCandidateSources(matching: .type("system")).first)
    let listed = expectation(description: "rows")
    var rows: [Candidate] = []
    source.liveCandidates(matching: "", in: delegate.registry.environment, scope: .all) {
      rows = CandidateFinder.prepare($0)
      listed.fulfill()
    }
    wait(for: [listed], timeout: 15)
    let trash = try XCTUnwrap(rows.first { $0.title == "Empty Trash" })
    delegate.openSourceItem(trash, recordMovement: false)
    XCTAssertEqual(delegate.hintSession.confirmation?.prompt, "Empty the Trash?")
    delegate.overlayDidConfirm(accepted: false)
    settleRunLoop(0.5)
    XCTAssertEqual(mechanisms.executions.count, 2, "a cancelled row runs nothing")

    delegate.openSourceItem(trash, recordMovement: false)
    delegate.overlayDidConfirm(accepted: true)
    waitUntilTrue("the confirmed row reached its mechanism") {
      self.mechanisms.executions == [Self.shutdown, .lockScreenChord, Self.emptyTrash]
    }
  }
}
