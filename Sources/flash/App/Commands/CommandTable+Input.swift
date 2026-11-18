import AppKit
import FlashCore

/// Text and keys: `input`, `key`, `register`, `clipboard` and `macro`.
extension URLEventHandler {
  static let inputCommands: [String: CommandDefinition] = [
    "input focus": .init(
      "Focus an editable field in the focused window, keeping the mode",
      parse: { a in a.args.isEmpty ? .focusInput : nil }),
    "input line_start": inputMotion(
      .lineStart, "Move the cursor to the start of its line in the focused text"),
    "input line_end": inputMotion(
      .lineEnd, "Move the cursor to the end of its line in the focused text"),
    "input char_left": inputMotion(
      .charLeft, "Move the cursor one character left in the focused text"),
    "input char_right": inputMotion(
      .charRight, "Move the cursor one character right in the focused text"),
    "input line_up": inputMotion(.lineUp, "Move the cursor up a line in the focused text"),
    "input line_down": inputMotion(.lineDown, "Move the cursor down a line in the focused text"),
    "input document_start": inputMotion(
      .documentStart, "Move the cursor to the start of the focused text"),
    "input document_end": inputMotion(
      .documentEnd, "Move the cursor to the end of the focused text"),
    "register yank": .init(
      "Copy the focused app's selection into a register", [.text("register", "name")],
      parse: { a in
        guard validRegisterArg(a) else { return nil }
        return .yankSelection(register: registerArg(a))
      }),
    "register paste": .init(
      "Paste a register with the app's own paste; --after first steps past the character "
        + "under the cursor, as vim's p",
      [.text("register", "name"), .flag("after")],
      parse: { a in
        guard validRegisterArg(a) else { return nil }
        return .paste(register: registerArg(a), after: a.bool("after"))
      }),
    "clipboard copy": .init(
      "Copy with the focused app's copy command", parse: { _ in .clipboardCopy }),
    "clipboard paste": .init(
      "Paste with the focused app's paste command", parse: { _ in .clipboardPaste }),
    "clipboard show": .init(
      "Open the clipboard history", [.text("offset", "0..10000")],
      parse: { args in
        let raw = args.value("offset") ?? "0"
        guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }),
          let offset = Int(raw), (0...10_000).contains(offset)
        else { return nil }
        return .clipboardHistory(action: "show", id: nil, offset: offset)
      }),
    "clipboard delete": .init(
      "Delete one clipboard history entry", [.text("id", "entry-id", required: true)],
      parse: { args in
        guard let id = args.value("id"), ClipboardCapture.isEntryID(id) else { return nil }
        return .clipboardHistory(action: "delete", id: id, offset: nil)
      }),
    "clipboard pin": .init(
      "Pin one clipboard history entry: it lists first and is never trimmed",
      [.text("id", "entry-id", required: true)],
      parse: { args in
        guard let id = args.value("id"), ClipboardCapture.isEntryID(id) else { return nil }
        return .clipboardHistory(action: "pin", id: id, offset: nil)
      }),
    "clipboard unpin": .init(
      "Unpin one clipboard history entry", [.text("id", "entry-id", required: true)],
      parse: { args in
        guard let id = args.value("id"), ClipboardCapture.isEntryID(id) else { return nil }
        return .clipboardHistory(action: "unpin", id: id, offset: nil)
      }),
    "clipboard restore": .init(
      "Put a clipboard history entry back on the clipboard; --paste pastes it, "
        + "--plain keeps only its text",
      [.text("id", "entry-id", required: true), .flag("paste"), .flag("plain")],
      parse: { args in
        guard let id = args.value("id"), ClipboardCapture.isEntryID(id) else { return nil }
        return .clipboardRestore(id: id, paste: args.bool("paste"), plain: args.bool("plain"))
      }),
    "macro record": .init(
      "Record the commands that follow into a register (q{reg})",
      [.text("register", "name", required: true)],
      parse: { a in
        a.value("register").flatMap(MacroCommand.recordingRegister).map {
          .macro(.record(register: $0))
        }
      }),
    "macro stop": .init(
      "Stop recording the macro", parse: { _ in .macro(.stop) }),
    "macro play": .init(
      "Replay a macro register, or the last one played (@{reg}, @@)",
      [.text("register", "name")],
      parse: { a in
        guard let raw = a.value("register") else { return .macro(.play(register: nil)) }
        return MacroCommand.playRegister(raw).map { .macro(.play(register: $0)) }
      }),
    "macro repeat": .init(
      "Run the last NORMAL command again (.), --count times instead of its own count ({count}.)",
      [.integer("count")],
      parse: { a in
        guard let raw = a.value("count") else { return .macro(.repeatLast(count: nil)) }
        guard let count = Int(raw), (1...RepeatCount.max).contains(count) else { return nil }
        return .macro(.repeatLast(count: count))
      }),
    "key system": .init(
      "Press an Apple function-row key (media_play, brightness_down, …)",
      [.text("key", "brightness_down", required: true)],
      parse: { a in
        guard let name = a.value("key"), let key = SystemKeyboard.RowKey.named(name) else {
          return nil
        }
        return .systemKey(key)
      }),
    "key function": .init(
      "Press a plain F1–F20 key", [.text("key", "f1", required: true)],
      parse: { a in
        guard let name = a.value("key")?.lowercased(),
          name.hasPrefix("f"), let index = Int(name.dropFirst()), (1...20).contains(index)
        else { return nil }
        return .functionKey(index)
      }),
    "key arrow": .init(
      "Press one arrow key; --shift holds Shift",
      [.text("direction", "left|down|up|right", required: true), .flag("shift")],
      parse: { a in
        guard let value = a.value("direction"),
          let direction = WindowFocusDirection(rawValue: value)
        else { return nil }
        return .arrow(direction: direction, shift: a.bool("shift"))
      }),
    "key send": .init(
      "Send one keystroke to the focused app", [.text("keys", "hotkey", required: true)],
      parse: sendKeyCommand),
    "key sequence": .init(
      "Send a short key sequence to the focused app",
      [.text("keys", "hotkey,hotkey,...", required: true)], parse: sendKeysCommand),
  ]

  /// `input <motion>`, which takes no arguments.
  static func inputMotion(_ motion: InputMotion, _ summary: String) -> CommandDefinition {
    .init(summary, parse: { a in a.args.isEmpty ? .inputMotion(motion) : nil })
  }

  /// `flash key send --keys=<hotkey>` synthesizes one modified keystroke to
  /// the focused app. `keys` uses the exact same syntax as a config hotkey
  /// (`cmd+option+r`, `shift+tab`, `0x24`), so a plugin can override a
  /// built-in keystroke (e.g. Safari's hard refresh is `cmd+option+r`, not
  /// the default `cmd+shift+r`) just by registering an app-scoped mapping
  /// that points here. Rejected at parse time when `keys` is missing or
  /// unparseable.
  static func sendKeyCommand(_ a: CommandArgs) -> URLCommand? {
    guard let keys = a.value("keys"), let parsed = HotkeySyntax.parse(hotkey: keys) else {
      return nil
    }
    return .sendKey(
      keys: keys,
      keyCode: CGKeyCode(parsed.virtualKey),
      flagsRawValue: parsed.eventFlags.rawValue)
  }

  /// `flash key sequence --keys=<hotkey,hotkey,...>` synthesizes a short key sequence
  /// to the focused app. It is primarily for app-local multi-stroke shortcuts
  /// such as Gmail's `g` then `i` navigation commands.
  static func sendKeysCommand(_ a: CommandArgs) -> URLCommand? {
    guard let keys = a.value("keys") else { return nil }
    var keyCodes: [CGKeyCode] = []
    var flagsRawValues: [UInt64] = []
    let parts = keys.split(separator: ",", omittingEmptySubsequences: false)
    guard !parts.isEmpty else { return nil }
    for raw in parts {
      let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !token.isEmpty, let parsed = HotkeySyntax.parse(hotkey: token) else {
        return nil
      }
      keyCodes.append(CGKeyCode(parsed.virtualKey))
      flagsRawValues.append(parsed.eventFlags.rawValue)
    }
    return .sendKeys(keys: keys, keyCodes: keyCodes, flagsRawValues: flagsRawValues)
  }
}
