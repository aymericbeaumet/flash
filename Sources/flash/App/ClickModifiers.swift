import AppKit
import CoreGraphics

struct ClickModifiers: OptionSet, Equatable {
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
    for name in names {
      if let modifier = Self.modifier(named: name) {
        out.insert(modifier)
      }
    }
    self = out
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

  private static func modifier(named rawName: String) -> ClickModifiers? {
    switch rawName.lowercased() {
    case "cmd", "command": return .command
    case "alt", "option": return .option
    case "ctrl", "control": return .control
    case "shift": return .shift
    default: return nil
    }
  }
}
