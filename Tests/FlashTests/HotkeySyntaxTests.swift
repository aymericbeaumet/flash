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

  // MARK: - Action parsing

  func testParseFlashMouseClick() {
    let action = parseMappingAction(rawString: "flash://mouse_click")
    guard case .flashCommand(let cmd) = action else {
      return XCTFail("expected .flashCommand")
    }
    if case .mouseClick(let hintAction) = cmd {
      XCTAssertEqual(hintAction, .leftClick)
    } else {
      XCTFail("expected .mouseClick, got \(cmd)")
    }

    XCTAssertEqual(
      parseMappingAction(rawString: "flash://mouse_click?right=1")?.command,
      .mouseClick(action: .rightClick))
    XCTAssertEqual(
      parseMappingAction(rawString: "flash://mouse_click?double=1")?.command,
      .mouseClick(action: .doubleClick))
    XCTAssertEqual(
      parseMappingAction(rawString: "flash://show_hints")?.command,
      .mouseClick(action: .leftClick))
    XCTAssertEqual(
      parseMappingAction(rawString: "flash://show_hints?right=1")?.command,
      .mouseClick(action: .rightClick))
  }

  func testParseFlashNormalMode() {
    let action = parseMappingAction(rawString: "flash://mode_normal")
    guard case .flashCommand(.normalMode) = action else {
      return XCTFail("expected .normalMode")
    }
    XCTAssertEqual(
      parseMappingAction(rawString: "flash://normal_mode")?.command,
      .normalMode)
  }

  func testParseFlashOpenApp() {
    let action = parseMappingAction(rawString: "flash://app_open?name=Alacritty")
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
    let action = parseMappingAction(rawString: "flash://app_open?name=Postico%202")
    guard case .flashCommand(.openApp(let name)) = action else {
      return XCTFail("expected .openApp")
    }
    XCTAssertEqual(name, "Postico 2")
    XCTAssertEqual(
      parseMappingAction(rawString: "flash://open_app?name=Postico%202")?.command,
      .openApp(name: "Postico 2"))
  }

  func testParseFlashShowAlert() {
    let action = parseMappingAction(rawString: "flash://alert_show?message=Wi-Fi%20OFF")
    guard case .flashCommand(.showAlert(let message)) = action else {
      return XCTFail("expected .showAlert")
    }
    XCTAssertEqual(message, "Wi-Fi OFF")
    XCTAssertEqual(
      parseMappingAction(rawString: "flash://show_alert?message=Wi-Fi%20OFF")?.command,
      .showAlert(message: "Wi-Fi OFF"))
  }

  func testParseFlashDismissAlert() {
    let action = parseMappingAction(rawString: "flash://alert_dismiss")
    guard case .flashCommand(.dismissAlert) = action else {
      return XCTFail("expected .dismissAlert")
    }
    XCTAssertEqual(
      parseMappingAction(rawString: "flash://dismiss_alert")?.command,
      .dismissAlert)
  }

  func testParseFlashHelp() {
    let help = parseMappingAction(rawString: "flash://help_show")
    guard case .flashCommand(.showUsage) = help else {
      return XCTFail("expected .showUsage for help_show")
    }
    XCTAssertEqual(parseMappingAction(rawString: "flash://help")?.command, .showUsage)
  }

  func testNonFlashStringIsRejected() {
    // Mapping actions must be `flash://...` URLs.
    XCTAssertNil(parseMappingAction(rawString: "https://example.com"))
    XCTAssertNil(parseMappingAction(rawString: "/Applications/Safari.app"))
    XCTAssertNil(parseMappingAction(rawString: "Safari"))
    XCTAssertNil(parseMappingAction(rawString: "open -a Foo"))
  }

  func testParseFlashModeActions() {
    XCTAssertEqual(parseMappingAction(rawString: "flash://mode_insert")?.command, .insertMode)
    XCTAssertEqual(parseMappingAction(rawString: "flash://insert_mode")?.command, .insertMode)
    XCTAssertEqual(parseMappingAction(rawString: "flash://mode_command")?.command, .commandMode)
    XCTAssertEqual(parseMappingAction(rawString: "flash://command_mode")?.command, .commandMode)
    XCTAssertEqual(parseMappingAction(rawString: "flash://mouse_move")?.command, .mouseMove)
    XCTAssertEqual(parseMappingAction(rawString: "flash://move_mouse")?.command, .mouseMove)
    XCTAssertEqual(parseMappingAction(rawString: "flash://url_copy")?.command, .copyURL)
    XCTAssertEqual(parseMappingAction(rawString: "flash://copy_url")?.command, .copyURL)
    XCTAssertEqual(
      parseMappingAction(rawString: "flash://app_open_finder")?.command,
      .appFinder(all: false))
    XCTAssertEqual(
      parseMappingAction(rawString: "flash://app_open_finder?all=1")?.command,
      .appFinder(all: true))
    XCTAssertEqual(
      parseMappingAction(rawString: "flash://open_app_finder?all=1")?.command,
      .appFinder(all: true))
    XCTAssertEqual(parseMappingAction(rawString: "flash://tab_next")?.command, .nextTab)
    XCTAssertEqual(parseMappingAction(rawString: "flash://next_tab")?.command, .nextTab)
    XCTAssertEqual(parseMappingAction(rawString: "flash://tab_previous")?.command, .previousTab)
    XCTAssertEqual(parseMappingAction(rawString: "flash://previous_tab")?.command, .previousTab)
    XCTAssertEqual(parseMappingAction(rawString: "flash://app_back")?.command, .appBack)
    XCTAssertEqual(parseMappingAction(rawString: "flash://app_forward")?.command, .appForward)
    XCTAssertEqual(parseMappingAction(rawString: "flash://app_quit")?.command, .quitApp(force: false))
    XCTAssertEqual(
      parseMappingAction(rawString: "flash://app_quit?force=1")?.command,
      .quitApp(force: true))
    XCTAssertEqual(
      parseMappingAction(rawString: "flash://quit_app?force=1")?.command,
      .quitApp(force: true))
    XCTAssertEqual(
      parseMappingAction(rawString: "flash://app_save_and_quit")?.command,
      .saveAndQuit(force: false))
    XCTAssertEqual(
      parseMappingAction(rawString: "flash://app_save_and_quit?force=1")?.command,
      .saveAndQuit(force: true))
    XCTAssertEqual(
      parseMappingAction(rawString: "flash://save_and_quit?force=1")?.command,
      .saveAndQuit(force: true))
  }

  func testInvalidFlashURLRejected() {
    XCTAssertNil(parseMappingAction(rawString: "flash://unknown_command"))
    XCTAssertNil(parseMappingAction(rawString: "flash://app_open"))  // no name
    XCTAssertNil(parseMappingAction(rawString: "flash://alert_show"))  // no message
    XCTAssertNil(parseMappingAction(rawString: "flash://usage"))
  }

  func testParseFlashMoveWindowPositionOnly() {
    let action = parseMappingAction(
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
    let next = parseMappingAction(
      rawString: "flash://window_move?screen=+1")
    guard case .flashCommand(.moveWindow(let nextP)) = next else {
      return XCTFail("expected .moveWindow for screen=+1")
    }
    XCTAssertNil(nextP.position)
    XCTAssertEqual(nextP.screen, 1)

    let prev = parseMappingAction(
      rawString: "flash://window_move?screen=-1")
    guard case .flashCommand(.moveWindow(let prevP)) = prev else {
      return XCTFail("expected .moveWindow for screen=-1")
    }
    XCTAssertNil(prevP.position)
    XCTAssertEqual(prevP.screen, -1)
  }

  func testParseFlashMoveWindowPositionAndScreen() {
    let action = parseMappingAction(
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
    XCTAssertNil(parseMappingAction(rawString: "flash://window_move"))
    // A typo'd position must not silently degrade to "just move
    // screen" — reject so the user sees the parse error in logs.
    XCTAssertNil(
      parseMappingAction(rawString: "flash://window_move?position=somewhere"))
    // Non-numeric `screen=` is also a parse failure.
    XCTAssertNil(
      parseMappingAction(rawString: "flash://window_move?screen=next"))
    XCTAssertEqual(
      parseMappingAction(rawString: "flash://move_window?position=lefthalf")?.command,
      .moveWindow(MoveWindowParams(position: .leftHalf, screen: 0)))
  }

}
