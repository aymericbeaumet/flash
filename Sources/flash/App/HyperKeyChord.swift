import CoreGraphics

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
