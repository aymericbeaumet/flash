import AppKit
import Carbon.HIToolbox

/// What every key code types on one keyboard layout, unshifted and shifted.
///
/// Hint labels, the mouse grid and NORMAL mappings are letters, but a
/// non-Latin input source (Russian, Greek, Hebrew, a CJK input method) makes
/// the same physical keys type other characters. With a reference table the
/// interpreters read a key by the character it types on that layout instead
/// (`KeyCharacters.read`), so `f` stays `f` under ЙЦУКЕН. The table is built
/// off the key path (`KeyboardLayoutMonitor`) and read with one array lookup
/// per key; the tap's swallow decision never consults it.
struct KeyboardLayout: Equatable {
  /// Key codes 0..<128 cover every key a Mac keyboard reports.
  static let keyCodeCount = 128

  /// The input source the table was translated from, or `us-ansi` for the
  /// built-in fallback.
  let sourceID: String
  private let plain: [String]
  private let shifted: [String]

  init(sourceID: String, plain: [UInt16: String], shifted: [UInt16: String]) {
    self.sourceID = sourceID
    func table(_ entries: [UInt16: String]) -> [String] {
      var table = [String](repeating: "", count: Self.keyCodeCount)
      for (code, text) in entries where Int(code) < Self.keyCodeCount { table[Int(code)] = text }
      return table
    }
    self.plain = table(plain)
    self.shifted = table(shifted)
  }

  /// The printable text `keyCode` types, or nil when it types none on this
  /// layout (Return, Escape, arrows, function keys).
  func character(keyCode: UInt16, shift: Bool) -> String? {
    guard Int(keyCode) < Self.keyCodeCount else { return nil }
    let text = (shift ? shifted : plain)[Int(keyCode)]
    return text.isEmpty ? nil : text
  }

  /// Every character the layout types unmodified or with Shift alone.
  var typableCharacters: Set<Character> {
    Set((plain + shifted).joined())
  }

  /// The characters it types without Shift: all the mouse grid can read,
  /// since Shift on a grid key rides the click instead.
  var unshiftedCharacters: Set<Character> {
    Set(plain.joined())
  }

  // MARK: US-ANSI

  static let usANSISourceID = "us-ansi"

  /// The main block of a US-ANSI keyboard: letters, digits and punctuation.
  private static let usANSIKeys: [(code: Int, plain: Character, shifted: Character)] = [
    (kVK_ANSI_A, "a", "A"), (kVK_ANSI_B, "b", "B"), (kVK_ANSI_C, "c", "C"),
    (kVK_ANSI_D, "d", "D"), (kVK_ANSI_E, "e", "E"), (kVK_ANSI_F, "f", "F"),
    (kVK_ANSI_G, "g", "G"), (kVK_ANSI_H, "h", "H"), (kVK_ANSI_I, "i", "I"),
    (kVK_ANSI_J, "j", "J"), (kVK_ANSI_K, "k", "K"), (kVK_ANSI_L, "l", "L"),
    (kVK_ANSI_M, "m", "M"), (kVK_ANSI_N, "n", "N"), (kVK_ANSI_O, "o", "O"),
    (kVK_ANSI_P, "p", "P"), (kVK_ANSI_Q, "q", "Q"), (kVK_ANSI_R, "r", "R"),
    (kVK_ANSI_S, "s", "S"), (kVK_ANSI_T, "t", "T"), (kVK_ANSI_U, "u", "U"),
    (kVK_ANSI_V, "v", "V"), (kVK_ANSI_W, "w", "W"), (kVK_ANSI_X, "x", "X"),
    (kVK_ANSI_Y, "y", "Y"), (kVK_ANSI_Z, "z", "Z"),
    (kVK_ANSI_1, "1", "!"), (kVK_ANSI_2, "2", "@"), (kVK_ANSI_3, "3", "#"),
    (kVK_ANSI_4, "4", "$"), (kVK_ANSI_5, "5", "%"), (kVK_ANSI_6, "6", "^"),
    (kVK_ANSI_7, "7", "&"), (kVK_ANSI_8, "8", "*"), (kVK_ANSI_9, "9", "("),
    (kVK_ANSI_0, "0", ")"),
    (kVK_ANSI_Minus, "-", "_"), (kVK_ANSI_Equal, "=", "+"),
    (kVK_ANSI_LeftBracket, "[", "{"), (kVK_ANSI_RightBracket, "]", "}"),
    (kVK_ANSI_Backslash, "\\", "|"), (kVK_ANSI_Semicolon, ";", ":"),
    (kVK_ANSI_Quote, "'", "\""), (kVK_ANSI_Comma, ",", "<"), (kVK_ANSI_Period, ".", ">"),
    (kVK_ANSI_Slash, "/", "?"), (kVK_ANSI_Grave, "`", "~"),
  ]

  /// The table used when no layout can be read: the reference for CJK input
  /// methods without an ASCII-capable companion, and for an explicit
  /// `keyboard_layout` that names no installed source.
  static let usANSI = KeyboardLayout(
    sourceID: usANSISourceID,
    plain: Dictionary(uniqueKeysWithValues: usANSIKeys.map { (UInt16($0.code), String($0.plain)) }),
    shifted: Dictionary(
      uniqueKeysWithValues: usANSIKeys.map { (UInt16($0.code), String($0.shifted)) }))

  /// The lowercase ASCII letter or digit `keyCode` types on US-ANSI. Recovers
  /// a Ctrl chord's key when the event's characters are a control character
  /// (Ctrl-I types a tab).
  static func usANSILetterOrDigit(_ keyCode: UInt16) -> Character? {
    guard let text = usANSI.character(keyCode: keyCode, shift: false), text.count == 1,
      let character = text.first, character.isLetter || character.isNumber
    else { return nil }
    return character
  }

  // MARK: Translation

  /// Translate every key code of a `UCKeyboardLayout` (an input source's
  /// `kTISPropertyUnicodeKeyLayoutData`). Dead keys yield their own
  /// character; keys that type a control character are left out.
  static func translating(layoutData: Data, sourceID: String, keyboardType: UInt32)
    -> KeyboardLayout
  {
    var plain: [UInt16: String] = [:]
    var shifted: [UInt16: String] = [:]
    let shiftState = UInt32(shiftKey >> 8) & 0xFF
    layoutData.withUnsafeBytes { buffer in
      guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self)
      else { return }
      for code in 0..<UInt16(keyCodeCount) {
        plain[code] = translate(layout, keyCode: code, modifiers: 0, keyboardType: keyboardType)
        shifted[code] = translate(
          layout, keyCode: code, modifiers: shiftState, keyboardType: keyboardType)
      }
    }
    return KeyboardLayout(sourceID: sourceID, plain: plain, shifted: shifted)
  }

  private static func translate(
    _ layout: UnsafePointer<UCKeyboardLayout>, keyCode: UInt16, modifiers: UInt32,
    keyboardType: UInt32
  ) -> String? {
    var deadKeyState: UInt32 = 0
    var length = 0
    var units = [UniChar](repeating: 0, count: 4)
    let status = UCKeyTranslate(
      layout, keyCode, UInt16(kUCKeyActionDown), modifiers, keyboardType,
      OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, units.count, &length, &units)
    guard status == noErr, length > 0 else { return nil }
    let text = String(utf16CodeUnits: units, count: length)
    guard
      !text.unicodeScalars.contains(where: {
        CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .privateUse
      })
    else { return nil }
    return text
  }

  // MARK: Reference selection

  /// `[app] keyboard_layout`.
  enum Setting: Equatable {
    /// Translate only while the current input source cannot type ASCII.
    case auto
    /// Always read keys against this input source.
    case inputSource(String)

    /// "auto", or an input-source ID (reverse-DNS, such as
    /// `com.apple.keylayout.US`); nil for anything else.
    init?(_ raw: String) {
      if raw == "auto" {
        self = .auto
        return
      }
      guard !raw.isEmpty, raw.contains("."), raw.trimmingCharacters(in: .whitespaces) == raw,
        !raw.unicodeScalars.contains(where: {
          CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
        })
      else { return nil }
      self = .inputSource(raw)
    }
  }

  /// The table keys are read against, and an explicit source that is not
  /// installed (its keys fall back to US-ANSI).
  struct Reference: Equatable {
    var table: KeyboardLayout?
    var missingSourceID: String?
  }

  /// Which table the interpreters read keys against. `auto` leaves an
  /// ASCII-capable source alone — what it types is what the labels show —
  /// and otherwise reads keys on the ASCII-capable layout the system pairs
  /// with it, or US-ANSI. An explicit source is always the reference.
  static func reference(
    setting: Setting,
    currentIsASCIICapable: Bool,
    asciiCapableLayout: () -> KeyboardLayout?,
    namedLayout: (String) -> KeyboardLayout?
  ) -> Reference {
    switch setting {
    case .auto:
      guard !currentIsASCIICapable else { return Reference(table: nil) }
      return Reference(table: asciiCapableLayout() ?? .usANSI)
    case .inputSource(let id):
      guard let table = namedLayout(id) else {
        return Reference(table: .usANSI, missingSourceID: id)
      }
      return Reference(table: table)
    }
  }
}

/// One key as Flash's interpreters read it: the event's own characters, or,
/// with a reference layout, the characters the key types there.
struct KeyCharacters: Equatable {
  /// What the key types with Shift applied (`NSEvent.characters`).
  var characters: String?
  /// `NSEvent.charactersIgnoringModifiers`, which keeps Shift.
  var ignoringModifiers: String?
  /// The key with no modifiers at all; read only while Shift is held, for
  /// the grid, which lets Shift ride the click instead of changing the cell.
  var unshifted: String?

  /// One table lookup when `layout` is set; the event's characters (and a
  /// lazy `unshifted`) otherwise. A key the layout types nothing on keeps
  /// the event's characters, so Return, Escape and arrows are unchanged.
  static func read(
    layout: KeyboardLayout?,
    keyCode: UInt16,
    modifierFlags: NSEvent.ModifierFlags,
    characters: String?,
    ignoringModifiers: String?,
    unshifted: () -> String?
  ) -> KeyCharacters {
    let shift = modifierFlags.contains(.shift)
    if let layout, let plain = layout.character(keyCode: keyCode, shift: false) {
      let typed = shift ? layout.character(keyCode: keyCode, shift: true) ?? plain : plain
      return KeyCharacters(characters: typed, ignoringModifiers: typed, unshifted: plain)
    }
    return KeyCharacters(
      characters: characters, ignoringModifiers: ignoringModifiers,
      unshifted: shift ? unshifted() : nil)
  }
}
