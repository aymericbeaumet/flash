import AppKit
import FlashCore
import XCTest

@testable import flash

/// `docs/schema/inspector/state.schema.json` pins the inspector snapshot: the
/// snapshot a populated resident really builds validates against it, as does
/// each scoped rebuild; its sections are the ones the snapshot carries; and
/// the validator refuses what the schema forbids.
final class InspectorStateSchemaTests: XCTestCase {
  private static let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  private static let directory = root.appendingPathComponent("docs/schema/inspector")
  private static let schema = "state.schema.json"
  /// The sections a scoped change rebuilds alone (`wireInspectorChangeSources`).
  private static let scopedSections = AppDelegate.statusBarSections.union(["widgets"])
  /// Every loadable official manifest, as `PluginManagerReloadTests` finds them.
  private static let officialIDs: Set<String> = Set(
    PluginRepository.officialPluginRoots().compactMap {
      (try? PluginManifest.load(from: $0))?.id
    })

  private var validator: JSONSchemaValidator!
  /// The same schema requiring only the snapshot's time: what a scoped
  /// rebuild returns before the server merges it into the last snapshot.
  private var sectionValidator: JSONSchemaValidator!

  override func setUpWithError() throws {
    _ = NSApplication.shared
    validator = try JSONSchemaValidator(directory: Self.directory)
    var relaxed = try XCTUnwrap(validator.documents[Self.schema])
    relaxed["required"] = ["snapshot_at_unix_ms"]
    let scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-state-schema-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: scratch) }
    try JSONSerialization.data(withJSONObject: relaxed)
      .write(to: scratch.appendingPathComponent(Self.schema))
    sectionValidator = try JSONSchemaValidator(directory: scratch)
  }

  // MARK: - Fixtures

  /// `state` as the page reads it: through JSON, numbered as `DebugServer`
  /// numbers a snapshot it publishes.
  private func published(_ state: [String: Any], seq: Int? = 1) throws -> [String: Any] {
    var state = state
    if let seq { state["snapshot_seq"] = seq }
    let data = try JSONSerialization.data(withJSONObject: state)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func assertValid(
    _ state: [String: Any], _ what: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(
      validator.problems(state, against: Self.schema), [], what, file: file, line: line)
  }

  private func assertInvalid(
    _ state: [String: Any], _ what: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertFalse(
      validator.problems(state, against: Self.schema).isEmpty, what, file: file, line: line)
  }

  /// A delegate before launch wiring, with nothing to show: no overlay
  /// state, widget controller, plugins, hints or monitors.
  private func bareDelegate() -> AppDelegate {
    let delegate = AppDelegate()
    delegate.overlay = OverlayPanel()
    delegate.overlay.statusPopupController = StatusPopupController(
      terminals: delegate.overlay.statusTerminals, windowActionsEnabled: false)
    addTeardownBlock { delegate.overlay.statusTerminals.shutdown() }
    return delegate
  }

  /// A delegate with something in every section a test can fill without a
  /// launched app: a laid-out bar, a running popup, a widget window, hints,
  /// clipboard entries and a register, a value monitor and an event monitor
  /// whose run failed, and two plugins the delegate's own manager loaded:
  /// the bundled manifest-only `defaults` (bindings) and an on-demand fixture
  /// (commands and a help topic), neither of which spawns a process.
  private func populatedDelegate() throws -> AppDelegate {
    let delegate = bareDelegate()
    let fixture = try PluginFixtureKit.make(
      id: "schemacmd",
      manifest: PluginFixtureKit.manifest(
        id: "schemacmd",
        extra: """
          "commands": [
            {"command": "schemacmd", "subcommand": "run", "description": "Run the fixture"}
          ],
          "help": {"topics": [
            {"name": "schemacmd", "title": "Fixture", "summary": "A topic.", "body": "# Fixture"}
          ]}
          """),
      script: PluginFixtureKit.script())
    addTeardownBlock { fixture.cleanup() }
    var config = ConfigLoader.parseLayers([
      ConfigLoader.Layer(
        text: """
          [popup.scratch]
          command = ["/bin/cat"]

          [monitors.keyboard]
          event = "core:usb.attached"
          usb = { vendor_id = 0x05ac, product_id = 0x024f }
          run = ["/usr/bin/true"]
          cooldown = 30
          """,
        valueSource: ConfigValueSource(layer: "config", detail: "flash.toml"))
    ])
    XCTAssertNil(config.loadingErrorAlertMessage)
    config.plugins.thirdParty = [try XCTUnwrap(PluginReference.parse("file:\(fixture.root.path)"))]
    config.plugins.disabled = Self.officialIDs.subtracting(["defaults"])
    config.plugins.watchingEnabled = false
    delegate.config = config
    delegate.registry = SourceRegistry(descriptors: [], runningApplications: [])
    delegate.monitor = AppMonitor(registry: delegate.registry, config: config)

    delegate.pluginManager.start(config: config)
    addTeardownBlock { delegate.pluginManager.stop() }
    waitUntilTrue("the delegate's plugins loaded") {
      Set(delegate.pluginManager.pluginStatuses().map(\.id)) == ["defaults", "schemacmd"]
    }

    // The bar laid out on one display, with its mode badge and two runs.
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    delegate.overlay.modeSurface.label = "NORMAL"
    delegate.overlay.modeSurface.style = .normal
    delegate.overlay.setStatusBarModel(
      FlashStatusBarModel(appText: "Finder", modeText: "", rightText: "12:00"))
    delegate.overlay.configureModeBadge(
      panelFrame: screen,
      screenSnapshot: OverlayPanel.ScreenSnapshot(
        screens: [(scale: 2, frame: screen, visibleFrame: screen, notch: nil)],
        unionFrame: screen, mainFrame: screen, mainScale: 2, mainVisibleFrame: screen,
        nativeStatusBarFallbackHeight: 26))
    // A configured popup, its command running on a PTY.
    let terminals = delegate.overlay.statusTerminals
    terminals.apply(
      style: config.popupStyle, terminals: config.terminalPopups.filter { $0.key == "scratch" },
      prewarm: ["scratch"])
    waitUntilTrue("the popup's command runs") {
      if case .running = terminals.session(named: "scratch")?.state { return true }
      return false
    }

    let display = WindowScreenLayout(
      id: 7, frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
      usableFrame: CGRect(x: 0, y: 0, width: 1440, height: 870))
    let widgets = WidgetController(setVisible: { _, _ in }, screenLayouts: { _, _ in [display] })
    addTeardownBlock { widgets.stop() }
    widgets.apply(
      widgets: ["clock": Config.Widget()], statusBarReservesSpace: true, statusBarMonitor: .all,
      hideFromCapture: false)
    widgets.show("clock", lines: StatusFormatDocument.parse("12:00").lines())
    delegate.widgetController = widgets

    delegate.hintSession.hints = [
      AssignedHint(
        target: JumpTarget(
          id: "a", frame: CGRect(x: 10, y: 10, width: 40, height: 20), role: "AXButton",
          pid: 42, providerID: "test"),
        label: "a")
    ]
    delegate.clipboardEntries = [
      ClipboardModalEntry(
        id: "0123456789abcdef0123456789abcdef", kind: "html", preview: "hello",
        value: "hello world", html: "<b>hello</b>", mime: nil, files: []),
      ClipboardModalEntry(
        id: "fedcba9876543210fedcba9876543210", kind: "files", preview: "a.png",
        value: "", html: nil, mime: "image/png", files: ["/tmp/a.png"], pinned: true),
    ]
    delegate.clipboardTotal = 3
    delegate.clipboardNextOffset = 2
    delegate.registers.write("yanked", register: "a")

    // The run answers at once, as a step that exited 2: no process starts.
    delegate.monitorRunner = MonitorRunner(
      store: MemoryMonitorRunStore(),
      execute: { _, _, _, completion in
        completion(.exited(2), "no such device")
        return nil
      })
    delegate.monitorsDidChange([
      MonitorSnapshot(
        id: "disk", spec: StatusMonitorSpec(value: .init(template: "93"), warning: 90),
        tracker: MonitorTracker(sinceMs: 0))
    ])
    let keyboard = try XCTUnwrap(config.monitors["keyboard"])
    delegate.monitorRunner.start(
      "keyboard", steps: keyboard.run, environment: [:], timeoutSeconds: keyboard.timeout,
      cooldownSeconds: 0)
    return delegate
  }

  private func rows(_ state: [String: Any], _ path: String...) -> [[String: Any]] {
    var value: Any? = state
    for key in path { value = (value as? [String: Any])?[key] }
    return value as? [[String: Any]] ?? []
  }

  private var properties: [String: Any] {
    validator.documents[Self.schema]?["properties"] as? [String: Any] ?? [:]
  }

  // MARK: - The document

  func testTheDocumentIsADraft07SchemaNamingItsPublishedAddress() throws {
    XCTAssertEqual(Array(validator.documents.keys), [Self.schema])
    let document = try XCTUnwrap(validator.documents[Self.schema])
    XCTAssertEqual(document["$schema"] as? String, "http://json-schema.org/draft-07/schema#")
    XCTAssertEqual(
      document["$id"] as? String,
      "https://raw.githubusercontent.com/aymericbeaumet/flash/main/docs/schema/inspector/"
        + Self.schema)
    XCTAssertNotNil(document["description"] as? String)
    XCTAssertEqual(document["additionalProperties"] as? Bool, false)
    // Every section is always there: a reader never tests for one.
    XCTAssertEqual(Set(document["required"] as? [String] ?? []), Set(properties.keys))
    // Every object type is a named definition a type generator can emit.
    let definitions = try XCTUnwrap(document["definitions"] as? [String: [String: Any]])
    for (name, definition) in definitions {
      XCTAssertNotNil(definition["description"] ?? definition["oneOf"], name)
    }
  }

  // MARK: - Real snapshots

  func testAPopulatedSnapshotValidates() throws {
    let delegate = try populatedDelegate()
    let state = try published(delegate.debugStateJSON())
    assertValid(state, "populated snapshot")

    // The snapshot is not vacuous: the arrays the schema types have rows.
    let sources = Set(rows(state, "commands").compactMap { $0["source_kind"] as? String })
    XCTAssertEqual(sources, ["core", "plugin"])
    XCTAssertEqual(
      rows(state, "plugins").compactMap { $0["id"] as? String }, ["defaults", "schemacmd"])
    XCTAssertEqual(
      rows(state, "plugins").compactMap { $0["state"] as? String }, ["manifest_only", "stopped"])
    XCTAssertTrue(rows(state, "docs").contains { $0["name"] as? String == "schemacmd" })
    XCTAssertFalse(rows(state, "mappings", "rows").isEmpty)
    XCTAssertFalse(rows(state, "mappings", "effective_rows").isEmpty)
    XCTAssertTrue(
      rows(state, "mappings", "commands").contains { $0["source"] as? String == "defaults" })
    XCTAssertEqual(
      rows(state, "monitors").compactMap { $0["kind"] as? String }, ["value", "event"])
    let run = try XCTUnwrap(rows(state, "monitors").last?["last_run"] as? [String: Any])
    XCTAssertEqual(run["status"] as? String, "failed")
    XCTAssertNotNil(rows(state, "monitors").last?["usb"] as? [String: Any])
    let sessions = rows(state, "terminals", "sessions")
    XCTAssertEqual(sessions.compactMap { $0["name"] as? String }, ["scratch"])
    XCTAssertEqual(sessions.first?["state"] as? String, "running")
    XCTAssertNotNil(sessions.first?["pid"] as? Int)
    XCTAssertFalse(rows(state, "statusbar", "runs").isEmpty)
    XCTAssertEqual(rows(state, "widgets", "windows").count, 1)
    XCTAssertEqual(rows(state, "hints").count, 1)
    XCTAssertEqual(rows(state, "clipboard").count, 2)
    XCTAssertTrue(rows(state, "clipboard_registers").contains { $0["name"] as? String == "a" })
    XCTAssertFalse(rows(state, "windows").isEmpty)
    XCTAssertFalse((state["config_sources"] as? [String: Any] ?? [:]).isEmpty)
  }

  /// With nothing to show the arrays are empty, never absent; a section whose
  /// owner does not exist yet says `{}`.
  func testABareSnapshotValidates() throws {
    let state = try published(bareDelegate().debugStateJSON())
    assertValid(state, "bare snapshot")
    XCTAssertEqual((state["widgets"] as? [String: Any])?.isEmpty, true)
    XCTAssertTrue(rows(state, "plugins").isEmpty)
    XCTAssertTrue(rows(state, "monitors").isEmpty)
    XCTAssertTrue(rows(state, "hints").isEmpty)

    let unowned = try published(
      AppDelegate().debugStateJSON(sections: ["statusbar", "widgets"]), seq: nil)
    XCTAssertEqual((unowned["statusbar"] as? [String: Any])?.isEmpty, true)
    XCTAssertEqual(sectionValidator.problems(unowned, against: Self.schema), [])
  }

  /// A running plugin's row (a pid, samples, a published segment), built by
  /// a manager with its own data directory and put in the snapshot's place.
  func testARunningPluginRowValidates() throws {
    let publish =
      PluginFixtureKit.initializeOK + "\n    "
      + #"printf '{"method":"status","params":{"segments":{"state":"ok"}}}\n'"#
    let fixture = try PluginFixtureKit.make(
      id: "schemarun",
      manifest: PluginFixtureKit.manifest(
        id: "schemarun", extra: #""status": ["state"]"#),
      script: PluginFixtureKit.script(onInitialize: publish))
    defer { fixture.cleanup() }
    var config = Config()
    config.plugins.thirdParty = [try XCTUnwrap(PluginReference.parse("file:\(fixture.root.path)"))]
    config.plugins.disabled = Self.officialIDs
    config.plugins.watchingEnabled = false
    // A status plugin runs while the enabled bar shows one of its segments.
    config.statusBar.template = FlashStatusBarTemplate(
      template: "#{flash.plugin.schemarun.state}",
      variables: [
        FlashStatusBarTemplateVariable(
          id: "statusbar.template.flash.plugin.schemarun.state",
          token: "flash.plugin.schemarun.state",
          source: .plugin(.statusSegment(pluginID: "schemarun", name: "state")))
      ])
    config.statusBar.enabled = true
    let manager = PluginManager(baseDataDir: fixture.baseDataDir)
    defer { manager.stop() }
    manager.start(config: config)
    waitUntilTrue("the fixture runs and published its segment") {
      manager.pluginStatuses().first?.statusSegments["state"] == "ok"
    }
    let row = try XCTUnwrap(manager.pluginStatuses().first).jsonObject
    XCTAssertEqual(row["state"] as? String, "running")
    XCTAssertNotNil(row["pid"] as? Int)

    var state = bareDelegate().debugStateJSON()
    state["plugins"] = [row]
    assertValid(try published(state), "running plugin row")
  }

  // MARK: - Sections

  func testEachScopedRebuildValidatesAndMergesIntoAValidSnapshot() throws {
    let delegate = try populatedDelegate()
    let full = delegate.debugStateJSON()
    func rebuilt(_ sections: Set<String>) throws -> [String: Any] {
      let subset = try published(delegate.debugStateJSON(sections: sections), seq: nil)
      XCTAssertEqual(Set(subset.keys), sections.union(["snapshot_at_unix_ms"]))
      XCTAssertEqual(
        sectionValidator.problems(subset, against: Self.schema), [], "\(sections.sorted())")
      XCTAssertFalse(
        validator.problems(subset, against: Self.schema).isEmpty,
        "alone, a scoped rebuild is not a snapshot")
      // As `DebugServer.publishState` merges it.
      assertValid(
        try published(full.merging(subset) { _, new in new }), "merged \(sections.sorted())")
      return subset
    }
    for section in Self.scopedSections.sorted() {
      _ = try rebuilt([section])
    }
    _ = try rebuilt(AppDelegate.statusBarSections)
    _ = try rebuilt(Self.scopedSections)
    // The whole snapshot validates section by section too.
    for (name, value) in try published(full) where name != "snapshot_at_unix_ms" {
      XCTAssertEqual(
        sectionValidator.problems(
          ["snapshot_at_unix_ms": 0, name: value], against: Self.schema), [], name)
    }
  }

  func testTheSchemasSectionsAreTheSnapshots() throws {
    let delegate = bareDelegate()
    let sections = Set(delegate.debugStateJSON().keys)
    XCTAssertEqual(
      sections.union(["snapshot_seq"]), Set(properties.keys),
      "a section the snapshot gains or loses changes the schema with it")
    XCTAssertTrue(Self.scopedSections.isSubset(of: sections))
    // The server accepts any section name: one it cannot rebuild alone
    // rebuilds the whole snapshot, never a part without it.
    for name in sections.subtracting(["snapshot_at_unix_ms"]) {
      let rebuilt = Set(delegate.debugStateJSON(sections: [name]).keys)
      XCTAssertEqual(
        rebuilt, Self.scopedSections.contains(name) ? [name, "snapshot_at_unix_ms"] : sections,
        name)
    }
    XCTAssertEqual(Set(delegate.debugStateJSON(sections: ["unknown"]).keys), sections)
  }

  // MARK: - What the schema refuses

  func testTheSchemaRefusesUnknownKeysWrongTypesAndMissingSections() throws {
    let delegate = try populatedDelegate()
    let state = try published(delegate.debugStateJSON())
    assertValid(state, "the snapshot the mutations start from")
    func mutated(_ change: (inout [String: Any]) -> Void) -> [String: Any] {
      var copy = state
      change(&copy)
      return copy
    }
    /// `state` with the first row of the array at `section` changed.
    func firstRow(_ section: String, _ change: (inout [String: Any]) -> Void) -> [String: Any] {
      mutated { state in
        var rows = state[section] as? [[String: Any]] ?? []
        change(&rows[0])
        state[section] = rows
      }
    }
    func nested(_ section: String, _ change: (inout [String: Any]) -> Void) -> [String: Any] {
      mutated { state in
        var object = state[section] as? [String: Any] ?? [:]
        change(&object)
        state[section] = object
      }
    }

    assertInvalid(mutated { $0["uptime_seconds"] = 3 }, "an unknown top-level key")
    assertInvalid(mutated { $0["plugins"] = nil }, "a missing section")
    assertInvalid(mutated { $0["snapshot_seq"] = nil }, "a snapshot without its number")
    assertInvalid(mutated { $0["snapshot_at_unix_ms"] = "now" }, "a wrong-typed scalar")
    assertInvalid(mutated { $0["hint_session"] = "dancing" }, "a phase outside the closed set")
    assertInvalid(mutated { $0["overlay"] = "elsewhere" }, "an overlay mode outside the closed set")
    assertInvalid(mutated { $0["monitors"] = NSNull() }, "monitors as null")
    assertInvalid(nested("runtime") { $0["pid"] = "42" }, "a wrong-typed runtime field")
    assertInvalid(nested("runtime") { $0["uptime_seconds"] = 3 }, "an unknown runtime key")
    assertInvalid(nested("runtime") { $0["config_error"] = nil }, "a nullable field left out")
    assertInvalid(nested("statusbar") { $0["bar_visible"] = nil }, "a partial status bar")
    assertInvalid(
      nested("telemetry") { $0["receiver"] = [:] as [String: Any] }, "an empty receiver")
    assertInvalid(firstRow("plugins") { $0["state"] = "sleeping" }, "an unknown plugin state")
    assertInvalid(firstRow("plugins") { $0["commands"] = [] as [Any] }, "an unknown plugin key")
    assertInvalid(firstRow("plugins") { $0["pid"] = "none" }, "a wrong-typed plugin field")
    assertInvalid(firstRow("monitors") { $0["kind"] = nil }, "a monitor of no kind")
    assertInvalid(firstRow("monitors") { $0["kind"] = "event" }, "a value monitor called an event")
    assertInvalid(
      firstRow("commands") { $0["source_kind"] = "plugin" }, "a core row called a plugin's")
    assertInvalid(firstRow("clipboard") { $0["value"] = "full text" }, "a clipboard entry's text")
    assertInvalid(firstRow("hints") { $0["frame"] = [10, 10, 40, 20] }, "a hint frame as an array")
  }
}
