import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// A keyboard modifier parsed from the tokens Flash accepts across config —
/// hotkey chords (`cmd+t`) and click magic-modifiers. One place owns the
/// accepted spellings and the mapping to every flag representation, so
/// `cmd`/`ctrl`/`alt`/`shift` parse identically
/// everywhere instead of drifting per call site.
enum KeyModifier: CaseIterable, Equatable {
  case command
  case control
  case option
  case shift

  enum ParseError: Error, Equatable {
    /// The token didn't name a modifier.
    case unknown(String)
  }

  /// Parse one modifier token (case-insensitive, whitespace-trimmed) into the
  /// enum, or an error naming the unrecognized token.
  static func parse(_ token: String) -> Result<KeyModifier, ParseError> {
    switch token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "cmd", "command", "super", "meta", "⌘": return .success(.command)
    case "ctrl", "control", "⌃": return .success(.control)
    case "alt", "opt", "option", "⌥": return .success(.option)
    case "shift", "⇧": return .success(.shift)
    default: return .failure(.unknown(token))
    }
  }

  /// Convenience failable init for callers that silently drop unknown tokens.
  init?(token: String) {
    guard case .success(let modifier) = Self.parse(token) else { return nil }
    self = modifier
  }

  /// Parse a list, keeping recognized modifiers (de-duplicated, in first-seen
  /// order) and reporting any unrecognized tokens for diagnostics.
  static func parseList(_ tokens: [String]) -> (modifiers: [KeyModifier], unknown: [String]) {
    var modifiers: [KeyModifier] = []
    var unknown: [String] = []
    for token in tokens where !token.trimmingCharacters(in: .whitespaces).isEmpty {
      switch parse(token) {
      case .success(let modifier):
        if !modifiers.contains(modifier) { modifiers.append(modifier) }
      case .failure(.unknown(let raw)):
        unknown.append(raw)
      }
    }
    return (modifiers, unknown)
  }

  /// Carbon `RegisterEventHotKey` modifier flag (`cmdKey`, …).
  var carbonFlag: UInt32 {
    switch self {
    case .command: return UInt32(cmdKey)
    case .control: return UInt32(controlKey)
    case .option: return UInt32(optionKey)
    case .shift: return UInt32(shiftKey)
    }
  }

  var cgEventFlag: CGEventFlags {
    switch self {
    case .command: return .maskCommand
    case .control: return .maskControl
    case .option: return .maskAlternate
    case .shift: return .maskShift
    }
  }

  var nsEventFlag: NSEvent.ModifierFlags {
    switch self {
    case .command: return .command
    case .control: return .control
    case .option: return .option
    case .shift: return .shift
    }
  }
}

extension KeyModifier {
  /// Combined Carbon flags for a token list (unknown tokens ignored).
  static func carbonFlags(_ tokens: [String]) -> UInt32 {
    parseList(tokens).modifiers.reduce(0) { $0 | $1.carbonFlag }
  }

  /// Combined `CGEventFlags` for a token list (unknown tokens ignored).
  static func cgEventFlags(_ tokens: [String]) -> CGEventFlags {
    parseList(tokens).modifiers.reduce(into: []) { $0.insert($1.cgEventFlag) }
  }
}
