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
enum HotkeySyntax {

  /// Parse `hotkey` and pair it with `target`. `target` passes
  /// through into the rule untouched and is interpreted later by
  /// `AppActivationCache.activate(target:)` as an app name or
  /// bundle ID.
  static func parse(hotkey: String, target: String) -> ShortcutRule? {
    let trimmed = hotkey.trimmingCharacters(in: .whitespaces)
    let tokens = trimmed.split(separator: "+", omittingEmptySubsequences: true)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    guard tokens.count >= 1 else { return nil }
    guard let key = parseKey(tokens.last!) else { return nil }
    let mods = parseModifiers(tokens.dropLast())
    return ShortcutRule(
      modifiers: mods, virtualKey: key,
      action: .launchApp(target: target), source: hotkey)
  }

  static func parseModifiers<S: Sequence>(_ tokens: S) -> UInt32
  where S.Element == String {
    var flags: UInt32 = 0
    for raw in tokens {
      switch raw.lowercased() {
      case "cmd", "command":
        flags |= UInt32(cmdKey)
      case "shift":
        flags |= UInt32(shiftKey)
      case "alt", "opt", "option":
        flags |= UInt32(optionKey)
      case "ctrl", "control":
        flags |= UInt32(controlKey)
      case "":
        continue
      default:
        // Unknown modifier — log via the caller's diagnostic path
        // by returning what we have; the registration will likely
        // fail and the caller will log the bad source line.
        continue
      }
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

  /// ANSI virtual key codes (see `<Carbon/HIToolbox/Events.h>`).
  /// Listed in declaration order rather than alphabetical so the
  /// table reads as a layout reference.
  private static let charToVirtualKey: [Character: UInt32] = [
    "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03,
    "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
    "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
    "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
    "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14,
    "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
    "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C,
    "0": 0x1D, "]": 0x1E, "o": 0x1F, "u": 0x20,
    "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25,
    "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
    "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D,
    "m": 0x2E, ".": 0x2F, "`": 0x32,
  ]
}

/// One Carbon hotkey binding to one app target.
struct ShortcutRule {
  let modifiers: UInt32  // Carbon modifier flags
  let virtualKey: UInt32  // Carbon virtual key code
  let action: ShortcutAction
  /// Original hotkey string from the config — kept for diagnostic
  /// logging on registration failure.
  let source: String
}

enum ShortcutAction {
  /// `target` is either a bundle ID (`com.apple.Safari`) or a
  /// localized app name (`Safari`).
  /// `AppActivationCache.activate(target:)` tries both lookup paths.
  case launchApp(target: String)
}
