import Carbon.HIToolbox
import XCTest

@testable import flash

/// F1–F20 are named keys, `<f1>`–`<f20>`, end to end: the mapping syntax,
/// the key a press resolves to (the session tap and the key window alike),
/// the Carbon registration of a chord, and the mappings page and which-key
/// spelling. The regression: `"<f12>"` was rejected and `"f12"` silently
/// meant the three keys f, 1, 2.
final class FunctionKeyMappingTests: XCTestCase {
  /// Each function key's virtual key and the character AppKit reports for it
  /// (`NSF1FunctionKey` onwards).
  private static let keys: [(name: String, keyCode: Int, character: String)] = [
    kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
    kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
  ].enumerated().map { index, keyCode in
    ("f\(index + 1)", keyCode, String(UnicodeScalar(0xF704 + index)!))
  }

  private func canonical(_ raw: String) -> String {
    NormalModeInterpreter.canonicalizeMappingKey(raw)!
  }

  private func command(
    keyCode: Int, character: String, flags: NSEvent.ModifierFlags = [.function],
    mappings: [ModeMapping]
  ) -> URLCommand? {
    NormalModeInterpreter.interpret(
      pending: "", keyCode: UInt16(keyCode), modifierFlags: flags, characters: character,
      charactersIgnoringModifiers: character, mappings: CompiledMappings(mappings)
    ).command
  }

  func testEveryFunctionKeyIsOneNamedAtom() {
    for key in Self.keys {
      XCTAssertEqual(NormalModeInterpreter.canonicalizeMappingKey("<\(key.name)>"), key.name)
      XCTAssertEqual(HotkeySyntax.parseKey(key.name), UInt32(key.keyCode), key.name)
      XCTAssertEqual(
        HotkeySyntax.canonicalKeyName(virtualKey: UInt32(key.keyCode)), key.name, key.name)
      XCTAssertEqual(
        NormalModeInterpreter.namedKeyAtom(keyCode: UInt16(key.keyCode)), key.name, key.name)
    }
    XCTAssertNil(NormalModeInterpreter.canonicalizeMappingKey("<f0>"))
    XCTAssertNil(NormalModeInterpreter.canonicalizeMappingKey("<f21>"))
    XCTAssertEqual(
      canonical("g<f5>"), NormalModeInterpreter.encodeKeyAtoms(["g", "f5"]))
  }

  /// The session tap recognizes the physical key and the interpreter
  /// resolves it, whether or not the event carries the fn flag every
  /// function key press has.
  func testEveryFunctionKeyResolvesByItsPhysicalKey() {
    for key in Self.keys {
      let mapping = ModeMapping(key: canonical("<\(key.name)>"), action: .flashCommand(.undo))
      for flags: NSEvent.ModifierFlags in [[], [.function]] {
        XCTAssertEqual(
          command(
            keyCode: key.keyCode, character: key.character, flags: flags, mappings: [mapping]),
          .undo, key.name)
      }
      for flags: CGEventFlags in [[], [.maskSecondaryFn]] {
        XCTAssertTrue(
          NormalModeInterpreter.recognizesPhysicalKey(
            pending: "", repeatAnchor: nil, virtualKey: UInt32(key.keyCode),
            modifierFlags: flags, mappings: CompiledMappings([mapping])), key.name)
      }
      // A bare function key is the tap's: Carbon registers modified chords only.
      XCTAssertNil(mapping.nativeHotkey, key.name)
    }
  }

  /// A modifier chord registers natively, and a shifted function key is its
  /// own binding beside the bare one.
  func testFunctionKeyChordsRegisterNativelyAndShiftIsItsOwnBinding() {
    XCTAssertEqual(canonical("cmd+<f12>"), "cmd+f12")
    XCTAssertEqual(canonical("cmd+f12"), "cmd+f12", "a named key after a modifier needs no <>")
    XCTAssertEqual(canonical("shift+cmd+<f1>"), "cmd+shift+f1")
    XCTAssertEqual(
      ModeMapping(key: canonical("cmd+<f12>"), action: .flashCommand(.undo)).nativeHotkey,
      ParsedHotkey(modifiers: UInt32(cmdKey), virtualKey: UInt32(kVK_F12)))
    XCTAssertEqual(
      ModeMapping(key: canonical("ctrl+alt+<f20>"), action: .flashCommand(.undo)).nativeHotkey,
      ParsedHotkey(modifiers: UInt32(controlKey | optionKey), virtualKey: UInt32(kVK_F20)))

    let mappings = [
      ModeMapping(key: canonical("<f1>"), action: .flashCommand(.tabNext)),
      ModeMapping(key: canonical("shift+<f1>"), action: .flashCommand(.tabPrev)),
      ModeMapping(key: canonical("cmd+<f1>"), action: .flashCommand(.undo)),
    ]
    let f1 = Self.keys[0]
    XCTAssertEqual(
      command(keyCode: f1.keyCode, character: f1.character, mappings: mappings), .tabNext)
    XCTAssertEqual(
      command(
        keyCode: f1.keyCode, character: f1.character, flags: [.function, .shift],
        mappings: mappings),
      .tabPrev)
    XCTAssertEqual(
      command(
        keyCode: f1.keyCode, character: f1.character, flags: [.function, .command],
        mappings: mappings),
      .undo)
    // Without a shifted binding, Shift-F1 is still F1, as Shift-Space is Space.
    XCTAssertEqual(
      command(
        keyCode: f1.keyCode, character: f1.character, flags: [.function, .shift],
        mappings: [mappings[0]]),
      .tabNext)
  }

  func testTheMappingsPageAndWhichKeySpellFunctionKeysInBrackets() {
    for (raw, shown) in [
      ("<f1>", "<f1>"), ("<f12>", "<f12>"), ("<f20>", "<f20>"), ("cmd+<f12>", "cmd+<f12>"),
      ("shift+<f3>", "shift+<f3>"), ("g<f5>", "g<f5>"), ("<f1><f2>", "<f1><f2>"),
    ] {
      XCTAssertEqual(NormalModeDispatcher.displayMappingKey(canonical(raw)), shown, raw)
    }
    let mappings = CompiledMappings(
      [("g<f5>", URLCommand.tabNext), ("g<f10>", .tabPrev), ("gg", .scroll(.top))].map {
        ModeMapping(key: canonical($0.0), action: .flashCommand($0.1))
      })
    XCTAssertEqual(
      WhichKey.entries(after: canonical("g"), in: mappings).map(\.key), ["<f10>", "<f5>", "g"])
  }

  func testConfigBindsFunctionKeysAndRejectsTheBareSpelling() {
    let config = ConfigLoader.parse(
      """
      [mode.normal.mappings]
      "<f12>" = ["flash", "hints", "dismiss"]
      "f 1 2" = ["flash", "tab", "next"]

      [mode.all.mappings]
      "cmd+<f5>" = ["flash", "config", "reload"]
      """)
    XCTAssertEqual(config.loadingDiagnostics.map(\.message), [])
    XCTAssertNotNil(config.mode.normal.first { $0.key == "f12" })
    XCTAssertNotNil(
      config.mode.normal.first { $0.key == NormalModeInterpreter.encodeKeyAtoms(["f", "1", "2"]) },
      "spaced out, f12 is the keys f, 1, 2")
    XCTAssertEqual(
      config.mode.all.first { $0.key == "cmd+f5" }?.nativeHotkey,
      ParsedHotkey(modifiers: UInt32(cmdKey), virtualKey: UInt32(kVK_F5)))

    let bare = ConfigLoader.parse(
      """
      [mode.normal.mappings]
      "f12" = ["flash", "hints", "dismiss"]
      "F1" = false
      """)
    XCTAssertEqual(
      bare.loadingDiagnostics.map(\.message).sorted(),
      [
        "mapping \"F1\" is the keys F, 1; write \"<f1>\" for the F1 key, or \"F 1\" for "
          + "those keys in turn",
        "mapping \"f12\" is the keys f, 1, 2; write \"<f12>\" for the F12 key, or \"f 1 2\" "
          + "for those keys in turn",
      ])
    XCTAssertNil(
      bare.mode.normal.first { $0.key == NormalModeInterpreter.encodeKeyAtoms(["f", "1", "2"]) })
  }

  func testKeyFunctionPressesF1ThroughF20() {
    XCTAssertEqual(URLEventHandler.parse(words: ["key", "function", "--key=f1"]), .functionKey(1))
    XCTAssertEqual(
      URLEventHandler.parse(words: ["key", "function", "--key=f20"]), .functionKey(20))
    XCTAssertNil(URLEventHandler.parse(words: ["key", "function", "--key=f21"]))
    XCTAssertNil(URLEventHandler.parse(words: ["key", "function", "--key=f0"]))
  }
}
