import Carbon.HIToolbox
import Foundation

/// Subset of the skhd configuration syntax we support today. Format:
///
///     # comments start with '#'
///     <modifier> [+ <modifier>...] - <key> : <command>
///
/// Supported modifiers (case-insensitive): `cmd`/`command`,
/// `shift`, `alt`/`opt`/`option`, `ctrl`/`control`. `fn` and the
/// l/r prefixes from skhd (lcmd, rshift, ...) collapse to their
/// generic equivalent — Carbon's `RegisterEventHotKey` doesn't
/// distinguish left/right modifier keys.
///
/// Supported keys: a-z, 0-9, the common punctuation that lives on a
/// US ANSI keyboard, and a small set of named keys (return, tab,
/// space, escape, delete, arrow keys).
///
/// Supported actions:
///   - `open -a "App Name"` (or unquoted, single-token name)
///   - `open <bundle.identifier>` (e.g. `com.apple.Safari`)
/// Everything else parses to `.unknown` and is skipped at registration
/// time — keeps the parser permissive enough to ignore skhd config
/// the user is also feeding to a real skhd daemon.
enum SKHDParser {

  static func parse(_ text: String) -> [ShortcutRule] {
    var out: [ShortcutRule] = []
    for raw in text.split(
      omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
    {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") { continue }
      if let rule = parseLine(line) { out.append(rule) }
    }
    return out
  }

  static func parseLine(_ line: String) -> ShortcutRule? {
    guard let colon = line.firstIndex(of: ":") else { return nil }
    let lhs = line[..<colon].trimmingCharacters(in: .whitespaces)
    let rhs = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    // LHS: `<modifiers> - <key>` (the LAST `-` separates modifier list
    // from key, because keys themselves can be `-`).
    guard let dash = lhs.lastIndex(of: "-") else { return nil }
    let modList = lhs[..<dash].trimmingCharacters(in: .whitespaces)
    let keyTok = lhs[lhs.index(after: dash)...].trimmingCharacters(in: .whitespaces)
    let mods = parseModifiers(String(modList))
    guard let key = parseKey(String(keyTok)) else { return nil }
    let action = parseAction(rhs)
    return ShortcutRule(
      modifiers: mods, virtualKey: key, action: action, source: line)
  }

  private static func parseModifiers(_ s: String) -> UInt32 {
    var flags: UInt32 = 0
    let tokens = s.split(whereSeparator: { $0 == "+" })
      .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    for t in tokens where !t.isEmpty {
      switch t {
      case "cmd", "command", "lcmd", "rcmd":
        flags |= UInt32(cmdKey)
      case "shift", "lshift", "rshift":
        flags |= UInt32(shiftKey)
      case "alt", "lalt", "ralt", "opt", "option":
        flags |= UInt32(optionKey)
      case "ctrl", "control", "lctrl", "rctrl":
        flags |= UInt32(controlKey)
      case "fn", "hyper":
        // Carbon doesn't expose `fn` as a modifier mask; skhd accepts
        // it but our user mentioned Karabiner, which usually maps fn
        // through Karabiner's own layer. Silently ignore.
        continue
      default:
        // Unknown modifier — ignore but keep parsing the rest.
        continue
      }
    }
    return flags
  }

  private static func parseKey(_ s: String) -> UInt32? {
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
      return Self.charToVirtualKey[ch]
    }
    // Skhd allows hex / 0xNN syntax for raw keycodes — useful for
    // keys we don't name. e.g. `0x32` for ` (backtick).
    if s.hasPrefix("0x"), let raw = UInt32(s.dropFirst(2), radix: 16) {
      return raw
    }
    return nil
  }

  /// ANSI key code mapping. Mirrors `<Carbon/HIToolbox/Events.h>`'s
  /// `kVK_ANSI_*` constants. Listed in declaration order rather than
  /// alphabetical so the table reads as a layout reference.
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

  private static func parseAction(_ rhs: String) -> ShortcutAction {
    // Most flexible form: `open -a "Some App"` or `open -a Safari`.
    if let target = matchOpenDashA(rhs) {
      return .launchApp(target: target)
    }
    // `open com.apple.Safari` (no -a) — treat as a bundle ID target.
    if rhs.hasPrefix("open ") {
      let rest = rhs.dropFirst("open ".count).trimmingCharacters(in: .whitespaces)
      if !rest.isEmpty, !rest.contains(" "), rest.contains(".") {
        return .launchApp(target: rest)
      }
    }
    return .unknown(rhs)
  }

  private static func matchOpenDashA(_ rhs: String) -> String? {
    // Hand-rolled to avoid pulling NSRegularExpression for a 2-token
    // shape. Accept either quoted ("My App") or single-token (Safari).
    var s = Substring(rhs)
    guard s.hasPrefix("open") else { return nil }
    s = s.dropFirst("open".count)
    while s.first?.isWhitespace == true { s = s.dropFirst() }
    guard s.hasPrefix("-a") else { return nil }
    s = s.dropFirst("-a".count)
    while s.first?.isWhitespace == true { s = s.dropFirst() }
    if s.first == "\"" {
      s = s.dropFirst()
      guard let end = s.firstIndex(of: "\"") else { return nil }
      return String(s[..<end])
    }
    // Unquoted — take everything to end of line, trimmed.
    let v = s.trimmingCharacters(in: .whitespaces)
    return v.isEmpty ? nil : v
  }
}

/// One parsed `<key> : <action>` binding.
struct ShortcutRule {
  let modifiers: UInt32  // Carbon modifier flags
  let virtualKey: UInt32  // Carbon virtual key code
  let action: ShortcutAction
  /// Original line from the config file — kept around for diagnostic
  /// logging on registration failure.
  let source: String
}

enum ShortcutAction {
  /// `target` is either a bundle ID (`com.apple.Safari`) or a
  /// localized app name (`Safari`). `AppActivationCache.activate(target:)`
  /// tries both lookup paths in order.
  case launchApp(target: String)
  case unknown(String)
}
