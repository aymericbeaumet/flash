import FlashCore
import Foundation

/// One step in the focused editable text, and the `input` command that takes
/// it alone: the cursor moves of NORMAL's `h` `j` `k` `l`, `gg` and `G` in
/// text (`move`) and Vim's `p`, and the app's selection keys VISUAL extends a
/// selection with where the app gives no text. None edits the text: Flash
/// never deletes, changes or inserts it. Each is asked of the focused app like
/// every source command: a source that performs it there, else the binding a
/// plugin declares for it. The `defaults` plugin carries the macOS keys
/// (Cmd-Left, Cmd-Right, the arrows, Cmd-Up, Cmd-Down, Shift with them); the
/// `terminals` plugin binds none of them, since a shell would receive every
/// one.
enum InputMotion: String, CaseIterable, Hashable {
  case lineStart = "line_start"
  case lineEnd = "line_end"
  case charLeft = "char_left"
  case charRight = "char_right"
  case lineUp = "line_up"
  case lineDown = "line_down"
  case documentStart = "document_start"
  case documentEnd = "document_end"
  /// The app's selection keys, which VISUAL extends a selection with where
  /// the app gives no text to measure: Shift with an arrow, with Option for
  /// a word and with Command for a line's or the text's edge.
  case selectLeft = "select_left"
  case selectRight = "select_right"
  case selectUp = "select_up"
  case selectDown = "select_down"
  case selectWordLeft = "select_word_left"
  case selectWordRight = "select_word_right"
  case selectLineStart = "select_line_start"
  case selectLineEnd = "select_line_end"
  case selectDocumentStart = "select_document_start"
  case selectDocumentEnd = "select_document_end"

  var commandName: CommandName { CommandName("input", rawValue) }

  /// Whether the focused text takes this step: any editable text, never a
  /// terminal or what is not editable.
  func isPermitted(in text: FocusedText) -> Bool {
    switch text.kind {
    case .uneditable, .terminal: return false
    case .singleLine, .multiLine: return true
    }
  }
}

/// What the focused-text read needs of one element's first answer.
struct FocusedTextIdentity: Equatable {
  var role: String?
  var subrole: String?
  /// `AXDOMClassList`: nil where the element is not web content, or its
  /// engine does not expose it.
  var domClasses: [String]?
  /// `AXDescription`.
  var description: String?
}

/// The reads the focused-text probe makes of one element, so the decision
/// runs on fake elements in tests. Each is blocking AX IPC in production.
protocol FocusedTextElement {
  /// The role, subrole, DOM classes and description, in one read; nil when
  /// the element answered nothing.
  func identity() -> FocusedTextIdentity?
  /// Whether `AXValue` is settable; nil when the app did not answer.
  func valueIsSettable() -> Bool?
  /// `AXSelectedTextRange`.
  func selectedRange() -> CFRange?
  /// `AXNumberOfCharacters`.
  func characterCount() -> Int?
  /// The one character at `location` (`AXStringForRange`).
  func character(at location: Int) -> String?
  /// The whole text (`AXValue`); never asked of a secure field.
  func value() -> String?
}

/// The focused element as `move`, the motions, VISUAL and the `input`
/// commands read it, once, off the main thread
/// (`NormalModeDispatcher.focusedText`).
struct FocusedText: Equatable {
  /// How much a read asks of the element: what it is, where the caret sits
  /// (Vim's `p`), or its contents (the motions, VISUAL, `h` and `l` in
  /// text).
  enum Detail: Equatable {
    case kind
    case caret
    case contents
  }

  /// What the motions and the in-line moves read: the selection and the
  /// length, which a secure field gives too, and the text itself, which it
  /// never does. Offsets are UTF-16, as Accessibility counts them.
  struct Contents: Equatable {
    var selection: Range<Int>
    var length: Int
    /// Nil in a secure field, past `maxTextLength`, or where the app's text
    /// disagrees with its own length (an attachment it counts differently):
    /// then only the selection and the length are known.
    var text: String?
  }

  /// Text longer than this is not read: one `AXValue` per keypress must stay
  /// a few milliseconds. Moves there act on lengths alone, or not at all.
  static let maxTextLength = 1_000_000

  enum Kind: Equatable {
    /// Nothing editable has focus: Finder's file list, a canvas, a web page,
    /// read-only text. Return there renames, presses or submits, so nothing
    /// is sent.
    case uneditable
    /// A text field, search field, combo box, secure field or single-line web
    /// input: Return submits it.
    case singleLine
    /// A text area: Return breaks the line.
    case multiLine
    /// A terminal: a declared terminal emulator, or one drawn in web content
    /// (xterm.js, in VS Code, Cursor, Hyper, Tabby or a browser tab). Its
    /// keys reach a shell, or the program running in it, so nothing is sent
    /// there, whatever role its input carries.
    case terminal
  }

  var kind: Kind
  /// Whether the caret ends its line, so Vim's `p` has nothing to step
  /// over; nil when it was not read or the app did not say.
  var caretAtLineEnd: Bool?
  /// The contents a `.contents` read found; nil for other reads, outside
  /// editable text, or where the app gave no selection.
  var contents: Contents?

  init(kind: Kind, caretAtLineEnd: Bool? = nil, contents: Contents? = nil) {
    self.kind = kind
    self.caretAtLineEnd = caretAtLineEnd
    self.contents = contents
  }

  static let uneditable = FocusedText(kind: .uneditable)
  static let terminal = FocusedText(kind: .terminal)

  /// The focused element as Flash reads it. A declared terminal
  /// emulator is a terminal without a single read; otherwise one read gives
  /// the role, subrole, DOM classes and description, a web terminal is
  /// recognised from those, and the value's settability decides the rest.
  /// With `.caret`, the caret is read too: its range and the text's length,
  /// and in multi-line text the character after it. Single-line text, a
  /// password field's included, never has a character read. With
  /// `.contents`, the selection, the length and the text (`contents`); a
  /// secure field gives its selection and length, never its text.
  static func read<Element: FocusedTextElement>(
    _ element: Element?, inTerminalEmulator: Bool, detail: Detail
  ) -> FocusedText {
    if inTerminalEmulator { return .terminal }
    guard let element, let identity = element.identity() else { return .uneditable }
    if isWebTerminal(identity) { return .terminal }
    let secure = identity.subrole == secureTextFieldSubrole
    let kind = Self.kind(
      role: identity.role, subrole: identity.subrole,
      valueSettable: secure ? nil : element.valueIsSettable())
    guard kind != .uneditable else { return .uneditable }
    var text = FocusedText(kind: kind)
    switch detail {
    case .kind: break
    case .caret: text.caretAtLineEnd = caretAtLineEnd(of: element, in: kind)
    case .contents: text.contents = contents(of: element, secure: secure)
    }
    return text
  }

  /// The selection, the length and, outside a secure field, the text. Nil
  /// when the app gives no selection or no length: nothing can be measured.
  private static func contents<Element: FocusedTextElement>(
    of element: Element, secure: Bool
  ) -> Contents? {
    guard let selection = element.selectedRange(), selection.location >= 0,
      selection.length >= 0, let length = element.characterCount(), length >= 0,
      selection.location + selection.length <= length
    else { return nil }
    var text: String?
    if !secure, length <= maxTextLength, let value = element.value(),
      value.utf16.count == length
    {
      text = value
    }
    return Contents(
      selection: selection.location..<(selection.location + selection.length), length: length,
      text: text)
  }

  /// xterm.js types into a hidden `<textarea class="xterm-helper-textarea">`,
  /// whatever page embeds it. Chromium (every Electron app) and WebKit expose
  /// an element's classes as `AXDOMClassList`, an array of class names.
  /// Firefox exposes none; there the textarea's label is the one thing
  /// xterm.js sets that Accessibility shows: its prompt label, `Terminal
  /// input` unless the embedder translated it.
  static func isWebTerminal(_ identity: FocusedTextIdentity) -> Bool {
    if let classes = identity.domClasses { return classes.contains(xtermInputClass) }
    return identity.description == xtermPromptLabel
  }

  static let xtermInputClass = "xterm-helper-textarea"
  static let xtermPromptLabel = "Terminal input"

  private static func caretAtLineEnd<Element: FocusedTextElement>(
    of element: Element, in kind: Kind
  ) -> Bool? {
    guard let selection = element.selectedRange(), selection.location >= 0 else { return nil }
    let length = element.characterCount()
    if let known = caretAtLineEnd(
      in: kind, location: selection.location, selectionLength: selection.length,
      length: length, next: nil)
    {
      return known
    }
    guard kind == .multiLine else { return nil }
    return caretAtLineEnd(
      in: kind, location: selection.location, selectionLength: 0, length: length,
      next: element.character(at: selection.location))
  }

  /// The kind for the focused element's role and subrole, and whether its
  /// value is settable (nil when the app did not answer). A secure field is
  /// editable whatever it says about its value; any other element is editable
  /// text only on an explicit yes.
  static func kind(role: String?, subrole: String?, valueSettable: Bool?) -> Kind {
    if subrole == secureTextFieldSubrole { return .singleLine }
    guard valueSettable == true else { return .uneditable }
    if role == "AXTextArea" { return .multiLine }
    return JumpTarget.isTextInput(role: role, subrole: subrole) ? .singleLine : .uneditable
  }

  static let secureTextFieldSubrole = "AXSecureTextField"

  /// Whether a caret at `location` ends its line: at the end of a text
  /// `length` long, or, in multi-line text, just before a line break (`next`,
  /// the character after it, which single-line text never needs). With a
  /// selection the caret steps over nothing, since Right collapses the
  /// selection to its end. Nil when nothing says.
  static func caretAtLineEnd(
    in kind: Kind, location: Int, selectionLength: Int, length: Int?, next: String?
  ) -> Bool? {
    if selectionLength > 0 { return false }
    if let length, location >= length { return true }
    if kind == .singleLine { return length == nil ? nil : false }
    guard let scalar = next?.unicodeScalars.first else { return nil }
    return lineBreaks.contains(scalar)
  }

  private static let lineBreaks: Set<Unicode.Scalar> = [
    "\n", "\r", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}",
  ]
}
