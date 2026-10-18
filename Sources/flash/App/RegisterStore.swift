import AppKit

/// Text registers shared by NORMAL and HOLD yank/paste commands.
/// Flash uses Vim's `unnamedplus` clipboard behavior: the unnamed register
/// reads the macOS pasteboard, while an explicit named yank also updates it.
final class RegisterStore {
  struct Entry: Equatable {
    let name: String
    let text: String
    let kind: String
    let truncated: Bool
  }

  private let pasteboard: NSPasteboard
  private var named: [Character: String] = [:]

  init(pasteboard: NSPasteboard = .general) {
    self.pasteboard = pasteboard
  }

  static func isSystemClipboard(_ register: String?) -> Bool {
    guard let register else { return true }
    return register == "+" || register == "*" || register == "\""
  }

  /// A bare yank updates register 0. Explicit destinations update the unnamed
  /// register too, but leave 0 alone, as in Vim. Uppercase letters append and
  /// make the accumulated value the unnamed register. The black hole discards.
  func write(_ text: String, register: String?) {
    guard !text.isEmpty else { return }
    guard let register else {
      named["0"] = text
      writeClipboard(text)
      return
    }
    guard register.count == 1, let name = register.first else { return }
    if name == "_" { return }
    if Self.isSystemClipboard(register) {
      if name == "\"" { named["0"] = text }
      writeClipboard(text)
      return
    }
    guard name.isASCII, name.isLetter || name.isNumber else { return }
    let key = Character(name.lowercased())
    let value: String
    if name.isUppercase {
      value = named[key, default: ""] + text
    } else {
      value = text
    }
    named[key] = value
    writeClipboard(value)
  }

  func read(register: String?) -> String? {
    guard let register else { return pasteboard.string(forType: .string) }
    guard register.count == 1, let name = register.first else { return nil }
    if Self.isSystemClipboard(register) {
      return pasteboard.string(forType: .string)
    }
    if name == "_" { return nil }
    return named[Character(name.lowercased())]
  }

  func snapshot() -> [Entry] {
    var entries: [Entry] = []
    let clipboard = pasteboard.string(forType: .string) ?? ""
    if !clipboard.isEmpty {
      entries.append(Self.entry(name: "\"", text: clipboard, kind: "unnamed"))
    }
    entries.append(Self.entry(name: "+", text: clipboard, kind: "clipboard"))
    if let yank = named["0"] {
      entries.append(Self.entry(name: "0", text: yank, kind: "yank"))
    }
    for key in "abcdefghijklmnopqrstuvwxyz" {
      if let text = named[key] {
        entries.append(Self.entry(name: String(key), text: text, kind: "named"))
      }
    }
    for key in "123456789" {
      if let text = named[key] {
        entries.append(Self.entry(name: String(key), text: text, kind: "named"))
      }
    }
    return entries
  }

  private func writeClipboard(_ text: String) {
    if pasteboard.string(forType: .string) == text { return }
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  private static func entry(name: String, text: String, kind: String) -> Entry {
    let limit = 16 * 1024
    let bytes = Array(text.utf8.prefix(limit + 1))
    let truncated = bytes.count > limit
    return Entry(
      name: name,
      text: truncated ? String(decoding: bytes.prefix(limit), as: UTF8.self) : text,
      kind: kind,
      truncated: truncated)
  }
}
