import AppKit
import Carbon.HIToolbox
import XCTest

@testable import flash

final class TerminalModeTests: XCTestCase {
  func testTerminalOwnsNoOverlayOrGlobalMappings() {
    for base in [Mode.disabled, .normal, .insert(locked: true)] {
      let (mode, effects) = ModeReducer.reduce(base, .openTerminal)
      XCTAssertEqual(mode, .terminal(restoreTo: base.asReturnMode))
      XCTAssertFalse(mode.ownsKeyboard(hasHints: false, activationInFlight: false))
      XCTAssertEqual(mode.label, .terminal)
      XCTAssertTrue(effects.contains(.setMappingScope(.terminal)))
      XCTAssertFalse(effects.contains(.scheduleRecapture))
      for scope in ModeScope.allCases {
        XCTAssertFalse(MappingsCoordinator.scopeIsActive(scope, for: .terminal))
      }
    }
  }

  func testFocusLossRestoresBaseWithoutActivatingAnotherApp() {
    for base in [Mode.disabled, .normal, .insert(locked: false), .insert(locked: true)] {
      let (mode, effects) = ModeReducer.reduce(
        .terminal(restoreTo: base.asReturnMode), .closeTerminal(targetPID: nil))
      XCTAssertEqual(mode, base)
      XCTAssertTrue(effects.contains(.hideTerminalPopup))
      XCTAssertFalse(
        effects.contains {
          if case .activateFocusedApp = $0 { return true }
          return false
        })
    }
  }

  func testExplicitPopupCloseRestoresPriorAppBeforeBaseModeRendering() {
    for base in [Mode.disabled, .normal, .insert(locked: false), .insert(locked: true)] {
      let (mode, effects) = ModeReducer.reduce(
        .terminal(restoreTo: base.asReturnMode), .closeTerminal(targetPID: 42))
      XCTAssertEqual(mode, base)
      XCTAssertEqual(Array(effects.prefix(2)), [.hideTerminalPopup, .activateFocusedApp(pid: 42)])
      XCTAssertEqual(effects.filter { $0 == .activateFocusedApp(pid: 42) }.count, 1)
      XCTAssertLessThan(
        effects.firstIndex(of: .activateFocusedApp(pid: 42)) ?? Int.max,
        effects.firstIndex(of: .renderSurface) ?? -1)
    }
  }

  func testPopupCloseOutsideTerminalDoesNotActivateApp() {
    for base in [Mode.disabled, .normal, .insert(locked: true)] {
      let (mode, effects) = ModeReducer.reduce(base, .closeTerminal(targetPID: 42))
      XCTAssertEqual(mode, base)
      XCTAssertTrue(effects.isEmpty)
    }
  }

  func testTerminalExitActivatesPriorAppBeforeNormalCapture() {
    let (mode, effects) = ModeReducer.reduce(
      .terminal(restoreTo: .insert(locked: false)), .enterNormal(targetPID: 42))
    XCTAssertEqual(mode, .normal)
    XCTAssertEqual(Array(effects.prefix(2)), [.hideTerminalPopup, .activateFocusedApp(pid: 42)])
    XCTAssertLessThan(
      effects.firstIndex(of: .activateFocusedApp(pid: 42))!,
      effects.firstIndex(of: .renderSurface)!)
  }

  func testTerminalInheritsOnlyWinningInsertExitMappings() {
    var mode = Config.Mode()
    mode.all = [mapping("x", .commandMode), mapping("y", .normalMode)]
    mode.insert = [mapping("x", .normalMode), mapping("z", .normalMode)]
    mode.terminal = [mapping("z", .commandMode)]
    mode.recompileMappings()
    XCTAssertNil(mode.compiledTerminal.mapping(for: "x"))
    XCTAssertEqual(mode.compiledTerminal.mapping(for: "y")?.action.command, .normalMode)
    XCTAssertEqual(mode.compiledTerminal.mapping(for: "z")?.action.command, .commandMode)
    XCTAssertEqual(mode.effectiveTerminalMappings.count, 2)
  }

  func testPluginPrecedenceIsResolvedBeforeTerminalDefaultsAreInherited() {
    var base = Config.Mode()
    base.insert = [mapping("x", .normalMode), mapping("y", .commandMode)]
    base.terminal = [mapping("z", .normalMode)]
    let merged = EffectiveMappings.merge(
      base: base,
      plugin: [
        (25, .insert, mapping("x", .commandMode)),
        (25, .insert, mapping("y", .normalMode)),
        (25, .terminal, mapping("z", .commandMode)),
      ])
    XCTAssertNil(merged.compiledTerminal.mapping(for: "x"))
    XCTAssertEqual(merged.compiledTerminal.mapping(for: "y")?.action.command, .normalMode)
    XCTAssertEqual(merged.compiledTerminal.mapping(for: "z")?.action.command, .commandMode)
  }

  func testPhysicalChordAliasesCannotBypassInsertPrecedence() {
    var mode = Config.Mode()
    mode.all = [mapping("cmd+esc", .commandMode)]
    mode.insert = [mapping("cmd+escape", .normalMode)]
    mode.recompileMappings()
    let escapeKey = NormalModeInterpreter.canonicalizeMappingKey("cmd+escape")!
    XCTAssertNil(mode.compiledTerminal.mapping(for: escapeKey))

    mode.all = [mapping("cmd+esc", .normalMode)]
    mode.terminal = [mapping("cmd+escape", .commandMode)]
    mode.recompileMappings()
    XCTAssertEqual(mode.effectiveTerminalMappings, [mapping("cmd+escape", .commandMode)])
  }

  func testTerminalConfigurationParsesSequencesAndRejectsLeader() {
    let config = ConfigLoader.parse(
      """
      [mode]
      labels = { normal = "N", insert = "I", command = "C", terminal = "TTY" }
      [mode.terminal.mappings]
      "gg" = ["flash", "enter_normal_mode"]
      "<leader>x" = ["flash", "enter_normal_mode"]
      """
    )
    XCTAssertEqual(config.mode.labels.terminal, "TTY")
    let key = NormalModeInterpreter.canonicalizeMappingKey("gg")!
    XCTAssertEqual(config.mode.compiledTerminal.mapping(for: key)?.action.command, .normalMode)
    XCTAssertEqual(config.mode.terminal.count, 4)
    XCTAssertTrue(
      config.loadingDiagnostics.contains { $0.message.contains("uses <leader> outside") })
    XCTAssertTrue(
      NormalModeDispatcher.mappingsJSON(config: config).contains { $0["scope"] == "terminal" })
  }

  func testConfigReloadKeepsTerminalInputAndUpdatesItsReturnMode() {
    let initial = Mode.terminal(restoreTo: .normal)
    let (disabled, effects) = ModeReducer.reduce(initial, .advancedModeChanged(enabled: false))
    XCTAssertEqual(disabled, .terminal(restoreTo: .disabled))
    XCTAssertEqual(effects, [.renderSurface])
    XCTAssertEqual(ModeReducer.reduce(disabled, .closeTerminal(targetPID: nil)).0, .disabled)
  }

  func testResolvedConfigIncludesTerminalDefaultsAndLabel() throws {
    var config = Config()
    config.mode.all = [mapping("cmd+escape", .normalMode)]
    config.mode.recompileMappings()
    let data = try XCTUnwrap(config.resolvedConfigJSON.data(using: .utf8))
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let mode = try XCTUnwrap(root["mode"] as? [String: Any])
    let mappings = try XCTUnwrap(mode["terminal"] as? [[String: Any]])
    XCTAssertEqual(mappings.count, 4)
    let labels = try XCTUnwrap(mode["labels"] as? [String: String])
    XCTAssertEqual(labels["terminal"], "TERMINAL")
  }

  func testLeaveModeConfigEnablesAdvancedModeAndInheritsIntoTerminal() throws {
    let config = ConfigLoader.parse(
      """
      [mode.all.mappings]
      "cmd+shift+[" = ["flash", "leave_mode"]
      """
    )
    XCTAssertTrue(config.loadingDiagnostics.isEmpty)
    XCTAssertTrue(config.mode.containsAdvancedModeMapping)
    XCTAssertTrue(config.mode.containsNormalModeMapping)
    let key = try XCTUnwrap(NormalModeInterpreter.canonicalizeMappingKey("cmd+shift+["))
    let mapping = try XCTUnwrap(config.mode.compiledTerminal.mapping(for: key))
    XCTAssertEqual(mapping.action.command, URLEventHandler.parse(verb: "leave_mode", args: [:]))
    XCTAssertEqual(mapping.action.command?.diagnosticDescription, "flash leave_mode")
    XCTAssertNil(URLEventHandler.parse(verb: "leave_mode", args: ["unexpected": "1"]))
  }

  func testShiftedBracketExitReachesTerminalMapping() throws {
    let config = ConfigLoader.parse(
      """
      [mode.all.mappings]
      "cmd+shift+[" = ["flash", "leave_mode"]
      """
    )
    var commands: [URLCommand] = []
    var replayed = false
    let handler = TerminalInputMappingHandler<String>(
      mappings: config.mode.compiledTerminal, timeoutMs: 1000,
      replay: { _, _ in replayed = true },
      dispatch: { mapping, _ in
        if let command = mapping.action.command { commands.append(command) }
      })
    let event = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
        timestamp: 0, windowNumber: 0, context: nil, characters: "{",
        charactersIgnoringModifiers: "{", isARepeat: false, keyCode: UInt16(kVK_ANSI_LeftBracket)))
    handler.handle(event: event, origin: "popup")
    XCTAssertEqual(commands, [.leaveMode])
    XCTAssertFalse(replayed)
  }

  func testExplicitTerminalMappingOverridesInheritedLeaveMode() throws {
    let config = ConfigLoader.parse(
      """
      [mode.all.mappings]
      "cmd+shift+[" = ["flash", "leave_mode"]
      [mode.terminal.mappings]
      "cmd+shift+[" = ["flash", "terminal_restart"]
      """
    )
    XCTAssertTrue(config.loadingDiagnostics.isEmpty)
    let key = try XCTUnwrap(NormalModeInterpreter.canonicalizeMappingKey("cmd+shift+["))
    XCTAssertEqual(
      config.mode.compiledTerminal.mapping(for: key)?.action.command,
      .terminalRestart(name: nil))
  }

  private func mapping(_ key: String, _ command: URLCommand) -> ModeMapping {
    ModeMapping(key: key, action: .flashCommand(command))
  }
}
