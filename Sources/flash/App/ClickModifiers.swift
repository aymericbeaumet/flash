import AppKit
import CoreGraphics

struct ClickModifiers: OptionSet, Hashable {
  let rawValue: UInt8

  static let command = ClickModifiers(rawValue: 1 << 0)
  static let option = ClickModifiers(rawValue: 1 << 1)
  static let control = ClickModifiers(rawValue: 1 << 2)
  static let shift = ClickModifiers(rawValue: 1 << 3)
  static let defaultMagic: ClickModifiers = [.command, .control, .option, .shift]
  static let all: ClickModifiers = [.command, .control, .option, .shift]

  init(rawValue: UInt8) {
    self.rawValue = rawValue
  }

  init(names: [String]) {
    var out: ClickModifiers = []
    for modifier in KeyModifier.parseList(names).modifiers {
      out.insert(Self.from(modifier))
    }
    self = out
  }

  /// Canonical `+`-joined form used by the mouse verbs' `--modifiers` arg.
  /// Keep the order aligned with normal-mode hotkey diagnostics.
  var argumentValue: String {
    var names: [String] = []
    if contains(.command) { names.append("cmd") }
    if contains(.control) { names.append("ctrl") }
    if contains(.option) { names.append("alt") }
    if contains(.shift) { names.append("shift") }
    return names.joined(separator: "+")
  }

  static func from(_ modifier: KeyModifier) -> ClickModifiers {
    switch modifier {
    case .command: return .command
    case .option: return .option
    case .control: return .control
    case .shift: return .shift
    }
  }

  init(eventFlags: NSEvent.ModifierFlags, allowed: ClickModifiers = .all) {
    var out: ClickModifiers = []
    if allowed.contains(.command), eventFlags.contains(.command) {
      out.insert(.command)
    }
    if allowed.contains(.option), eventFlags.contains(.option) {
      out.insert(.option)
    }
    if allowed.contains(.control), eventFlags.contains(.control) {
      out.insert(.control)
    }
    if allowed.contains(.shift), eventFlags.contains(.shift) {
      out.insert(.shift)
    }
    self = out
  }

  var cgEventFlags: CGEventFlags {
    var out: CGEventFlags = []
    if contains(.command) {
      out.insert(.maskCommand)
    }
    if contains(.option) {
      out.insert(.maskAlternate)
    }
    if contains(.control) {
      out.insert(.maskControl)
    }
    if contains(.shift) {
      out.insert(.maskShift)
    }
    return out
  }
}
