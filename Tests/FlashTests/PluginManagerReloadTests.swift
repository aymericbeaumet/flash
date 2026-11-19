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
      manager.bangCandidates(in: terminal).contains { $0.title == "!sb" }
    }
    XCTAssertEqual(manager.bangCandidateSource(token: "sb", in: terminal), "scopedbang.rows")
    let performed = expectation(description: "bang dispatched to its owner")
    XCTAssertTrue(
      manager.invokeBang(token: "sb", query: "hello", in: terminal) { result in
        XCTAssertTrue(result.ok)
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
      manager.invoke(command: "wired", subcommand: "echo", args: ["a", "b"]) { result in
        XCTAssertTrue(result.ok)
        performed.fulfill()
      })
    XCTAssertTrue(
      manager.invokeBang(token: "wb", query: "hello  world") { result in
        XCTAssertTrue(result.ok)
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

  /// A NORMAL count before a plugin command's key is one `perform` carrying
  /// the count, never that many performs.
  func testACountedCommandIsOnePerformCarryingItsCount() throws {
    let fixture = try PluginFixtureKit.make(
      id: "countperform",
      manifest: PluginFixtureKit.manifest(
        id: "countperform",
        extra: Self.residentSurfaces
          + """
          ,
          "commands": [{ "command": "counted", "subcommand": "step", "description": "test" }]
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
    let performed = expectation(description: "the command answered")
    XCTAssertTrue(
      manager.invoke(command: "counted", subcommand: "step", args: [], count: 5) { result in
        XCTAssertTrue(result.ok)
        performed.fulfill()
      })
    wait(for: [performed], timeout: 15)
    let lines = try String(
      contentsOf: fixture.dataDir.appendingPathComponent("performs"), encoding: .utf8
    ).split(separator: "\n")
    XCTAssertEqual(lines.count, 1, "five steps are one request")
    let frame = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(try XCTUnwrap(lines.first).utf8)) as? [String: Any])
    let params = try XCTUnwrap(frame["params"] as? [String: Any])
    XCTAssertEqual(Set(params.keys), ["kind", "command", "subcommand", "args", "count"])
    XCTAssertEqual(params["count"] as? Int, 5)
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
    XCTAssertEqual(
      BrowserEngines.declared.table.engine(of: "com.apple.Safari"), .webkit,
      "publishing declares the defaults plugin's browser engines")
    XCTAssertNil(BrowserEngines.declared.table.engine(of: "com.example.app"))
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
          + #","commands":[{"command":"routed","subcommand":"ping","description":"test"}]"#
          // A setting reaches the plugin, and so changes its definition, only
          // when its manifest declares it.
          + #","settings":{"generation":{"type":"string","description":"test"}}"#),
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
      manager.invoke(command: "routed", subcommand: "ping", args: []) { result in
        handled = result.ok
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

  // MARK: - live sources

  /// A plugin's live sources reach the flashlight through its adapter: kept
  /// out of the warm fan-outs, listed for the scope that names their type,
  /// and pulled from cold with one `search`. A `per_scope` source is asked
  /// without the text, and a row it answered resolves like a catalog row.
  func testALivePluginSourceIsPulledOnlyForAQueryScopedToIt() throws {
    let fixture = try PluginFixtureKit.make(
      id: "mgrlive",
      manifest: PluginFixtureKit.manifest(
        id: "mgrlive",
        extra:
          #""sources": [{ "name": "mgrlive.items", "type": "liveitems", "live": "per_scope" }]"#
      ),
      script: PluginFixtureKit.script(
        onPerform: #"printf '%s\n' "$line" >> "$D/performs"; "# + PluginFixtureKit.performOK,
        onSearch: """
          printf '%s\\n' "$line" >> "$D/searches"
          printf '{"id":%s,"result":{"ok":true,"rows":[{"source":"mgrlive.items","title":"Lock screen"}]}}\\n' "$id"
          """))
    defer { fixture.cleanup() }
    let manager = PluginManager(baseDataDir: fixture.baseDataDir)
    defer { manager.stop() }
    manager.start(config: testConfig(thirdParty: ["file:\(fixture.root.path)"]))
    waitUntilTrue("registered") { self.status(manager, "mgrlive")?.activation == "on_demand" }

    let registry = SourceRegistry(
      descriptors: [], runningApplications: [], pluginSourcesProvider: { manager.sources })
    let live = registry.liveCandidateSources(matching: .type("liveitems"))
    XCTAssertEqual(live.map(\.identifier), ["plugin:mgrlive"])
    XCTAssertEqual(
      registry.liveCandidateSources(matching: .source("mgrlive.items")).map(\.identifier),
      ["plugin:mgrlive"], "a bang bound to the source pulls it too")
    XCTAssertTrue(registry.liveCandidateSources(matching: .type("tabs")).isEmpty)
    XCTAssertTrue(
      registry.nonLocationCandidateSources(matching: .type("liveitems")).isEmpty,
      "a live source is no warm catalog")
    XCTAssertEqual(registry.resourceTypesBySource()["mgrlive.items"], "liveitems")
    let source = try XCTUnwrap(live.first)
    XCTAssertTrue(source.servesLiveCandidates)
    XCTAssertFalse(source.liveCandidatesDependOnText, "per_scope: pulled once per scope")
    XCTAssertEqual(AppDelegate.liveQueryText("lo", sources: [source]), "")
    XCTAssertEqual(source.candidates(in: registry.environment, scope: .all).count, 0)
    XCTAssertEqual(fixture.spawnCount(), 0, "nothing ran before a query named the type")

    let answered = expectation(description: "live rows")
    var rows: [Candidate] = []
    source.liveCandidates(matching: "lo", in: registry.environment, scope: .all) {
      XCTAssertTrue(Thread.isMainThread)
      rows = $0
      answered.fulfill()
    }
    wait(for: [answered], timeout: 8)
    XCTAssertEqual(rows.map(\.title), ["Lock screen"])
    XCTAssertEqual(fixture.spawnCount(), 1, "the first scoped query spawned it")
    let sent = try String(
      contentsOf: fixture.dataDir.appendingPathComponent("searches"), encoding: .utf8)
    XCTAssertTrue(sent.contains(#""query":"""#), "a per_scope source gets no text: \(sent)")
    XCTAssertEqual(manager.catalogStore.publishedPluginIDs(), [])

    let resolved = expectation(description: "row resolved")
    registry.resolveCandidate(CandidateFinder.prepare(rows)[0]) { resolution in
      XCTAssertTrue(resolution.didResolve)
      resolved.fulfill()
    }
    wait(for: [resolved], timeout: 8)
    let performed = try String(
      contentsOf: fixture.dataDir.appendingPathComponent("performs"), encoding: .utf8)
    XCTAssertTrue(performed.contains(#""kind":"resolve""#), performed)
    XCTAssertTrue(performed.contains(#""title":"Lock screen""#), performed)
    XCTAssertTrue(performed.contains(#""source":"mgrlive.items""#), performed)
  }

  // MARK: - destructive host actions

  /// What keeps a faulty plugin from restarting the Mac unprompted, end to
  /// end over the wire: the same `host.system_action` request is refused
  /// when the plugin sends it at startup or inside a perform the user was
  /// not asked about, and honoured once inside a perform the user
  /// confirmed. The mechanisms are a stub; nothing here reaches macOS.
  func testADestructiveHostActionNeedsAConfirmedPerformInFlight() throws {
    let restart = #"{"id":%s,"method":"host.system_action","params":{"action":"restart"}}"#
    let ask = """
      printf '\(restart)\\n' "$n"
      n=$((n + 1))
      while IFS= read -r reply; do
        case "$reply" in *'"result"'*) break ;; esac
      done
      printf '%s\\n' "$reply" >> "$D/replies"
      """
    let fixture = try PluginFixtureKit.make(
      id: "mgrgate",
      manifest: PluginFixtureKit.manifest(
        id: "mgrgate",
        extra: """
          "capabilities": ["system_actions"],
          "listen": ["core:config.changed"],
          "commands": [{ "command": "mgrgate", "subcommand": "go", "description": "x" }]
          """),
      script: PluginFixtureKit.script(
        prologue: "n=1",
        onInitialize: PluginFixtureKit.initializeOK + "\n" + ask,
        onPerform: ask + "\n" + ask + "\n" + PluginFixtureKit.performOK))
    defer { fixture.cleanup() }
    let manager = PluginManager(baseDataDir: fixture.baseDataDir)
    defer { manager.stop() }
    let mechanisms = SystemActionStub()
    manager.hostRPC.systemActions = mechanisms
    manager.start(config: testConfig(thirdParty: ["file:\(fixture.root.path)"]))
    waitUntilTrue("running") { self.status(manager, "mgrgate")?.state == "running" }

    func replies() -> [NSDictionary] {
      let text =
        (try? String(
          contentsOf: fixture.dataDir.appendingPathComponent("replies"), encoding: .utf8)) ?? ""
      return text.split(separator: "\n").compactMap {
        (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["result"]
          as? NSDictionary
      }
    }
    func invoke(confirmed: Bool) {
      let answered = expectation(description: "perform")
      XCTAssertTrue(
        manager.invoke(command: "mgrgate", subcommand: "go", args: [], confirmed: confirmed) {
          XCTAssertTrue($0.ok)
          answered.fulfill()
        })
      wait(for: [answered], timeout: 15)
    }
    let refused: NSDictionary = ["ok": false, "error": "requires a perform the user confirmed"]
    let honoured: NSDictionary = ["ok": true]

    // Outside any perform, at startup: refused.
    waitUntilTrue("the startup request was answered") { replies().count == 1 }
    XCTAssertEqual(replies(), [refused])
    // Inside a perform the user was not asked about: refused, twice.
    invoke(confirmed: false)
    XCTAssertEqual(replies(), [refused, refused, refused])
    XCTAssertEqual(mechanisms.executions, [], "nothing was asked of macOS")

    // Inside a perform the user confirmed: honoured, once.
    invoke(confirmed: true)
    XCTAssertEqual(replies().suffix(2), [honoured, refused])
    XCTAssertEqual(
      mechanisms.executions,
      [.appleScript("tell application \"System Events\" to restart", timeout: 10)])

    // The confirmed perform was answered: its consent went with it.
    invoke(confirmed: false)
    XCTAssertEqual(replies().suffix(2), [refused, refused])
    XCTAssertEqual(mechanisms.executions.count, 1)
  }

  // MARK: - privacy prompts

  /// What keeps a plugin from raising macOS's Calendars prompt out of
  /// nowhere, end to end over the wire: the same `request_access` is refused
  /// when the plugin sends it at startup with nothing of its on a surface,
  /// and honoured inside one of its performs, or at startup once a status
  /// surface shows one of its segments. The calendar is a stub; nothing here
  /// reaches macOS.
  func testAPrivacyPromptNeedsTheUserToBeUsingThePlugin() throws {
    let request =
      #"{"id":%s,"method":"host.calendar_events","params":{"operation":"request_access"}}"#
    let ask = """
      printf '\(request)\\n' "$n"
      n=$((n + 1))
      while IFS= read -r reply; do
        case "$reply" in *'"result"'*) break ;; esac
      done
      printf '%s\\n' "$reply" >> "$D/replies"
      """
    // `listen` keeps the first one running with nothing of its shown, as a
    // mapped command keeps a status plugin warm.
    func fixture(_ id: String, surface: String) throws -> PluginFixtureKit.Fixture {
      try PluginFixtureKit.make(
        id: id,
        manifest: PluginFixtureKit.manifest(
          id: id,
          extra: """
            "capabilities": ["calendar_events"],
            \(surface),
            "commands": [{ "command": "\(id)", "subcommand": "go", "description": "x" }]
            """),
        script: PluginFixtureKit.script(
          prologue: "n=1",
          onInitialize: PluginFixtureKit.initializeOK + "\n" + ask,
          onPerform: ask + "\n" + PluginFixtureKit.performOK))
    }
    func replies(_ fixture: PluginFixtureKit.Fixture) -> [NSDictionary] {
      let text =
        (try? String(
          contentsOf: fixture.dataDir.appendingPathComponent("replies"), encoding: .utf8)) ?? ""
      return text.split(separator: "\n").compactMap {
        (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["result"]
          as? NSDictionary
      }
    }
    let refused: NSDictionary = [
      "ok": false, "error": "requires the user to be using the plugin",
    ]
    let granted: NSDictionary = ["ok": true, "access": "granted"]

    // Nothing of the plugin's is on a surface: its startup request is
    // refused, and the one its command makes is honoured.
    let quiet = try fixture("mgrprompt", surface: #""listen": ["core:config.changed"]"#)
    defer { quiet.cleanup() }
    let manager = PluginManager(baseDataDir: quiet.baseDataDir)
    defer { manager.stop() }
    let calendar = CalendarEventStub(access: .undetermined)
    manager.hostRPC.calendarEvents = HostCalendarEvents(
      provider: calendar, scheduler: PollScheduler(), changed: {})
    manager.start(config: testConfig(thirdParty: ["file:\(quiet.root.path)"]))
    waitUntilTrue("the startup request was answered") { replies(quiet).count == 1 }
    XCTAssertEqual(replies(quiet), [refused])
    XCTAssertEqual(calendar.asks, 0, "no prompt")
    let answered = expectation(description: "perform")
    XCTAssertTrue(
      manager.invoke(command: "mgrprompt", subcommand: "go", args: []) {
        XCTAssertTrue($0.ok)
        answered.fulfill()
      })
    wait(for: [answered], timeout: 15)
    XCTAssertEqual(replies(quiet), [refused, granted])
    XCTAssertEqual(calendar.asks, 1)

    // The configuration reads one of its segments, on the enabled bar or
    // in a text popup: that runs the plugin, and is not yet anyone looking.
    // Its startup request asks only once a surface shows the segment.
    func bar(_ id: String, _ root: URL) -> Config {
      var config = testConfig(thirdParty: ["file:\(root.path)"])
      config.statusBar.template = FlashStatusBarTemplate(
        template: "#{flash.plugin.\(id).next}",
        variables: [
          FlashStatusBarTemplateVariable(
            id: "statusbar.template.flash.plugin.\(id).next",
            token: "flash.plugin.\(id).next",
            source: .plugin(.statusSegment(pluginID: id, name: "next")))
        ])
      config.statusBar.enabled = true
      return config
    }
    for (id, isShown) in [("mgrread", false), ("mgrshown", true)] {
      let fixture = try fixture(id, surface: #""status": ["next"]"#)
      defer { fixture.cleanup() }
      let observing = PluginManager(baseDataDir: fixture.baseDataDir)
      defer { observing.stop() }
      let observedCalendar = CalendarEventStub(access: .undetermined, grants: false)
      observing.hostRPC.calendarEvents = HostCalendarEvents(
        provider: observedCalendar, scheduler: PollScheduler(), changed: {})
      // What the status controller reports: nothing while only a closed
      // popup or a covered widget reads the segment.
      observing.setShownStatusSegments(isShown ? ["\(id).next"] : [])
      observing.start(config: bar(id, fixture.root))
      waitUntilTrue("\(id): the startup request was answered") { replies(fixture).count == 1 }
      XCTAssertEqual(status(observing, id)?.activation, "resident", id)
      XCTAssertEqual(
        replies(fixture), [isShown ? ["ok": true, "access": "denied"] as NSDictionary : refused],
        id)
      XCTAssertEqual(observedCalendar.asks, isShown ? 1 : 0, id)
    }
  }

  /// A flashlight query scoped to a live source is the user using the
  /// plugin: a request for access made while its `search` is in flight is
  /// honoured, and the same request made once the search was answered is
  /// refused. The plugin listens to events, which feed its rows: nothing of
  /// it runs until the first query. Notes is a stub; nothing here reaches
  /// macOS.
  func testAPrivacyPromptIsHonouredWhileALiveSearchIsInFlight() throws {
    let request = #"{"id":%s,"method":"host.notes","params":{"operation":"request_access"}}"#
    let ask = """
      printf '\(request)\\n' "$n"
      n=$((n + 1))
      while IFS= read -r reply; do
        case "$reply" in *'"result"'*) break ;; esac
      done
      printf '%s\\n' "$reply" >> "$D/replies"
      """
    let rows = #"printf '{"id":%s,"result":{"ok":true,"rows":[]}}\n' "$id""#
    let fixture = try PluginFixtureKit.make(
      id: "mgrsearchprompt",
      manifest: PluginFixtureKit.manifest(
        id: "mgrsearchprompt",
        extra: """
          "capabilities": ["notes"],
          "listen": ["core:focus.changed", "core:session.opened"],
          "sources": [{ "name": "mgrsearchprompt.items", "type": "promptitems", "live": "per_scope" }]
          """),
      script: PluginFixtureKit.script(
        prologue: "n=1; s=0",
        // The first search is answered before it asks, the second after.
        onSearch: """
          s=$((s + 1))
          if [ "$s" = 1 ]; then
            \(rows)
            \(ask)
          else
            \(ask)
            \(rows)
          fi
          """))
    defer { fixture.cleanup() }
    func replies() -> [NSDictionary] {
      let text =
        (try? String(
          contentsOf: fixture.dataDir.appendingPathComponent("replies"), encoding: .utf8)) ?? ""
      return text.split(separator: "\n").compactMap {
        (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["result"]
          as? NSDictionary
      }
    }
    let manager = PluginManager(baseDataDir: fixture.baseDataDir)
    defer { manager.stop() }
    let notes = AppItemStub(access: .undetermined)
    manager.hostRPC.appItems[.notes] = AppItemStub.host(.notes, notes)
    manager.start(config: testConfig(thirdParty: ["file:\(fixture.root.path)"]))
    waitUntilTrue("registered") {
      self.status(manager, "mgrsearchprompt")?.activation == "on_demand"
    }
    XCTAssertTrue(manager.hasListener(for: .focusChanged))
    settleRunLoop(0.2)
    XCTAssertEqual(fixture.spawnCount(), 0, "events that feed live rows keep no process")

    let registry = SourceRegistry(
      descriptors: [], runningApplications: [], pluginSourcesProvider: { manager.sources })
    let source = try XCTUnwrap(
      registry.liveCandidateSources(matching: .type("promptitems")).first)
    func search() {
      let answered = expectation(description: "search")
      source.liveCandidates(matching: "", in: registry.environment, scope: .all) { _ in
        answered.fulfill()
      }
      wait(for: [answered], timeout: 8)
    }
    let refused: NSDictionary = [
      "ok": false, "error": "requires the user to be using the plugin",
    ]
    search()
    waitUntilTrue("the late request was answered") { replies().count == 1 }
    XCTAssertEqual(replies(), [refused])
    XCTAssertEqual(notes.asks, 0, "no prompt once the search was answered")

    search()
    XCTAssertEqual(replies(), [refused, ["ok": true, "access": "granted"] as NSDictionary])
    XCTAssertEqual(notes.asks, 1)
    XCTAssertEqual(fixture.spawnCount(), 1)
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
