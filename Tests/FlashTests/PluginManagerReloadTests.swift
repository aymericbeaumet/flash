import FlashCore
import Foundation
import XCTest

@testable import flash

/// PluginManager reconciliation: file/github third-party materialization,
/// the `[plugins] disabled` gate, `reloadAll`, and the config-generation
/// guard. Every config built here disables all discoverable official
/// plugins so reconciles only ever spawn the test fixtures.
final class PluginManagerReloadTests: XCTestCase {

  /// IDs of every loadable official manifest (discovered from the repo's
  /// `Plugins/` via cwd, like production). Disabled wholesale in every test
  /// config so `reloadDesiredPlugins` never launches a real plugin.
  private static let officialIDs: Set<String> = Set(
    PluginRepository.officialPluginRoots().compactMap {
      (try? PluginManifest.load(from: $0))?.id
    })

  private func testConfig(
    thirdParty: [String], disabled: Set<String> = []
  ) -> Config {
    var config = Config()
    config.plugins.thirdParty = thirdParty.compactMap { PluginReference.parse($0) }
    XCTAssertEqual(config.plugins.thirdParty.count, thirdParty.count, "unparseable test ref")
    config.plugins.disabled = Self.officialIDs.union(disabled)
    config.plugins.watchingEnabled = false
    return config
  }

  private static let residentSurfaces = #""listen": ["core:config.changed"]"#

  private func status(_ manager: PluginManager, _ id: String) -> PluginStatus? {
    manager.pluginStatuses().first { $0.id == id }
  }

  /// Resident whatever the status bar shows: `listen` alone keeps a plugin
  /// running (a status-only one waits for the bar to observe it).
  private func residentFixture(id: String, baseDataDir: URL? = nil) throws
    -> PluginFixtureKit.Fixture
  {
    try PluginFixtureKit.make(
      id: id,
      manifest: PluginFixtureKit.manifest(id: id, extra: Self.residentSurfaces),
      script: PluginFixtureKit.script(),
      baseDataDir: baseDataDir)
  }

  // MARK: - file: refs

  func testFileReferenceLoadsRunsAndStopsThirdPartyPlugin() throws {
    let fixture = try residentFixture(id: "mgrfile")
    defer { fixture.cleanup() }
    let manager = PluginManager(baseDataDir: fixture.baseDataDir)
    defer { manager.stop() }
    manager.start(config: testConfig(thirdParty: ["file:\(fixture.root.path)"]))
    waitUntilTrue("plugin running under the manager") {
      self.status(manager, "mgrfile")?.state == "running"
    }
    let running = try XCTUnwrap(status(manager, "mgrfile"))
    XCTAssertEqual(running.origin, "file:\(fixture.root.path)")
    XCTAssertEqual(running.activation, "resident")
    let pid = try XCTUnwrap(running.pid)
    manager.stop()
    XCTAssertTrue(manager.pluginStatuses().isEmpty)
    waitUntilTrue("child exits after manager stop") { kill(pid_t(pid), 0) != 0 }
  }

  // MARK: - [plugins] disabled

  func testDisabledListPreventsAnyProcessForTheDisabledID() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-mgr-disabled-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let off = try residentFixture(id: "mgroff", baseDataDir: base)
    let on = try residentFixture(id: "mgron", baseDataDir: base)
    defer {
      off.cleanup()
      on.cleanup()
    }
    let manager = PluginManager(baseDataDir: base)
    defer { manager.stop() }
    manager.start(
      config: testConfig(
        thirdParty: ["file:\(off.root.path)", "file:\(on.root.path)"],
        disabled: ["mgroff"]))
    // The enabled sibling reaching `running` proves the reconcile completed.
    waitUntilTrue("enabled sibling running") { self.status(manager, "mgron")?.state == "running" }
    XCTAssertNil(status(manager, "mgroff"), "a disabled plugin is skipped, not failed")
    XCTAssertEqual(off.spawnCount(), 0, "no process may ever spawn for a disabled id")
  }

  // MARK: - status-bound activation

  func testStatusOnlyPluginRunsWhileTheEnabledBarShowsIt() throws {
    let fixture = try PluginFixtureKit.make(
      id: "mgrbound",
      manifest: PluginFixtureKit.manifest(id: "mgrbound"),
      script: PluginFixtureKit.script())
    defer { fixture.cleanup() }
    let manager = PluginManager(baseDataDir: fixture.baseDataDir)
    defer { manager.stop() }
    var config = testConfig(thirdParty: ["file:\(fixture.root.path)"])
    config.statusBar.template = FlashStatusBarTemplate(
      template: "#{flash.plugin.mgrbound.state}",
      variables: [
        FlashStatusBarTemplateVariable(
          id: "statusbar.template.flash.plugin.mgrbound.state",
          token: "flash.plugin.mgrbound.state",
          source: .plugin(.statusSegment(pluginID: "mgrbound", name: "state")))
      ])
    manager.start(config: config)
    waitUntilTrue("registered") { self.status(manager, "mgrbound")?.activation == "on_demand" }
    settleRunLoop(0.3)
    XCTAssertEqual(fixture.spawnCount(), 0, "the template shows it, but the bar is hidden")

    config.statusBar.enabled = true
    manager.updateConfig(config)
    waitUntilTrue("observed plugin spawned") {
      self.status(manager, "mgrbound")?.state == "running"
    }
    XCTAssertEqual(status(manager, "mgrbound")?.activation, "resident")
    XCTAssertEqual(fixture.spawnCount(), 1)
  }

  // MARK: - prewarm

  /// Once startup settles, the manager spawns the on-demand plugins whose
  /// command a configured mapping runs, and only those; a reconcile that maps
  /// another command warms that plugin too.
  func testReconcileWarmsMappedCommandPluginsOnceStartupSettles() throws {
    let previousDelay = PluginManager.prewarmDelayMs
    PluginManager.prewarmDelayMs = 100
    defer { PluginManager.prewarmDelayMs = previousDelay }
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-mgr-prewarm-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    func commandFixture(_ id: String) throws -> PluginFixtureKit.Fixture {
      try PluginFixtureKit.make(
        id: id,
        manifest: PluginFixtureKit.manifest(
          id: id,
          extra: #""commands": [{ "command": ""# + id
            + #"", "subcommand": "go", "description": "x" }]"#),
        script: PluginFixtureKit.script(),
        baseDataDir: base)
    }
    let mapped = try commandFixture("mgrmapped")
    let unmapped = try commandFixture("mgrunmapped")
    defer {
      mapped.cleanup()
      unmapped.cleanup()
    }
    func mapping(_ key: String, _ command: String) -> ModeMapping {
      ModeMapping(
        key: key,
        action: .flashCommand(.pluginCommand(command: command, subcommand: "go", args: [])))
    }
    let manager = PluginManager(baseDataDir: base)
    defer { manager.stop() }
    var config = testConfig(
      thirdParty: ["file:\(mapped.root.path)", "file:\(unmapped.root.path)"])
    config.mode.normal.append(mapping("<leader>m", "mgrmapped"))
    manager.start(config: config)
    waitUntilTrue("mapped plugin warmed without a command") {
      self.status(manager, "mgrmapped")?.state == "running"
    }
    XCTAssertEqual(status(manager, "mgrmapped")?.activation, "on_demand")
    settleRunLoop(0.3)
    XCTAssertEqual(unmapped.spawnCount(), 0, "nothing maps it: it waits for its first command")
    XCTAssertEqual(status(manager, "mgrunmapped")?.state, "stopped")

    config.mode.hyper.append(mapping("u", "mgrunmapped"))
    manager.updateConfig(config)
    waitUntilTrue("newly mapped plugin warmed") {
      self.status(manager, "mgrunmapped")?.state == "running"
    }
    XCTAssertEqual(mapped.spawnCount(), 1)
    XCTAssertEqual(unmapped.spawnCount(), 1)
  }

  // MARK: - bangs

  /// A bang is typed in the flashlight, whatever app is focused: an owner
  /// scoped to its apps (browsers' `!fh`) still lists, resolves and swaps
  /// the pool to its named source from Terminal.
  func testBangsOfAnAppScopedPluginResolveInAnyApp() throws {
    let fixture = try PluginFixtureKit.make(
      id: "scopedbang",
      manifest: PluginFixtureKit.manifest(
        id: "scopedbang",
        extra: """
          "only_bundle_ids": ["org.mozilla.firefox"],
          "sources": [{ "name": "scopedbang.rows", "type": "rows", "kind": "default", "priority": "normal" }],
          "bangs": [{ "token": "sb", "description": "scoped bang", "source": "scopedbang.rows" }]
          """),
      script: PluginFixtureKit.script())
    defer { fixture.cleanup() }
    let manager = PluginManager(baseDataDir: fixture.baseDataDir)
    defer { manager.stop() }
    manager.start(config: testConfig(thirdParty: ["file:\(fixture.root.path)"]))
    let terminal = PluginSelectorContext(bundleID: "com.apple.Terminal")
    waitUntilTrue("bang published") {
      manager.shebangCandidates(in: terminal).contains { $0.title == "!sb" }
    }
    XCTAssertEqual(manager.shebangCandidateSource(token: "sb", in: terminal), "scopedbang.rows")
    let performed = expectation(description: "bang dispatched to its owner")
    XCTAssertTrue(
      manager.invokeShebang(token: "sb", query: "hello", in: terminal) { ok, _, _, _ in
        XCTAssertTrue(ok)
        performed.fulfill()
      })
    wait(for: [performed], timeout: 10)
  }

  /// A command or bang perform carries the command, its subcommand and the
  /// whitespace-split args, and nothing else.
  func testCommandAndBangPerformsCarryOnlyTheirWordsAndArgs() throws {
    let fixture = try PluginFixtureKit.make(
      id: "wireperform",
      manifest: PluginFixtureKit.manifest(
        id: "wireperform",
        extra: Self.residentSurfaces
          + """
          ,
          "commands": [{ "command": "wired", "subcommand": "echo", "description": "test" }],
          "bangs": [{ "token": "wb", "description": "test bang" }]
          """),
      script: PluginFixtureKit.script(
        onPerform: #"printf '%s\n' "$line" >> "$D/performs"; "#
          + PluginFixtureKit.performOK))
    defer { fixture.cleanup() }
    let manager = PluginManager(baseDataDir: fixture.baseDataDir)
    defer { manager.stop() }
    manager.start(config: testConfig(thirdParty: ["file:\(fixture.root.path)"]))
    waitUntilTrue("plugin running") {
      self.status(manager, fixture.pluginID)?.state == "running"
    }
    let performed = expectation(description: "both performs answered")
    performed.expectedFulfillmentCount = 2
    XCTAssertTrue(
      manager.invoke(command: "wired", subcommand: "echo", args: ["a", "b"]) { ok, _, _, _ in
        XCTAssertTrue(ok)
        performed.fulfill()
      })
    XCTAssertTrue(
      manager.invokeShebang(token: "wb", query: "hello  world") { ok, _, _, _ in
        XCTAssertTrue(ok)
        performed.fulfill()
      })
    wait(for: [performed], timeout: 15)
    let lines = try String(
      contentsOf: fixture.dataDir.appendingPathComponent("performs"), encoding: .utf8
    ).split(separator: "\n")
    let params = try lines.map { line -> [String: Any] in
      let frame = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
      return try XCTUnwrap(frame["params"] as? [String: Any])
    }
    XCTAssertEqual(params.count, 2)
    for perform in params {
      XCTAssertEqual(Set(perform.keys), ["kind", "command", "subcommand", "args"])
    }
    let command = try XCTUnwrap(params.first { $0["subcommand"] as? String == "echo" })
    XCTAssertEqual(command["command"] as? String, "wired")
    XCTAssertEqual(command["args"] as? [String], ["a", "b"])
    let bang = try XCTUnwrap(params.first { $0["subcommand"] as? String == "wb" })
    XCTAssertEqual(bang["command"] as? String, fixture.pluginID)
    XCTAssertEqual(bang["args"] as? [String], ["hello", "world"])
  }

  // MARK: - bindings

  func testOwnTextEditingChangesNotifyOnceAfterPublication() throws {
    let previous = OwnTextEditingApps.declared.all
    OwnTextEditingApps.declared.declare([])
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-mgr-text-policy-\(UUID().uuidString)")
    let root = base.appendingPathComponent("editing")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try """
    {
      "id": "editing", "name": "Editing", "version": "1.0.0",
      "description": "Text policy fixture",
      "own_text_editing": ["com.example.editor"]
    }
    """.write(to: root.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    let manager = PluginManager(baseDataDir: base)
    defer {
      manager.onOwnTextEditingAppsChanged = nil
      manager.stop()
      OwnTextEditingApps.declared.declare(previous)
    }
    var snapshots: [Set<String>] = []
    var publications = 0
    manager.onOwnTextEditingAppsChanged = {
      XCTAssertTrue(Thread.isMainThread)
      snapshots.append(OwnTextEditingApps.declared.all)
    }
    manager.onStateChanged = { publications += 1 }
    let config = testConfig(thirdParty: ["file:\(root.path)"])
    manager.start(config: config)
    waitUntilTrue("first publication") { publications >= 1 }
    XCTAssertEqual(snapshots, [["com.example.editor"]])

    manager.updateConfig(config)
    waitUntilTrue("unchanged publication") { publications >= 2 }
    XCTAssertEqual(snapshots, [["com.example.editor"]], "unchanged declarations do not notify")

    var disabled = config
    disabled.plugins.disabled.insert("editing")
    manager.updateConfig(disabled)
    waitUntilTrue("removed publication") { publications >= 3 }
    XCTAssertEqual(snapshots, [["com.example.editor"], []])
  }

  /// A bundle's own binding beats a plugin-wide one across plugins; an
  /// app-specific chord marks the emulator as binding it. The emulator
  /// declarations come from an on-demand fixture (the bundled terminals
  /// plugin runs tmux, which no reconcile here may spawn).
  func testCommandBindingsResolvePerAppAcrossPlugins() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-mgr-bindings-\(UUID().uuidString)")
    let root = base.appendingPathComponent("wide")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try """
    {
      "id": "wide",
      "name": "Wide",
      "version": "1.0.0",
      "description": "Plugin-wide chords",
      "only_bundle_ids": ["com.example.app", "com.apple.MobileSMS"],
      "bindings": { "tab next": { "": "cmd+option+right" } }
    }
    """.write(
      to: root.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    let emulators = try PluginFixtureKit.make(
      id: "emulators",
      manifest: PluginFixtureKit.manifest(
        id: "emulators",
        extra: """
          "terminal_emulators": ["com.mitchellh.ghostty", "org.alacritty"],
          "own_text_editing": ["com.example.editor"],
          "bindings": {
            "pane next": { "com.mitchellh.ghostty": "cmd+]" },
            "pane previous": { "com.mitchellh.ghostty": "cmd+[" }
          }
          """),
      script: PluginFixtureKit.script(),
      baseDataDir: base)
    defer { emulators.cleanup() }
    let manager = PluginManager(baseDataDir: base)
    defer { manager.stop() }
    var config = testConfig(thirdParty: ["file:\(root.path)", "file:\(emulators.root.path)"])
    config.plugins.disabled.subtract(["defaults"])
    manager.start(config: config)

    func chord(_ key: String, _ bundle: String) -> CommandBinding? {
      manager.commandBinding(
        CommandBindingKey(key)!, in: PluginSelectorContext(bundleID: bundle))
    }
    func parsed(_ hotkey: String) throws -> CommandBinding {
      .chords([try XCTUnwrap(HotkeySyntax.parse(hotkey: hotkey))])
    }
    waitUntilTrue("manifests published") { chord("tab next", "com.example.app") != nil }
    XCTAssertEqual(chord("tab next", "com.example.app"), try parsed("cmd+option+right"))
    XCTAssertEqual(
      chord("tab next", "com.apple.MobileSMS"), try parsed("ctrl+tab"),
      "Messages' own entry in defaults beats the other plugin's plugin-wide chord")
    XCTAssertEqual(
      chord("tab next", "com.example.elsewhere"), try parsed("cmd+shift+]"),
      "outside its selector, the defaults convention applies")
    XCTAssertNil(chord("tab last", "com.example.app"))
    XCTAssertEqual(
      chord("history back", "com.todesktop.230313mzl4w4u92"), try parsed("ctrl+-"),
      "editors go back with their own chord, not the outdenting Cmd-[")
    XCTAssertEqual(chord("history forward", "com.apple.dt.Xcode"), try parsed("ctrl+cmd+right"))
    XCTAssertEqual(
      chord("history back", "com.apple.Notes"), CommandBinding.unbound,
      "apps without history send nothing")
    XCTAssertEqual(
      chord("history back", "com.apple.Safari"), try parsed("cmd+["), "the defaults convention")

    let bracket = try XCTUnwrap(HotkeySyntax.parse(hotkey: "cmd+]"))
    XCTAssertTrue(
      manager.declaresBinding(
        key: bracket.keyCode, flags: bracket.eventFlags,
        in: PluginSelectorContext(bundleID: "com.mitchellh.ghostty")))
    XCTAssertFalse(
      manager.declaresBinding(
        key: bracket.keyCode, flags: bracket.eventFlags,
        in: PluginSelectorContext(bundleID: "org.alacritty")))
    XCTAssertTrue(
      TerminalEmulators.contains("org.alacritty"), "publishing declares the terminals plugin's list"
    )
    XCTAssertFalse(TerminalEmulators.contains("com.example.app"))
    XCTAssertTrue(
      OwnTextEditingApps.contains("com.example.editor")
        && OwnTextEditingApps.contains(
          "com.microsoft.VSCode"),
      "own_text_editing is the union of every plugin's list, the defaults plugin's included")
    XCTAssertFalse(OwnTextEditingApps.contains("com.example.app"))
  }

  /// A core-topic `commands[]` entry is a claim on the source chain, never a
  /// plugin command: it registers for neither dispatch nor completion, and
  /// a mapping running it warms nothing.
  func testCoreCommandEntriesNeverEnterDispatchOrCompletion() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-mgr-core-commands-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    let fixture = try PluginFixtureKit.make(
      id: "split",
      manifest: PluginFixtureKit.manifest(
        id: "split",
        extra: """
          "commands": [
            { "command": "split", "subcommand": "run", "description": "Run" },
            { "command": "tab", "subcommand": "close" }
          ]
          """),
      script: PluginFixtureKit.script(),
      baseDataDir: base)
    defer { fixture.cleanup() }
    let manager = PluginManager(baseDataDir: base)
    defer { manager.stop() }
    manager.start(config: testConfig(thirdParty: ["file:\(fixture.root.path)"]))
    waitUntilTrue("manifest published") {
      manager.commandRegistrations().contains { $0.command == "split" }
    }
    let registered = manager.commandRegistrations().map { "\($0.command) \($0.subcommand)" }
    XCTAssertTrue(registered.contains("split run"))
    XCTAssertFalse(registered.contains("tab close"), "\(registered)")
    XCTAssertFalse(manager.invoke(command: "tab", subcommand: "close", args: []))
    XCTAssertEqual(
      manager.pluginStatuses().first { $0.id == "split" }?.commands.map(\.subcommand), ["run"])
    XCTAssertEqual(
      PluginWarmPolicy.warmPluginIDs(
        references: [.init(command: "tab", subcommand: "close")],
        commands: ["split": manager.pluginStatuses().first { $0.id == "split" }?.commands ?? []]),
      [])
  }

  // MARK: - reloadAll

  func testReloadAllRestartsRunningPluginsWithoutBlockingTheMainThread() throws {
    let fixture = try residentFixture(id: "mgrreload")
    defer { fixture.cleanup() }
    let manager = PluginManager(baseDataDir: fixture.baseDataDir)
    defer { manager.stop() }
    manager.start(config: testConfig(thirdParty: ["file:\(fixture.root.path)"]))
    waitUntilTrue("running before reload") { self.status(manager, "mgrreload")?.state == "running" }
    XCTAssertEqual(fixture.spawnCount(), 1)

    // Called from the main thread; returns synchronously with the affected
    // ids while the restarts run asynchronously off the snapshot.
    let started = CFAbsoluteTimeGetCurrent()
    let ids = manager.reloadAll()
    XCTAssertLessThan(
      CFAbsoluteTimeGetCurrent() - started, 0.5,
      "reloadAll must never block the main thread on the manager queue")
    XCTAssertTrue(ids.contains("mgrreload"))
    waitUntilTrue("respawned by reloadAll") { fixture.spawnCount() >= 2 }
    waitUntilTrue("running after reload") { self.status(manager, "mgrreload")?.state == "running" }
  }

  // MARK: - github: refs (local git fixture, no network)

  func testExplicitReloadReconcilesChangedManifestAndKeepsLastGoodOnInvalidReplacement() throws {
    let fixture = try residentFixture(id: "definitionreload")
    defer { fixture.cleanup() }
    let manager = PluginManager(baseDataDir: fixture.baseDataDir)
    defer { manager.stop() }
    manager.start(config: testConfig(thirdParty: ["file:\(fixture.root.path)"]))
    waitUntilTrue("initial definition running") {
      self.status(manager, fixture.pluginID)?.state == "running"
    }
    let manifestURL = fixture.root.appendingPathComponent("manifest.json")
    let replacement = PluginFixtureKit.manifest(
      id: fixture.pluginID,
      extra:
        Self.residentSurfaces
        + #","commands":[{"command":"newcommand","subcommand":"ping","description":"test"}]"#
    ).replacingOccurrences(of: "1.0.0", with: "2.0.0")
    try replacement.write(to: manifestURL, atomically: true, encoding: .utf8)
    manager.reloadAll()
    waitUntilTrue("replacement definition registered") {
      self.status(manager, fixture.pluginID)?.version == "2.0.0"
    }
    XCTAssertEqual(status(manager, fixture.pluginID)?.commandCount, 1)
    waitUntilTrue("replacement running") {
      self.status(manager, fixture.pluginID)?.state == "running"
    }
    let replacementPID = status(manager, fixture.pluginID)?.pid
    try "{invalid".write(to: manifestURL, atomically: true, encoding: .utf8)
    manager.reloadAll()
    waitUntilTrue("invalid replacement reported") {
      self.status(manager, fixture.pluginID)?.lastError?.contains("definition") == true
    }
    XCTAssertEqual(status(manager, fixture.pluginID)?.version, "2.0.0")
    XCTAssertEqual(status(manager, fixture.pluginID)?.pid, replacementPID)
    XCTAssertEqual(manager.pluginStatuses().filter { $0.id == fixture.pluginID }.count, 1)
  }

  /// A changed definition's requests route to its replacement from the
  /// moment it is reconciled, while the old child is still being stopped: a
  /// command typed right after saving the config waits for the replacement
  /// instead of failing on a process that is going away.
  func testReconcileRoutesToTheReplacementWhileTheOldChildStops() throws {
    // Answers requests while stdin is open, then lingers past EOF and
    // ignores SIGTERM, so stopping the old child takes the full escalation.
    let script = """
      #!/bin/sh
      D="$FLASH_PLUGIN_DATA_DIR"
      printf 'spawn\\n' >> "$D/spawns"
      trap '' TERM
      while IFS= read -r line; do
        id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
        case "$line" in
        *'"method":"initialize"'*)
          \(PluginFixtureKit.initializeOK)
          ;;
        *'"method":"perform"'*)
          \(PluginFixtureKit.performOK)
          ;;
        esac
      done
      while :; do sleep 0.05; done
      """
    let fixture = try PluginFixtureKit.make(
      id: "reloadrouting",
      manifest: PluginFixtureKit.manifest(
        id: "reloadrouting",
        extra: Self.residentSurfaces
          + #","commands":[{"command":"routed","subcommand":"ping","description":"test"}]"#),
      script: script)
    defer { fixture.cleanup() }
    let manager = PluginManager(baseDataDir: fixture.baseDataDir)
    defer { manager.stop() }
    var config = testConfig(thirdParty: ["file:\(fixture.root.path)"])
    manager.start(config: config)
    waitUntilTrue("first definition running") {
      self.status(manager, fixture.pluginID)?.state == "running"
    }
    let firstPID = try XCTUnwrap(status(manager, fixture.pluginID)?.pid)

    config.plugins.settings[fixture.pluginID] = ["generation": .string("2")]
    manager.updateConfig(config)
    // The reconcile has reached this definition once its row stops reading
    // "running": the old child is being stopped, and lingers for ~1.5 s.
    waitUntilTrue("reconcile reached the definition") {
      self.status(manager, fixture.pluginID)?.state != "running"
    }
    XCTAssertEqual(kill(pid_t(firstPID), 0), 0, "the old child is still alive")
    let answered = expectation(description: "command answered")
    var handled: Bool?
    XCTAssertTrue(
      manager.invoke(command: "routed", subcommand: "ping", args: []) {
        ok, _, _, _ in
        handled = ok
        answered.fulfill()
      })
    wait(for: [answered], timeout: 15)
    XCTAssertEqual(handled, true, "the replacement answered once it ran")
    waitUntilTrue("replacement running") {
      let row = self.status(manager, fixture.pluginID)
      return row?.state == "running" && row?.pid != firstPID
    }
    waitUntilTrue("old child killed") { kill(pid_t(firstPID), 0) != 0 }
  }

  func testManifestFileChangeReconcilesWithoutExplicitReload() throws {
    let fixture = try residentFixture(id: "definitionwatch")
    defer { fixture.cleanup() }
    let manager = PluginManager(baseDataDir: fixture.baseDataDir)
    defer { manager.stop() }
    var config = testConfig(thirdParty: ["file:\(fixture.root.path)"])
    config.plugins.watchingEnabled = true
    manager.start(config: config)
    waitUntilTrue("watched definition running") {
      self.status(manager, fixture.pluginID)?.state == "running"
    }
    let replacement = PluginFixtureKit.manifest(id: fixture.pluginID).replacingOccurrences(
      of: "1.0.0", with: "2.0.0")
    try replacement.write(
      to: fixture.root.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    waitUntilTrue("manifest watcher reconciles definition") {
      self.status(manager, fixture.pluginID)?.version == "2.0.0"
    }
  }

  func testGithubMaterializationEnforcesTheCommitPin() throws {
    let fm = FileManager.default
    let temp = fm.temporaryDirectory
      .appendingPathComponent("flash-mgr-github-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: temp) }
    let work = temp.appendingPathComponent("work")
    try fm.createDirectory(at: work, withIntermediateDirectories: true)
    try PluginFixtureKit.manifest(id: "ghfix").write(
      to: work.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    try runGit(["init", "-q"], in: work)
    try runGit(["add", "manifest.json"], in: work)
    try runGit(
      [
        "-c", "user.name=fixture", "-c", "user.email=fixture@test", "-c", "commit.gpgsign=false",
        "commit", "-q", "-m", "init",
      ], in: work)
    let sha = try runGit(["rev-parse", "HEAD"], in: work)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertEqual(sha.count, 40)
    let bare = temp.appendingPathComponent("upstream.git")
    try runGit(["clone", "-q", "--bare", work.path, bare.path], in: temp)
    // The materializer fetches the pinned SHA directly; local transports
    // need the explicit want-any-sha opt-in a hosting forge enables.
    try runGit(["config", "uploadpack.allowAnySHA1InWant", "true"], in: bare)

    let originalBuilder = PluginRepository.remoteURLBuilder
    defer { PluginRepository.remoteURLBuilder = originalBuilder }
    PluginRepository.remoteURLBuilder = { _, _ in bare.path }
    let repository = PluginRepository(baseDataDir: temp.appendingPathComponent("data"))

    // Correct pinned SHA: checkout succeeds and lands under the SHA-stamped root.
    let ref = try XCTUnwrap(PluginReference.parse("github:owner/repo@\(sha)"))
    let materialized = try XCTUnwrap(repository.materialize(ref))
    XCTAssertTrue(
      fm.fileExists(atPath: materialized.root.appendingPathComponent("manifest.json").path))
    XCTAssertTrue(materialized.root.path.contains("github/owner-repo-\(sha)"))
    XCTAssertEqual(materialized.origin.label, "github:owner/repo@\(sha)")

    // A populated, pin-verified root short-circuits the network entirely
    // (previously vetted plugins keep working offline).
    PluginRepository.remoteURLBuilder = { _, _ in "/nonexistent/upstream.git" }
    XCTAssertNotNil(repository.materialize(ref), "cached checkout must not refetch")

    // A wrong pinned SHA (valid repo, nonexistent commit) is refused.
    PluginRepository.remoteURLBuilder = { _, _ in bare.path }
    let wrongSHA = String(sha.dropLast()) + (sha.hasSuffix("0") ? "1" : "0")
    let wrongRef = try XCTUnwrap(PluginReference.parse("github:owner/repo@\(wrongSHA)"))
    XCTAssertNil(
      repository.materialize(wrongRef),
      "a mismatched commit pin must refuse the checkout")
  }

  // MARK: - Config-generation race

  func testRestartUsesTheNewestDesiredConfiguration() throws {
    var state = PluginManager.DesiredState()
    let initial = try XCTUnwrap(
      state.request(.configure(testConfig(thirdParty: [], disabled: ["old"]))))
    let changed = try XCTUnwrap(
      state.request(.configure(testConfig(thirdParty: [], disabled: ["new"]))))
    let restart = try XCTUnwrap(state.request(.restart(["plugin"])))

    XCTAssertGreaterThan(restart.generation, changed.generation)
    XCTAssertTrue(restart.config.plugins.disabled.contains("new"))
    XCTAssertFalse(restart.config.plugins.disabled.contains("old"))
    XCTAssertNil(state.takeRestarts(for: initial.generation))
    XCTAssertNil(state.takeRestarts(for: changed.generation))
    XCTAssertEqual(state.takeRestarts(for: restart.generation), ["plugin"])
  }

  func testStopRevokesDesiredConfigurationAndRejectsRestarts() throws {
    var state = PluginManager.DesiredState()
    XCTAssertNil(state.request(.restart(["before-start"])))
    _ = state.request(.configure(testConfig(thirdParty: [])))
    let restart = try XCTUnwrap(state.request(.restart(["before-stop"])))

    state.stop()

    XCTAssertNil(state.config)
    XCTAssertFalse(state.isCurrent(restart.generation))
    XCTAssertNil(state.request(.restart(["after-stop"])))
    XCTAssertNil(state.takeRestarts(for: restart.generation))
    let resumed = try XCTUnwrap(state.request(.configure(testConfig(thirdParty: []))))
    XCTAssertGreaterThan(resumed.generation, restart.generation)
    XCTAssertEqual(state.takeRestarts(for: resumed.generation), [])
  }

  func testSupersededReconciliationCannotConsumePendingRestarts() throws {
    var state = PluginManager.DesiredState()
    _ = state.request(.configure(testConfig(thirdParty: [])))
    let first = try XCTUnwrap(state.request(.restart(["first"])))
    _ = state.request(.configure(testConfig(thirdParty: [], disabled: ["updated"])))
    let second = try XCTUnwrap(state.request(.restart(["second"])))

    XCTAssertNil(state.takeRestarts(for: first.generation))
    XCTAssertEqual(state.takeRestarts(for: second.generation), ["first", "second"])
    let next = try XCTUnwrap(state.request(.restart(["next"])))
    XCTAssertEqual(state.takeRestarts(for: next.generation), ["next"])
  }

  func testStaleConfigGenerationIsDroppedWholesale() throws {
    // Two rapid reconciles: the older config is still materializing (slowed
    // through the remote-URL seam) when the newer one bumps the generation.
    // Pinned behavior: the superseded reload is dropped WHOLE — its plugins
    // never spawn, nothing from it clobbers the newer state.
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-mgr-race-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let stale = try residentFixture(id: "mgrstale", baseDataDir: base)
    let fresh = try residentFixture(id: "mgrfresh", baseDataDir: base)
    defer {
      stale.cleanup()
      fresh.cleanup()
    }
    let originalBuilder = PluginRepository.remoteURLBuilder
    defer { PluginRepository.remoteURLBuilder = originalBuilder }
    PluginRepository.remoteURLBuilder = { _, _ in
      // Keep config A inside its materialize phase until config B has
      // superseded it, then fail the fetch fast.
      Thread.sleep(forTimeInterval: 0.4)
      return "/nonexistent/slow.git"
    }
    let manager = PluginManager(baseDataDir: base)
    defer { manager.stop() }
    let slowSHA = String(repeating: "a", count: 40)
    manager.start(
      config: testConfig(
        thirdParty: ["github:slow/slow@\(slowSHA)", "file:\(stale.root.path)"]))
    manager.updateConfig(testConfig(thirdParty: ["file:\(fresh.root.path)"]))

    waitUntilTrue("newer config applies") { self.status(manager, "mgrfresh")?.state == "running" }
    XCTAssertNil(status(manager, "mgrstale"), "the stale generation must not land")
    XCTAssertEqual(stale.spawnCount(), 0, "the stale config's plugin must never spawn")
    // And it stays that way once the stale pipeline has fully drained.
    settleRunLoop(0.6)
    XCTAssertNil(status(manager, "mgrstale"))
    XCTAssertEqual(stale.spawnCount(), 0)
    XCTAssertEqual(status(manager, "mgrfresh")?.state, "running")
  }

  // MARK: - git helper

  @discardableResult
  private func runGit(_ arguments: [String], in directory: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = directory
    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw PluginError.failure("git \(arguments.joined(separator: " ")) failed")
    }
    return String(
      data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
  }
}
