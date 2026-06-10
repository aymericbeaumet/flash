import Carbon.HIToolbox
import FlashCore
import XCTest

@testable import flash

final class HotkeySyntaxTests: XCTestCase {

  func testSingleModifier() {
    let r = HotkeySyntax.parse(hotkey: "cmd+h")
    XCTAssertEqual(r?.modifiers, UInt32(cmdKey))
    XCTAssertEqual(r?.virtualKey, 0x04)  // h
  }

  func testMultipleModifiersJoinedByPlus() {
    let r = HotkeySyntax.parse(hotkey: "cmd+ctrl+a")
    XCTAssertEqual(r?.modifiers, UInt32(cmdKey | controlKey))
    XCTAssertEqual(r?.virtualKey, 0x00)  // a
  }

  func testAllFourModifiers() {
    let r = HotkeySyntax.parse(hotkey: "cmd+shift+ctrl+alt+1")
    let expected = UInt32(cmdKey | shiftKey | controlKey | optionKey)
    XCTAssertEqual(r?.modifiers, expected)
    XCTAssertEqual(r?.virtualKey, 0x12)  // 1
  }

  func testNamedKeys() {
    XCTAssertEqual(
      HotkeySyntax.parse(hotkey: "cmd+return")?.virtualKey,
      UInt32(kVK_Return))
    XCTAssertEqual(
      HotkeySyntax.parse(hotkey: "ctrl+alt+left")?.virtualKey,
      UInt32(kVK_LeftArrow))
    XCTAssertEqual(
      HotkeySyntax.parse(hotkey: "ctrl+space")?.virtualKey,
      UInt32(kVK_Space))
  }

  func testCaseInsensitive() {
    let upper = HotkeySyntax.parse(hotkey: "CMD+CTRL+A")
    let lower = HotkeySyntax.parse(hotkey: "cmd+ctrl+a")
    XCTAssertEqual(upper?.modifiers, lower?.modifiers)
    XCTAssertEqual(upper?.virtualKey, lower?.virtualKey)
  }

  func testAliasesMapToSameFlag() {
    let a = HotkeySyntax.parse(hotkey: "command+option+control+a")
    let b = HotkeySyntax.parse(hotkey: "cmd+opt+ctrl+a")
    let c = HotkeySyntax.parse(hotkey: "cmd+alt+ctrl+a")
    XCTAssertEqual(a?.modifiers, b?.modifiers)
    XCTAssertEqual(b?.modifiers, c?.modifiers)
  }

  func testRawHexKeyCode() {
    let r = HotkeySyntax.parse(hotkey: "cmd+0x32")
    XCTAssertEqual(r?.virtualKey, 0x32)
  }

  func testShiftedPunctuationAliasesUsePhysicalKey() {
    XCTAssertEqual(
      HotkeySyntax.parse(hotkey: "cmd+shift+{")?.virtualKey,
      UInt32(kVK_ANSI_LeftBracket))
    XCTAssertEqual(
      HotkeySyntax.parse(hotkey: "cmd+shift+}")?.virtualKey,
      UInt32(kVK_ANSI_RightBracket))
    XCTAssertEqual(
      HotkeySyntax.parse(hotkey: "cmd+shift+?")?.virtualKey,
      UInt32(kVK_ANSI_Slash))
    XCTAssertEqual(
      HotkeySyntax.parse(hotkey: "cmd+shift+~")?.virtualKey,
      UInt32(kVK_ANSI_Grave))
  }

  func testBraceHotkeysKeepCommandShiftModifiers() {
    let r = HotkeySyntax.parse(hotkey: "cmd+shift+}")
    XCTAssertEqual(r?.modifiers, UInt32(cmdKey | shiftKey))
    XCTAssertEqual(r?.virtualKey, UInt32(kVK_ANSI_RightBracket))
  }

  func testInvalidKeyReturnsNil() {
    XCTAssertNil(HotkeySyntax.parse(hotkey: "cmd+nothing"))
    XCTAssertNil(HotkeySyntax.parse(hotkey: ""))
  }

  func testAllScopeCommandMappingsDispatchInNormalMode() {
    XCTAssertTrue(
      MappingsCoordinator.mappingApplies(
        scope: .all,
        currentMode: .normal,
        modifiers: UInt32(cmdKey)))
    XCTAssertTrue(
      MappingsCoordinator.mappingApplies(
        scope: .all,
        currentMode: .insert,
        modifiers: UInt32(cmdKey)))
  }

  func testNormalScopeCommandMappingsDispatchInNormalMode() {
    // `[mode.normal.mappings]` cmd-prefixed mappings must fire when in
    // normal mode. The previous behaviour blocked them, which meant
    // configuring `"cmd+a" = "flash://..."` under `[mode.normal.mappings]`
    // silently did nothing.
    XCTAssertTrue(
      MappingsCoordinator.mappingApplies(
        scope: .normal,
        currentMode: .normal,
        modifiers: UInt32(cmdKey | shiftKey)))
    XCTAssertTrue(
      MappingsCoordinator.mappingApplies(
        scope: .normal,
        currentMode: .normal,
        modifiers: UInt32(optionKey)))
    // Normal-scope cmd-mappings must NOT fire when we're in insert mode.
    XCTAssertFalse(
      MappingsCoordinator.mappingApplies(
        scope: .normal,
        currentMode: .insert,
        modifiers: UInt32(cmdKey)))
  }

  func testScopeIsActiveGovernsCarbonRegistration() {
    // `applyForFlashMode` filters Carbon registrations through
    // `scopeIsActive`. A `.normal`-scope mapping (e.g. `cmd+tab`) must
    // be **unregistered** in insert mode so the Dock app switcher gets
    // the key combo. `.all` mappings stay registered in both modes.
    XCTAssertTrue(MappingsCoordinator.scopeIsActive(.all, for: .normal))
    XCTAssertTrue(MappingsCoordinator.scopeIsActive(.all, for: .insert))
    XCTAssertTrue(MappingsCoordinator.scopeIsActive(.normal, for: .normal))
    XCTAssertFalse(MappingsCoordinator.scopeIsActive(.normal, for: .insert))
    XCTAssertFalse(MappingsCoordinator.scopeIsActive(.insert, for: .normal))
    XCTAssertTrue(MappingsCoordinator.scopeIsActive(.insert, for: .insert))
  }

  func testDefaultNormalMappingsIncludeCmdTab() {
    let cmdTab = Config.Mode.defaultNormalMappings.first { $0.key == "cmd+tab" }
    XCTAssertEqual(cmdTab?.action.command, .appNext)
    let cmdShiftTab = Config.Mode.defaultNormalMappings.first {
      $0.key == "cmd+shift+tab"
    }
    XCTAssertEqual(cmdShiftTab?.action.command, .appPrev)
  }

  // MARK: - Action parsing

  func testParseFlashMouseTarget() {
    let action = parseMappingCommand(rawString: "flash://mouse_target")
    guard case .flashCommand(let cmd) = action else {
      return XCTFail("expected .flashCommand")
    }
    if case .mouseTarget(.click(let hintAction)) = cmd {
      XCTAssertEqual(hintAction, .leftClick)
    } else {
      XCTFail("expected .mouseTarget, got \(cmd)")
    }

    XCTAssertEqual(
      parseMappingCommand(rawString: "flash://mouse_target?secondary=1")?.command,
      .mouseTarget(.click(.rightClick)))
    XCTAssertEqual(
      parseMappingCommand(rawString: "flash://mouse_target?double=1")?.command,
      .mouseTarget(.click(.doubleClick)))
    XCTAssertEqual(
      parseMappingCommand(rawString: "flash://mouse_target?move=1")?.command,
      .mouseTarget(.move))
    XCTAssertEqual(
      parseMappingCommand(rawString: "flash://mouse_grid?move=1")?.command,
      .mouseGrid(.move))
    XCTAssertEqual(
      parseMappingCommand(rawString: "flash://mouse_snipe?move=1")?.command,
      .mouseGrid(.move))
    XCTAssertEqual(
      parseMappingCommand(rawString: "flash://mouse_click")?.command,
      .mouseTarget(.click(.leftClick)))
    XCTAssertNil(parseMappingCommand(rawString: "flash://mouse_move"))
  }

  func testParseFlashNormalMode() {
    let action = parseMappingCommand(rawString: "flash://mode_normal")
    guard case .flashCommand(.normalMode) = action else {
      return XCTFail("expected .normalMode")
    }
  }

  func testParseFlashOpenApp() {
    let action = parseMappingCommand(rawString: "flash://app_open?name=Alacritty")
    guard case .flashCommand(let cmd) = action else {
      return XCTFail("expected .flashCommand")
    }
    if case .openApp(let name) = cmd {
      XCTAssertEqual(name, "Alacritty")
    } else {
      XCTFail("expected .openApp")
    }
  }

  func testParseFlashOpenAppWithSpaces() {
    let action = parseMappingCommand(rawString: "flash://app_open?name=Postico%202")
    guard case .flashCommand(.openApp(let name)) = action else {
      return XCTFail("expected .openApp")
    }
    XCTAssertEqual(name, "Postico 2")
  }

  func testParseFlashShowAlert() {
    let action = parseMappingCommand(rawString: "flash://alert_show?message=Wi-Fi%20OFF")
    guard case .flashCommand(.showAlert(let message)) = action else {
      return XCTFail("expected .showAlert")
    }
    XCTAssertEqual(message, "Wi-Fi OFF")
  }

  func testParseFlashDismissAlert() {
    let action = parseMappingCommand(rawString: "flash://alert_dismiss")
    guard case .flashCommand(.dismissAlert) = action else {
      return XCTFail("expected .dismissAlert")
    }
  }

  func testParseFlashHelp() {
    let help = parseMappingCommand(rawString: "flash://help_show")
    guard case .flashCommand(.showUsage(topic: nil)) = help else {
      return XCTFail("expected .showUsage for help_show")
    }
    XCTAssertEqual(
      parseMappingCommand(rawString: "flash://help_show?topic=plugins")?.command,
      .showUsage(topic: "plugins"))
  }

  func testParseFlashPlugins() {
    XCTAssertEqual(parseMappingCommand(rawString: "flash://plugins")?.command, .showPlugins)
    let action = parseMappingCommand(
      rawString: "flash://plugin_command?command=spotify&subcommand=pause&args=quiet")
    guard case .flashCommand(.pluginCommand(let command, let subcommand, let args)) = action else {
      return XCTFail("expected .pluginCommand")
    }
    XCTAssertEqual(command, "spotify")
    XCTAssertEqual(subcommand, "pause")
    XCTAssertEqual(args, ["quiet"])
  }

  func testNonFlashStringIsRejected() {
    // Mapping actions must be `flash://...` URLs.
    XCTAssertNil(parseMappingCommand(rawString: "https://example.com"))
    XCTAssertNil(parseMappingCommand(rawString: "/Applications/Safari.app"))
    XCTAssertNil(parseMappingCommand(rawString: "Safari"))
    XCTAssertNil(parseMappingCommand(rawString: "open -a Foo"))
  }

  func testShellCommandActionDiagnosticUsesArraySyntax() {
    let action = MappingCommand.shellCommand(["sh", "~/.dotfiles/scripts/toggle-colors"])
    XCTAssertEqual(action.diagnosticDescription, "[\"sh\", \"~/.dotfiles/scripts/toggle-colors\"]")
    XCTAssertNil(action.command)
  }

  func testCommandMappingRunnerLaunchPlanUsesEnvForBareExecutable() throws {
    let plan = try XCTUnwrap(
      CommandMappingRunner.launchPlan(for: ["sh", "~/.dotfiles/scripts/toggle-colors"]))
    XCTAssertEqual(plan.executableURL.path, "/usr/bin/env")
    XCTAssertEqual(plan.arguments.first, "sh")
    XCTAssertEqual(
      plan.arguments.dropFirst().first,
      FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".dotfiles/scripts/toggle-colors").path)
  }

  func testCommandMappingRunnerLaunchPlanExpandsDirectExecutable() throws {
    let plan = try XCTUnwrap(
      CommandMappingRunner.launchPlan(for: ["~/bin/toggle-colors", "--quiet"]))
    XCTAssertEqual(
      plan.executableURL.path,
      FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("bin/toggle-colors").path)
    XCTAssertEqual(plan.arguments, ["--quiet"])
  }

  func testParseFlashModeActions() {
    XCTAssertEqual(parseMappingCommand(rawString: "flash://mode_insert")?.command, .insertMode)
    XCTAssertEqual(parseMappingCommand(rawString: "flash://mode_command")?.command, .commandMode)
    XCTAssertEqual(parseMappingCommand(rawString: "flash://url_copy")?.command, .copyURL)
    XCTAssertEqual(
      parseMappingCommand(rawString: "flash://app_open_finder")?.command,
      .candidateFinder(all: false))
    XCTAssertEqual(
      parseMappingCommand(rawString: "flash://app_open_finder?all=1")?.command,
      .candidateFinder(all: true))
    XCTAssertEqual(parseMappingCommand(rawString: "flash://app_reload")?.command, .reload(force: false))
    XCTAssertEqual(
      parseMappingCommand(rawString: "flash://app_reload?force=1")?.command,
      .reload(force: true))
    XCTAssertEqual(parseMappingCommand(rawString: "flash://flashlight")?.command, .flashlight)
    XCTAssertEqual(parseMappingCommand(rawString: "flash://tab_next")?.command, .tabNext)
    XCTAssertEqual(parseMappingCommand(rawString: "flash://tab_previous")?.command, .tabPrev)
    XCTAssertEqual(parseMappingCommand(rawString: "flash://tab_select")?.command, .tabSelect(index: nil))
    XCTAssertEqual(parseMappingCommand(rawString: "flash://tab_select?index=4")?.command, .tabSelect(index: 4))
    XCTAssertEqual(parseMappingCommand(rawString: "flash://tab_new")?.command, .tabNew)
    XCTAssertEqual(parseMappingCommand(rawString: "flash://tab_close")?.command, .tabClose)
    XCTAssertEqual(parseMappingCommand(rawString: "flash://history_back")?.command, .historyBack)
    XCTAssertEqual(parseMappingCommand(rawString: "flash://history_forward")?.command, .historyForward)
    XCTAssertEqual(parseMappingCommand(rawString: "flash://movement_back")?.command, .movementBack)
    XCTAssertEqual(parseMappingCommand(rawString: "flash://movement_forward")?.command, .movementForward)
    XCTAssertEqual(parseMappingCommand(rawString: "flash://app_previous")?.command, .appPrev)
    XCTAssertEqual(parseMappingCommand(rawString: "flash://app_next")?.command, .appNext)
    XCTAssertEqual(parseMappingCommand(rawString: "flash://app_quit")?.command, .quitApp(force: false))
    XCTAssertEqual(
      parseMappingCommand(rawString: "flash://app_quit?force=1")?.command,
      .quitApp(force: true))
    XCTAssertEqual(
      parseMappingCommand(rawString: "flash://app_save_and_quit")?.command,
      .saveAndQuit(force: false))
    XCTAssertEqual(
      parseMappingCommand(rawString: "flash://app_save_and_quit?force=1")?.command,
      .saveAndQuit(force: true))
  }

  func testInvalidFlashURLRejected() {
    XCTAssertNil(parseMappingCommand(rawString: "flash://unknown_command"))
    XCTAssertNil(parseMappingCommand(rawString: "flash://app_open"))  // no name
    XCTAssertNil(parseMappingCommand(rawString: "flash://alert_show"))  // no message
    XCTAssertNil(parseMappingCommand(rawString: "flash://show_alert"))  // alias removed
    XCTAssertNil(parseMappingCommand(rawString: "flash://plugin_command?command=spotify"))  // no subcommand
    XCTAssertNil(parseMappingCommand(rawString: "flash://usage"))
  }

  func testParseFlashMoveWindowPositionOnly() {
    let action = parseMappingCommand(
      rawString: "flash://window_move?position=lefthalf")
    guard case .flashCommand(.moveWindow(let params)) = action else {
      return XCTFail("expected .moveWindow")
    }
    XCTAssertEqual(params.position, .leftHalf)
    XCTAssertEqual(params.screen, 0)
  }

  func testParseFlashMoveWindowScreenOnly() {
    // `screen=+1` with no `position` is the multi-monitor "move
    // this window to the next display" form. Position must remain
    // nil so WindowMover does a proportional remap instead of
    // snapping to a fixed slot.
    let next = parseMappingCommand(
      rawString: "flash://window_move?screen=+1")
    guard case .flashCommand(.moveWindow(let nextP)) = next else {
      return XCTFail("expected .moveWindow for screen=+1")
    }
    XCTAssertNil(nextP.position)
    XCTAssertEqual(nextP.screen, 1)

    let prev = parseMappingCommand(
      rawString: "flash://window_move?screen=-1")
    guard case .flashCommand(.moveWindow(let prevP)) = prev else {
      return XCTFail("expected .moveWindow for screen=-1")
    }
    XCTAssertNil(prevP.position)
    XCTAssertEqual(prevP.screen, -1)
  }

  func testParseFlashMoveWindowPositionAndScreen() {
    let action = parseMappingCommand(
      rawString: "flash://window_move?position=maximized&screen=+1")
    guard case .flashCommand(.moveWindow(let params)) = action else {
      return XCTFail("expected .moveWindow")
    }
    XCTAssertEqual(params.position, .maximized)
    XCTAssertEqual(params.screen, 1)
  }

  func testParseFlashMoveWindowRejectsInvalidOrEmpty() {
    // Empty form is rejected — a mapping with no query is always a
    // user error, not a "silent no-op" hotkey.
    XCTAssertNil(parseMappingCommand(rawString: "flash://window_move"))
    // A typo'd position must not silently degrade to "just move
    // screen" — reject so the user sees the parse error in logs.
    XCTAssertNil(
      parseMappingCommand(rawString: "flash://window_move?position=somewhere"))
    // Non-numeric `screen=` is also a parse failure.
    XCTAssertNil(
      parseMappingCommand(rawString: "flash://window_move?screen=next"))
  }

  func testLegacyFlashActionAliasesAreRejected() {
    for raw in [
      "flash://show_hints?right=1",
      "flash://move_mouse",
      "flash://normal_mode",
      "flash://insert_mode",
      "flash://command_mode",
      "flash://half_page_up",
      "flash://half_page_down",
      "flash://reload",
      "flash://undo",
      "flash://redo",
      "flash://close",
      "flash://find",
      "flash://open_candidate_finder?all=1",
      "flash://copy_url",
      "flash://next_frame",
      "flash://main_frame",
      "flash://next_tab",
      "flash://previous_tab",
      "flash://quit_app?force=1",
      "flash://force_quit_app",
      "flash://save",
      "flash://save_and_quit?force=1",
      "flash://print",
      "flash://open",
      "flash://new_window",
      "flash://new_tab",
      "flash://copy",
      "flash://cut",
      "flash://paste",
      "flash://copy_all",
      "flash://dismiss_alert",
      "flash://help",
      "flash://dismiss_hints",
      "flash://quit",
      "flash://open_app?name=Firefox",
      "flash://move_window?position=lefthalf",
    ] {
      XCTAssertNil(parseMappingCommand(rawString: raw), "legacy alias \(raw)")
    }
  }

}
