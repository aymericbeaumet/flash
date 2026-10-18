import Carbon.HIToolbox
import XCTest

@testable import flash

/// The keys the HOLD table binds by name must resolve through the
/// interpreter from the physical key: Return drops a drag, Escape cancels or
/// ends one, as `config.default.toml` promises. A named key has one atom,
/// whichever alias the mapping spelled and whatever character the event
/// carried.
final class HeldButtonModeKeysTests: XCTestCase {
  private func command(
    keyCode: Int, characters: String?, mappings: [ModeMapping]
  ) -> URLCommand? {
    NormalModeInterpreter.interpret(
      pending: "", keyCode: UInt16(keyCode), modifierFlags: [], characters: characters,
      charactersIgnoringModifiers: characters, mappings: CompiledMappings(mappings)
    ).command
  }

  func testReturnDropsAndEscapeCancelsADrag() {
    let drag = Config.default.mode.hold
    let drop = URLCommand.mouseButton(.init(state: .release, button: .primary, hold: .hold))
    XCTAssertEqual(command(keyCode: kVK_Return, characters: "\r", mappings: drag), drop)
    XCTAssertEqual(
      command(keyCode: kVK_ANSI_KeypadEnter, characters: "\u{3}", mappings: drag), drop)
    XCTAssertEqual(command(keyCode: kVK_Return, characters: nil, mappings: drag), drop)
    XCTAssertEqual(
      command(keyCode: kVK_Escape, characters: "\u{1B}", mappings: drag),
      .mouseButton(.init(state: .cancel, button: .primary, hold: .hold)))
  }

  func testYankEndsHeldSelectionInHoldMode() {
    XCTAssertEqual(
      command(keyCode: kVK_ANSI_Y, characters: "y", mappings: Config.default.mode.hold),
      .selection(.copy))
  }

  func testNamedKeyAliasesShareOneAtom() throws {
    for (aliases, canonical) in [
      (["<esc>", "<escape>"], "escape"),
      (["<return>", "<enter>"], "return"),
      (["<delete>", "<backspace>"], "delete"),
      (["<delete_forward>", "<forward_delete>"], "delete_forward"),
      (["<space>"], "space"),
      (["<tab>"], "tab"),
      (["<left>"], "left"),
      (["<pageup>"], "pageup"),
    ] {
      for alias in aliases {
        XCTAssertEqual(NormalModeInterpreter.canonicalizeMappingKey(alias), canonical, alias)
      }
    }
    XCTAssertEqual(
      NormalModeInterpreter.canonicalizeMappingKey("<esc><enter>"),
      NormalModeInterpreter.encodeKeyAtoms(["escape", "return"]))
  }

  func testEveryNamedKeyResolvesByItsPhysicalKey() {
    let keys: [(Int, String?, String)] = [
      (kVK_Return, "\r", "<enter>"), (kVK_ANSI_KeypadEnter, "\u{3}", "<return>"),
      (kVK_Escape, "\u{1B}", "<esc>"), (kVK_Delete, "\u{7F}", "<backspace>"),
      (kVK_ForwardDelete, "\u{F728}", "<forward_delete>"), (kVK_Tab, "\t", "<tab>"),
      (kVK_Space, " ", "<space>"), (kVK_LeftArrow, "\u{F702}", "<left>"),
      (kVK_RightArrow, "\u{F703}", "<right>"), (kVK_UpArrow, "\u{F700}", "<up>"),
      (kVK_DownArrow, "\u{F701}", "<down>"), (kVK_Home, "\u{F729}", "<home>"),
      (kVK_End, "\u{F72B}", "<end>"), (kVK_PageUp, "\u{F72C}", "<pageup>"),
      (kVK_PageDown, "\u{F72D}", "<pagedown>"),
    ]
    for (keyCode, characters, spelled) in keys {
      let canonical = try! XCTUnwrap(NormalModeInterpreter.canonicalizeMappingKey(spelled))
      let mapping = ModeMapping(key: canonical, action: .flashCommand(.undo))
      XCTAssertEqual(
        command(keyCode: keyCode, characters: characters, mappings: [mapping]), .undo, spelled)
      XCTAssertTrue(
        NormalModeInterpreter.recognizesPhysicalKey(
          pending: "", repeatAnchor: nil, virtualKey: UInt32(keyCode), modifierFlags: [],
          mappings: CompiledMappings([mapping])), spelled)
    }
    // Typeable keys keep matching by the character the layout produced, so
    // a US-ANSI position never leaks in as an atom.
    XCTAssertNil(NormalModeInterpreter.namedKeyAtom(keyCode: UInt16(kVK_ANSI_S)))
  }
}
