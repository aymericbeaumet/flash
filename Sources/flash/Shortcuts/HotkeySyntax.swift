import Carbon.HIToolbox
import Foundation

/// Parses Flash's TOML hotkey syntax. Modifiers and the key are
/// joined by `+`. The LAST token is the key; everything before it
/// is a modifier.
///
///     "cmd+ctrl+a"       -> cmd + ctrl + A
///     "cmd+shift+ctrl+r" -> cmd + shift + ctrl + R
///     "cmd+return"       -> cmd + Return
///
/// Modifiers (case-insensitive): `cmd`/`command`, `shift`,
/// `alt`/`opt`/`option`, `ctrl`/`control`.
///
/// Keys: a-z, 0-9, ANSI punctuation single characters, or one of
/// the named keys (return, tab, space, escape, delete, arrows,
/// home/end, pageup/down). `0xNN` accepts a raw virtual-key for
/// keys without a name.
struct ParsedHotkey {
  let modifiers: UInt32  // Carbon modifier flags
  let virtualKey: UInt32  // Carbon virtual key code
}

enum HotkeySyntax {

  /// Parse the LHS of a native modified-key mapping. Returns nil for empty
  /// input or unrecognised keys.
  static func parse(hotkey: String) -> ParsedHotkey? {
    let trimmed = hotkey.trimmingCharacters(in: .whitespaces)
    let tokens = trimmed.split(separator: "+", omittingEmptySubsequences: true)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    guard tokens.count >= 1 else { return nil }
    guard let key = parseKey(tokens.last!) else { return nil }
    let mods = parseModifiers(tokens.dropLast())
    return ParsedHotkey(modifiers: mods, virtualKey: key)
  }

  static func parseModifiers<S: Sequence>(_ tokens: S) -> UInt32
  where S.Element == String {
    // Modifier spellings live in one place (`KeyModifier`). Unknown tokens are
    // dropped here; the registration then fails on the incomplete chord and the
    // caller logs the bad source line.
    var flags: UInt32 = 0
    for raw in tokens {
      if let modifier = KeyModifier(token: raw) { flags |= modifier.carbonFlag }
    }
    return flags
  }

  static func parseKey(_ s: String) -> UInt32? {
    switch s.lowercased() {
    case "return", "enter": return UInt32(kVK_Return)
    case "tab": return UInt32(kVK_Tab)
    case "space": return UInt32(kVK_Space)
    case "delete", "backspace": return UInt32(kVK_Delete)
    case "escape", "esc": return UInt32(kVK_Escape)
    case "left": return UInt32(kVK_LeftArrow)
    case "right": return UInt32(kVK_RightArrow)
    case "up": return UInt32(kVK_UpArrow)
    case "down": return UInt32(kVK_DownArrow)
    case "home": return UInt32(kVK_Home)
    case "end": return UInt32(kVK_End)
    case "pageup", "page_up": return UInt32(kVK_PageUp)
    case "pagedown", "page_down": return UInt32(kVK_PageDown)
    case "leftbrace": return UInt32(kVK_ANSI_LeftBracket)
    case "rightbrace": return UInt32(kVK_ANSI_RightBracket)
    default: break
    }
    if s.count == 1, let ch = s.first {
      return Self.charToVirtualKey[Character(ch.lowercased())]
    }
    if s.hasPrefix("0x"), let raw = UInt32(s.dropFirst(2), radix: 16) {
      return raw
    }
    return nil
  }

  static func canonicalKeyName(virtualKey: UInt32) -> String? {
    switch Int(virtualKey) {
    case kVK_Return: return "return"
    case kVK_Tab: return "tab"
    case kVK_Space: return "space"
    case kVK_Delete: return "delete"
    case kVK_Escape: return "escape"
    case kVK_LeftArrow: return "left"
    case kVK_RightArrow: return "right"
    case kVK_UpArrow: return "up"
    case kVK_DownArrow: return "down"
    case kVK_Home: return "home"
    case kVK_End: return "end"
    case kVK_PageUp: return "pageup"
    case kVK_PageDown: return "pagedown"
    default:
      return Self.virtualKeyToCanonicalCharacter[virtualKey].map(String.init)
    }
  }

  /// ANSI virtual key codes (see `<Carbon/HIToolbox/Events.h>`). Shifted
  /// punctuation maps to the same physical key as its unshifted form so
  /// `"cmd+shift+}"` and `"cmd+shift+]"` register identically.
  /// Listed in declaration order rather than alphabetical so the table
  /// reads as a layout reference.
  private static let charToVirtualKey: [Character: UInt32] = [
    "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03,
    "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
    "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
    "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
    "t": 0x11, "1": 0x12, "!": 0x12, "2": 0x13, "@": 0x13, "3": 0x14,
    "#": 0x14, "4": 0x15, "$": 0x15, "6": 0x16, "^": 0x16,
    "5": 0x17, "%": 0x17, "=": 0x18, "+": 0x18,
    "9": 0x19, "(": 0x19, "7": 0x1A, "&": 0x1A, "-": 0x1B,
    "_": 0x1B, "8": 0x1C, "*": 0x1C, "0": 0x1D, ")": 0x1D,
    "]": 0x1E, "}": 0x1E, "o": 0x1F, "u": 0x20,
    "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25,
    "{": 0x21, "j": 0x26, "'": 0x27, "\"": 0x27, "k": 0x28,
    ";": 0x29, ":": 0x29, "\\": 0x2A, "|": 0x2A,
    ",": 0x2B, "<": 0x2B, "/": 0x2C, "?": 0x2C, "n": 0x2D,
    "m": 0x2E, ".": 0x2F, ">": 0x2F, "`": 0x32, "~": 0x32,
  ]

  private static let virtualKeyToCanonicalCharacter: [UInt32: Character] = [
    0x00: "a", 0x01: "s", 0x02: "d", 0x03: "f",
    0x04: "h", 0x05: "g", 0x06: "z", 0x07: "x",
    0x08: "c", 0x09: "v", 0x0B: "b", 0x0C: "q",
    0x0D: "w", 0x0E: "e", 0x0F: "r", 0x10: "y",
    0x11: "t", 0x12: "1", 0x13: "2", 0x14: "3",
    0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=",
    0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8",
    0x1D: "0", 0x1E: "]", 0x1F: "o", 0x20: "u",
    0x21: "[", 0x22: "i", 0x23: "p", 0x25: "l",
    0x26: "j", 0x27: "'", 0x28: "k", 0x29: ";",
    0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2D: "n",
    0x2E: "m", 0x2F: ".", 0x32: "`",
  ]
}
