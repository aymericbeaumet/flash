import AppKit
import CoreGraphics

/// The configured hyper key, prepared once per config load so the per-key
/// test is a key-code or character comparison before any atom is built.
struct HyperKeyMatcher: Equatable {
  let atom: String
  /// The physical chord when the atom names one (`space`, `cmd+space`,
  /// `ctrl-a`, `f`); nil for atoms only the character path can match.
  let chord: HyperKeyChord?
  /// For an atom that matches by typed character (`f`, `?`, `ctrl-a`), the
  /// characters an event may carry for it; empty for named keys and chords.
  let characters: Set<Character>

  init(atom: String) {
    self.atom = atom
    self.chord = HyperKeyChord.parse(atom)
    var characters: Set<Character> = []
    let base: Substring
    if atom.hasPrefix("ctrl-"), !atom.contains("+") {
      base = atom.dropFirst("ctrl-".count)
    } else {
      base = atom[...]
    }
    if base.count == 1, let character = base.first {
      characters.insert(character)
      for variant in character.lowercased() { characters.insert(variant) }
      for variant in character.uppercased() { characters.insert(variant) }
      if character == "?" { characters.insert("/") }
    }
    self.characters = characters
  }

  /// Whether a key event with this key code can be the hyper key at all:
  /// the chord's own key, or any key when the atom matches by character. The
  /// tap uses this on key-up to drop other releases without an `NSEvent`.
  func mayMatch(keyCode: Int64) -> Bool {
    if let chord, chord.keyCode == keyCode { return true }
    return chord == nil || !characters.isEmpty
  }
}

/// The physical keys of one hyper chord, read from the HID state table.
///
/// `hidSystemState` is updated before the session tap, so a key the tap
/// swallowed still reads as down. Combined session state does not: a swallowed
/// press can look up there and would drop HYPER on the tick after it began.
struct HyperKeyChord: Equatable {
  var key: CGKeyCode
  var modifiers: CGEventFlags

  /// `atom` is one resolved hyper key (`"space"`, `"cmd+space"`, `"ctrl-a"`).
  static func parse(_ atom: String) -> HyperKeyChord? {
    let modifiers: [String]
    let keyName: String
    if atom.hasPrefix("ctrl-"), !atom.contains("+") {
      modifiers = ["ctrl"]
      keyName = String(atom.dropFirst("ctrl-".count))
    } else {
      let parts = atom.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
      guard let last = parts.last, !last.isEmpty else { return nil }
      modifiers = Array(parts.dropLast())
      keyName = last
    }
    guard !keyName.isEmpty, let virtualKey = HotkeySyntax.parseKey(keyName) else { return nil }
    var flags: CGEventFlags = []
    for modifier in modifiers {
      switch modifier {
      case "cmd": flags.insert(.maskCommand)
      case "ctrl": flags.insert(.maskControl)
      case "alt": flags.insert(.maskAlternate)
      case "shift": flags.insert(.maskShift)
      default: return nil
      }
    }
    return HyperKeyChord(key: CGKeyCode(virtualKey), modifiers: flags)
  }

  /// The physical key named by `atom` as a `CGKeyCode`, read by the tap to
  /// decide whether a swallowed release is worth an `NSEvent` and a main hop.
  var keyCode: Int64 { Int64(key) }

  static func isDown(
    _ chord: HyperKeyChord,
    keyIsDown: (CGKeyCode) -> Bool,
    flags: CGEventFlags
  ) -> Bool {
    keyIsDown(chord.key) && flags.contains(chord.modifiers)
  }

  static func isPhysicallyDown(_ chord: HyperKeyChord) -> Bool {
    isDown(
      chord,
      keyIsDown: { CGEventSource.keyState(.hidSystemState, key: $0) },
      flags: CGEventSource.flagsState(.hidSystemState))
  }
}
