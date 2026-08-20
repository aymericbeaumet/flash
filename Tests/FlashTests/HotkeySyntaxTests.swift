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

  func testNormalModeModifierSyntaxCanonicalizesModifierOrder() {
    XCTAssertEqual(
      NormalModeInterpreter.canonicalizeMappingKey("shift+cmd+]"),
      NormalModeInterpreter.canonicalizeMappingKey("cmd+shift+]"))
    XCTAssertEqual(
      NormalModeInterpreter.canonicalizeMappingKey("option+command+space"),
      "cmd+alt+space")
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
    // configuring `"cmd+a" = ["flash", "..."]` under `[mode.normal.mappings]`
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
    // The mapping scope filters Carbon registrations through
    // `scopeIsActive`. A `.normal`-scope mapping (e.g. `cmd+tab`) must
    // be **unregistered** in insert mode so the Dock app switcher gets
    // the key combo. `.all` mappings stay registered in every mode, including
    // command-line and candidate-finder surfaces.
    XCTAssertTrue(MappingsCoordinator.scopeIsActive(.all, for: .normal))
    XCTAssertTrue(MappingsCoordinator.scopeIsActive(.all, for: .insert))
    XCTAssertTrue(MappingsCoordinator.scopeIsActive(.all, for: .command))
    XCTAssertTrue(MappingsCoordinator.scopeIsActive(.normal, for: .normal))
    XCTAssertFalse(MappingsCoordinator.scopeIsActive(.normal, for: .insert))
    XCTAssertFalse(MappingsCoordinator.scopeIsActive(.normal, for: .command))
    XCTAssertFalse(MappingsCoordinator.scopeIsActive(.insert, for: .normal))
    XCTAssertTrue(MappingsCoordinator.scopeIsActive(.insert, for: .insert))
    XCTAssertFalse(MappingsCoordinator.scopeIsActive(.insert, for: .command))
  }

  func testDefaultNormalMappingsOmitCmdChords() {
    XCTAssertNil(Config.Mode.defaultNormalMappings.first { $0.key == "cmd+tab" })
    XCTAssertNil(Config.Mode.defaultNormalMappings.first { $0.key == "cmd+shift+tab" })
  }

  // MARK: - Action parsing

  func testParseFlashMouseTarget() {
    let action = parseMappingCommand(argv: ["flash", "mouse_target"])
    guard case .flashCommand(let cmd) = action else {
      return XCTFail("expected .flashCommand")
    }
    if case .mouseTarget(.click(let hintAction, let modifiers)) = cmd {
      XCTAssertEqual(hintAction, .leftClick)
      XCTAssertTrue(modifiers.isEmpty)
    } else {
      XCTFail("expected .mouseTarget, got \(cmd)")
    }

    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse_target", "--secondary"])?.command,
      .mouseTarget(.click(.rightClick, modifiers: [])))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse_target", "--double"])?.command,
      .mouseTarget(.click(.doubleClick, modifiers: [])))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse_target", "--middle"])?.command,
      .mouseTarget(.click(.middleClick, modifiers: [])))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse_target", "--triple"])?.command,
      .mouseTarget(.click(.tripleClick, modifiers: [])))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse_grid", "--middle"])?.command,
      .mouseGrid(.click(.middleClick, modifiers: [])))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse_target", "--drag"])?.command,
      .mouseTarget(.drag(modifiers: [])))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse_grid", "--drag"])?.command,
      .mouseGrid(.drag(modifiers: [])))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse_target", "--drag", "--modifiers=alt"])?.command,
      .mouseTarget(.drag(modifiers: .option)))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse_target", "--select"])?.command,
      .mouseTarget(.select(modifiers: [])))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse_grid", "--select"])?.command,
      .mouseGrid(.select(modifiers: [])))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse_target", "--multi"])?.command,
      .mouseTarget(.multi(.leftClick, modifiers: [])))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse_target", "--multi", "--secondary"])?.command,
      .mouseTarget(.multi(.rightClick, modifiers: [])))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse_grid", "--multi", "--modifiers=cmd"])?.command,
      .mouseGrid(.multi(.leftClick, modifiers: .command)))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse_target", "--move"])?.command,
      .mouseTarget(.move))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse_grid", "--move"])?.command,
      .mouseGrid(.move))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse_snipe", "--move"])?.command,
      .mouseGrid(.move))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse_click"])?.command,
      .mouseTarget(.click(.leftClick, modifiers: [])))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse_target", "--modifiers=cmd"])?.command,
      .mouseTarget(.click(.leftClick, modifiers: .command)))
    XCTAssertEqual(
      parseMappingCommand(
        argv: ["flash", "mouse_grid", "--modifiers=shift+command+ctrl"]
      )?.command,
      .mouseGrid(.click(.leftClick, modifiers: [.command, .control, .shift])))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse_target", "--modifiers=bogus"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse_grid", "--modifiers="]))
    XCTAssertNil(
      parseMappingCommand(argv: ["flash", "mouse_target", "--move", "--modifiers=cmd"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse_move"]))
    // Click variants are mutually exclusive.
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse_target", "--secondary", "--double"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse_target", "--middle", "--secondary"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse_target", "--triple", "--double"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse_grid", "--middle", "--triple"]))
    // Drag/select compose with modifiers only — not with move, click
    // variants, or each other.
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse_target", "--drag", "--move"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse_target", "--drag", "--double"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse_grid", "--drag", "--secondary"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse_target", "--select", "--move"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse_target", "--select", "--triple"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse_target", "--drag", "--select"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse_target", "--multi", "--drag"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse_target", "--multi", "--move"]))
  }

  func testParseEnterCommandRestoreMode() {
    // `enter_command_mode --input='emojis '` is the replacement for the
    // old `emojis` verb. `--restore-mode` is the mode-preserve flag —
    // internally the dict key is still `restore_mode` because flag names
    // are normalized hyphen → underscore.
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "enter_command_mode", "--input=flashlight "])?.command,
      .enterCommand(input: "flashlight ", restoreMode: false))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "enter_command_mode", "--input=emojis "])?.command,
      .enterCommand(input: "emojis ", restoreMode: false))
    // Bare flag (no `=`) and `--restore-mode=1` both turn the bool on.
    XCTAssertEqual(
      parseMappingCommand(
        argv: ["flash", "enter_command_mode", "--input=emojis ", "--restore-mode"]
      )?.command,
      .enterCommand(input: "emojis ", restoreMode: true))
    XCTAssertEqual(
      parseMappingCommand(
        argv: ["flash", "enter_command_mode", "--input=flashlight ", "--restore-mode=1"]
      )?.command,
      .enterCommand(input: "flashlight ", restoreMode: true))
    // Leading colons are stripped (one `:` is later prepended for display);
    // everything after the last leading `:` is passed through verbatim. Trailing
    // whitespace is meaningful and never trimmed — the user controls whether
    // they want command-completion (`--input=:open`) or an empty-query opening
    // of the verb (`--input=:open `).
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "enter_command_mode", "--input=:open"])?.command,
      .enterCommand(input: "open", restoreMode: false))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "enter_command_mode", "--input=::: open"])?.command,
      .enterCommand(input: " open", restoreMode: false))
    // `--input` is optional only for the plain command-mode switch.
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "enter_command_mode"])?.command, .commandMode)
    XCTAssertNil(parseMappingCommand(argv: ["flash", "enter_command_mode", "--input="]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "enter_command_mode", "--restore-mode"]))
    // The old command-line verb is gone.
    XCTAssertNil(parseMappingCommand(argv: ["flash", "enter_command"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "enter_command", "--input=flashlight "]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mode_normal"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mode_insert"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mode_command"]))
    // The old dedicated verbs are gone — the parser must reject them so
    // a stale config surfaces a clear failure instead of silently doing
    // nothing.
    XCTAssertNil(parseMappingCommand(argv: ["flash", "flashlight"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "emojis"]))
  }

  func testParseFlashNormalMode() {
    let action = parseMappingCommand(argv: ["flash", "enter_normal_mode"])
    guard case .flashCommand(.normalMode) = action else {
      return XCTFail("expected .normalMode")
    }
  }

  func testParseFlashOpenApp() {
    let action = parseMappingCommand(argv: ["flash", "app_open", "--name=Alacritty"])
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
    let action = parseMappingCommand(argv: ["flash", "app_open", "--name=Postico 2"])
    guard case .flashCommand(.openApp(let name)) = action else {
      return XCTFail("expected .openApp")
    }
    XCTAssertEqual(name, "Postico 2")
  }

  func testParseFlashSendKeys() {
    let action = parseMappingCommand(argv: ["flash", "send_keys", "--keys=g,i"])
    guard case .flashCommand(.sendKeys(let keys, let keyCodes, let flagsRawValues)) = action else {
      return XCTFail("expected .sendKeys")
    }
    XCTAssertEqual(keys, "g,i")
    XCTAssertEqual(keyCodes, [CGKeyCode(kVK_ANSI_G), CGKeyCode(kVK_ANSI_I)])
    XCTAssertEqual(flagsRawValues, [0, 0])
    XCTAssertNil(parseMappingCommand(argv: ["flash", "send_keys"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "send_keys", "--keys=g,,i"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "send_keys", "--keys=nope"]))
  }

  func testParseFlashShowAlert() {
    let action = parseMappingCommand(argv: ["flash", "alert_show", "--message=Wi-Fi OFF"])
    guard case .flashCommand(.showAlert(let alert)) = action else {
      return XCTFail("expected .showAlert")
    }
    XCTAssertEqual(alert.message, "Wi-Fi OFF")
    XCTAssertNil(alert.duration)
    XCTAssertEqual(alert.style, .standard)
  }

  func testParseFlashShowAlertOptions() {
    let action = parseMappingCommand(argv: [
      "flash", "alert_show", "--message=Sleep toggling", "--duration=0.75", "--style=error",
    ])
    guard case .flashCommand(.showAlert(let alert)) = action else {
      return XCTFail("expected .showAlert")
    }
    XCTAssertEqual(alert.message, "Sleep toggling")
    XCTAssertEqual(alert.duration, 0.75)
    XCTAssertEqual(alert.style, .error)
  }

  func testParseFlashDismissAlert() {
    let action = parseMappingCommand(argv: ["flash", "alert_dismiss"])
    guard case .flashCommand(.dismissAlert) = action else {
      return XCTFail("expected .dismissAlert")
    }
  }

  func testParseFlashHelp() {
    let help = parseMappingCommand(argv: ["flash", "help_show"])
    guard case .flashCommand(.showUsage(topic: nil)) = help else {
      return XCTFail("expected .showUsage for help_show")
    }
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "help_show", "--topic=plugins"])?.command,
      .showUsage(topic: "plugins"))
  }

  func testParseFlashPlugins() {
    XCTAssertEqual(parseMappingCommand(argv: ["flash", "plugins"])?.command, .showPlugins)
    XCTAssertEqual(parseMappingCommand(argv: ["flash", "about"])?.command, .showAbout)
    let action = parseMappingCommand(argv: [
      "flash", "plugin_command", "--command=spotify", "--subcommand=pause", "--args=quiet",
    ])
    guard case .flashCommand(.pluginCommand(let command, let subcommand, let args)) = action else {
      return XCTFail("expected .pluginCommand")
    }
    XCTAssertEqual(command, "spotify")
    XCTAssertEqual(subcommand, "pause")
    XCTAssertEqual(args, ["quiet"])
  }

  func testNonFlashArgvIsTreatedAsShellCommand() {
    // Any array whose head doesn't name Flash is a shell command (argv exec).
    // The empty array is the only rejection: nothing to run.
    XCTAssertNil(parseMappingCommand(argv: []))
    let safariCmd = parseMappingCommand(argv: ["open", "-a", "Safari"])
    if case .shellCommand(let argv)? = safariCmd {
      XCTAssertEqual(argv, ["open", "-a", "Safari"])
    } else {
      XCTFail("expected .shellCommand for non-flash head")
    }
  }

  func testFlashExecutablePathArgvIsInProcessCommand() {
    XCTAssertEqual(
      parseMappingCommand(
        argv: ["/Applications/Flash.app/Contents/MacOS/flash", "tab_next"]
      )?.command,
      .tabNext)
    XCTAssertEqual(
      parseMappingCommand(
        argv: ["~/.local/bin/flash", "enter_command_mode", "--input=flashlight "]
      )?.command,
      .enterCommand(input: "flashlight ", restoreMode: false))
    XCTAssertNil(
      parseMappingCommand(
        argv: ["/Applications/Flash.app/Contents/MacOS/flash", "unknown_command"]))
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

  func testCommandMappingRunnerRefusesFlashExecutable() {
    XCTAssertNil(CommandMappingRunner.launchPlan(for: ["flash", "tab_next"]))
    XCTAssertNil(
      CommandMappingRunner.launchPlan(
        for: ["/Applications/Flash.app/Contents/MacOS/flash", "tab_next"]))
    XCTAssertNil(CommandMappingRunner.launchPlan(for: ["~/.local/bin/flash", "tab_next"]))
  }

  func testParseFlashModeActions() {
    XCTAssertEqual(parseMappingCommand(argv: ["flash", "enter_insert_mode"])?.command, .insertMode)
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "enter_locked_insert_mode"])?.command,
      .lockedInsertMode)
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "enter_command_mode"])?.command, .commandMode)
    XCTAssertEqual(parseMappingCommand(argv: ["flash", "url_copy"])?.command, .copyURL)
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "app_open_finder"])?.command,
      .candidateFinder(all: false))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "app_open_finder", "--all"])?.command,
      .candidateFinder(all: true))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "app_reload"])?.command, .reload(force: false))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "app_reload", "--force"])?.command,
      .reload(force: true))
    XCTAssertEqual(parseMappingCommand(argv: ["flash", "resource_archive"])?.command, .archive)
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "resource_next"])?.command, .resourceNext)
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "resource_previous"])?.command, .resourcePrevious)
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "enter_command_mode", "--input=flashlight "])?.command,
      .enterCommand(input: "flashlight ", restoreMode: false))
    XCTAssertEqual(parseMappingCommand(argv: ["flash", "tab_next"])?.command, .tabNext)
    XCTAssertEqual(parseMappingCommand(argv: ["flash", "tab_previous"])?.command, .tabPrev)
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "tab_select"])?.command, .tabSelect(index: nil))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "tab_select", "--index=4"])?.command,
      .tabSelect(index: 4))
    XCTAssertEqual(parseMappingCommand(argv: ["flash", "tab_new"])?.command, .tabNew)
    XCTAssertEqual(parseMappingCommand(argv: ["flash", "tab_close"])?.command, .tabClose)
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "pane_split_vertical"])?.command,
      .paneSplitVertical)
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "pane_split_horizontal"])?.command,
      .paneSplitHorizontal)
    XCTAssertEqual(parseMappingCommand(argv: ["flash", "pane_close"])?.command, .paneClose)
    XCTAssertEqual(parseMappingCommand(argv: ["flash", "history_back"])?.command, .historyBack)
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "history_forward"])?.command, .historyForward)
    XCTAssertEqual(parseMappingCommand(argv: ["flash", "movement_back"])?.command, .movementBack)
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "movement_forward"])?.command, .movementForward)
    XCTAssertEqual(parseMappingCommand(argv: ["flash", "app_previous"])?.command, .appPrev)
    XCTAssertEqual(parseMappingCommand(argv: ["flash", "app_next"])?.command, .appNext)
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "app_quit"])?.command, .quitApp(force: false))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "app_quit", "--force"])?.command,
      .quitApp(force: true))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "app_save_and_quit"])?.command,
      .saveAndQuit(force: false))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "app_save_and_quit", "--force"])?.command,
      .saveAndQuit(force: true))
    XCTAssertEqual(parseMappingCommand(argv: ["flash", "quit"])?.command, .quit)
  }

  func testInvalidFlashURLRejected() {
    XCTAssertNil(parseMappingCommand(argv: ["flash", "unknown_command"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "app_open"]))  // no name
    XCTAssertNil(parseMappingCommand(argv: ["flash", "alert_show"]))  // no message
    XCTAssertNil(
      parseMappingCommand(argv: ["flash", "alert_show", "--message=x", "--duration=soon"]))
    XCTAssertNil(
      parseMappingCommand(argv: ["flash", "alert_show", "--message=x", "--style=warning"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "show_alert"]))  // alias removed
    // no subcommand
    XCTAssertNil(parseMappingCommand(argv: ["flash", "plugin_command", "--command=spotify"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "usage"]))
    // Old `flash_quit` spelling is gone — `flash quit` is the new form.
    XCTAssertNil(parseMappingCommand(argv: ["flash", "flash_quit"]))
  }

  func testParseFlashMoveWindowPositionOnly() {
    let action = parseMappingCommand(argv: ["flash", "window_move", "--position=lefthalf"])
    guard case .flashCommand(.moveWindow(let params)) = action else {
      return XCTFail("expected .moveWindow")
    }
    XCTAssertEqual(params.position, .leftHalf)
    XCTAssertEqual(params.screen, 0)
  }

  func testParseFlashMoveWindowScreenOnly() {
    // `--screen=+1` with no `--position` is the multi-monitor "move this
    // window to the next display" form. Position must remain nil so
    // WindowMover does a proportional remap instead of snapping to a
    // fixed slot.
    let next = parseMappingCommand(argv: ["flash", "window_move", "--screen=+1"])
    guard case .flashCommand(.moveWindow(let nextP)) = next else {
      return XCTFail("expected .moveWindow for --screen=+1")
    }
    XCTAssertNil(nextP.position)
    XCTAssertEqual(nextP.screen, 1)

    let prev = parseMappingCommand(argv: ["flash", "window_move", "--screen=-1"])
    guard case .flashCommand(.moveWindow(let prevP)) = prev else {
      return XCTFail("expected .moveWindow for --screen=-1")
    }
    XCTAssertNil(prevP.position)
    XCTAssertEqual(prevP.screen, -1)
  }

  func testParseFlashMoveWindowPositionAndScreen() {
    let action = parseMappingCommand(argv: [
      "flash", "window_move", "--position=maximized", "--screen=+1",
    ])
    guard case .flashCommand(.moveWindow(let params)) = action else {
      return XCTFail("expected .moveWindow")
    }
    XCTAssertEqual(params.position, .maximized)
    XCTAssertEqual(params.screen, 1)
  }

  func testParseFlashMoveWindowRejectsInvalidOrEmpty() {
    // Empty form is rejected — a mapping with no query is always a
    // user error, not a "silent no-op" hotkey.
    XCTAssertNil(parseMappingCommand(argv: ["flash", "window_move"]))
    // A typo'd position must not silently degrade to "just move
    // screen" — reject so the user sees the parse error in logs.
    XCTAssertNil(
      parseMappingCommand(argv: ["flash", "window_move", "--position=somewhere"]))
    // Non-numeric `screen=` is also a parse failure.
    XCTAssertNil(
      parseMappingCommand(argv: ["flash", "window_move", "--screen=next"]))
  }

}
