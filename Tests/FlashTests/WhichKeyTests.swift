import AppKit
import XCTest

@testable import flash

/// The which-key palette: after a NORMAL prefix pause, the keys that can
/// follow it and what each runs.
final class WhichKeyTests: XCTestCase {
  private func key(_ raw: String) -> String {
    NormalModeInterpreter.canonicalizeMappingKey(raw)!
  }

  private var mappings: CompiledMappings {
    CompiledMappings(
      [
        ("gt", URLCommand.tabNext), ("gT", .tabPrev), ("gg", .scroll(.top)),
        ("gsx", .showAbout), ("gsy", .showMappings), ("j", .scroll(.down)),
      ].map { ModeMapping(key: key($0.0), action: .flashCommand($0.1)) })
  }

  func testAPrefixListsEachNextKeyOnceWithWhatItRuns() {
    let entries = WhichKey.entries(after: key("g"), in: mappings)
    XCTAssertEqual(
      entries,
      [
        WhichKey.Entry(key: "g", title: "scroll top"),
        WhichKey.Entry(key: "s", title: "+2 more"),
        WhichKey.Entry(key: "t", title: "tab next"),
        WhichKey.Entry(key: "T", title: "tab previous"),
      ])
  }

  func testApostropheListsJumpBackBesideConfiguredAppShortcuts() {
    let shortcuts = ["a", "b", "c", "e", "f", "i", "l", "n", "p", "r", "s", "y", "w"]
    let table = CompiledMappings(
      shortcuts.map {
        ModeMapping(key: key("'" + $0), action: .flashCommand(.showAbout))
      })
    let rows = WhichKey.rows(after: "'", in: table).entries
    XCTAssertEqual(
      Array(rows.prefix(shortcuts.count)).map(\.label), shortcuts.sorted().map { "'" + $0 })
    XCTAssertTrue(rows.contains(WhichKey.Row(label: "''", title: "movement back")))
    XCTAssertTrue(rows.contains(WhichKey.Row(label: "'`", title: "movement back")))
    for shortcut in shortcuts {
      XCTAssertEqual(
        rows.filter { $0.label == "'" + shortcut },
        [
          WhichKey.Row(label: "'" + shortcut, title: "about show")
        ])
    }
    XCTAssertTrue(rows.contains(WhichKey.Row(label: "'d", title: "mark jump --letter=d")))
  }

  func testConfiguredJumpBackOverrideAppearsOnceAndWins() {
    let table = CompiledMappings([
      ModeMapping(key: key("''"), action: .flashCommand(.showAbout)),
      ModeMapping(key: key("'ab"), action: .flashCommand(.showMappings)),
    ])
    let rows = WhichKey.rows(after: "'", in: table).entries
    XCTAssertEqual(
      rows.filter { $0.label == "''" },
      [
        WhichKey.Row(label: "''", title: "about show")
      ])
    XCTAssertEqual(
      rows.filter { $0.label == "'a" },
      [
        WhichKey.Row(label: "'a", title: "+1 more")
      ], "a longer configured mapping takes priority over the built-in mark")
  }

  private func press(_ character: String, after pending: String = "", in table: CompiledMappings)
    -> NormalModeTransition
  {
    NormalModeInterpreter.interpret(
      pending: pending, keyCode: 0xFFFF,
      modifierFlags: character.first?.isUppercase == true ? [.shift] : [],
      characters: character, charactersIgnoringModifiers: character.lowercased(), mappings: table)
  }

  func testBuiltInSelectorsShowOnlyTheKeysTheyAccept() {
    let table = CompiledMappings([])
    for (operation, count) in [("'", 64), ("`", 64), ("m", 62), ("q", 62), ("@", 64), ("\"", 66)] {
      let pending = press(operation, in: table).pending
      let palette = WhichKey.rows(after: pending, in: table)
      XCTAssertEqual(palette.typed, operation)
      XCTAssertEqual(palette.entries.count, count, operation)
      for row in palette.entries {
        let next = String(row.label.dropFirst(operation.count))
        let transition = press(next == "<plus>" ? "+" : next, after: pending, in: table)
        XCTAssertTrue(transition.action != nil || !transition.pending.isEmpty, row.label)
      }
    }
    let macro = press("@", after: "3", in: table).pending
    XCTAssertEqual(WhichKey.rows(after: macro, in: table).typed, "3@")
    XCTAssertTrue(
      WhichKey.rows(after: macro, in: table).entries.contains {
        $0.label == "3@@" && $0.title == "macro play"
      })
  }

  func testExpiredMarkPrefixDoesNotAdvertiseMappingsTheInterpreterNoLongerReads() {
    let table = CompiledMappings([
      ModeMapping(key: key("'ab"), action: .flashCommand(.showAbout)),
      ModeMapping(key: key("'!"), action: .flashCommand(.showAbout)),
    ])
    let expired = NormalModeInterpreter.expiredPending("'", mappings: table)
    let rows = WhichKey.rows(after: expired, in: table).entries
    XCTAssertEqual(
      rows.filter { $0.label == "'a" },
      [
        WhichKey.Row(label: "'a", title: "mark jump --letter=a")
      ])
    XCTAssertFalse(rows.contains { $0.label == "'!" })
  }

  func testRegisterSelectorHidesCommandMappingsThatItIntercepts() {
    let table = CompiledMappings([
      ModeMapping(key: "a", action: .flashCommand(.showAbout)),
      ModeMapping(key: "!", action: .flashCommand(.showAbout)),
    ])
    let rows = WhichKey.rows(after: "\"", in: table, includeRoot: true).entries
    XCTAssertTrue(rows.contains(WhichKey.Row(label: "\"a", title: "register a")))
    XCTAssertFalse(rows.contains { $0.label == "\"!" })
    XCTAssertFalse(rows.contains { $0.title == "about show" })
  }

  func testLiteralScopesAndNonVimTablesNeverInventMarkFallbacks() {
    let mapping = ModeMapping(key: key("'a"), action: .flashCommand(.showAbout))
    XCTAssertEqual(
      WhichKey.rows(after: "'", in: CompiledMappings([mapping]), literal: true).entries,
      [WhichKey.Row(label: "'a", title: "about show")])
    XCTAssertEqual(
      WhichKey.rows(after: "'", in: CompiledMappings([mapping], readsVimKeys: false)).entries,
      [WhichKey.Row(label: "'a", title: "about show")])
  }

  func testMappedDigitAndQuotePrefixesStayDistinctFromCountsAndRegisters() {
    let table = CompiledMappings(
      [
        ModeMapping(key: key("2g"), action: .flashCommand(.showAbout)),
        ModeMapping(key: key("\"g"), action: .flashCommand(.showMappings)),
        ModeMapping(key: "l", action: .flashCommand(.scroll(.right))),
      ], readsVimKeys: false)
    for (prefix, command) in [("2", URLCommand.showAbout), ("\"", .showMappings)] {
      let pending = press(prefix, in: table).pending
      let palette = WhichKey.rows(after: pending, in: table, includeRoot: true)
      XCTAssertEqual(palette.typed, prefix)
      XCTAssertEqual(
        palette.entries,
        [
          WhichKey.Row(label: prefix + "g", title: WhichKey.title(of: .flashCommand(command)))
        ])
      XCTAssertEqual(press("g", after: pending, in: table).action, .flashCommand(command))
    }
    let counted = press("l", after: press("3", in: table).pending, in: table)
    XCTAssertEqual(counted.action, .flashCommand(.scroll(.right)))
    XCTAssertEqual(counted.repeatCount, 3)
  }

  func testRegisterNameInterceptsImplicitMarkAndMacroStarters() {
    let table = CompiledMappings([])
    for name in ["m", "q"] {
      let selected = press(name, after: "\"", in: table).pending
      XCTAssertEqual(NormalModeInterpreter.pendingLead(selected), "\"" + name)
      XCTAssertEqual(NormalModeInterpreter.pendingPrefix(selected), "")
    }
    for invalid in ["'", "`", "@"] {
      XCTAssertEqual(press(invalid, after: "\"", in: table), .consume)
    }
  }

  func testSelectedRegisterIsReflectedInACompletedMapping() {
    let table = CompiledMappings([
      ModeMapping(key: key("gp"), action: .flashCommand(.paste(register: nil, after: false)))
    ])
    XCTAssertEqual(
      WhichKey.rows(after: "\"a" + key("g"), in: table).entries,
      [
        WhichKey.Row(label: "\"agp", title: "register paste --register=a")
      ])
  }

  func testACharacterSearchDoesNotAdvertiseFiniteMappings() {
    let table = CompiledMappings([
      ModeMapping(key: "a", action: .flashCommand(.showAbout))
    ])
    let pending = NormalModeInterpreter.characterPending(
      for: .flashCommand(.cursor(.findCharacter(.nextChar, nil))), count: 1)!
    XCTAssertTrue(WhichKey.entries(after: pending, in: table, includeRoot: true).isEmpty)
  }

  func testHoldPrefixSchedulesTheEffectiveTablePalette() {
    _ = NSApplication.shared
    let delegate = AppDelegate()
    delegate.monitor = AppMonitor(
      registry: SourceRegistry(descriptors: [], runningApplications: []), config: .default)
    delegate.overlay = OverlayPanel()
    defer {
      delegate.whichKeyDeadline.cancel()
      delegate.overlay.orderOut(nil)
    }
    delegate.modeStore.dispatch(.startup(advancedEnabled: true))
    delegate.modeStore.perform = { _, _, _ in }
    delegate.modeStore.dispatch(.buttonHeld(.hold))
    XCTAssertTrue(delegate.modeStore.mode.isHold)
    delegate.overlay.normalModePending = key("g")
    delegate.scheduleWhichKeyIfNeeded()
    XCTAssertTrue(delegate.whichKeyDeadline.isArmed)
  }

  func testLayerRootShowsCountAndRegisterLeadAndOmitsAnInterceptedZero() {
    let table = CompiledMappings(
      [
        ModeMapping(key: key("0g"), action: .flashCommand(.showAbout)),
        ModeMapping(key: "g", action: .flashCommand(.showMappings)),
        ModeMapping(key: "p", action: .flashCommand(.paste(register: nil, after: false))),
      ], readsVimKeys: false)
    let counted = WhichKey.rows(after: "3", in: table, includeRoot: true)
    XCTAssertEqual(counted.typed, "3")
    XCTAssertEqual(counted.entries.map(\.label), ["3g", "3p"])
    XCTAssertEqual(press("0", after: "3", in: table).pending, "30")
    let registered = WhichKey.rows(after: "\"a", in: table, includeRoot: true)
    XCTAssertEqual(registered.typed, "\"a")
    XCTAssertTrue(
      registered.entries.contains {
        $0.label == "\"ap" && $0.title == "register paste --register=a"
      })
    XCTAssertTrue(registered.entries.contains { $0.label == "\"a0" })
  }

  func testRootPaletteDoesNotAdvertiseEscapeMappingsWhileEscapeCancelsPending() {
    let table = CompiledMappings(
      [
        ModeMapping(key: key("<esc>"), action: .flashCommand(.showAbout)),
        ModeMapping(key: key("ctrl+["), action: .flashCommand(.showMappings)),
        ModeMapping(key: "p", action: .flashCommand(.paste(register: nil, after: false))),
      ], readsVimKeys: false)
    for pending in ["3", "\"a"] {
      let rows = WhichKey.rows(after: pending, in: table, includeRoot: true).entries
      XCTAssertEqual(rows.count, 1, "Escape cancels the count/register, not the layer")
      let cancel = NormalModeInterpreter.interpret(
        pending: pending, keyCode: 53, modifierFlags: [], characters: "\u{1B}",
        charactersIgnoringModifiers: "\u{1B}", mappings: table)
      XCTAssertEqual(cancel, .consume)
    }
    XCTAssertEqual(WhichKey.entries(after: "", in: table, includeRoot: true).count, 3)
  }

  func testMappedModifiedDigitRunsAfterACountWhilePlainZeroExtendsIt() {
    let table = CompiledMappings(
      [
        ModeMapping(key: key("ctrl+0"), action: .flashCommand(.showAbout))
      ], readsVimKeys: false)
    let mapped = NormalModeInterpreter.interpret(
      pending: "3", keyCode: 29, modifierFlags: [.control], characters: "0",
      charactersIgnoringModifiers: "0", mappings: table)
    XCTAssertEqual(mapped.action, .flashCommand(.showAbout))
    XCTAssertEqual(mapped.repeatCount, 3)
    XCTAssertEqual(press("0", after: "3", in: table).pending, "30")
    XCTAssertEqual(
      WhichKey.rows(after: "3", in: table, includeRoot: true).entries,
      [
        WhichKey.Row(label: "3ctrl-0", title: "about show")
      ])
    let shifted = NormalModeInterpreter.interpret(
      pending: "", keyCode: 18, modifierFlags: [.shift], characters: "!",
      charactersIgnoringModifiers: "1", mappings: table)
    XCTAssertEqual(shifted, .consume, "shifted punctuation is not a repeat count")
  }

  /// The palette shows where you are: each row's chip is the whole sequence,
  /// with the keys already typed (a register and count included) faded the
  /// way a hint chip fades its typed letters.
  func testEachRowShowsTheKeysAlreadyTypedBeforeItsNextKey() {
    XCTAssertEqual(WhichKey.typed(key("g")), "g")
    XCTAssertEqual(WhichKey.typed(key("gs")), "gs")
    XCTAssertEqual(WhichKey.typed("3" + key("g")), "3g")
    XCTAssertEqual(WhichKey.typed("\"a2" + key("g")), "\"a2g")
    XCTAssertEqual(WhichKey.typed(""), "")
    XCTAssertEqual(WhichKey.typed("3"), "", "a count alone opens no palette")
    let rows = WhichKey.rows(after: "3" + key("g"), in: mappings)
    XCTAssertEqual(rows.typed, "3g")
    XCTAssertEqual(rows.entries.map(\.label), ["3gg", "3gs", "3gt", "3gT"])
    XCTAssertEqual(
      rows.entries.map(\.title), ["scroll top", "+2 more", "tab select --index=3", "tab previous"])
    XCTAssertTrue(rows.entries.allSatisfy { $0.label.hasPrefix(rows.typed) })
  }

  /// A click or a scroll is not the key a half-typed sequence waits for: it
  /// drops the sequence and takes the palette down, so the next key starts
  /// fresh instead of completing a mapping the user moved away from.
  func testAPointerInteractionDropsTheHalfTypedSequenceAndItsPalette() {
    _ = NSApplication.shared
    let delegate = AppDelegate()
    delegate.monitor = AppMonitor(
      registry: SourceRegistry(descriptors: [], runningApplications: []), config: .default)
    delegate.overlay = OverlayPanel()
    defer { delegate.overlay.orderOut(nil) }
    delegate.modeStore.dispatch(.startup(advancedEnabled: true))
    delegate.modeStore.perform = { _, _, _ in }
    delegate.overlay.normalModePending = key("g")
    delegate.whichKeyShown = true
    delegate.overlayDidCancelByPointer(.scroll)
    XCTAssertEqual(delegate.overlay.normalModePending, "")
    XCTAssertFalse(delegate.whichKeyShown)
  }

  func testACountBeforeThePrefixIsIgnoredAndNothingFollowsALeaf() {
    XCTAssertEqual(
      WhichKey.entries(after: "3" + key("g"), in: mappings).map(\.key), ["g", "s", "t", "T"])
    XCTAssertEqual(WhichKey.entries(after: key("j"), in: mappings), [])
    XCTAssertEqual(WhichKey.entries(after: "", in: mappings), [])
  }

  func testTheDefaultTablesBracketPrefixListsItsTabCommands() {
    let defaults = CompiledMappings(Config.Mode.defaultNormalMappings)
    let entries = WhichKey.entries(after: key("]"), in: defaults)
    XCTAssertTrue(entries.contains(WhichKey.Entry(key: "t", title: "tab next")), "\(entries)")
  }

  func testHyperAndLayersCanListRootKeysAndLiteralDigitPrefixes() {
    let table = CompiledMappings([
      ModeMapping(key: key("1x"), action: .flashCommand(.showAbout)),
      ModeMapping(key: key("j"), action: .flashCommand(.scroll(.down))),
    ])
    XCTAssertEqual(
      WhichKey.rows(after: "", in: table, literal: true, includeRoot: true).entries.map(\.label),
      ["1", "j"])
    XCTAssertEqual(
      WhichKey.rows(after: key("1"), in: table, literal: true, includeRoot: true).entries,
      [WhichKey.Row(label: "1x", title: "about show")])
    XCTAssertTrue(WhichKey.rows(after: "", in: table).entries.isEmpty)
  }

  func testHyperAndLayerPalettesUseTheirCurrentModeAndRejectStaleShows() {
    _ = NSApplication.shared
    let delegate = AppDelegate()
    delegate.monitor = AppMonitor(
      registry: SourceRegistry(descriptors: [], runningApplications: []), config: .default)
    delegate.overlay = OverlayPanel()
    defer { delegate.overlay.orderOut(nil) }
    delegate.modeStore.dispatch(.startup(advancedEnabled: true))
    delegate.modeStore.perform = { _, _, _ in }
    delegate.modeStore.dispatch(.enterHyper)
    delegate.overlay.inputMode = .normal
    delegate.overlay.hyperModeMappings = mappings
    let hyper = delegate.modeStore.mode
    delegate.showWhichKey(for: "", mode: hyper)
    XCTAssertTrue(delegate.whichKeyShown, "HYPER's root mappings are discoverable while held")
    delegate.dispatchMode(.exitHyper)
    XCTAssertFalse(delegate.whichKeyShown)
    delegate.showWhichKey(for: "", mode: hyper)
    XCTAssertFalse(delegate.whichKeyShown, "a deadline for the released hold cannot draw")
    delegate.modeStore.dispatch(.enterLayer(name: "window", sticky: true))
    delegate.overlay.normalModeMappings = mappings
    delegate.overlay.inputMode = .normal
    delegate.showWhichKey(for: "", mode: delegate.modeStore.mode)
    XCTAssertTrue(delegate.whichKeyShown, "a layer lists its table at the root")
    delegate.hideWhichKey()
  }

  func testTheMappingPaletteKeepsTheActiveWindowBorderBehindItsRows() throws {
    _ = NSApplication.shared
    let delegate = AppDelegate()
    delegate.monitor = AppMonitor(
      registry: SourceRegistry(descriptors: [], runningApplications: []), config: .default)
    delegate.overlay = OverlayPanel()
    let panel = delegate.overlay!
    defer {
      delegate.whichKeyDeadline.cancel()
      panel.setActiveWindowBorder(around: nil)
      panel.hide()
      panel.orderOut(nil)
    }
    delegate.modeStore.dispatch(.startup(advancedEnabled: true))
    delegate.modeStore.perform = { _, _, _ in }
    panel.inputMode = .normal
    panel.normalModeMappings = mappings
    let window = CGRect(x: 100, y: 100, width: 800, height: 500)
    panel.setActiveWindowBorder(around: window)
    let border = panel.activeWindowBorderLayer

    for prefix in ["g", "gs"] {
      panel.normalModePending = key(prefix)
      delegate.showWhichKey(for: key(prefix), mode: .normal)
      XCTAssertTrue(delegate.whichKeyShown)
      XCTAssertEqual(panel.inputMode, .normal)
      XCTAssertFalse(delegate.hintSession.isActive, "the palette does not become a hint session")
      XCTAssertEqual(panel.normalModePending, key(prefix))
      XCTAssertEqual(panel.activeWindowBorderFrame, window)
      XCTAssertNotNil(border.path)
      let layers = try XCTUnwrap(panel.contentLayer.sublayers)
      XCTAssertTrue(layers.first === border, "the focus border stays behind the mapping palette")
      XCTAssertEqual(layers.filter { $0 === border }.count, 1)
      XCTAssertNotNil(layers.first { $0.cornerRadius == 10 }, "the mapping palette still draws")
    }
    panel.hide()
    XCTAssertFalse(panel.transientContentVisible)
    XCTAssertTrue(
      panel.contentLayer.sublayers?.first === border, "closing the palette keeps the border")
    panel.setActiveWindowBorder(around: nil)
    delegate.showWhichKey(for: key("gs"), mode: .normal)
    XCTAssertFalse(
      panel.contentLayer.sublayers?.contains { $0 === border } ?? false,
      "a hidden border is never restored by the palette")
  }

  func testAWindowSelectionListDoesNotRestoreTheActiveWindowBorder() {
    _ = NSApplication.shared
    let panel = OverlayPanel()
    defer {
      panel.setActiveWindowBorder(around: nil)
      panel.hide()
      panel.orderOut(nil)
    }
    panel.inputMode = .passive
    panel.setActiveWindowBorder(around: CGRect(x: 100, y: 100, width: 800, height: 500))
    panel.displayWindowSwitcher(
      .init(
        rows: [.init(label: "A", app: "App", title: "Window", badge: nil, icon: nil)],
        selection: 0, typed: "", anchor: nil))
    XCTAssertFalse(
      panel.contentLayer.sublayers?.contains { $0 === panel.activeWindowBorderLayer } ?? false)
  }

  func testThePauseIsConfigurableAndZeroTurnsItOff() {
    XCTAssertEqual(Config.default.mode.whichKeyMs, 500)
    XCTAssertEqual(ConfigLoader.parse("[mode]\nwhich_key_ms = 0").mode.whichKeyMs, 0)
    XCTAssertTrue(
      ConfigLoader.parse("[mode]\nwhich_key_ms = -1").loadingDiagnostics.contains {
        $0.message.contains("mode.which_key_ms must be an integer between 0 and 10000")
      })
  }
}
