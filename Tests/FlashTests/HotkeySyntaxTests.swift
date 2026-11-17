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
    XCTAssertFalse(MappingsCoordinator.scopeIsActive(.command, for: .normal))
    XCTAssertFalse(MappingsCoordinator.scopeIsActive(.command, for: .insert))
    XCTAssertTrue(MappingsCoordinator.scopeIsActive(.command, for: .command))
  }

  func testDefaultNormalMappingsOmitCmdChords() {
    XCTAssertNil(Config.Mode.defaultNormalMappings.first { $0.key == "cmd+tab" })
    XCTAssertNil(Config.Mode.defaultNormalMappings.first { $0.key == "cmd+shift+tab" })
  }

  // MARK: - Action parsing

  func testParseFlashMouseTarget() {
    let action = parseMappingCommand(argv: ["flash", "mouse", "target"])
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
      parseMappingCommand(argv: ["flash", "mouse", "target", "--secondary"])?.command,
      .mouseTarget(.click(.rightClick, modifiers: [])))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse", "target", "--double"])?.command,
      .mouseTarget(.click(.doubleClick, modifiers: [])))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse", "target", "--middle"])?.command,
      .mouseTarget(.click(.middleClick, modifiers: [])))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse", "target", "--triple"])?.command,
      .mouseTarget(.click(.tripleClick, modifiers: [])))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse", "grid", "--middle"])?.command,
      .mouseGrid(.init(.click(.middleClick, modifiers: []))))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse", "target", "--drag"])?.command,
      .mouseTarget(.drag(modifiers: [])))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse", "grid", "--drag"])?.command,
      .mouseGrid(.init(.drag(modifiers: []))))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse", "target", "--drag", "--modifiers=alt"])?.command,
      .mouseTarget(.drag(modifiers: .option)))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse", "target", "--select"])?.command,
      .mouseTarget(.select(modifiers: [])))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse", "grid", "--select"])?.command,
      .mouseGrid(.init(.select(modifiers: []))))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse", "target", "--multi"])?.command,
      .mouseTarget(.multi(.leftClick, modifiers: [])))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse", "target", "--multi", "--double"])?.command,
      .mouseTarget(.multi(.doubleClick, modifiers: [])))
    // A secondary click's menu takes the keyboard: it never repeats.
    XCTAssertNil(
      parseMappingCommand(argv: ["flash", "mouse", "target", "--multi", "--secondary"]))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse", "grid", "--multi", "--modifiers=cmd"])?.command,
      .mouseGrid(.init(.multi(.leftClick, modifiers: .command))))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse", "target", "--move"])?.command,
      .mouseTarget(.move))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse", "grid", "--move"])?.command,
      .mouseGrid(.init(.move)))
    // Retired aliases are rejected, not translated.
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse_snipe", "--move"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse_click"]))
    // Bisect and zoom-to-depth combine with every click flag.
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse", "grid", "--bisect", "--secondary"])?.command,
      .mouseGrid(.init(.click(.rightClick, modifiers: []), bisect: true)))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse", "grid", "--bisect", "--drag"])?.command,
      .mouseGrid(.init(.drag(modifiers: []), bisect: true)))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse", "grid", "--zoom-to-depth=2", "--move"])?.command,
      .mouseGrid(.init(.move, zoomToDepth: 2)))
    XCTAssertEqual(
      parseMappingCommand(
        argv: ["flash", "mouse", "grid", "--zoom-to-depth=1", "--bisect", "--double"])?.command,
      .mouseGrid(.init(.click(.doubleClick, modifiers: []), zoomToDepth: 1, bisect: true)))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse", "grid", "--zoom-to-depth=0"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse", "grid", "--zoom-to-depth=-1"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse", "grid", "--zoom-to-depth=deep"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse", "target", "--bisect"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse", "target", "--zoom-to-depth=1"]))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse", "target", "--modifiers=cmd"])?.command,
      .mouseTarget(.click(.leftClick, modifiers: .command)))
    XCTAssertEqual(
      parseMappingCommand(
        argv: ["flash", "mouse", "grid", "--modifiers=shift+command+ctrl"]
      )?.command,
      .mouseGrid(.init(.click(.leftClick, modifiers: [.command, .control, .shift]))))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse", "target", "--modifiers=bogus"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse", "grid", "--modifiers="]))
    XCTAssertNil(
      parseMappingCommand(argv: ["flash", "mouse", "target", "--move", "--modifiers=cmd"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse_move"]))
    // Click variants are mutually exclusive.
    XCTAssertNil(
      parseMappingCommand(argv: ["flash", "mouse", "target", "--secondary", "--double"]))
    XCTAssertNil(
      parseMappingCommand(argv: ["flash", "mouse", "target", "--middle", "--secondary"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse", "target", "--triple", "--double"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse", "grid", "--middle", "--triple"]))
    // Drag/select compose with modifiers only — not with move, click
    // variants, or each other.
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse", "target", "--drag", "--move"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse", "target", "--drag", "--double"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse", "grid", "--drag", "--secondary"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse", "target", "--select", "--move"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse", "target", "--select", "--triple"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse", "target", "--drag", "--select"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse", "target", "--multi", "--drag"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse", "target", "--multi", "--move"]))
    // mouse repeat takes no arguments.
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse", "repeat"])?.command, .mouseRepeat)
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse", "repeat", "--secondary"]))
    // Adjust: mouse target only, exclusive with the other session flags.
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse", "target", "--adjust"])?.command,
      .mouseTarget(.adjust(.leftClick, modifiers: [])))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse", "target", "--adjust", "--secondary"])?.command,
      .mouseTarget(.adjust(.rightClick, modifiers: [])))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse", "grid", "--adjust"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse", "target", "--adjust", "--multi"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse", "target", "--adjust", "--drag"]))
    // Pointer mode takes no arguments.
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse", "pointer"])?.command, .mousePointer)
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse", "pointer", "--secondary"]))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "scroll", "target"])?.command, .scrollTarget)
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "input", "focus"])?.command, .focusInput)
    // Search: mouse target only, exclusive with the other session flags.
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse", "target", "--search"])?.command,
      .mouseTarget(.search(.leftClick, modifiers: [])))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse", "target", "--search", "--double"])?.command,
      .mouseTarget(.search(.doubleClick, modifiers: [])))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse", "grid", "--search"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse", "target", "--search", "--multi"]))
    // Screen scope: click variants only, unknown scopes rejected.
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse", "target", "--scope=screen"])?.command,
      .mouseTargetScreen(.click(.leftClick, modifiers: [])))
    XCTAssertEqual(
      parseMappingCommand(
        argv: ["flash", "mouse", "target", "--scope=screen", "--secondary"])?.command,
      .mouseTargetScreen(.click(.rightClick, modifiers: [])))
    XCTAssertNil(
      parseMappingCommand(argv: ["flash", "mouse", "target", "--scope=screen", "--drag"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse", "target", "--scope=window"]))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse", "dock"])?.command, .mouseDock)
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse", "menubar"])?.command, .mouseMenuBar)
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse", "notifications"])?.command, .mouseNotifications)
    XCTAssertNil(
      parseMappingCommand(argv: ["flash", "mouse_statusbar"]),
      "mouse menubar replaced it; no alias remains")
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse", "menubar", "--secondary"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse", "notifications", "--multi"]))
    XCTAssertEqual(URLCommand.mouseMenuBar.diagnosticDescription, "flash mouse menubar")
    XCTAssertEqual(
      URLCommand.mouseNotifications.diagnosticDescription, "flash mouse notifications")
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse", "bigram"])?.command,
      .mouseBigram(.click(.leftClick, modifiers: [])))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse", "bigram", "--move"])?.command,
      .mouseBigram(.move))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mouse", "bigram", "--secondary"])?.command,
      .mouseBigram(.click(.rightClick, modifiers: [])))
    XCTAssertEqual(
      URLCommand.mouseBigram(.click(.doubleClick, modifiers: [])).diagnosticDescription,
      "flash mouse bigram --double")
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse", "bigram", "--drag"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse", "bigram", "--select"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse", "bigram", "--multi"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse", "bigram", "--adjust"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse", "bigram", "--search"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse", "bigram", "--move", "--secondary"]))
  }

  func testParseEnterCommandRestoreMode() {
    // `mode command --input='emojis '` is the replacement for the
    // old `emojis` verb. `--restore-mode` is the mode-preserve flag —
    // internally the dict key is still `restore_mode` because flag names
    // are normalized hyphen → underscore.
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mode", "command", "--input=flashlight "])?.command,
      .enterCommand(input: "flashlight ", restoreMode: false))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mode", "command", "--input=emojis "])?.command,
      .enterCommand(input: "emojis ", restoreMode: false))
    // Bare flag (no `=`) and `--restore-mode=1` both turn the bool on.
    XCTAssertEqual(
      parseMappingCommand(
        argv: ["flash", "mode", "command", "--input=emojis ", "--restore-mode"]
      )?.command,
      .enterCommand(input: "emojis ", restoreMode: true))
    XCTAssertEqual(
      parseMappingCommand(
        argv: ["flash", "mode", "command", "--input=flashlight ", "--restore-mode=1"]
      )?.command,
      .enterCommand(input: "flashlight ", restoreMode: true))
    // Leading colons are stripped (one `:` is later prepended for display);
    // everything after the last leading `:` is passed through verbatim. Trailing
    // whitespace is meaningful and never trimmed — the user controls whether
    // they want command-completion (`--input=:open`) or an empty-query opening
    // of the verb (`--input=:open `).
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mode", "command", "--input=:open"])?.command,
      .enterCommand(input: "open", restoreMode: false))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mode", "command", "--input=::: open"])?.command,
      .enterCommand(input: " open", restoreMode: false))
    // `--input` is optional only for the plain command-mode switch.
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mode", "command"])?.command, .commandMode)
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mode", "command", "--input="]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mode", "command", "--restore-mode"]))
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
    let action = parseMappingCommand(argv: ["flash", "mode", "normal"])
    guard case .flashCommand(.normalMode) = action else {
      return XCTFail("expected .normalMode")
    }
  }

  func testParseFlashOpenApp() {
    let action = parseMappingCommand(argv: ["flash", "app", "open", "--name=Alacritty"])
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
    let action = parseMappingCommand(argv: ["flash", "app", "open", "--name=Postico 2"])
    guard case .flashCommand(.openApp(let name)) = action else {
      return XCTFail("expected .openApp")
    }
    XCTAssertEqual(name, "Postico 2")
  }

  func testParseFlashSendKeys() {
    let action = parseMappingCommand(argv: ["flash", "key", "sequence", "--keys=g,i"])
    guard case .flashCommand(.sendKeys(let keys, let keyCodes, let flagsRawValues)) = action else {
      return XCTFail("expected .sendKeys")
    }
    XCTAssertEqual(keys, "g,i")
    XCTAssertEqual(keyCodes, [CGKeyCode(kVK_ANSI_G), CGKeyCode(kVK_ANSI_I)])
    XCTAssertEqual(flagsRawValues, [0, 0])
    XCTAssertNil(parseMappingCommand(argv: ["flash", "key", "sequence"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "key", "sequence", "--keys=g,,i"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "key", "sequence", "--keys=nope"]))
  }

  func testParseFlashShowAlert() {
    let action = parseMappingCommand(argv: ["flash", "alert", "show", "--message=Wi-Fi OFF"])
    guard case .flashCommand(.showAlert(let alert)) = action else {
      return XCTFail("expected .showAlert")
    }
    XCTAssertEqual(alert.message, "Wi-Fi OFF")
    XCTAssertNil(alert.duration)
    XCTAssertEqual(alert.style, .standard)
  }

  func testParseFlashShowAlertOptions() {
    let action = parseMappingCommand(argv: [
      "flash", "alert", "show", "--message=Sleep toggling", "--duration=0.75", "--style=error",
    ])
    guard case .flashCommand(.showAlert(let alert)) = action else {
      return XCTFail("expected .showAlert")
    }
    XCTAssertEqual(alert.message, "Sleep toggling")
    XCTAssertEqual(alert.duration, 0.75)
    XCTAssertEqual(alert.style, .error)
    let warning = parseMappingCommand(argv: [
      "flash", "alert", "show", "--message=Disk almost full", "--style=warning",
    ])
    guard case .flashCommand(.showAlert(let shown)) = warning else {
      return XCTFail("expected .showAlert")
    }
    XCTAssertEqual(shown.style, .warning)
    XCTAssertEqual(shown.alert.style, .warning)
  }

  func testParseFlashConfirmWrapsACommandLine() throws {
    let action = parseMappingCommand(argv: [
      "flash", "alert", "confirm", "--prompt=Close this window?", "--command=tab close",
    ])
    guard case .flashCommand(.confirm(let request)) = action else {
      return XCTFail("expected .confirm")
    }
    XCTAssertEqual(request.prompt, "Close this window?")
    XCTAssertEqual(request.command, .tabClose)
    XCTAssertEqual(
      URLCommand.confirm(request).argv,
      ["flash", "alert", "confirm", "--prompt=Close this window?", "--command=tab close"],
      "the command line round-trips through argv")

    // The wrapped line takes the same words a mapping would after `flash`:
    // arguments, and a plugin command.
    let withArgs = parseMappingCommand(argv: [
      "flash", "alert", "confirm", "--prompt=Jump?", "--command=tab select --index=2",
    ])
    guard case .flashCommand(.confirm(let selected)) = withArgs else {
      return XCTFail("expected .confirm")
    }
    XCTAssertEqual(selected.command, .tabSelect(index: 2))
    XCTAssertEqual(selected.commandText, "tab select --index=2")
    XCTAssertEqual(
      URLCommand.confirm(selected).explanation,
      "Asks \"Jump?\" first; y then " + URLCommand.tabSelect(index: 2).explanation.lowercasedFirst)
  }

  func testParseFlashConfirmRejectsAMissingQuestionOrCommand() {
    XCTAssertNil(parseMappingCommand(argv: ["flash", "alert", "confirm"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "alert", "confirm", "--prompt=Close?"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "alert", "confirm", "--command=tab close"]))
    XCTAssertNil(
      parseMappingCommand(argv: ["flash", "alert", "confirm", "--prompt= ", "--command=tab close"]))
    XCTAssertNil(
      parseMappingCommand(argv: ["flash", "alert", "confirm", "--prompt=Close?", "--command="]))
    XCTAssertNil(
      parseMappingCommand(argv: [
        "flash", "alert", "confirm", "--prompt=Close?", "--command=no_such_verb",
      ]))
    XCTAssertNil(
      parseMappingCommand(argv: [
        "flash", "alert", "confirm", "--prompt=Close?", "--command=tab select --index=zero",
      ]))
    XCTAssertNil(
      parseMappingCommand(argv: [
        "flash", "alert", "confirm", "--prompt=Twice?",
        "--command=alert confirm --prompt=Again? --command=tab close",
      ]), "a confirmation cannot wrap another one")
  }

  func testParseFlashDismissAlert() {
    let action = parseMappingCommand(argv: ["flash", "alert", "dismiss"])
    guard case .flashCommand(.dismissAlert) = action else {
      return XCTFail("expected .dismissAlert")
    }
  }

  func testParseFlashHelp() {
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mappings", "show"])?.command?.diagnosticDescription,
      "flash mappings show")
    let help = parseMappingCommand(argv: ["flash", "help", "show"])
    guard case .flashCommand(.showUsage(topic: nil)) = help else {
      return XCTFail("expected .showUsage for help show")
    }
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "help", "show", "--topic=plugins"])?.command,
      .showUsage(topic: "plugins"))
  }

  func testParseFlashPlugins() {
    XCTAssertEqual(parseMappingCommand(argv: ["flash", "plugins", "show"])?.command, .showPlugins)
    XCTAssertEqual(parseMappingCommand(argv: ["flash", "about", "show"])?.command, .showAbout)
    XCTAssertNil(
      parseMappingCommand(argv: [
        "flash", "plugin_command", "--command=screenshot", "--subcommand=window", "--args=quiet",
      ]))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "screenshot", "window"])?.diagnosticDescription,
      "flash screenshot window")
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "tmux", "session", "Daft", "Punk"])?
        .diagnosticDescription,
      "flash tmux session Daft Punk")
    XCTAssertNil(
      URLEventHandler.parse(
        topic: "plugin", action: "command", args: ["command": "screenshot", "subcommand": "window"])
    )
  }

  /// A plugin mapping's origin names the plugin for the inspector: its
  /// display name, else its id when the manifest names none.
  func testPluginMappingOriginNamesThePlugin() {
    XCTAssertEqual(ModeMapping.pluginOrigin(id: "tmux", name: "tmux"), "plugin:tmux")
    XCTAssertEqual(ModeMapping.pluginOrigin(id: "spotify", name: " Spotify "), "plugin:Spotify")
    XCTAssertEqual(ModeMapping.pluginOrigin(id: "bare", name: "  "), "plugin:bare")
    let mapping = ModeMapping(
      key: "q", action: .flashCommand(.redo), origin: ModeMapping.pluginOrigin(id: "x", name: ""))
    XCTAssertEqual(mapping.origin, "plugin:x")
    XCTAssertEqual(mapping, ModeMapping(key: "q", action: .flashCommand(.redo)), "display only")
  }

  func testPluginCommandIsAFlashSubcommand() {
    let action = parseMappingCommand(argv: ["flash", "screenshot", "window"])
    guard case .flashCommand(.pluginCommand(let command, let subcommand, let args)) = action else {
      return XCTFail("expected screenshot window, got \(String(describing: action))")
    }
    XCTAssertEqual(command, "screenshot")
    XCTAssertEqual(subcommand, "window")
    XCTAssertEqual(args, [])

    // The tail is the command bar's words: `:tmux session Daft Punk`.
    let positioned = parseMappingCommand(argv: ["flash", "tmux", "session", "Daft", "Punk"])
    guard case .flashCommand(.pluginCommand(_, let session, let queryArgs)) = positioned else {
      return XCTFail("expected tmux session, got \(String(describing: positioned))")
    }
    XCTAssertEqual(session, "session")
    XCTAssertEqual(queryArgs, ["Daft", "Punk"])

    let clipboard = parseMappingCommand(argv: ["flash", "clipboard", "show"])
    guard case .flashCommand(.clipboardHistory(let action, let id, let offset)) = clipboard else {
      return XCTFail("expected core clipboard history, got \(String(describing: clipboard))")
    }
    XCTAssertEqual(action, "show")
    XCTAssertNil(id)
    XCTAssertEqual(offset, 0)
    XCTAssertNil(parseMappingCommand(argv: ["flash", "clipboard", "show", "offset=1"]))
    XCTAssertNil(
      parseMappingCommand(argv: ["flash", "clipboard", "delete", String(repeating: "a", count: 32)])
    )
    XCTAssertNil(parseMappingCommand(argv: ["flash", "clipboard"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "screenshot"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "screenshot", "not-a-subcommand"]))
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
        argv: ["/Applications/Flash.app/Contents/MacOS/flash", "tab", "next"]
      )?.command,
      .tabNext)
    XCTAssertEqual(
      parseMappingCommand(
        argv: ["~/.local/bin/flash", "mode", "command", "--input=flashlight "]
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
    XCTAssertNil(CommandMappingRunner.launchPlan(for: ["flash", "tab", "next"]))
    XCTAssertNil(
      CommandMappingRunner.launchPlan(
        for: ["/Applications/Flash.app/Contents/MacOS/flash", "tab", "next"]))
    XCTAssertNil(CommandMappingRunner.launchPlan(for: ["~/.local/bin/flash", "tab", "next"]))
  }

  /// `mode flashlight` pre-fills the command line with `flashlight `, then the
  /// query and one space: a `@scope` or `!bang` is confirmed as typed, and a
  /// plain query, whose trailing space the matcher trims, reads the same.
  func testTheFlashlightOpensWithItsQueryConfirmed() {
    XCTAssertEqual(URLCommand.flashlightInput(query: nil), "flashlight ")
    XCTAssertEqual(
      URLCommand.flashlightInput(query: "@emojis"), "flashlight @emojis ")
    XCTAssertEqual(URLCommand.flashlightInput(query: "  !clip  "), "flashlight !clip ")
    XCTAssertEqual(URLCommand.flashlightInput(query: "safari"), "flashlight safari ")
    XCTAssertEqual(
      URLCommand.flashlight(query: "@menus", restoreMode: true).argv,
      ["flash", "mode", "flashlight", "--query=@menus", "--restore-mode"])
  }

  func testParseFlashModeActions() {
    XCTAssertEqual(parseMappingCommand(argv: ["flash", "mode", "insert"])?.command, .insertMode)
    XCTAssertNil(parseMappingCommand(argv: ["flash", "enter_locked_insert_mode"]))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mode", "command"])?.command, .commandMode)
    XCTAssertEqual(parseMappingCommand(argv: ["flash", "url", "copy"])?.command, .copyURL)
    XCTAssertEqual(parseMappingCommand(argv: ["flash", "app", "switch"])?.command, .appSwitch)
    XCTAssertNil(
      parseMappingCommand(argv: ["flash", "app", "switch", "--all"]),
      "the whole flashlight is mode flashlight")
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mode", "flashlight"])?.command,
      .flashlight(query: nil, restoreMode: false))
    XCTAssertEqual(
      parseMappingCommand(
        argv: ["flash", "mode", "flashlight", "--query=@emojis", "--restore-mode"])?.command,
      .flashlight(query: "@emojis", restoreMode: true))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mode", "flashlight", "--query="]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mode", "flashlight", "--query=   "]))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "app", "reload"])?.command, .reload(force: false))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "app", "reload", "--force"])?.command,
      .reload(force: true))
    XCTAssertEqual(parseMappingCommand(argv: ["flash", "resource", "archive"])?.command, .archive)
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "resource", "next"])?.command, .resourceNext)
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "resource", "previous"])?.command, .resourcePrevious)
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mode", "command", "--input=flashlight "])?.command,
      .enterCommand(input: "flashlight ", restoreMode: false))
    XCTAssertEqual(parseMappingCommand(argv: ["flash", "tab", "next"])?.command, .tabNext)
    XCTAssertEqual(parseMappingCommand(argv: ["flash", "tab", "previous"])?.command, .tabPrev)
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "tab", "select"])?.command, .tabSelect(index: nil))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "tab", "select", "--index=4"])?.command,
      .tabSelect(index: 4))
    XCTAssertEqual(parseMappingCommand(argv: ["flash", "tab", "new"])?.command, .tabNew)
    XCTAssertEqual(parseMappingCommand(argv: ["flash", "tab", "close"])?.command, .tabClose)
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "pane", "split_vertical"])?.command,
      .paneSplitVertical)
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "pane", "split_horizontal"])?.command,
      .paneSplitHorizontal)
    XCTAssertEqual(parseMappingCommand(argv: ["flash", "pane", "close"])?.command, .paneClose)
    XCTAssertEqual(parseMappingCommand(argv: ["flash", "pane", "next"])?.command, .paneNext)
    XCTAssertEqual(parseMappingCommand(argv: ["flash", "pane", "previous"])?.command, .panePrev)
    XCTAssertEqual(parseMappingCommand(argv: ["flash", "history", "back"])?.command, .historyBack)
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "history", "forward"])?.command, .historyForward)
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "movement", "back"])?.command, .movementBack)
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "movement", "forward"])?.command, .movementForward)
    XCTAssertEqual(parseMappingCommand(argv: ["flash", "app", "previous"])?.command, .appPrev)
    XCTAssertEqual(parseMappingCommand(argv: ["flash", "app", "next"])?.command, .appNext)
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "app", "quit"])?.command, .quitApp(force: false))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "app", "quit", "--force"])?.command,
      .quitApp(force: true))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "app", "save_and_quit"])?.command,
      .saveAndQuit(force: false))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "app", "save_and_quit", "--force"])?.command,
      .saveAndQuit(force: true))
    XCTAssertEqual(parseMappingCommand(argv: ["flash", "resident", "quit"])?.command, .quit)
  }

  func testInvalidFlashURLRejected() {
    XCTAssertNil(parseMappingCommand(argv: ["flash", "screenshot_window"]))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "screenshot", "window"])?.command,
      .pluginCommand(command: "screenshot", subcommand: "window", args: []))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "unknown_command"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "app", "open"]))  // no name
    XCTAssertNil(parseMappingCommand(argv: ["flash", "alert", "show"]))  // no message
    XCTAssertNil(
      parseMappingCommand(argv: ["flash", "alert", "show", "--message=x", "--duration=soon"]))
    XCTAssertNil(
      parseMappingCommand(argv: ["flash", "alert", "show", "--message=x", "--style=loud"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "show_alert"]))  // alias removed
    // no subcommand
    XCTAssertNil(parseMappingCommand(argv: ["flash", "plugin_command", "--command=screenshot"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "usage"]))
    // Old `flash_quit` spelling is gone — `flash resident quit` is the new form.
    XCTAssertNil(parseMappingCommand(argv: ["flash", "flash_quit"]))
  }

  func testParseFlashMoveWindowPositionOnly() {
    let action = parseMappingCommand(argv: ["flash", "window", "move", "--position=lefthalf"])
    guard case .flashCommand(.moveWindow(let params)) = action else {
      return XCTFail("expected .moveWindow")
    }
    XCTAssertEqual(params.layout, .position(.leftHalf))
    XCTAssertEqual(params.screen, 0)
  }

  func testParseWindowStateCommands() {
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "window", "minimize"])?.command,
      .windowState(.minimize))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "window", "restore"])?.command,
      .windowState(.restore))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "window", "fullscreen"])?.command,
      .windowState(.fullscreen(.toggle)))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "window", "fullscreen", "--state=on"])?.command,
      .windowState(.fullscreen(.on)))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "window", "fullscreen", "--state=off"])?.command,
      .windowState(.fullscreen(.off)))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "window", "fullscreen", "--state=toggle"])?
        .diagnosticDescription,
      "flash window fullscreen")
    XCTAssertNil(parseMappingCommand(argv: ["flash", "window", "fullscreen", "--state=invalid"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "window", "minimize", "--state=on"]))
  }

  func testParseFlashMoveWindowProportionalFrame() {
    let action = parseMappingCommand(argv: [
      "flash", "window", "move",
      "--x=10.6925%", "--y=10.6925%",
      "--width=78.615%", "--height=78.615%",
    ])
    guard case .flashCommand(.moveWindow(let params)) = action else {
      return XCTFail("expected .moveWindow")
    }
    XCTAssertEqual(
      params.layout,
      .proportional(
        ProportionalWindowFrame(
          xPercent: 10.6925,
          yPercent: 10.6925,
          widthPercent: 78.615,
          heightPercent: 78.615)))
    XCTAssertEqual(params.screen, 0)
    XCTAssertEqual(
      action?.diagnosticDescription,
      "flash window move --x=10.6925% --y=10.6925% --width=78.615% --height=78.615% --screen=0")
  }

  func testParseFlashMoveWindowScreenOnly() {
    // `--screen=+1` with no `--position` is the multi-monitor "move this
    // window to the next display" form. Layout must remain nil so
    // WindowMover does a proportional remap instead of snapping to a
    // fixed slot.
    let next = parseMappingCommand(argv: ["flash", "window", "move", "--screen=+1"])
    guard case .flashCommand(.moveWindow(let nextP)) = next else {
      return XCTFail("expected .moveWindow for --screen=+1")
    }
    XCTAssertNil(nextP.layout)
    XCTAssertEqual(nextP.screen, 1)

    let prev = parseMappingCommand(argv: ["flash", "window", "move", "--screen=-1"])
    guard case .flashCommand(.moveWindow(let prevP)) = prev else {
      return XCTFail("expected .moveWindow for --screen=-1")
    }
    XCTAssertNil(prevP.layout)
    XCTAssertEqual(prevP.screen, -1)
  }

  func testParseFlashMoveWindowPositionAndScreen() {
    let action = parseMappingCommand(argv: [
      "flash", "window", "move", "--position=maximized", "--screen=+1",
    ])
    guard case .flashCommand(.moveWindow(let params)) = action else {
      return XCTFail("expected .moveWindow")
    }
    XCTAssertEqual(params.layout, .position(.maximized))
    XCTAssertEqual(params.screen, 1)
  }

  func testParseFlashMoveWindowRejectsInvalidOrEmpty() {
    // Empty form is rejected — a mapping with no query is always a
    // user error, not a "silent no-op" hotkey.
    XCTAssertNil(parseMappingCommand(argv: ["flash", "window", "move"]))
    // A typo'd position must not silently degrade to "just move
    // screen" — reject so the user sees the parse error in logs.
    XCTAssertNil(
      parseMappingCommand(argv: ["flash", "window", "move", "--position=somewhere"]))
    // Non-numeric `screen=` is also a parse failure.
    XCTAssertNil(
      parseMappingCommand(argv: ["flash", "window", "move", "--screen=next"]))
    // Percentage frames are atomic and cannot be mixed with named slots.
    XCTAssertNil(
      parseMappingCommand(argv: [
        "flash", "window", "move", "--x=10%", "--width=80%", "--height=80%",
      ]))
    XCTAssertNil(
      parseMappingCommand(argv: [
        "flash", "window", "move", "--position=centered",
        "--x=10%", "--y=10%", "--width=80%", "--height=80%",
      ]))
    // Percent signs are required, dimensions must be positive, and the
    // resulting frame must stay inside the usable screen.
    XCTAssertNil(
      parseMappingCommand(argv: [
        "flash", "window", "move", "--x=10", "--y=10%", "--width=80%", "--height=80%",
      ]))
    XCTAssertNil(
      parseMappingCommand(argv: [
        "flash", "window", "move", "--x=10%", "--y=10%", "--width=0%", "--height=80%",
      ]))
    XCTAssertNil(
      parseMappingCommand(argv: [
        "flash", "window", "move", "--x=30%", "--y=10%", "--width=80%", "--height=80%",
      ]))
    XCTAssertNil(
      parseMappingCommand(argv: [
        "flash", "window", "move", "--x=10%", "--y=10%", "--width=nan%", "--height=80%",
      ]))
  }

}

extension String {
  fileprivate var lowercasedFirst: String {
    guard let first = first else { return self }
    return first.lowercased() + dropFirst()
  }
}
