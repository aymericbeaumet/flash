import AppKit
import Carbon.HIToolbox
import FlashCore
import XCTest

@testable import flash

/// The focused element as Flash reads it (`FocusedText`) and the `input`
/// commands that move the cursor or extend the app's selection in it. None
/// edits the text: Flash never does (`NoTextEditingTests`).
final class FocusedTextTests: XCTestCase {
  override func setUp() {
    super.setUp()
    TerminalEmulatorFixture.declareOfficial()
  }

  // MARK: - The input commands

  func testInputMotionsAreCommandsAskedOfTheFocusedApp() throws {
    for motion in InputMotion.allCases {
      let command = try XCTUnwrap(URLEventHandler.parse(words: ["input", motion.rawValue]))
      XCTAssertEqual(command, .inputMotion(motion))
      XCTAssertEqual(command.argv, ["flash", "input", motion.rawValue])
      XCTAssertEqual(command.sourceCommand?.name, CommandName("input", motion.rawValue))
      XCTAssertEqual(command.changesMode, false)
      XCTAssertTrue(URLEventHandler.sourceCommandNames.contains(motion.commandName))
      XCTAssertNil(URLEventHandler.parse(words: ["input", motion.rawValue, "--force"]))
      XCTAssertTrue(MacroState.repeats(.flashCommand(command)), "\(motion)")
    }
    XCTAssertEqual(
      InputMotion.allCases.map(\.rawValue),
      [
        "line_start", "line_end", "char_left", "char_right", "line_up", "line_down",
        "document_start", "document_end", "select_left", "select_right", "select_up", "select_down",
        "select_word_left",
        "select_word_right", "select_line_start", "select_line_end", "select_document_start",
        "select_document_end",
      ])
  }

  // MARK: - Resolution per app kind

  /// The `defaults` plugin carries the macOS keys for every app.
  func testATextAppGetsTheMacOSKeys() throws {
    let index = CommandBindingIndex(manifests: try SourceCommandFallbackTests.officialManifests())
    let expected: [InputMotion: String] = [
      .lineStart: "cmd+left", .lineEnd: "cmd+right", .charLeft: "left", .charRight: "right",
      .lineUp: "up", .lineDown: "down", .documentStart: "cmd+up", .documentEnd: "cmd+down",
      .selectLeft: "shift+left", .selectRight: "shift+right", .selectUp: "shift+up",
      .selectDown: "shift+down", .selectWordLeft: "shift+alt+left",
      .selectWordRight: "shift+alt+right", .selectLineStart: "shift+cmd+left",
      .selectLineEnd: "shift+cmd+right", .selectDocumentStart: "shift+cmd+up",
      .selectDocumentEnd: "shift+cmd+down",
    ]
    for bundle in ["com.apple.TextEdit", "com.microsoft.VSCode", "com.example.unknown"] {
      for motion in InputMotion.allCases {
        let resolution = try XCTUnwrap(
          index.resolve(Self.key(motion), in: PluginSelectorContext(bundleID: bundle)),
          "\(motion) in \(bundle)")
        XCTAssertEqual(resolution.pluginID, "defaults", "\(motion) in \(bundle)")
        XCTAssertEqual(
          Self.chords(index, motion, in: bundle), [try Self.chord(expected[motion]!)],
          "\(motion) in \(bundle)")
      }
    }
  }

  /// Inside a terminal emulator (tmux panes included, which live in one)
  /// every one of those keys would reach the shell, or vim running in it, so
  /// the `terminals` plugin binds none of them.
  func testATerminalBindsNoMotion() throws {
    let index = CommandBindingIndex(manifests: try SourceCommandFallbackTests.officialManifests())
    XCTAssertFalse(TerminalEmulatorFixture.official.isEmpty)
    for emulator in TerminalEmulatorFixture.official {
      let context = PluginSelectorContext(bundleID: emulator)
      for motion in InputMotion.allCases {
        let resolution = try XCTUnwrap(index.resolve(Self.key(motion), in: context))
        XCTAssertEqual(resolution.pluginID, "terminals", "\(motion) in \(emulator)")
        XCTAssertEqual(resolution.spec, .unbound, "\(motion) in \(emulator)")
        XCTAssertEqual(
          SourceCommandFallback.resolve(
            motion.commandName, binding: index.binding(Self.key(motion), in: context)),
          SourceCommandFallback.none, "\(motion) in \(emulator)")
      }
    }
  }

  /// A terminal types any key without Command, so whatever a default command
  /// resolves to there carries Command or is nothing at all.
  func testNoDefaultCommandSendsAPlainKeyToATerminal() throws {
    let index = CommandBindingIndex(manifests: try SourceCommandFallbackTests.officialManifests())
    for emulator in TerminalEmulatorFixture.official {
      let context = PluginSelectorContext(bundleID: emulator)
      for key in URLEventHandler.sourceCommandBindingKeys {
        guard case .chords(let chords)? = index.binding(key, index: 1, in: context) else {
          continue
        }
        for chord in chords {
          XCTAssertTrue(
            chord.eventFlags.contains(.maskCommand), "\(key) in \(emulator): \(chord.keyCode)")
        }
      }
    }
  }

  // MARK: - The focused text

  func testTheFocusedElementDecidesTheKindOfText() {
    let table: [(String?, String?, Bool?, FocusedText.Kind)] = [
      ("AXTextArea", nil, true, .multiLine),
      ("AXTextField", nil, true, .singleLine),
      ("AXTextField", "AXSearchField", true, .singleLine),
      ("AXSearchField", nil, true, .singleLine),
      ("AXComboBox", nil, true, .singleLine),
      // A secure field is editable text whatever it says about its value.
      ("AXTextField", "AXSecureTextField", true, .singleLine),
      ("AXTextField", "AXSecureTextField", false, .singleLine),
      ("AXTextField", "AXSecureTextField", nil, .singleLine),
      // Read-only text (a log view, a message bubble, a license sheet whose
      // default button Return would press) and anything that did not say.
      ("AXTextArea", nil, false, .uneditable),
      ("AXTextArea", nil, nil, .uneditable),
      ("AXTextField", nil, false, .uneditable),
      // Finder's file list, a canvas, a web page, a button.
      ("AXOutline", nil, false, .uneditable),
      ("AXList", nil, nil, .uneditable),
      ("AXWebArea", nil, false, .uneditable),
      ("AXGroup", nil, true, .uneditable),
      ("AXButton", nil, nil, .uneditable),
      (nil, nil, nil, .uneditable),
    ]
    for (role, subrole, settable, kind) in table {
      XCTAssertEqual(
        FocusedText.kind(role: role, subrole: subrole, valueSettable: settable), kind,
        "\(role ?? "nil") \(subrole ?? "nil") \(String(describing: settable))")
    }
  }

  func testTheCaretEndsItsLineBeforeABreakOrAtTheEnd() {
    func atEnd(
      _ location: Int, selection: Int = 0, length: Int?, next: String?,
      in kind: FocusedText.Kind = .multiLine
    ) -> Bool? {
      FocusedText.caretAtLineEnd(
        in: kind, location: location, selectionLength: selection, length: length, next: next)
    }
    XCTAssertEqual(atEnd(5, length: 5, next: nil), true)
    XCTAssertEqual(atEnd(2, length: 5, next: "\n"), true)
    XCTAssertEqual(atEnd(2, length: 5, next: "\r"), true)
    XCTAssertEqual(atEnd(2, length: 5, next: "\u{2028}"), true)
    XCTAssertEqual(atEnd(2, length: 5, next: "x"), false)
    // Right collapses a selection to its end, stepping over nothing.
    XCTAssertEqual(atEnd(2, selection: 3, length: 5, next: "\n"), false)
    // Nothing read, nothing known.
    XCTAssertNil(atEnd(2, length: 5, next: nil))
    XCTAssertNil(atEnd(2, length: nil, next: nil))
    // One line ends where its text does; its characters are never needed.
    XCTAssertEqual(atEnd(5, length: 5, next: nil, in: .singleLine), true)
    XCTAssertEqual(atEnd(2, length: 5, next: nil, in: .singleLine), false)
    XCTAssertNil(atEnd(2, length: nil, next: nil, in: .singleLine))
  }

  /// The arrows move in any editable text, a field's Up and Down included
  /// (a search field's suggestions), as NORMAL's `j` and `k` do; nothing
  /// that is not editable text, and no terminal, native or drawn by
  /// xterm.js, gets one, whatever its plugin bindings say.
  func testEveryMoveNeedsEditableText() {
    let multi = FocusedText(kind: .multiLine, caretAtLineEnd: nil)
    let single = FocusedText(kind: .singleLine, caretAtLineEnd: nil)
    for motion in InputMotion.allCases {
      XCTAssertTrue(motion.isPermitted(in: multi), "\(motion)")
      XCTAssertTrue(motion.isPermitted(in: single), "\(motion)")
      XCTAssertFalse(motion.isPermitted(in: .uneditable), "\(motion)")
      XCTAssertFalse(motion.isPermitted(in: .terminal), "\(motion)")
    }
  }

  // MARK: - Reading the focused element

  /// xterm.js (VS Code's, Cursor's, Hyper's, Tabby's terminals, a web
  /// terminal) types into `textarea.xterm-helper-textarea`, a text area or,
  /// with its `aria-multiline="false"`, a text field to Accessibility.
  func testAnXtermInputIsATerminal() {
    for role in ["AXTextArea", "AXTextField"] {
      let element = FakeTextElement(
        role: role, domClasses: ["xterm-helper-textarea"], description: "Terminal 1, zsh")
      XCTAssertEqual(Self.read(element), .terminal, role)
      XCTAssertEqual(element.reads, ["identity"], "nothing more is read")
    }
    let editor = FakeTextElement(role: "AXTextArea", domClasses: ["inputarea"])
    XCTAssertEqual(Self.read(editor).kind, .multiLine, "VS Code's editor stays text")
    let page = FakeTextElement(role: "AXTextArea", domClasses: [])
    XCTAssertEqual(Self.read(page).kind, .multiLine)
  }

  /// Firefox exposes no DOM classes: xterm.js's prompt label is what tells
  /// its input apart there. Where classes are exposed they decide.
  func testWithoutClassesTheXtermPromptLabelTellsTheTerminal() {
    let firefox = FakeTextElement(
      role: "AXTextArea", domClasses: nil, description: "Terminal input")
    XCTAssertEqual(Self.read(firefox), .terminal)
    let labelled = FakeTextElement(
      role: "AXTextArea", domClasses: [], description: "Terminal input")
    XCTAssertEqual(Self.read(labelled).kind, .multiLine)
    let native = FakeTextElement(role: "AXTextArea", domClasses: nil, description: "Notes")
    XCTAssertEqual(Self.read(native).kind, .multiLine)
  }

  /// A declared terminal emulator is a terminal without a single read.
  func testADeclaredTerminalEmulatorIsNotRead() {
    let element = FakeTextElement(role: "AXTextArea")
    XCTAssertEqual(
      FocusedText.read(element, inTerminalEmulator: true, detail: .contents), .terminal)
    XCTAssertEqual(element.reads, [])
  }

  func testTheFocusedElementIsReadOnlyAsFarAsItMatters() {
    XCTAssertEqual(
      FocusedText.read(FakeTextElement?.none, inTerminalEmulator: false, detail: .caret),
      .uneditable)
    let silent = FakeTextElement(role: nil)
    silent.answersIdentity = false
    XCTAssertEqual(Self.read(silent), .uneditable)

    let finder = FakeTextElement(role: "AXOutline", settable: false)
    XCTAssertEqual(Self.read(finder, caret: true), .uneditable)
    XCTAssertEqual(finder.reads, ["identity", "settable"], "no caret read without text")

    // A password field: editable, never asked about its value or a character.
    let password = FakeTextElement(
      role: "AXTextField", subrole: "AXSecureTextField", settable: nil, selection: (2, 0),
      length: 8)
    XCTAssertEqual(
      Self.read(password, caret: true),
      FocusedText(kind: .singleLine, caretAtLineEnd: false))
    XCTAssertEqual(password.reads, ["identity", "range", "count"])

    // Single-line text ends where it does: its characters are never read.
    let field = FakeTextElement(role: "AXTextField", selection: (2, 0), length: 5)
    XCTAssertEqual(Self.read(field, caret: true).caretAtLineEnd, false)
    XCTAssertFalse(field.reads.contains("character"))

    // Multi-line text reads the one character after the caret.
    let area = FakeTextElement(role: "AXTextArea", selection: (2, 0), length: 5, next: "\n")
    XCTAssertEqual(Self.read(area, caret: true).caretAtLineEnd, true)
    XCTAssertEqual(area.reads, ["identity", "settable", "range", "count", "character:2"])
    let noCaret = FakeTextElement(role: "AXTextArea", selection: (2, 0), length: 5, next: "\n")
    XCTAssertNil(Self.read(noCaret).caretAtLineEnd)
    XCTAssertEqual(noCaret.reads, ["identity", "settable"])
  }

  /// What an element is: the region the movement keys read follows its
  /// editability; whether NORMAL acts on it is the engagement on top
  /// (`TextScopeTests`).
  func testEditableFocusIsTextAndTheRestIsNot() {
    var scope = TextScope()
    _ = scope.engage(.init(pid: 7, identity: 1), in: "com.example.app", reason: .leftInsert)
    for kind in [FocusedText.Kind.singleLine, .multiLine] {
      let text = FocusedText(
        kind: kind, contents: FocusedText.Contents(selection: 0..<0, length: 3, text: "abc"))
      XCTAssertTrue(TextScope.isEditable(text), "\(kind)")
      XCTAssertTrue(scope.isActive(for: text, pid: 7, element: 1), "\(kind)")
      XCTAssertEqual(FocusRegion.classify(text: text, roles: []), .text(kind))
    }
    for text in [FocusedText.uneditable, .terminal] {
      XCTAssertFalse(TextScope.isEditable(text), "\(text)")
      XCTAssertFalse(scope.isActive(for: text, pid: 7, element: 1), "\(text)")
      XCTAssertNotEqual(FocusRegion.classify(text: text, roles: []), .text(text.kind))
    }
  }

  // MARK: - Reading the contents

  /// The contents read: the selection and length always, the text only
  /// outside a secure field and when it agrees with the length.
  func testTheContentsReadNeverReadsASecureFieldsText() {
    let field = FakeTextElement(role: "AXTextField", selection: (2, 0), length: 5)
    field.text = "hello"
    XCTAssertEqual(
      Self.contents(field).contents,
      FocusedText.Contents(selection: 2..<2, length: 5, text: "hello"))
    XCTAssertEqual(field.reads, ["identity", "settable", "range", "count", "value"])

    let password = FakeTextElement(
      role: "AXTextField", subrole: "AXSecureTextField", settable: nil, selection: (3, 0),
      length: 8)
    password.text = "secret!!"
    XCTAssertEqual(
      Self.contents(password).contents, FocusedText.Contents(selection: 3..<3, length: 8, text: nil)
    )
    XCTAssertEqual(password.reads, ["identity", "range", "count"], "no value read")

    // An app whose text and length disagree (an attachment it counts as
    // two) keeps its text unread: offsets could not be trusted.
    let attachment = FakeTextElement(role: "AXTextArea", selection: (1, 0), length: 6)
    attachment.text = "a\u{FFFC}b"
    XCTAssertNil(Self.contents(attachment).contents?.text)
    XCTAssertEqual(Self.contents(attachment).contents?.length, 6)

    // No selection: nothing measured.
    let silent = FakeTextElement(role: "AXTextArea", selection: nil, length: 6)
    XCTAssertNil(Self.contents(silent).contents)
  }

  // MARK: - Helpers

  private static func read(_ element: FakeTextElement, caret: Bool = false) -> FocusedText {
    FocusedText.read(element, inTerminalEmulator: false, detail: caret ? .caret : .kind)
  }

  private static func contents(_ element: FakeTextElement) -> FocusedText {
    FocusedText.read(element, inTerminalEmulator: false, detail: .contents)
  }

  private static func key(_ motion: InputMotion) -> CommandBindingKey {
    CommandBindingKey(motion.commandName)
  }

  private static func chords(
    _ index: CommandBindingIndex, _ motion: InputMotion, in bundle: String
  ) -> [BindingChord]? {
    guard
      case .chords(let hotkeys)? = index.binding(
        key(motion), in: PluginSelectorContext(bundleID: bundle))
    else { return nil }
    return hotkeys.map(BindingChord.init)
  }

  private static func chord(_ text: String) throws -> BindingChord {
    BindingChord(try XCTUnwrap(HotkeySyntax.parse(hotkey: text), text))
  }
}

/// A focused element that answers from fixed values and records each read.
final class FakeTextElement: FocusedTextElement {
  let role: String?
  let subrole: String?
  let domClasses: [String]?
  let elementDescription: String?
  let settable: Bool?
  let selection: (location: Int, length: Int)?
  let length: Int?
  let next: String?
  var text: String?
  var answersIdentity = true
  private(set) var reads: [String] = []

  init(
    role: String?, subrole: String? = nil, domClasses: [String]? = nil,
    description: String? = nil, settable: Bool? = true,
    selection: (location: Int, length: Int)? = nil, length: Int? = nil, next: String? = nil
  ) {
    self.role = role
    self.subrole = subrole
    self.domClasses = domClasses
    self.elementDescription = description
    self.settable = settable
    self.selection = selection
    self.length = length
    self.next = next
  }

  func identity() -> FocusedTextIdentity? {
    reads.append("identity")
    guard answersIdentity else { return nil }
    return FocusedTextIdentity(
      role: role, subrole: subrole, domClasses: domClasses, description: elementDescription)
  }

  func valueIsSettable() -> Bool? {
    reads.append("settable")
    return settable
  }

  func selectedRange() -> CFRange? {
    reads.append("range")
    return selection.map { CFRange(location: $0.location, length: $0.length) }
  }

  func characterCount() -> Int? {
    reads.append("count")
    return length
  }

  func character(at location: Int) -> String? {
    reads.append("character:\(location)")
    return next
  }

  func value() -> String? {
    reads.append("value")
    return text
  }
}
