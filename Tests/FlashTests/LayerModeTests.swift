import AppKit
import Carbon.HIToolbox
import XCTest

@testable import flash

/// User-defined layers (`[mode.layers.<name>]`, `mode layer --name=<name>`):
/// a named key table entered from NORMAL, INSERT, HYPER or HOLD that
/// captures like NORMAL, reads only its own keys and `[mode.all]`, and goes
/// back to the base mode it came from on Escape or `mode leave`.
final class LayerModeTests: XCTestCase {
  private static let resize = """
    [mode.normal.mappings]
    "<leader>r" = ["flash", "mode", "layer", "--name=resize"]

    [mode.all.mappings]
    "cmd+ctrl+r" = ["flash", "mode", "layer", "--name=resize"]

    [mode.layers.resize]
    label = "RSZ"

    [mode.layers.resize.mappings]
    "h" = ["flash", "window", "move", "--position=lefthalf"]
    "l" = ["flash", "window", "move", "--position=righthalf"]
    "gg" = ["flash", "window", "move", "--position=maximized"]
    "ctrl+h" = ["flash", "window", "focus", "--direction=left"]

    [mode.layers.media]
    sticky = false

    [mode.layers.media.mappings]
    "p" = ["flash", "key", "system", "--key=media_play"]
    """

  private func layer(_ name: String, sticky: Bool = true, from base: ReturnMode = .normal)
    -> Mode
  {
    .layer(LayerMode(name: name, sticky: sticky, restoreTo: base))
  }

  // MARK: Reducer

  func testALayerIsEnteredFromEveryCapturingModeAndReturnsToItsBase() {
    let cases: [(Mode, ReturnMode)] = [
      (.normal, .normal), (.insert, .insert), (.hyper(restoreTo: .normal), .normal),
      (.hold, .normal), (.command(restoreTo: .insert), .insert),
      (.terminal(restoreTo: .normal, returnPID: nil), .normal),
      (layer("media", sticky: false, from: .insert), .insert),
    ]
    for (base, restoreTo) in cases {
      let (entered, effects) = ModeReducer.reduce(base, .enterLayer(name: "resize", sticky: true))
      XCTAssertEqual(entered, layer("resize", from: restoreTo), "from \(base)")
      XCTAssertTrue(effects.contains(.scheduleRecapture), "a layer takes the keyboard: \(base)")
      XCTAssertEqual(ModeReducer.reduce(entered, .leaveMode(hasHints: false)).0, restoreTo.mode)
    }
  }

  func testEnteringALayerFromAPopupClosesItAndActivatesTheAppItCovered() {
    let (mode, effects) = ModeReducer.reduce(
      .terminal(restoreTo: .insert, returnPID: 42), .enterLayer(name: "resize", sticky: true))
    XCTAssertEqual(mode, layer("resize", from: .insert))
    XCTAssertEqual(Array(effects.prefix(2)), [.hideTerminalPopup, .restoreCoveredApp(pid: 42)])
  }

  func testALayerNeedsAdvancedMode() {
    XCTAssertEqual(
      ModeReducer.reduce(.disabled, .enterLayer(name: "resize", sticky: true)).0, .disabled)
    XCTAssertEqual(
      ModeReducer.reduce(
        .command(restoreTo: .disabled), .enterLayer(name: "resize", sticky: true)
      ).0, .disabled)
  }

  func testEnteringTheActiveLayerChangesNothing() {
    let active = layer("resize", from: .insert)
    let (mode, effects) = ModeReducer.reduce(active, .enterLayer(name: "resize", sticky: true))
    XCTAssertEqual(mode, active)
    XCTAssertTrue(effects.isEmpty)
  }

  /// Back in NORMAL only the pill changes, as when HYPER ends; INSERT gets
  /// the keyboard back. Neither drops a hint session, which a one-shot
  /// layer's command may just have started.
  func testLeavingALayerKeepsAHintSessionItsCommandStarted() {
    let toNormal = ModeReducer.reduce(layer("resize"), .leaveMode(hasHints: false))
    XCTAssertEqual(toNormal.0, .normal)
    XCTAssertEqual(toNormal.1, [.renderSurface])
    let toInsert = ModeReducer.reduce(layer("resize", from: .insert), .leaveMode(hasHints: false))
    XCTAssertEqual(toInsert.0, .insert)
    XCTAssertEqual(toInsert.1, [.prepareModeEntry, .hideOverlayIfIdle, .renderSurface])
    for (_, effects) in [toNormal, toInsert] {
      XCTAssertFalse(effects.contains(.clearTransientHintState))
      XCTAssertFalse(effects.contains(.scheduleRecapture))
    }
  }

  func testLeaveWithHintsDismissesThemAndKeepsTheLayer() {
    let active = layer("resize")
    let (mode, effects) = ModeReducer.reduce(active, .leaveMode(hasHints: true))
    XCTAssertEqual(mode, active)
    XCTAssertTrue(effects.contains(.clearTransientHintState))
  }

  func testAOneShotLayerLeavesBeforeItsMappingRuns() {
    for base in [ReturnMode.normal, .insert] {
      let oneShot = layer("media", sticky: false, from: base)
      XCTAssertEqual(ModeReducer.reduce(oneShot, .layerMappingFired).0, base.mode)
      let sticky = layer("resize", from: base)
      let (mode, effects) = ModeReducer.reduce(sticky, .layerMappingFired)
      XCTAssertEqual(mode, sticky, "a sticky layer stays after a mapping")
      XCTAssertTrue(effects.isEmpty)
    }
    for state in [Mode.normal, .insert, .hold, .hyper(restoreTo: .normal)] {
      XCTAssertEqual(ModeReducer.reduce(state, .layerMappingFired).0, state)
    }
  }

  func testAReloadLeavesARemovedLayerAndUpdatesAKeptOne() {
    let active = layer("resize", from: .insert)
    XCTAssertEqual(ModeReducer.reduce(active, .layersChanged([:])).0, .insert)
    XCTAssertEqual(
      ModeReducer.reduce(active, .layersChanged(["resize": false])).0,
      layer("resize", sticky: false, from: .insert))
    let (kept, effects) = ModeReducer.reduce(active, .layersChanged(["resize": true]))
    XCTAssertEqual(kept, active)
    XCTAssertTrue(effects.isEmpty)
    XCTAssertEqual(ModeReducer.reduce(.normal, .layersChanged([:])).0, .normal)
  }

  /// A reload that keeps the layer is a refresh, not an entry: the layer
  /// and its capture context survive it.
  func testAReloadKeepingTheLayerPerformsNoModeEntry() {
    let store = ModeStore(initial: .normal)
    store.dispatch(.enterLayer(name: "resize", sticky: true))
    var entries = 0
    store.perform = { effects, _, _ in
      entries += effects.filter { $0 == .prepareModeEntry }.count
    }
    store.dispatch(.layersChanged(["resize": true, "media": false]))
    store.dispatch(.advancedModeChanged(enabled: true))
    XCTAssertEqual(entries, 0)
    XCTAssertEqual(store.mode, layer("resize"))
  }

  /// HYPER is NORMAL's leader hold, so the hyper key is a layer key like
  /// any other; focus changes keep the layer like every mode. A held button
  /// is HOLD from a layer too (the all-mode ⌘⌃H), and its release lands in
  /// NORMAL.
  func testALayerPersistsAcrossFocusAndTheHyperKey() {
    let active = layer("resize", from: .insert)
    for event: ModeEvent in [
      .focusedAppChanged(pid: 7), .enterHyper, .exitHyper, .buttonReleased,
      .closeCommand(reason: "submit"), .closeTerminal(restoresApp: true),
      .advancedModeChanged(enabled: true),
    ] {
      XCTAssertEqual(ModeReducer.reduce(active, event).0, active, "\(event)")
    }
    XCTAssertEqual(
      ModeReducer.reduce(active, .focusedAppChanged(pid: 7)).1, [.scheduleRecapture])
    XCTAssertTrue(active.canToggleHoldMode)
    let held = ModeReducer.reduce(active, .buttonHeld(.hold))
    XCTAssertEqual(held.0, .hold)
    XCTAssertEqual(held.1, [.renderSurface])
    XCTAssertEqual(ModeReducer.reduce(held.0, .buttonReleased).0, .normal)
    XCTAssertEqual(ModeReducer.reduce(active, .enterNormal).0, .normal)
    XCTAssertEqual(ModeReducer.reduce(active, .enterInsert(.explicitCommand)).0, .insert)
    XCTAssertEqual(ModeReducer.reduce(active, .advancedModeChanged(enabled: false)).0, .disabled)
    XCTAssertEqual(
      ModeReducer.reduce(active, .openCommand(restoreMode: true)).0,
      .command(restoreTo: .insert), "the command line returns to the layer's base")
  }

  func testALayerProjectsAsNormalCaptureWithItsOwnTableLabelAndStyle() {
    let active = layer("resize", from: .insert)
    XCTAssertEqual(active.flashMode, .normal)
    XCTAssertTrue(active.ownsKeyboard(hasHints: false, activationInFlight: false))
    XCTAssertFalse(active.ownsKeyboard(hasHints: true, activationInFlight: false))
    XCTAssertEqual(active.overlayInputMode(hasHints: false, activationInFlight: false), .normal)
    XCTAssertEqual(active.overlayInputMode(hasHints: true, activationInFlight: false), .hints)
    XCTAssertEqual(
      active.overlayInputMode(
        hasHints: false, activationInFlight: false, nativeSurfaceSuspended: true), .normal)
    XCTAssertEqual(active.mappingScope, .layer("resize"))
    XCTAssertEqual(active.mappingScope.name, "resize")
    XCTAssertEqual(active.label, .layer("resize"))
    XCTAssertEqual(active.badgeStyle, .layer)
    XCTAssertEqual(active.asReturnMode, .insert)
    XCTAssertEqual(FlashStatusReport.modeName(active), "resize")
    XCTAssertEqual(ModeReducer.enterEffects(for: active), ModeReducer.enterEffects(for: .normal))
  }

  /// The tap swallows every key in a layer, as in NORMAL: an unmapped key
  /// never reaches the app.
  func testTheTapSwallowsEveryKeyInALayer() {
    let active = layer("resize", from: .insert)
    for chord in [false, true] {
      XCTAssertEqual(
        KeyboardCaptureTap.decide(
          isTerminal: active.isTerminal, flashMode: active.flashMode,
          inputMode: active.overlayInputMode(hasHints: false, activationInFlight: false),
          aboutWindowVisible: false, aboutWindowOwnsKeyboard: false,
          nativeSurfaceSuspended: false, isModifiedChord: chord),
        .swallow)
    }
  }

  // MARK: Configuration

  func testALayerDeclaresItsKeysLabelAndStickiness() throws {
    let config = ConfigLoader.parse(Self.resize)
    XCTAssertEqual(config.diagnostics.map(\.message), [])
    let resize = try XCTUnwrap(config.mode.layers["resize"])
    XCTAssertEqual(resize.label, "RSZ")
    XCTAssertTrue(resize.sticky)
    XCTAssertEqual(resize.mappings.count, 4)
    XCTAssertEqual(config.mode.layerLabel("resize"), "RSZ")
    let media = try XCTUnwrap(config.mode.layers["media"])
    XCTAssertFalse(media.sticky)
    XCTAssertEqual(config.mode.layerLabel("media"), "MEDIA")
    XCTAssertTrue(
      config.mode.normal.contains { $0.action == .flashCommand(.layerMode(name: "resize")) })
  }

  private func key(_ raw: String) -> String {
    NormalModeInterpreter.canonicalizeMappingKey(raw)!
  }

  private func command(_ argv: String...) -> MappingCommand? {
    parseMappingCommand(argv: ["flash"] + argv)
  }

  /// A layer reads its own keys, then Escape's `mode leave`, then
  /// `[mode.all]`; NORMAL's keys are not there.
  func testALayerReadsItsKeysEscapeAndAllModeChordsOnly() throws {
    let config = ConfigLoader.parse(Self.resize)
    let table = config.mode.compiledLayer("resize")
    XCTAssertEqual(
      table.mapping(for: key("h"))?.action, command("window", "move", "--position=lefthalf"))
    XCTAssertEqual(table.mapping(for: key("<esc>"))?.action, .flashCommand(.leaveMode))
    XCTAssertEqual(
      table.mapping(for: key("cmd+ctrl+r"))?.action, .flashCommand(.layerMode(name: "resize")))
    XCTAssertNil(table.mapping(for: key("f")), "NORMAL's f is not the layer's")
    XCTAssertTrue(table.hasStrictPrefix(key("g")))
    XCTAssertEqual(
      config.mode.compiledLayer("gone").mapping(for: key("<esc>"))?.action,
      .flashCommand(.leaveMode), "an undeclared layer can still be left")

    let natives = MappingsCoordinator.nativeMappings(in: config.mode, scope: .layer("resize"))
    XCTAssertEqual(
      Set(natives.map(\.key)), [key("ctrl+h"), key("cmd+ctrl+r"), key("cmd+ctrl+h")],
      "its own chord and the all-mode ones, ⌘⌃H's HOLD included")
    XCTAssertEqual(
      MappingsCoordinator.scopedNativeMappings(in: config.mode, scope: .layer("resize")).map(
        \.key), [key("ctrl+h")], "all-mode chords keep their own registration")
    XCTAssertEqual(
      AppDelegate.interpreterTable(for: .layer("resize"), in: config.mode), table)
  }

  /// The regression: a layer passed its own table to the NORMAL
  /// interpreter, which reads `q`/`@` as macros and `m`/`'`/`` ` `` as marks
  /// whenever no mapping takes them, so `qa` started a recording and `'a`
  /// jumped to another app mid-resize. A layer reads only its own keys.
  func testALayerLeavesVimsMacroAndMarkKeysAlone() {
    let table = ConfigLoader.parse(Self.resize).mode.compiledLayer("resize")
    func typed(_ keys: String) -> NormalModeTransition? {
      var pending = ""
      var last: NormalModeTransition?
      for character in keys {
        let text = String(character)
        let transition = NormalModeInterpreter.interpret(
          pending: pending, keyCode: 0xFFFF, modifierFlags: [], characters: text,
          charactersIgnoringModifiers: text, mappings: table, recordingMacro: false)
        pending = transition.pending
        last = transition
      }
      return last
    }
    for keys in ["qa", "@a", "ma", "'a", "`a"] {
      XCTAssertNil(typed(keys)?.action, keys)
      XCTAssertEqual(typed(keys)?.pending, "", keys)
    }
    XCTAssertEqual(
      typed("h")?.action, command("window", "move", "--position=lefthalf"),
      "its own keys still run")
    // NORMAL keeps them.
    let normal = CompiledMappings(Config.Mode.defaultNormalMappings)
    XCTAssertTrue(normal.readsVimKeys)
    XCTAssertFalse(table.readsVimKeys)
  }

  func testALayerCanRemapOrRemoveEscapeAndAllModeKeys() throws {
    let config = ConfigLoader.parse(
      """
      [mode.all.mappings]
      "cmd+ctrl+r" = ["flash", "mode", "layer", "--name=media"]

      [mode.layers.media.mappings]
      "<esc>" = ["flash", "mode", "normal"]
      "cmd+ctrl+r" = false
      """)
    XCTAssertEqual(config.diagnostics.map(\.message), [])
    let table = config.mode.compiledLayer("media")
    XCTAssertEqual(table.mapping(for: key("<esc>"))?.action, .flashCommand(.normalMode))
    XCTAssertNil(table.mapping(for: key("cmd+ctrl+r")))
    XCTAssertNotNil(table.mapping(for: key("cmd+ctrl+h")), "other all-mode chords stay")
    let removed = ConfigLoader.parse(
      """
      [mode.layers.media.mappings]
      "<escape>" = false
      """)
    XCTAssertEqual(removed.diagnostics.map(\.message), [])
    XCTAssertNil(removed.mode.compiledLayer("media").mapping(for: key("<esc>")))
  }

  /// Counts work as in NORMAL: `3l` runs `l` three times.
  func testCountsRepeatALayerMapping() {
    let table = ConfigLoader.parse(Self.resize).mode.compiledLayer("resize")
    func press(_ pending: String, _ chars: String) -> NormalModeTransition {
      NormalModeInterpreter.interpret(
        pending: pending, keyCode: 0, modifierFlags: [], characters: chars,
        charactersIgnoringModifiers: chars, mappings: table)
    }
    let counted = press("", "3")
    XCTAssertNil(counted.action)
    let fired = press(counted.pending, "l")
    XCTAssertEqual(fired.action, command("window", "move", "--position=righthalf"))
    XCTAssertEqual(fired.repeatCount, 3)
    XCTAssertNil(press("", "x").action, "an unmapped key is consumed")
  }

  /// The mappings page lists each layer's own keys and its Escape under
  /// `layers.<name>`, the TOML table a row's snippet rewrites; the all-mode
  /// chords it reads stay listed once, under `all`.
  func testTheMappingsPageListsEachLayerUnderItsTable() {
    let rows = NormalModeDispatcher.mappingsJSON(mode: ConfigLoader.parse(Self.resize).mode)
    let resize = rows.filter { $0["scope"] == "layers.resize" }
    XCTAssertEqual(resize.count, 5, "\(resize)")
    XCTAssertTrue(resize.contains { $0["action"] == "flash mode leave" })
    XCTAssertFalse(resize.contains { $0["action"]?.hasPrefix("flash mode layer") == true })
    XCTAssertEqual(rows.filter { $0["scope"] == "layers.media" }.count, 2)
  }

  func testLayerNamesAreCheckedAtLoad() {
    let messages = ConfigLoader.parse(
      """
      [mode.layers.Resize.mappings]
      "h" = ["flash", "window", "move", "--position=lefthalf"]

      [mode.layers.normal.mappings]
      "h" = ["flash", "window", "move", "--position=lefthalf"]

      [mode.layers.ok]
      label = ""
      sticky = "yes"
      timeout = 3
      """
    ).diagnostics.map(\.message)
    XCTAssertTrue(
      messages.contains { $0.contains("mode.layers.Resize") && $0.contains("a-z") }, "\(messages)")
    XCTAssertTrue(
      messages.contains { $0.contains("mode.layers.normal") && $0.contains("built-in") },
      "\(messages)")
    XCTAssertTrue(messages.contains { $0.contains("mode.layers.ok.label") }, "\(messages)")
    XCTAssertTrue(messages.contains { $0.contains("mode.layers.ok.sticky") }, "\(messages)")
    XCTAssertTrue(
      messages.contains { $0.contains("mode.layers.ok") && $0.contains("'timeout'") },
      "\(messages)")
  }

  /// A mapping that enters a layer no `[mode.layers.<name>]` declares is
  /// reported where it is written and dropped.
  func testAMappingNamingAnUndeclaredLayerIsRejected() {
    let config = ConfigLoader.parse(
      """
      [mode.normal.mappings]
      "<leader>w" = ["flash", "mode", "layer", "--name=window"]

      [mode.layers.resize.mappings]
      "w" = ["flash", "mode", "layer", "--name=window"]
      "<leader>x" = ["flash", "mode", "normal"]
      """)
    let messages = config.diagnostics.map(\.message)
    XCTAssertEqual(
      messages.filter { $0.contains("[mode.layers.window]") }.count, 2, "\(messages)")
    XCTAssertTrue(messages.contains { $0.contains("<leader>") }, "\(messages)")
    XCTAssertFalse(
      config.mode.normal.contains { $0.action == .flashCommand(.layerMode(name: "window")) })
    XCTAssertEqual(config.mode.layers["resize"]?.mappings, [])
  }

  func testTheLayerCommandNeedsAValidName() {
    XCTAssertEqual(
      URLEventHandler.parse(topic: "mode", action: "layer", args: ["name": "resize"]),
      .layerMode(name: "resize"))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mode", "layer", "--name=my-layer_2"]),
      .flashCommand(.layerMode(name: "my-layer_2")))
    for args: [String: String] in [[:], ["name": ""], ["name": "Resize"], ["name": "a b"]] {
      XCTAssertNil(URLEventHandler.parse(topic: "mode", action: "layer", args: args), "\(args)")
    }
    XCTAssertNil(
      URLEventHandler.parse(
        topic: "mode", action: "layer", args: ["name": "resize", "sticky": "1"]))
    XCTAssertTrue(URLCommand.layerMode(name: "resize").changesMode)
  }

  /// The bundled file's commented example is a working configuration.
  func testTheBundledLayerExampleLoads() throws {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("config.default.toml")
    let text = try String(contentsOf: url, encoding: .utf8)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let intro = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("# Layers are key tables") })
    let start = try XCTUnwrap(
      lines[intro...].firstIndex { $0 == "# [mode.normal.mappings]" })
    let end = lines[start...].firstIndex { !$0.hasPrefix("#") } ?? lines.endIndex
    let example = lines[start..<end]
      .map { $0 == "#" ? "" : String($0.dropFirst(2)) }
      .joined(separator: "\n")
    let config = ConfigLoader.parseLayers([.init(text: text), .init(text: example)])
    XCTAssertEqual(config.diagnostics.map(\.message), [])
    XCTAssertEqual(config.mode.layers["resize"]?.mappings.count, 8)
    XCTAssertEqual(config.mode.layers["media"]?.sticky, false)
    XCTAssertTrue(
      config.mode.normal.contains { $0.action == .flashCommand(.layerMode(name: "resize")) })
    XCTAssertEqual(
      ConfigLoader.parse(text).mode.layers, [:], "the example ships commented out")
  }
}
