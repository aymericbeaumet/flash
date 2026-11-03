import AppKit
import FlashCore
import XCTest

@testable import flash

/// NORMAL's `h` `j` `k` `l`, `ctrl+d` `ctrl+u`, `ctrl+f` `ctrl+b`, `gg` and
/// `G` are `move` commands: arrows that move the caret in editable text and
/// the selection in a list, scrolls in a page or a terminal. Where the focus
/// sits comes from a cache each focus change refreshes, never from
/// Accessibility on the keypress.
final class MoveCommandTests: XCTestCase {
  override func setUp() {
    super.setUp()
    TerminalEmulatorFixture.declareOfficial()
  }

  // MARK: - Commands

  func testMoveCommandsParseAndRender() throws {
    for move in MoveCommand.allCases {
      let command = try XCTUnwrap(URLEventHandler.parse(words: ["move", move.rawValue]))
      XCTAssertEqual(command, .move(move))
      XCTAssertEqual(command.argv, ["flash", "move", move.rawValue])
      XCTAssertEqual(parseMappingCommand(argv: command.argv)?.command, command)
      XCTAssertEqual(command.changesMode, false)
      XCTAssertNil(URLEventHandler.parse(words: ["move", move.rawValue, "--count=3"]))
      XCTAssertFalse(command.explanation.isEmpty)
    }
    XCTAssertEqual(
      MoveCommand.allCases.map(\.rawValue),
      [
        "down", "up", "left", "right", "half_page_down", "half_page_up", "page_down", "page_up",
        "top", "bottom",
      ])
    XCTAssertNil(URLEventHandler.parse(words: ["move", "sideways"]))
  }

  /// The one-step moves are what a list's app binds; a half page or a page
  /// repeats the one-step binding, so it has none of its own.
  func testOnlyTheOneStepMovesAreBindingKeys() {
    let keys = Set(URLEventHandler.sourceCommandBindingKeys.map(\.description))
    for move in [MoveCommand.down, .up, .left, .right, .top, .bottom] {
      XCTAssertTrue(keys.contains("move \(move.rawValue)"), move.rawValue)
    }
    for move in [MoveCommand.halfPageDown, .halfPageUp, .pageDown, .pageUp] {
      XCTAssertFalse(keys.contains("move \(move.rawValue)"), move.rawValue)
      XCTAssertNil(URLCommand.move(move).sourceCommand)
    }
    XCTAssertFalse(URLCommand.move(.top).sourceCommandRepeats)
    XCTAssertTrue(URLCommand.move(.down).sourceCommandRepeats)
  }

  /// Vim's `.` repeats a change, never a motion; a macro still records it.
  func testAMoveIsNotWhatDotRepeats() {
    for move in MoveCommand.allCases {
      XCTAssertFalse(MacroState.repeats(.flashCommand(.move(move))), move.rawValue)
    }
    var macros = MacroState()
    macros.startRecording("a")
    macros.note(MacroStep(action: .flashCommand(.move(.down)), repeatCount: 3))
    XCTAssertEqual(macros.stopRecording()?.count, 1)
    XCTAssertNil(macros.lastStep)
  }

  // MARK: - Where the focus sits

  /// Each role the focused element (or an ancestor) carries decides the
  /// region; anything unknown scrolls.
  func testTheFocusedRoleDecidesTheRegion() {
    let table: [([(String?, String?)], FocusRegion)] = [
      ([("AXList", nil)], .collection),
      ([("AXTable", nil)], .collection),
      ([("AXOutline", nil)], .collection),
      ([("AXBrowser", nil)], .collection),
      ([("AXGrid", nil)], .collection),
      ([("AXRow", "AXOutlineRow")], .collection),
      ([("AXCell", nil)], .collection),
      // A cell's text, a row's disclosure button.
      ([("AXStaticText", nil), ("AXCell", nil), ("AXRow", nil)], .collection),
      ([("AXButton", nil), ("AXRow", nil)], .collection),
      // A web page's plain list has no selection: Down scrolls the page.
      ([("AXLink", nil), ("AXGroup", nil), ("AXList", "AXContentList")], .document),
      ([("AXWebArea", nil), ("AXScrollArea", nil)], .document),
      ([("AXScrollArea", nil)], .document),
      ([("AXGroup", nil)], .document),
      ([("AXImage", nil)], .document),
      ([("AXSlider", nil)], .document),
      ([("AXPopUpButton", nil)], .document),
      ([(nil, nil)], .document),
      ([], .document),
    ]
    for (roles, region) in table {
      XCTAssertEqual(
        FocusRegion.classify(text: .uneditable, roles: roles.map { ($0.0, $0.1) }), region,
        "\(roles)")
    }
  }

  /// Editable text and terminals are what the focused-text read says,
  /// whatever ancestors surround them.
  func testTextAndTerminalsComeFromTheFocusedTextRead() {
    let inList = [(role: String?.some("AXTextField"), subrole: String?.none)]
    XCTAssertEqual(
      FocusRegion.classify(text: FocusedText(kind: .singleLine), roles: inList),
      .text(.singleLine))
    XCTAssertEqual(
      FocusRegion.classify(text: FocusedText(kind: .multiLine), roles: []), .text(.multiLine))
    XCTAssertEqual(FocusRegion.classify(text: .terminal, roles: [("AXList", nil)]), .terminal)
    // xterm.js reads as a terminal: VS Code's integrated terminal scrolls.
    let xterm = FakeTextElement(role: "AXTextArea", domClasses: ["xterm-helper-textarea"])
    let read = FocusedText.read(xterm, inTerminalEmulator: false, detail: .kind)
    XCTAssertEqual(FocusRegion.classify(text: read, roles: []), .terminal)
  }

  // MARK: - What a move does there

  func testEachRegionResolvesEachMove() {
    func resolve(_ move: MoveCommand, _ region: FocusRegion) -> MoveResolution {
      MoveResolution.resolve(move, in: region, pageLines: 15)
    }
    let text = FocusRegion.text(.multiLine)
    XCTAssertEqual(resolve(.down, text), .text(.lineDown, times: 1))
    XCTAssertEqual(resolve(.up, text), .text(.lineUp, times: 1))
    XCTAssertEqual(resolve(.left, text), .textInLine(.charLeft))
    XCTAssertEqual(resolve(.right, text), .textInLine(.charRight))
    XCTAssertEqual(resolve(.halfPageDown, text), .text(.lineDown, times: 15))
    XCTAssertEqual(resolve(.halfPageUp, text), .text(.lineUp, times: 15))
    XCTAssertEqual(resolve(.pageDown, text), .text(.lineDown, times: 30))
    XCTAssertEqual(resolve(.pageUp, text), .text(.lineUp, times: 30))
    XCTAssertEqual(resolve(.top, text), .text(.documentStart, times: 1))
    XCTAssertEqual(resolve(.bottom, text), .text(.documentEnd, times: 1))
    XCTAssertEqual(resolve(.down, .text(.singleLine)), .text(.lineDown, times: 1))

    XCTAssertEqual(resolve(.down, .collection), .arrows(.down, times: 1))
    XCTAssertEqual(resolve(.left, .collection), .arrows(.left, times: 1))
    XCTAssertEqual(resolve(.right, .collection), .arrows(.right, times: 1))
    XCTAssertEqual(resolve(.halfPageDown, .collection), .arrows(.down, times: 15))
    XCTAssertEqual(resolve(.pageUp, .collection), .arrows(.up, times: 30))
    XCTAssertEqual(resolve(.top, .collection), .arrows(.top, times: 1))
    XCTAssertEqual(resolve(.bottom, .collection), .arrows(.bottom, times: 1))

    // h j k l are arrows on a page too (a browser or a PDF scrolls on them);
    // the page keys and the edges keep scrolling there.
    for move in MoveCommand.allCases {
      let arrow: Set<MoveCommand> = [.down, .up, .left, .right]
      XCTAssertEqual(
        resolve(move, .document),
        arrow.contains(move) ? .arrows(move, times: 1) : .scroll(move.scroll), "\(move) on a page")
      // An arrow in a terminal is input to the shell (Up recalls history).
      XCTAssertEqual(resolve(move, .terminal), .scroll(move.scroll), "\(move) in a terminal")
    }
  }

  /// A count multiplies the arrows: `3` then `ctrl+d` is three half pages.
  func testACountMultipliesTheArrows() {
    XCTAssertEqual(
      MoveResolution.resolve(.halfPageDown, in: .collection, pageLines: 15).strokes(count: 3),
      45)
    XCTAssertEqual(
      MoveResolution.resolve(.pageDown, in: .text(.multiLine), pageLines: 10).strokes(count: 2),
      40)
    XCTAssertEqual(
      MoveResolution.resolve(.down, in: .text(.multiLine), pageLines: 15).strokes(count: 5), 5)
    // The edges are one key however often they are asked for.
    XCTAssertEqual(
      MoveResolution.resolve(.bottom, in: .text(.multiLine), pageLines: 15).strokes(count: 5), 1)
    XCTAssertEqual(
      MoveResolution.resolve(.top, in: .collection, pageLines: 15).strokes(count: 5), 1)
    XCTAssertEqual(MoveResolution.resolve(.down, in: .document, pageLines: 15).strokes(count: 4), 4)
  }

  /// `h` and `l` never leave the line: `h` stops at its start, `l` on its
  /// last character, as Vim's do; characters are whole graphemes.
  func testLeftAndRightStayOnTheLine() {
    let buffer = TextBuffer("ab\ncd👍🏽e\n\nf")
    func steps(_ motion: InputMotion, _ count: Int, from caret: Int) -> Int {
      LineStep.count(motion, requested: count, caret: caret, in: buffer)
    }
    XCTAssertEqual(steps(.charLeft, 1, from: 3), 0, "at the line start")
    XCTAssertEqual(steps(.charLeft, 5, from: 5), 2)
    XCTAssertEqual(steps(.charRight, 1, from: 0), 1)
    XCTAssertEqual(steps(.charRight, 1, from: 1), 0, "on the last character")
    XCTAssertEqual(steps(.charRight, 9, from: 3), 3, "c, d, the emoji, then e is last")
    XCTAssertEqual(steps(.charLeft, 1, from: 9), 1, "the emoji is one character")
    XCTAssertEqual(steps(.charLeft, 2, from: 10), 2, "from after the last character")
    XCTAssertEqual(steps(.charRight, 1, from: 10), 0, "past the last character")
    XCTAssertEqual(steps(.charLeft, 1, from: 11), 0, "an empty line")
    XCTAssertEqual(steps(.charRight, 1, from: 11), 0, "an empty line")
  }

  /// Without the text (a secure field, an app that does not give it) the
  /// arrows go as counted, which a field's edges stop; nothing outside
  /// editable text.
  func testLeftAndRightWithoutTheText() {
    let secure = FocusedText(
      kind: .singleLine,
      contents: FocusedText.Contents(selection: 2..<2, length: 8, text: nil))
    XCTAssertEqual(AppDelegate.inLineRepeats(.charRight, count: 3, in: secure), 3)
    XCTAssertEqual(
      AppDelegate.inLineRepeats(.charRight, count: 3, in: FocusedText(kind: .multiLine)), 3)
    XCTAssertEqual(AppDelegate.inLineRepeats(.charLeft, count: 3, in: .uneditable), 0)
    XCTAssertEqual(AppDelegate.inLineRepeats(.charLeft, count: 3, in: .terminal), 0)
    let text = FocusedText(
      kind: .multiLine,
      contents: FocusedText.Contents(selection: 1..<1, length: 5, text: "ab\ncd"))
    XCTAssertEqual(AppDelegate.inLineRepeats(.charRight, count: 3, in: text), 0)
    XCTAssertEqual(AppDelegate.inLineRepeats(.charLeft, count: 3, in: text), 1)
  }

  // MARK: - The cache

  /// A read lands for the latest focus only; a command typed while one is
  /// pending waits for it, in order, instead of acting on a stale region.
  func testTheCacheServesTheLatestFocusOnly() {
    var reads: [(pid_t, (FocusRegionTracker.Reading) -> Void)] = []
    let tracker = FocusRegionTracker { pid, deliver in reads.append((pid, deliver)) }
    tracker.focusMayHaveChanged(pid: 7)
    XCTAssertEqual(reads.count, 1)
    var answers: [FocusRegion] = []
    tracker.withReading(for: 7) { answers.append($0.region) }
    tracker.withReading(for: 7) { answers.append($0.region) }
    XCTAssertEqual(answers, [], "nothing known yet: the commands wait")

    // Focus moves before the read lands: its answer describes what was
    // focused before and is dropped; the tracker reads again.
    tracker.focusMayHaveChanged(pid: 7)
    reads[0].1(FocusRegionTracker.Reading(region: .text(.multiLine)))
    XCTAssertEqual(answers, [])
    XCTAssertNil(tracker.cachedReading(for: 7))
    XCTAssertEqual(reads.count, 2)
    reads[1].1(FocusRegionTracker.Reading(region: .collection))
    XCTAssertEqual(answers, [.collection, .collection])
    XCTAssertEqual(tracker.cachedReading(for: 7)?.region, .collection)

    // Cached: at once.
    tracker.withReading(for: 7) { answers.append($0.region) }
    XCTAssertEqual(answers.last, .collection)
    XCTAssertEqual(reads.count, 2)
  }

  /// A focus change empties the cache at once: a stale region never answers.
  func testAFocusChangeDropsTheStaleRegion() {
    var reads: [(pid_t, (FocusRegionTracker.Reading) -> Void)] = []
    let tracker = FocusRegionTracker { pid, deliver in reads.append((pid, deliver)) }
    tracker.focusMayHaveChanged(pid: 7)
    reads[0].1(FocusRegionTracker.Reading(region: .text(.singleLine)))
    XCTAssertEqual(tracker.cachedReading(for: 7)?.region, .text(.singleLine))
    tracker.focusMayHaveChanged(pid: 7)
    XCTAssertNil(tracker.cachedReading(for: 7))
  }

  /// A command for an app the cache no longer describes is answered as an
  /// unknown region, a page: it scrolls and types nothing.
  func testAnotherAppsCommandGetsTheUnknownRegion() {
    var reads: [(pid_t, (FocusRegionTracker.Reading) -> Void)] = []
    let tracker = FocusRegionTracker { pid, deliver in reads.append((pid, deliver)) }
    tracker.focusMayHaveChanged(pid: 7)
    var answer: FocusRegion?
    tracker.withReading(for: 7) { answer = $0.region }
    tracker.focusMayHaveChanged(pid: 9)
    reads[0].1(FocusRegionTracker.Reading(region: .text(.multiLine)))
    XCTAssertNil(answer, "7's read is stale; 9's is pending")
    reads[1].1(FocusRegionTracker.Reading(region: .collection))
    XCTAssertEqual(answer, .document)
    // Asking about an app the cache does not describe starts its read.
    tracker.withReading(for: 11) { answer = $0.region }
    XCTAssertEqual(reads.last?.0, 11)
  }

  /// Only focus moving re-reads the region; an element's destruction, which
  /// a web app posts constantly, does not.
  func testOnlyFocusChangesRereadTheRegion() {
    for notification in [
      kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification,
      kAXMainWindowChangedNotification,
    ] {
      XCTAssertTrue(AppMonitor.notificationMovesFocus(notification as String), notification)
    }
    for notification in [
      kAXUIElementDestroyedNotification, kAXValueChangedNotification,
      kAXLayoutChangedNotification, kAXSelectedTextChangedNotification,
    ] {
      XCTAssertFalse(AppMonitor.notificationMovesFocus(notification as String), notification)
    }
  }

  // MARK: - Where a scroll lands

  func testAScrollLandsInTheFocusedWindow() {
    let window = CGRect(x: 100, y: 100, width: 800, height: 600)
    let area = CGRect(x: 300, y: 150, width: 400, height: 300)
    // The pointer inside the window: where the user looks.
    XCTAssertNil(
      NormalModeDispatcher.lineScrollPoint(
        pointer: CGPoint(x: 500, y: 400), window: window, scrollArea: area))
    // Outside it: the focused scroll area, else the window's middle.
    XCTAssertEqual(
      NormalModeDispatcher.lineScrollPoint(
        pointer: CGPoint(x: 10, y: 10), window: window, scrollArea: area),
      CGPoint(x: 500, y: 300))
    XCTAssertEqual(
      NormalModeDispatcher.lineScrollPoint(
        pointer: CGPoint(x: 10, y: 10), window: window, scrollArea: nil),
      CGPoint(x: 500, y: 400))
    // A scroll area off the window is not where the window scrolls.
    XCTAssertEqual(
      NormalModeDispatcher.lineScrollPoint(
        pointer: CGPoint(x: 10, y: 10), window: window,
        scrollArea: CGRect(x: 2000, y: 2000, width: 50, height: 50)),
      CGPoint(x: 500, y: 400))
    // No window known: the pointer, as before.
    XCTAssertNil(
      NormalModeDispatcher.lineScrollPoint(
        pointer: CGPoint(x: 10, y: 10), window: nil, scrollArea: area))
  }

  // MARK: - Bindings per app kind

  /// A text app and a list app get the arrows from the `defaults` plugin; a
  /// terminal binds none (a shell would get them: Up recalls history), and
  /// no shared chord names a list's first or last item.
  func testTheArrowsResolvePerAppKind() throws {
    let index = CommandBindingIndex(manifests: try SourceCommandFallbackTests.officialManifests())
    let arrows: [(String, String)] = [
      ("move down", "down"), ("move up", "up"), ("move left", "left"), ("move right", "right"),
      ("input line_down", "down"), ("input line_up", "up"), ("input char_left", "left"),
      ("input char_right", "right"), ("input document_start", "cmd+up"),
      ("input document_end", "cmd+down"),
    ]
    for bundle in ["com.apple.TextEdit", "com.apple.finder", "com.apple.mail"] {
      let context = PluginSelectorContext(bundleID: bundle)
      for (spelled, chord) in arrows {
        let key = try XCTUnwrap(CommandBindingKey(spelled))
        guard case .chords(let chords)? = index.binding(key, in: context) else {
          XCTFail("\(spelled) in \(bundle)")
          continue
        }
        XCTAssertEqual(
          chords.map(BindingChord.init),
          [BindingChord(try XCTUnwrap(HotkeySyntax.parse(hotkey: chord)))],
          "\(spelled) in \(bundle)")
      }
      for edge in ["move top", "move bottom"] {
        let key = try XCTUnwrap(CommandBindingKey(edge))
        XCTAssertNil(index.binding(key, in: context), "\(edge) in \(bundle)")
        XCTAssertEqual(
          SourceCommandFallback.resolve(key.name, binding: nil),
          .scrollEdge(edge == "move top" ? .top : .bottom))
      }
    }
    for emulator in TerminalEmulatorFixture.official {
      let context = PluginSelectorContext(bundleID: emulator)
      for (spelled, _) in arrows + [("move top", ""), ("move bottom", "")] {
        let key = try XCTUnwrap(CommandBindingKey(spelled))
        XCTAssertEqual(
          SourceCommandFallback.resolve(key.name, binding: index.binding(key, in: context)),
          SourceCommandFallback.none, "\(spelled) in \(emulator)")
      }
    }
  }

  /// A chat app gets the shared arrows.
  func testAChatAppGetsTheArrows() throws {
    let index = CommandBindingIndex(manifests: try SourceCommandFallbackTests.officialManifests())
    let slack = PluginSelectorContext(bundleID: "com.tinyspeck.slackmacgap")
    let down = try XCTUnwrap(CommandBindingKey("move down"))
    XCTAssertEqual(index.resolve(down, in: slack)?.isAppSpecific, false)
    XCTAssertEqual(index.resolve(down, in: slack)?.pluginID, "defaults")
  }

  // MARK: - Config

  func testTheHalfPageArrowCountIsConfigurable() {
    XCTAssertEqual(Config.default.mode.movePageLines, 15)
    XCTAssertEqual(ConfigLoader.parse("[mode]\nmove_page_lines = 1").mode.movePageLines, 1)
    XCTAssertEqual(ConfigLoader.parse("[mode]\nmove_page_lines = 200").mode.movePageLines, 200)
    for bad in ["0", "201", "-3", "\"ten\"", "1.5"] {
      let config = ConfigLoader.parse("[mode]\nmove_page_lines = \(bad)")
      XCTAssertEqual(config.mode.movePageLines, 15, bad)
      XCTAssertTrue(
        config.diagnostics.contains { $0.message.contains("mode.move_page_lines") }, bad)
    }
    let schema = ConfigSchema.declaredTypes["mode.move_page_lines"]
    XCTAssertEqual(schema?["type"] as? String, "integer")
    XCTAssertEqual(schema?["minimum"] as? Int, 1)
    XCTAssertEqual(schema?["maximum"] as? Int, 200)
  }
}
