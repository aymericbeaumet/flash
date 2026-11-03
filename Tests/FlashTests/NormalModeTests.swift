import AppKit
import ApplicationServices
import Carbon.HIToolbox
import FlashCore
import XCTest

@testable import flash

final class NormalModeTests: XCTestCase {
  override func setUp() {
    super.setUp()
    TerminalEmulatorFixture.declareOfficial()
  }

  func testAboutWindowYieldsKeyboardToTransientHintInput() {
    XCTAssertTrue(
      AppDelegate.aboutWindowShouldOwnNativeKeyboard(
        visible: true, isKey: true, hasTransientInput: false, activationInFlight: false))
    XCTAssertFalse(
      AppDelegate.aboutWindowShouldOwnNativeKeyboard(
        visible: true, isKey: true, hasTransientInput: false, activationInFlight: true))
    XCTAssertFalse(
      AppDelegate.aboutWindowShouldOwnNativeKeyboard(
        visible: true, isKey: true, hasTransientInput: true, activationInFlight: false))
  }

  /// Left open behind another app, About owns nothing: NORMAL keeps
  /// swallowing that app's keys instead of letting them through as text.
  func testABackgroundAboutWindowOwnsNoKeys() {
    XCTAssertFalse(
      AppDelegate.aboutWindowShouldOwnNativeKeyboard(
        visible: true, isKey: false, hasTransientInput: false, activationInFlight: false))
  }

  /// A half-typed sequence and the timeout armed for it belong to one mapping
  /// table. When the effective mappings are rebuilt for another selector —
  /// the focused app changed, or a plugin's mappings did — the sequence is
  /// dropped and the timeout disowned, so it cannot fire a mapping from the
  /// previous table. The same selector again leaves a sequence alone.
  func testMappingTableChangeDropsThePendingSequenceAndItsTimeout() {
    _ = NSApplication.shared
    let delegate = AppDelegate()
    delegate.registry = SourceRegistry(descriptors: [], runningApplications: [])
    delegate.monitor = AppMonitor(registry: delegate.registry, config: delegate.config)
    delegate.overlay = OverlayPanel()
    delegate.overlay.normalModePending = "g"
    delegate.overlay.normalModeRepeatAnchor = "t"
    delegate.overlay.hyperPending = "x"
    let token = delegate.normalModePendingCommandToken
    delegate.invalidateEffectiveMappings()
    delegate.refreshEffectiveMappings(for: nil)
    XCTAssertEqual(delegate.overlay.normalModePending, "")
    XCTAssertNil(delegate.overlay.normalModeRepeatAnchor)
    XCTAssertEqual(delegate.overlay.hyperPending, "")
    XCTAssertNotEqual(delegate.normalModePendingCommandToken, token, "the timeout is disowned")

    delegate.overlay.normalModePending = "g"
    let settled = delegate.normalModePendingCommandToken
    delegate.refreshEffectiveMappings(for: nil)
    XCTAssertEqual(delegate.overlay.normalModePending, "g", "the same selector keeps it")
    XCTAssertEqual(delegate.normalModePendingCommandToken, settled)
  }

  /// `h` `j` `k` `l` move what has focus (`move`); `ctrl+e` / `ctrl+y`
  /// scroll one line, as vim's scroll the view without moving the cursor.
  func testDirectionalKeysMoveAndControlKeysScroll() {
    XCTAssertEqual(command(chars: "h"), .move(.left))
    XCTAssertEqual(command(chars: "j"), .move(.down))
    XCTAssertEqual(command(chars: "k"), .move(.up))
    XCTAssertEqual(command(chars: "l"), .move(.right))
    XCTAssertEqual(command(chars: "e", flags: [.control]), .scroll(.lineDown))
    XCTAssertEqual(command(chars: "y", flags: [.control]), .scroll(.lineUp))
  }

  func testHalfPageKeysUseControlForms() {
    XCTAssertNil(command(chars: "d"))
    XCTAssertEqual(command(chars: "u", flags: [.control]), .move(.halfPageUp))
    XCTAssertEqual(command(chars: "d", flags: [.control]), .move(.halfPageDown))
  }

  func testUndoAndRedoKeysResolveImmediately() {
    let undo = transition(chars: "u")
    XCTAssertEqual(undo.command, .undo)
    XCTAssertEqual(undo.pending, "")
    XCTAssertEqual(command(chars: "r", flags: [.control]), .redo)
  }

  func testFirstAndLastTabHaveVimMappings() {
    let actions = Dictionary(
      Config.Mode.defaultNormalMappings.map { ($0.key, $0.action) }, uniquingKeysWith: { a, _ in a }
    )
    XCTAssertEqual(actions[key("g0")], .flashCommand(.tabFirst))
    XCTAssertEqual(actions[key("g^")], .flashCommand(.tabFirst))
    XCTAssertEqual(actions[key("g$")], .flashCommand(.tabLast))
  }

  func testApplicationSpecificActionsHaveNoDefaultMappings() {
    let mappingKeys = Set(Config.Mode.defaultNormalMappings.map(\.key))
    let removedKeys = [
      "c", "d", "m", "[h", "]h", "]b", "[B", "]B",
      "[e", "]e", "[s", "]s", "ctrl+tab", "ctrl+shift+tab",
      "ctrl+s", "ctrl+shift+f", "e", "yy",
    ]
    for removedKey in removedKeys {
      XCTAssertFalse(
        mappingKeys.contains(key(removedKey)), "unexpected default mapping: \(removedKey)")
    }
    // `f` and the letter jump `s` finish a mouse prefix; no other letter
    // does, and nothing ends in `gw`.
    let mouseFinishers: Set<Character> = ["f", "s"]
    for prefix in ["", "c", "d", "m"] {
      XCTAssertFalse(mappingKeys.contains(key("\(prefix)gw")), "\(prefix)gw")
    }
    for letter in "abcdefghijklmnopqrstuvwxyz" {
      for prefix in ["c", "d", "m"] {
        XCTAssertEqual(
          mappingKeys.contains(key("\(prefix)\(letter)")),
          mouseFinishers.contains(letter),
          "\(prefix)\(letter)")
      }
      XCTAssertFalse(mappingKeys.contains(key("`\(letter)")))
    }
    for letter in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" {
      for prefix in ["c", "d", "m"] {
        XCTAssertEqual(
          mappingKeys.contains(key("\(prefix)\(letter)")),
          // `F` is the grid finisher.
          letter == "F",
          "\(prefix)\(letter)")
      }
    }
  }

  func testDefaultTabMappingsAndExplicitInsertMappingKeepDistinctActions() {
    let config = ConfigLoader.parse(
      """
      [mode.normal.mappings]
      "i" = ["flash", "mode", "insert"]
      """
    )
    XCTAssertTrue(config.diagnostics.isEmpty)
    XCTAssertEqual(command(pending: "[", chars: "t", mappings: config.mode.normal), .tabPrev)
    XCTAssertEqual(command(pending: "]", chars: "t", mappings: config.mode.normal), .tabNext)
    let newTab = transition(chars: "t", mappings: config.mode.normal)
    XCTAssertEqual(newTab.command, .tabNew)
    XCTAssertEqual(newTab.pending, "")
    XCTAssertNil(newTab.repeatAnchor)
    XCTAssertEqual(command(chars: "x", mappings: config.mode.normal), .tabClose)
    XCTAssertEqual(
      command(chars: "X", flags: [.shift], mappings: config.mode.normal), .tabReopen)
    XCTAssertEqual(command(chars: "r", mappings: config.mode.normal), .reload(force: false))
    XCTAssertEqual(
      command(chars: "R", flags: [.shift], mappings: config.mode.normal), .reload(force: true))
    XCTAssertEqual(command(chars: "i", mappings: config.mode.normal), .insertMode)
    XCTAssertEqual(command(chars: "i"), .insertMode, "the default binds it too")
  }

  func testVerticalScrollPostsLineEventsInEveryAppWithoutWindowGeometry() throws {
    let restore = NormalModeDispatcher.wheelEventPoster
    defer { NormalModeDispatcher.wheelEventPoster = restore }
    var events: [CGEvent] = []
    NormalModeDispatcher.wheelEventPoster = { events.append($0) }
    let cases: [(NormalModeDispatcher.ScrollKind, Int64)] = [
      (.down, -3), (.up, 3), (.lineDown, -1), (.lineUp, 1), (.halfPageDown, -20),
      (.halfPageUp, 20),
    ]
    for bundle in ["org.alacritty", "com.apple.Terminal", "org.mozilla.firefox"] {
      for (kind, lines) in cases {
        events.removeAll()
        XCTAssertTrue(
          NormalModeDispatcher.scroll(kind, pid: -1, bundleID: bundle, windowFrame: nil))
        XCTAssertEqual(events.count, 1, "\(kind) in \(bundle)")
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.type, .scrollWheel)
        XCTAssertEqual(event.flags, [])
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventIsContinuous), 0)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis1), lines)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis2), 0)
        XCTAssertEqual(
          event.getIntegerValueField(.eventSourceUserData), ActionDispatcher.syntheticMouseEventTag)
      }
    }
  }

  func testVerticalScrollUsesConfiguredLineCounts() throws {
    let restore = NormalModeDispatcher.wheelEventPoster
    defer {
      NormalModeDispatcher.wheelEventPoster = restore
      FlashTunables.apply(.default)
    }
    let config = ConfigLoader.parse(
      """
      [mode]
      scroll_step_lines = 7
      scroll_page_lines = 31
      """)
    XCTAssertTrue(config.diagnostics.isEmpty)
    FlashTunables.apply(config)
    var lines: [Int64] = []
    NormalModeDispatcher.wheelEventPoster = {
      lines.append($0.getIntegerValueField(.scrollWheelEventDeltaAxis1))
    }
    for kind in [NormalModeDispatcher.ScrollKind.up, .down, .halfPageUp, .halfPageDown] {
      XCTAssertTrue(NormalModeDispatcher.scroll(kind, pid: -1, bundleID: "org.alacritty"))
    }
    XCTAssertEqual(lines, [7, -7, 31, -31])
  }

  func testTerminalEdgesAreBoundedLineScrolls() {
    let restore = NormalModeDispatcher.wheelEventPoster
    defer { NormalModeDispatcher.wheelEventPoster = restore }
    var events: [CGEvent] = []
    NormalModeDispatcher.wheelEventPoster = { events.append($0) }
    XCTAssertTrue(NormalModeDispatcher.scroll(.top, pid: -1, bundleID: "org.alacritty"))
    XCTAssertTrue(NormalModeDispatcher.scroll(.bottom, pid: -1, bundleID: "org.alacritty"))
    XCTAssertEqual(
      events.map { $0.getIntegerValueField(.scrollWheelEventDeltaAxis1) },
      [Int64(NormalModeDispatcher.edgeScrollLines), -Int64(NormalModeDispatcher.edgeScrollLines)])
    XCTAssertEqual(
      events.map { $0.getIntegerValueField(.scrollWheelEventIsContinuous) }, [0, 0],
      "line units, like ctrl-u / ctrl-d")
  }

  func testLineScrollCountsMultiplyStepAndPageLines() {
    XCTAssertEqual(NormalModeDispatcher.scrollLineDelta(for: .down, repeatCount: 4), -12)
    XCTAssertEqual(NormalModeDispatcher.scrollLineDelta(for: .up, repeatCount: 4), 12)
    XCTAssertEqual(NormalModeDispatcher.scrollLineDelta(for: .lineDown, repeatCount: 4), -4)
    XCTAssertEqual(NormalModeDispatcher.scrollLineDelta(for: .halfPageDown, repeatCount: 2), -40)
    XCTAssertEqual(NormalModeDispatcher.scrollLineDelta(for: .halfPageUp, repeatCount: 2), 40)
    XCTAssertEqual(NormalModeDispatcher.scrollLineDelta(for: .up, repeatCount: 0), 3)
    XCTAssertEqual(
      NormalModeDispatcher.scrollLineDelta(for: .halfPageUp, repeatCount: 1000), 19_980)
    XCTAssertNil(NormalModeDispatcher.scrollLineDelta(for: .left))
    XCTAssertNil(NormalModeDispatcher.scrollLineDelta(for: .top))
  }

  func testTopBottomUseExtremeWheelDeltasForWheelFallback() {
    // AX scrollbar value-setters are the primary path for gg/G, but
    // they don't move every app (tmux has none, some Electron apps
    // ignore the AX-set). For those apps the dispatcher falls back to
    // a synthetic wheel event with a huge delta — large enough to
    // exceed any realistic document height while still fitting Int32.
    let top = NormalModeDispatcher.pixelScrollWheelDelta(for: .top)
    XCTAssertNotNil(top)
    XCTAssertGreaterThanOrEqual(top?.vertical ?? 0, 100_000)
    XCTAssertEqual(top?.horizontal, 0)

    let bottom = NormalModeDispatcher.pixelScrollWheelDelta(for: .bottom)
    XCTAssertNotNil(bottom)
    XCTAssertLessThanOrEqual(bottom?.vertical ?? 0, -100_000)
    XCTAssertEqual(bottom?.horizontal, 0)
  }

  func testTopBottomAndNavigationSequences() {
    XCTAssertEqual(transition(chars: "g").pending, "g")
    XCTAssertEqual(command(pending: "g", chars: "g"), .move(.top))
    XCTAssertEqual(command(chars: "G", ignoring: "g", flags: [.shift]), .move(.bottom))
    XCTAssertEqual(command(pending: "[", chars: "a"), .appPrev)
    XCTAssertEqual(command(pending: "]", chars: "a"), .appNext)
    XCTAssertEqual(command(chars: "o", flags: [.control]), .movementBack)
    XCTAssertEqual(command(chars: "i", flags: [.control]), .movementForward)
  }

  func testRepeatCountsApplyToSingleAndMultiKeyCommands() {
    XCTAssertEqual(transition(chars: "1").pending, "1")
    XCTAssertEqual(transition(pending: "1", chars: "0").pending, "10")

    let halfPageUp = transition(pending: "10", chars: "u", flags: [.control])
    XCTAssertEqual(halfPageUp.command, .move(.halfPageUp))
    XCTAssertEqual(halfPageUp.repeatCount, 10)

    let previousApp = transition(pending: "2[", chars: "a")
    XCTAssertEqual(previousApp.command, .appPrev)
    XCTAssertEqual(previousApp.repeatCount, 2)

    let nextApp = transition(pending: "2]", chars: "a")
    XCTAssertEqual(nextApp.command, .appNext)
    XCTAssertEqual(nextApp.repeatCount, 2)

    let undo = transition(pending: "3", chars: "u")
    XCTAssertEqual(undo.command, .undo)
    XCTAssertEqual(undo.repeatCount, 3)

    let leadingZero = transition(chars: "0")
    XCTAssertNil(leadingZero.command)
    XCTAssertEqual(leadingZero.pending, "")

    // A count before a mouse finisher reaches it as a finger count.
    let threeFingers = transition(pending: "3", chars: "f")
    XCTAssertEqual(threeFingers.command, .mouseTarget(.click(.leftClick, modifiers: [])))
    XCTAssertEqual(threeFingers.repeatCount, 3)
    let smartZoom = transition(pending: "2d", chars: "f")
    XCTAssertEqual(smartZoom.command, .mouseTarget(.click(.doubleClick, modifiers: [])))
    XCTAssertEqual(smartZoom.repeatCount, 2)
  }

  func testRepeatableMappingRepeatsOnItsFinalKey() {
    let first = transition(pending: "[", chars: "a")
    XCTAssertEqual(first.command, .appPrev)
    XCTAssertEqual(first.repeatAnchor, key("[a"))

    var anchor = first.repeatAnchor
    for _ in 0..<3 {
      let repeated = transition(repeatAnchor: anchor, chars: "a")
      XCTAssertEqual(repeated.command, .appPrev)
      XCTAssertEqual(repeated.repeatAnchor, key("[a"))
      anchor = repeated.repeatAnchor
    }

    let different = transition(repeatAnchor: anchor, chars: "u")
    XCTAssertEqual(different.command, .undo)
    XCTAssertNil(different.repeatAnchor)

    let next = transition(pending: "]", chars: "a")
    XCTAssertEqual(next.command, .appNext)
    XCTAssertEqual(next.repeatAnchor, key("]a"))
    let repeatedNext = transition(repeatAnchor: next.repeatAnchor, chars: "a")
    XCTAssertEqual(repeatedNext.command, .appNext)
    XCTAssertEqual(repeatedNext.repeatAnchor, key("]a"))
  }

  func testBracketNavigationMappingsRepeatOnFinalKey() {
    let cases: [(prefix: String, letter: String, command: URLCommand)] = [
      ("[", "a", .appPrev),
      ("]", "a", .appNext),
      ("[", "t", .tabPrev),
      ("]", "t", .tabNext),
    ]
    for testCase in cases {
      let first = transition(pending: testCase.prefix, chars: testCase.letter)
      XCTAssertEqual(first.command, testCase.command)
      XCTAssertEqual(first.repeatAnchor, key("\(testCase.prefix)\(testCase.letter)"))

      let repeated = transition(repeatAnchor: first.repeatAnchor, chars: testCase.letter)
      XCTAssertEqual(repeated.command, testCase.command)
      XCTAssertEqual(repeated.repeatAnchor, key("\(testCase.prefix)\(testCase.letter)"))
    }
  }

  func testNonRepeatableMappingDoesNotRetainFinalKey() {
    let transition = transition(pending: "g", chars: "g")
    XCTAssertEqual(transition.command, .move(.top))
    XCTAssertNil(transition.repeatAnchor)
  }

  func testPendingSequenceTimesOut() {
    let start = Date(timeIntervalSince1970: 1_000)
    XCTAssertEqual(NormalModeInterpreter.sequenceTimeoutMs, 1000)
    XCTAssertFalse(
      NormalModeInterpreter.pendingSequenceTimedOut(
        pending: "g",
        lastInputAt: start,
        now: start.addingTimeInterval(0.999)))
    XCTAssertTrue(
      NormalModeInterpreter.pendingSequenceTimedOut(
        pending: "g",
        lastInputAt: start,
        now: start.addingTimeInterval(1.001)))
  }

  func testCopyDoesNotWaitForAnApplicationSpecificSequence() {
    let copy = transition(chars: "y")
    XCTAssertEqual(copy.command, .yankSelection(register: nil))
    XCTAssertEqual(copy.pending, "")
  }

  func testMoveMouseSequence() {
    XCTAssertEqual(transition(chars: "m").pending, "m")
    XCTAssertEqual(command(pending: "m", chars: "f"), .mouseTarget(.move))
    XCTAssertEqual(
      command(pending: "m", chars: "F", ignoring: "f", flags: [.shift]), .mouseGrid(.init(.move)))
  }

  func testHintCommitWaitsForFocusOnlyWhenTheTargetIsNotAlreadyFrontmost() {
    // Repro for hint clicks that "don't go through": `activate` is advisory
    // and asynchronous, so a click posted on a fixed delay lands on whichever
    // app is still frontmost. Measured at 9 of 43 clicks hitting the wrong
    // app before this waited for the real handoff.
    XCTAssertTrue(
      AppDelegate.hintCommitNeedsFrontmostHandoff(targetPID: 501, frontmostPID: 777))
    // Flash itself being frontmost is the same problem, not an exemption.
    XCTAssertTrue(
      AppDelegate.hintCommitNeedsFrontmostHandoff(targetPID: 501, frontmostPID: nil))
    // Already there: post on this turn, no wait, no delay.
    XCTAssertFalse(
      AppDelegate.hintCommitNeedsFrontmostHandoff(targetPID: 501, frontmostPID: 501))
    // Nothing to hand off to.
    XCTAssertFalse(
      AppDelegate.hintCommitNeedsFrontmostHandoff(targetPID: nil, frontmostPID: 501))
    // Gatekeeper and the other agents that show a dialog never become
    // frontmost. Waiting on that handoff only delays the click.
    XCTAssertFalse(
      AppDelegate.hintCommitNeedsFrontmostHandoff(
        targetPID: 501, frontmostPID: 777, targetActivates: false))
    // Bounded, so an app that refuses activation still gets its click.
    XCTAssertGreaterThanOrEqual(AppDelegate.frontmostHandoffTimeoutMs, 200)
    XCTAssertLessThanOrEqual(AppDelegate.frontmostHandoffTimeoutMs, 1_000)
  }

  func testMouseTargetAndGridCurrentAndNewTabMappings() {
    XCTAssertEqual(
      command(chars: "f"),
      .mouseTarget(.click(.leftClick, modifiers: [])))
    // `F` is the grid twin of `f`. Right-click is the `c` prefix, not Control.
    XCTAssertEqual(
      command(chars: "F", ignoring: "f", flags: [.shift]),
      .mouseGrid(.init(.click(.leftClick, modifiers: []))))
    // `ctrl+f` is a page down, as in vim; the shifted chord is unbound.
    XCTAssertEqual(
      command(keyCode: kVK_ANSI_F, chars: "f", flags: [.control]), .move(.pageDown))
    XCTAssertNil(
      command(keyCode: kVK_ANSI_F, chars: "F", ignoring: "f", flags: [.control, .shift]))
    // Every click prefix reaches both surfaces, and they are all lowercase.
    XCTAssertEqual(
      command(pending: "m", chars: "f"),
      .mouseTarget(.move))
    XCTAssertEqual(
      command(pending: "m", chars: "s"),
      .mouseBigram(.move))
    XCTAssertEqual(
      command(pending: "m", chars: "F", ignoring: "f", flags: [.shift]),
      .mouseGrid(.init(.move)))
    // Triple click ships unbound so `t` can stay the new-tab mapping: a key
    // that is also the prefix of a longer one waits for the sequence timeout.
    XCTAssertNotNil(command(chars: "t"))
    // `s` starts no other mapping, so the jump fires at once.
    let jump = transition(chars: "s")
    XCTAssertEqual(jump.command, .mouseBigram(.click(.leftClick, modifiers: [])))
    XCTAssertEqual(jump.pending, "")
    XCTAssertEqual(command(chars: "j"), .move(.down))
  }

  func testDoubleClickHintModeSequences() {
    // `d` is the double-click prefix, so it parks rather than yielding `nil`.
    XCTAssertNil(command(chars: "d"))
    XCTAssertEqual(transition(chars: "d").pending, "d")
    XCTAssertEqual(
      command(pending: "d", chars: "f"),
      .mouseTarget(.click(.doubleClick, modifiers: [])))
    XCTAssertEqual(
      command(pending: "d", chars: "s"),
      .mouseBigram(.click(.doubleClick, modifiers: [])))
    XCTAssertEqual(
      command(pending: "d", chars: "F", ignoring: "f", flags: [.shift]),
      .mouseGrid(.init(.click(.doubleClick, modifiers: []))))
  }

  func testContextClickHintModeSequences() {
    XCTAssertNil(command(chars: "c"))
    XCTAssertEqual(transition(chars: "c").pending, "c")
    XCTAssertEqual(
      command(pending: "c", chars: "f"),
      .mouseTarget(.click(.rightClick, modifiers: [])))
    XCTAssertEqual(
      command(pending: "c", chars: "s"),
      .mouseBigram(.click(.rightClick, modifiers: [])))
    XCTAssertEqual(
      command(pending: "c", chars: "F", ignoring: "f", flags: [.shift]),
      .mouseGrid(.init(.click(.rightClick, modifiers: []))))
  }

  func testHelpAndModifiedKeyConsumption() {
    // Only `i` enters INSERT; vim's other insert keys are unbound, and so
    // swallowed: Flash never edits text.
    XCTAssertEqual(command(chars: "i"), .insertMode)
    XCTAssertNil(command(chars: "a"))
    XCTAssertNil(command(chars: "A", ignoring: "a", flags: [.shift]))
    XCTAssertNil(command(chars: "I", ignoring: "i", flags: [.shift]))
    XCTAssertNil(command(chars: "o"))
    XCTAssertNil(command(chars: "O", ignoring: "o", flags: [.shift]))
    XCTAssertEqual(command(chars: "?"), .showMappings)
    XCTAssertEqual(command(chars: "?", ignoring: "/", flags: [.shift]), .showMappings)
    XCTAssertNil(
      NormalModeInterpreter.interpret(
        pending: "",
        keyCode: UInt16(kVK_Space),
        modifierFlags: [.command],
        characters: " ",
        charactersIgnoringModifiers: " ",
        mappings: CompiledMappings(Config.Mode.defaultNormalMappings)
      ).command)
    XCTAssertEqual(command(chars: "r"), .reload(force: false))
    XCTAssertEqual(command(chars: ":", ignoring: ";", flags: [.shift]), .commandMode)
    XCTAssertEqual(command(chars: "x"), .tabClose)
    XCTAssertTrue(
      NormalModeInterpreter.recognizesPhysicalKey(
        pending: "",
        repeatAnchor: nil,
        virtualKey: UInt32(kVK_ANSI_X),
        modifierFlags: [],
        mappings: defaultMappings))
    XCTAssertEqual(command(chars: "/"), .find)
    // `s` is the EasyMotion jump and fires on its own. It is not a prefix, so
    // it does not wait out `sequence_timeout_ms`.
    let jump = transition(chars: "s")
    XCTAssertEqual(jump.command, .mouseBigram(.click(.leftClick, modifiers: [])))
    XCTAssertEqual(jump.pending, "")
    XCTAssertFalse(defaultMappings.hasStrictPrefix("s"))
    XCTAssertNil(transition(chars: "\\").command)
    XCTAssertEqual(transition(chars: "\\").pending, "")
    XCTAssertNil(transition(pending: "\\", keyCode: kVK_Space, chars: " ").command)
    let modified = transition(chars: "r", flags: [.command])
    XCTAssertNil(modified.command)
    // The interpreter consumes an unrecognized modified chord; the keyboard
    // capture edge decides whether configured modifiers pass through instead.
    XCTAssertEqual(modified.pending, "")
  }

  /// `gg` and `f` typed under a Russian source, read on US-ANSI.
  func testNormalMappingsMatchPhysicalKeysUnderANonLatinSource() {
    func russian(_ keyCode: Int, _ typed: String) -> KeyCharacters {
      KeyCharacters.read(
        layout: .usANSI, keyCode: UInt16(keyCode), modifierFlags: [], characters: typed,
        ignoringModifiers: typed, unshifted: { nil })
    }
    let f = russian(kVK_ANSI_F, "а")
    XCTAssertEqual(
      command(keyCode: kVK_ANSI_F, chars: f.characters ?? "", ignoring: f.ignoringModifiers),
      .mouseTarget(.click(.leftClick, modifiers: [])))
    let g = russian(kVK_ANSI_G, "п")
    let first = transition(
      keyCode: kVK_ANSI_G, chars: g.characters ?? "", ignoring: g.ignoringModifiers)
    XCTAssertEqual(first.pending, "g")
    XCTAssertEqual(
      command(
        pending: first.pending, keyCode: kVK_ANSI_G, chars: g.characters ?? "",
        ignoring: g.ignoringModifiers),
      .move(.top))
    // Read as typed, the same keys match nothing.
    XCTAssertNil(command(keyCode: kVK_ANSI_F, chars: "а"))
  }

  func testRemovingTLetsTripleClickFireWithoutTheSequenceTimeout() {
    let config = ConfigLoader.parse(
      """
      [mode.normal.mappings]
      "t" = false
      "tf" = ["flash", "mouse", "target", "--triple"]
      """)
    XCTAssertTrue(config.loadingDiagnostics.isEmpty, "\(config.loadingDiagnostics.map(\.message))")
    let mappings = config.mode.normal
    let first = transition(chars: "t", mappings: mappings)
    XCTAssertNil(first.command)
    XCTAssertEqual(first.pending, "t")
    // Nothing is parked on the bare `t`, so the sequence timeout has nothing
    // to fire: the prefix only waits for its next key.
    XCTAssertNil(
      NormalModeInterpreter.pendingCommand(
        pending: first.pending, mappings: CompiledMappings(mappings)))
    XCTAssertEqual(
      command(pending: first.pending, chars: "f", mappings: mappings),
      .mouseTarget(.click(.tripleClick, modifiers: [])))

    // With the default `t` kept, the same prefix parks `tab new` for the timeout.
    let kept = ConfigLoader.parse(
      """
      [mode.normal.mappings]
      "tf" = ["flash", "mouse", "target", "--triple"]
      """
    ).mode.normal
    XCTAssertNotNil(
      NormalModeInterpreter.pendingCommand(pending: "t", mappings: CompiledMappings(kept)))
  }

  func testPendingPrefixBrokenByUnmappableKeyAbandonsItAsVimDoes() {
    // An invalid continuation abandons the sequence and the key, as Vim's
    // does: neither runs.
    XCTAssertNil(command(pending: "[", chars: "u"))
    XCTAssertNil(command(pending: "]", chars: "u"))
    // `gi` focuses an input and keeps NORMAL; `gn` and `gu` are no
    // sequence, so nothing runs.
    XCTAssertEqual(command(pending: "g", chars: "i"), .focusInput)
    XCTAssertNil(command(pending: "g", chars: "n"))
    XCTAssertNil(command(pending: "g", chars: "u"))
    XCTAssertEqual(transition(pending: "g", chars: "u").pending, "")
    // Valid sequence continuations still resolve to the mapped action.
    XCTAssertEqual(command(pending: "g", chars: "g"), .move(.top))
    XCTAssertEqual(command(pending: "m", chars: "f"), .mouseTarget(.move))
    // No mapping at any depth: a clean consume (no command, no
    // carried-over pending).
    let unmappable = transition(pending: "g", chars: "Q")
    XCTAssertNil(unmappable.command)
    XCTAssertEqual(unmappable.pending, "")
  }

  func testEditableFocusRepairRequiresOneStrongVisibleTextInput() {
    let window = CGRect(x: 0, y: 0, width: 800, height: 600)
    let compose = editableRepairCandidate(
      role: "AXTextArea",
      frame: CGRect(x: 200, y: 520, width: 560, height: 44))

    XCTAssertEqual(
      NormalModeDispatcher.strongEditableFocusCandidates([compose], windowFrame: window),
      [compose])

    XCTAssertTrue(
      NormalModeDispatcher.strongEditableFocusCandidates(
        [
          editableRepairCandidate(role: "AXSearchField"),
          editableRepairCandidate(role: "AXTextField", subrole: "AXSearchField"),
          editableRepairCandidate(role: "AXComboBox"),
          editableRepairCandidate(role: "AXTextField", enabled: false),
          editableRepairCandidate(role: "AXTextField", hidden: true),
          editableRepairCandidate(
            role: "AXTextField",
            frame: CGRect(x: 900, y: 20, width: 120, height: 24)),
        ],
        windowFrame: window
      ).isEmpty)
  }

  func testEditableFocusRepairTreatsMultipleStrongInputsAsAmbiguous() {
    let window = CGRect(x: 0, y: 0, width: 800, height: 600)
    let first = editableRepairCandidate(
      role: "AXTextField",
      frame: CGRect(x: 80, y: 120, width: 240, height: 28))
    let second = editableRepairCandidate(
      role: "AXTextArea",
      frame: CGRect(x: 80, y: 500, width: 640, height: 52))

    XCTAssertEqual(
      NormalModeDispatcher.strongEditableFocusCandidates(
        [first, second],
        windowFrame: window),
      [first, second])
  }

  func testEditableFocusRepairDedupesDuplicateAXNodesForSameControl() {
    let window = CGRect(x: 0, y: 0, width: 800, height: 600)
    let outer = editableRepairCandidate(
      role: "AXTextArea",
      frame: CGRect(x: 200, y: 520, width: 560, height: 44))
    let innerDuplicate = editableRepairCandidate(
      role: "AXTextArea",
      frame: CGRect(x: 202, y: 522, width: 556, height: 40))

    XCTAssertEqual(
      NormalModeDispatcher.strongEditableFocusCandidates(
        [outer, innerDuplicate],
        windowFrame: window),
      [outer])
  }

  func testNormalModeContextPrefersCapturedTargetOnlyDuringIdleNormalCapture() {
    XCTAssertTrue(
      AppDelegate.normalModeShouldPreferCapturedContext(
        mode: .normal,
        overlayInputMode: .normal,
        hasHints: false,
        activationInFlight: false,
        normalModeTargetPID: pid_t(42)))
    XCTAssertFalse(
      AppDelegate.normalModeShouldPreferCapturedContext(
        mode: .insert,
        overlayInputMode: .normal,
        hasHints: false,
        activationInFlight: false,
        normalModeTargetPID: pid_t(42)))
    XCTAssertFalse(
      AppDelegate.normalModeShouldPreferCapturedContext(
        mode: .normal,
        overlayInputMode: .hints,
        hasHints: false,
        activationInFlight: false,
        normalModeTargetPID: pid_t(42)))
    XCTAssertFalse(
      AppDelegate.normalModeShouldPreferCapturedContext(
        mode: .normal,
        overlayInputMode: .normal,
        hasHints: true,
        activationInFlight: false,
        normalModeTargetPID: pid_t(42)))
    XCTAssertFalse(
      AppDelegate.normalModeShouldPreferCapturedContext(
        mode: .normal,
        overlayInputMode: .normal,
        hasHints: false,
        activationInFlight: true,
        normalModeTargetPID: pid_t(42)))
    XCTAssertFalse(
      AppDelegate.normalModeShouldPreferCapturedContext(
        mode: .normal,
        overlayInputMode: .normal,
        hasHints: false,
        activationInFlight: false,
        normalModeTargetPID: nil))
  }

  func testNormalModeDispatchUsesCurrentFocusBeforeTheCapturedApp() {
    XCTAssertEqual(
      AppDelegate.normalModeDispatchTargetPID(focusedPID: 7, capturedPID: 42), 7,
      "CLI and Carbon commands must not paste into or act on the app NORMAL captured before a switch"
    )
    XCTAssertEqual(AppDelegate.normalModeDispatchTargetPID(focusedPID: 7, capturedPID: nil), 7)
    XCTAssertEqual(AppDelegate.normalModeDispatchTargetPID(focusedPID: nil, capturedPID: 42), 42)
    XCTAssertNil(AppDelegate.normalModeDispatchTargetPID(focusedPID: nil, capturedPID: nil))
  }

  func testInsertFocusExitOnlyProbesFocusChangingAXNotifications() {
    XCTAssertTrue(
      AppMonitor.notificationMayChangeFocusedElement(
        kAXFocusedUIElementChangedNotification as String))
    XCTAssertTrue(
      AppMonitor.notificationMayChangeFocusedElement(
        kAXFocusedWindowChangedNotification as String))
    XCTAssertFalse(
      AppMonitor.notificationMayChangeFocusedElement(
        kAXValueChangedNotification as String))
  }

  func testBackgroundModelRefreshThrottleAppliesOnlyToNoisyRefreshes() {
    XCTAssertTrue(ModelRefreshReason.axEvent("AXValueChanged").isThrottled)
    XCTAssertTrue(ModelRefreshReason.queued.isThrottled)
    XCTAssertFalse(ModelRefreshReason.maintenance.isThrottled)
    XCTAssertTrue(ModelRefreshReason.maintenance.isSpeculative)
    XCTAssertFalse(ModelRefreshReason.focus.isThrottled)
    XCTAssertFalse(ModelRefreshReason.userAction("normal_scroll").isSpeculative)
    XCTAssertEqual(ModelRefreshReason.axEvent("AXValueChanged").logValue, "ax:AXValueChanged")
    // The walk a readiness ladder ends in is owed, not speculative: storms and
    // slow walks must not suppress it, and noise must not demote it.
    XCTAssertFalse(ModelRefreshReason.readiness.isThrottled)
    XCTAssertFalse(ModelRefreshReason.readiness.isSpeculative)
    XCTAssertEqual(ModelRefreshReason.readiness.priority, ModelRefreshReason.focus.priority)
    XCTAssertEqual(ModelRefreshReason.readiness.logValue, "readiness")
  }

  func testAPendingReadinessLadderDefersSpeculativeWalksButNotExplicitOnes() {
    let registry = SourceRegistry(descriptors: [], runningApplications: [])
    let monitor = AppMonitor(registry: registry, config: .default)
    let pid = pid_t(44)
    _ = monitor.modelScheduler.scheduleReadiness(
      pid: pid, step: 0, then: .focus, deadline: DispatchTime.now().uptimeNanoseconds)
    for reason: ModelRefreshReason in [.axEvent("AXLayoutChanged"), .queued, .maintenance] {
      monitor.scheduleModelRefresh(for: pid, reason: reason)
      XCTAssertFalse(monitor.modelScheduler.hasRefresh(pid: pid), reason.logValue)
    }
    monitor.scheduleModelRefresh(for: pid, reason: .userAction("normal_scroll"))
    XCTAssertTrue(monitor.modelScheduler.hasRefresh(pid: pid))
    monitor.cancelRefreshWork(for: pid)
    XCTAssertFalse(monitor.modelScheduler.hasReadiness(pid: pid))
  }

  func testStormsAndSlowWalksDoNotSuppressTheReadinessWalk() {
    let registry = SourceRegistry(descriptors: [], runningApplications: [])
    let monitor = AppMonitor(registry: registry, config: .default)
    let pid = pid_t(45)
    _ = monitor.recordModelWalk(
      pid: pid, bundleIdentifier: "com.example.app", reason: .focus, elapsedMs: 900,
      unchanged: false, degenerate: false)
    monitor.axEventStormingPIDs.insert(pid)
    monitor.scheduleModelRefresh(for: pid, reason: .readiness)
    XCTAssertTrue(monitor.modelScheduler.hasRefresh(pid: pid))
    monitor.cancelRefreshWork(for: pid)
  }

  func testAGatedAppGetsNoAutomaticWalksUntilConfigReopensIt() {
    let registry = SourceRegistry(descriptors: [], runningApplications: [])
    let monitor = AppMonitor(registry: registry, config: .default)
    let pid = pid_t(46)
    for _ in 0..<EmptyBackgroundWalkGate.threshold {
      _ = monitor.backgroundWalkGate.noteBackgroundWalk(
        pid: pid, targets: 0, hasVolatileProvider: true)
    }
    for reason: ModelRefreshReason in [
      .focus, .axEvent("AXLayoutChanged"), .maintenance, .readiness, .space, .screen,
      .userAction("normal_scroll"),
    ] {
      monitor.scheduleModelRefresh(for: pid, reason: reason)
      XCTAssertFalse(monitor.modelScheduler.hasRefresh(pid: pid), reason.logValue)
    }
    monitor.backgroundWalkGate.reset()
    monitor.scheduleModelRefresh(for: pid, reason: .focus)
    XCTAssertTrue(monitor.modelScheduler.hasRefresh(pid: pid))
    monitor.cancelRefreshWork(for: pid)
  }

  func testAXEventStormSuppressesOnlySpeculativePreparedModelRefreshes() {
    let registry = SourceRegistry(descriptors: [], runningApplications: [])
    let monitor = AppMonitor(registry: registry, config: .default)
    let pid = pid_t(42)
    monitor.scheduleModelRefresh(for: pid, reason: .axEvent("AXUIElementDestroyed"))
    XCTAssertTrue(monitor.modelScheduler.hasRefresh(pid: pid))

    for _ in 0..<AppMonitor.axEventStormCountThreshold {
      monitor.noteAXEventForStormDetection(
        pid: pid, notification: kAXUIElementDestroyedNotification as String)
    }

    XCTAssertTrue(monitor.axEventStormingPIDs.contains(pid))
    XCTAssertFalse(monitor.modelScheduler.hasRefresh(pid: pid))
    monitor.scheduleModelRefresh(for: pid, reason: .axEvent("AXUIElementDestroyed"))
    XCTAssertFalse(monitor.modelScheduler.hasRefresh(pid: pid))
    monitor.scheduleModelRefresh(for: pid, reason: .maintenance)
    XCTAssertFalse(monitor.modelScheduler.hasRefresh(pid: pid))

    monitor.scheduleModelRefresh(for: pid, reason: .focus)
    XCTAssertTrue(monitor.modelScheduler.hasRefresh(pid: pid))
    monitor.cancelRefreshWork(for: pid)
  }

  /// Maintenance is the one self-renewing wake — every stored model arms the
  /// next — so it rides the shared clock, and a cancellation leaves it.
  func testMaintenanceRidesTheSharedClockAndLeavesItWhenCancelled() {
    let registry = SourceRegistry(descriptors: [], runningApplications: [])
    let scheduler = PollScheduler()
    let monitor = AppMonitor(registry: registry, config: .default, pollScheduler: scheduler)
    func registered() -> [String] {
      let listed = DispatchSemaphore(value: 0)
      var ids: [String] = []
      scheduler.registeredIDs {
        ids = $0
        listed.signal()
      }
      listed.wait()
      return ids
    }
    let model = PreparedModel(
      pid: 44, targets: [], hints: [], computedAt: .now(), dirtyToken: 0, configRevision: 0,
      fingerprint: 0, freshnessMs: AppMonitor.modelFreshnessMs, occluded: false, occlusion: nil)
    monitor.scheduleMaintenanceRefresh(for: model)
    XCTAssertEqual(registered(), [AppMonitor.maintenanceClientID])
    monitor.cancelRefreshWork(for: 44)
    XCTAssertEqual(registered(), [])

    monitor.scheduleMaintenanceRefresh(for: model)
    monitor.invalidatePreparedModel(for: 44, because: .invalidated)
    XCTAssertEqual(registered(), [])
  }

  /// Debounce and readiness wakes re-arm themselves, so they ride the shared
  /// clock too — one registration per app and kind — and cancelling the
  /// app's refresh work releases them instead of leaving a stale wake-up.
  func testRefreshAndReadinessWakesRideTheSharedClockAndLeaveItWhenCancelled() {
    let registry = SourceRegistry(descriptors: [], runningApplications: [])
    let scheduler = PollScheduler()
    let monitor = AppMonitor(registry: registry, config: .default, pollScheduler: scheduler)
    func registered() -> [String] {
      let listed = DispatchSemaphore(value: 0)
      var ids: [String] = []
      scheduler.registeredIDs {
        ids = $0
        listed.signal()
      }
      listed.wait()
      return ids
    }
    monitor.scheduleModelRefresh(for: 45, reason: .focus)
    monitor.armReadinessStep(pid: 45, step: 0, then: .focus)
    monitor.scheduleModelRefresh(for: 46, reason: .focus)
    XCTAssertEqual(
      registered(),
      [
        "core:prepared_model_readiness:45", "core:prepared_model_refresh:45",
        "core:prepared_model_refresh:46",
      ])
    monitor.cancelRefreshWork(for: 45)
    XCTAssertEqual(registered(), ["core:prepared_model_refresh:46"])
    monitor.cancelAllRefreshWork()
    XCTAssertEqual(registered(), [])
  }

  func testAXEventStormThresholdUsesEventRate() {
    XCTAssertTrue(
      AppMonitor.axEventRateIsStorm(
        count: AppMonitor.axEventStormThresholdPerSecond,
        elapsedMs: 1000))
    XCTAssertFalse(
      AppMonitor.axEventRateIsStorm(
        count: AppMonitor.axEventStormThresholdPerSecond - 1,
        elapsedMs: 1000))
    XCTAssertFalse(
      AppMonitor.axEventRateIsStorm(
        count: AppMonitor.axEventStormThresholdPerSecond,
        elapsedMs: 2000))
  }

  /// A slow walk is one whose repetition every freshness window would cost
  /// more than a tenth of a core. The threshold is a fraction of the app's
  /// current maintenance interval, never an absolute figure: the apps hints
  /// matter for (Electron, Gecko, Catalyst) walk in 50–100 ms, and a flat
  /// 50 ms budget switched the prepared model off for every one of them.
  func testASlowWalkIsMeasuredAgainstTheModelsFreshnessWindow() {
    XCTAssertEqual(AppMonitor.slowAutomaticModelRefreshThresholdMs(intervalMs: 1500), 150)
    XCTAssertEqual(AppMonitor.slowAutomaticModelRefreshThresholdMs(intervalMs: 30_000), 3000)
    XCTAssertEqual(
      AppMonitor.slowAutomaticModelRefreshThresholdMs(intervalMs: 100), 50, "the floor")
    XCTAssertFalse(AppMonitor.automaticModelRefreshIsSlow(elapsedMs: 60, intervalMs: 1500))
    XCTAssertFalse(AppMonitor.automaticModelRefreshIsSlow(elapsedMs: 149.9, intervalMs: 1500))
    XCTAssertTrue(AppMonitor.automaticModelRefreshIsSlow(elapsedMs: 150, intervalMs: 1500))
    XCTAssertFalse(AppMonitor.automaticModelRefreshIsSlow(elapsedMs: 200, intervalMs: 3000))
    XCTAssertTrue(AppMonitor.automaticModelRefreshIsSlow(elapsedMs: 3000, intervalMs: 30_000))
  }

  /// A 60 ms focus walk keeps the maintenance wake at the 1.5 s floor. A
  /// 200 ms one backs off by doubling the app's interval, not by cancelling
  /// maintenance: the next wake is armed at the longer interval, and the
  /// app's event-driven refreshes wait that interval out too.
  func testASlowAutomaticWalkBacksOffByDoublingNotByCancellingMaintenance() {
    let registry = SourceRegistry(descriptors: [], runningApplications: [])
    let scheduler = PollScheduler()
    let monitor = AppMonitor(registry: registry, config: .default, pollScheduler: scheduler)
    func registered() -> [String] {
      let listed = DispatchSemaphore(value: 0)
      var ids: [String] = []
      scheduler.registeredIDs {
        ids = $0
        listed.signal()
      }
      listed.wait()
      return ids
    }
    let pid = pid_t(43)
    func model(freshnessMs: Int) -> PreparedModel {
      PreparedModel(
        pid: pid, targets: [], hints: [], computedAt: .now(), dirtyToken: 0, configRevision: 0,
        fingerprint: 0, freshnessMs: freshnessMs, occluded: false, occlusion: nil)
    }
    func walked(_ elapsedMs: Double, reason: ModelRefreshReason = .focus) -> Int {
      monitor.recordModelWalk(
        pid: pid, bundleIdentifier: "com.example.app", reason: reason, elapsedMs: elapsedMs,
        unchanged: false, degenerate: false)
    }

    XCTAssertEqual(walked(60), AppMonitor.modelFreshnessMs)
    monitor.scheduleMaintenanceRefresh(for: model(freshnessMs: AppMonitor.modelFreshnessMs))
    XCTAssertEqual(registered(), [AppMonitor.maintenanceClientID])

    XCTAssertEqual(walked(200), AppMonitor.modelFreshnessMs * 2)
    XCTAssertEqual(monitor.modelIntervalMs(pid: pid), AppMonitor.modelFreshnessMs * 2)
    monitor.scheduleMaintenanceRefresh(for: model(freshnessMs: monitor.modelIntervalMs(pid: pid)))
    XCTAssertEqual(
      registered(), [AppMonitor.maintenanceClientID], "a slow walk does not cancel maintenance")
    monitor.scheduleModelRefresh(for: pid, reason: .maintenance)
    XCTAssertTrue(monitor.modelScheduler.hasRefresh(pid: pid))
    monitor.modelScheduler.cancelRefresh(pid: pid)

    // The interval, not only the fixed 2.5 s minimum, spaces event refreshes.
    let now = DispatchTime.now().uptimeNanoseconds
    monitor.modelScheduler.noteRefreshStarted(pid: pid, now: now)
    monitor.scheduleModelRefresh(for: pid, reason: .axEvent("AXLayoutChanged"))
    let deadline = monitor.modelScheduler.refreshDeadline(pid: pid)
    XCTAssertNotNil(deadline)
    XCTAssertGreaterThanOrEqual(deadline ?? 0, now + 3_000_000_000)

    // A cheap walk lets the interval shrink back to the floor; a degenerate
    // one is fast because there was nothing to read, so it never does.
    XCTAssertEqual(
      monitor.recordModelWalk(
        pid: pid, bundleIdentifier: "com.example.app", reason: .maintenance, elapsedMs: 5,
        unchanged: false, degenerate: true),
      AppMonitor.modelFreshnessMs * 2)
    XCTAssertEqual(walked(60, reason: .maintenance), AppMonitor.modelFreshnessMs)

    monitor.cancelRefreshWork(for: pid)
    XCTAssertEqual(registered(), [])
  }

  func testAutomaticPreparedModelRefreshSkipsDeclaredOnDemandApps() {
    let previous = OnDemandHintApps.declared.all
    defer { OnDemandHintApps.declared.declare(previous) }
    OnDemandHintApps.declared.declare(["com.example.heavy"])
    XCTAssertFalse(
      AppMonitor.shouldRunAutomaticPreparedModelRefresh(bundleIdentifier: "com.example.heavy"))
    XCTAssertEqual(
      AppMonitor.observedNotifications(forBundleIdentifier: "com.example.heavy"),
      AppMonitor.lightObservedNotifications)
    XCTAssertTrue(
      AppMonitor.shouldRunAutomaticPreparedModelRefresh(bundleIdentifier: "com.example.light"))
    XCTAssertEqual(
      AppMonitor.observedNotifications(forBundleIdentifier: "com.example.light"),
      AppMonitor.observedNotifications)
  }

  func testPreparedModelRefreshSkipsValueAndTitleChurn() {
    XCTAssertFalse(
      AppMonitor.notificationShouldSchedulePreparedModelRefresh(
        kAXValueChangedNotification as String))
    XCTAssertFalse(
      AppMonitor.notificationShouldSchedulePreparedModelRefresh(
        kAXTitleChangedNotification as String)
    )
    XCTAssertTrue(
      AppMonitor.notificationShouldSchedulePreparedModelRefresh(
        kAXLayoutChangedNotification as String)
    )
    XCTAssertTrue(
      AppMonitor.notificationShouldSchedulePreparedModelRefresh(
        kAXFocusedWindowChangedNotification as String))
  }

  func testPointerScrollPassesThroughInIdleNormalMode() {
    // Wheel ticks in normal mode always pass through to the focused app
    // (the overlay panel `ignoresMouseEvents`) and must never flip
    // Flash into insert or re-key normal capture. Hints visible is the
    // one exception — there the scroll dismisses the picker.
    XCTAssertTrue(
      AppDelegate.pointerScrollShouldPassThrough(
        mode: .normal,
        hasHints: false))
    XCTAssertFalse(
      AppDelegate.pointerScrollShouldPassThrough(
        mode: .normal,
        hasHints: true))
    XCTAssertFalse(
      AppDelegate.pointerScrollShouldPassThrough(
        mode: .insert,
        hasHints: false))
  }

  func testPointerFocusLossClickClassifiesPressedMouseButtons() {
    XCTAssertEqual(
      AppDelegate.pointerFocusLossClick(
        pressedMouseButtons: 1,
        location: CGPoint(x: 20, y: 30)),
      OverlayPointerClick(
        action: .leftClick,
        location: CGPoint(x: 20, y: 30),
        modifiers: .all))
    XCTAssertEqual(
      AppDelegate.pointerFocusLossClick(
        pressedMouseButtons: 2,
        location: CGPoint(x: 20, y: 30))?.action,
      .rightClick)
    XCTAssertEqual(
      AppDelegate.pointerFocusLossClick(
        pressedMouseButtons: 0,
        currentEventType: .rightMouseDown,
        location: CGPoint(x: 20, y: 30))?.action,
      .rightClick)
    XCTAssertEqual(
      AppDelegate.pointerFocusLossClick(
        pressedMouseButtons: 0,
        currentEventType: .leftMouseDown,
        location: CGPoint(x: 20, y: 30))?.action,
      .leftClick)
    XCTAssertNil(
      AppDelegate.pointerFocusLossClick(
        pressedMouseButtons: 0,
        location: CGPoint(x: 20, y: 30)))
  }

  func testPointerFocusLossDefersRecaptureWhilePointerMonitorCanClassifyClick() {
    XCTAssertTrue(
      AppDelegate.pointerFocusLossShouldDeferRecaptureForPointerMonitor(inputMode: .normal))
    XCTAssertTrue(
      AppDelegate.pointerFocusLossShouldDeferRecaptureForPointerMonitor(inputMode: .commandLine))
    XCTAssertFalse(
      AppDelegate.pointerFocusLossShouldDeferRecaptureForPointerMonitor(inputMode: .hints))
  }

  func testNormalModeInputCaptureStaysOwnedDuringSourceResolution() {
    XCTAssertTrue(
      AppDelegate.normalModeShouldOwnKeyboardInput(
        mode: .normal,
        overlayInputMode: .normal,
        hasHints: false,
        activationInFlight: false))
    XCTAssertFalse(
      AppDelegate.normalModeShouldOwnKeyboardInput(
        mode: .insert,
        overlayInputMode: .passive,
        hasHints: false,
        activationInFlight: false))
  }

  func testActiveWindowBorderVisibility() {
    // The border shows in BOTH modes (thin green normal / thicker blue insert)
    // when advanced mode is on, no hints are up, and the desktop session is
    // active — so the active window is always identifiable.
    XCTAssertTrue(
      AppDelegate.activeWindowBorderShouldBeVisible(
        configEnabled: true,
        modeBadgeEnabled: true,
        hasHints: false,
        sessionActive: true))
    // `[overlay] window_border = false` opts out wholesale.
    XCTAssertFalse(
      AppDelegate.activeWindowBorderShouldBeVisible(
        configEnabled: false,
        modeBadgeEnabled: true,
        hasHints: false,
        sessionActive: true))
    // No advanced mode → no normal/insert distinction to draw.
    XCTAssertFalse(
      AppDelegate.activeWindowBorderShouldBeVisible(
        configEnabled: true,
        modeBadgeEnabled: false,
        hasHints: false,
        sessionActive: true))
    // Lock/session switch/sleep hides the border immediately.
    XCTAssertFalse(
      AppDelegate.activeWindowBorderShouldBeVisible(
        configEnabled: true,
        modeBadgeEnabled: true,
        hasHints: false,
        sessionActive: false))
    // Hints suppress the border so chips aren't double-framed.
    XCTAssertFalse(
      AppDelegate.activeWindowBorderShouldBeVisible(
        configEnabled: true,
        modeBadgeEnabled: true,
        hasHints: true,
        sessionActive: true))
  }

  func testActiveWindowBorderStyleIsGreenInNormalAndBlueInInsert() {
    // Normal = thin green (no glow); insert = thicker, glowing blue. Both share
    // the same outer edge — insert grows inward.
    let normal = OverlayPanel.activeWindowBorderStyle(for: .normal)
    let insert = OverlayPanel.activeWindowBorderStyle(for: .insert)
    XCTAssertEqual(normal.color, OverlayPanel.nordAuroraGreenCG)
    XCTAssertEqual(normal.lineWidth, 1)
    XCTAssertFalse(normal.glow)
    XCTAssertEqual(insert.color, OverlayPanel.nordFrost2CG)
    XCTAssertEqual(insert.lineWidth, 2)
    XCTAssertTrue(insert.glow)
    XCTAssertGreaterThan(insert.lineWidth, normal.lineWidth)

    // Command = thin purple (1px like normal), no glow.
    let command = OverlayPanel.activeWindowBorderStyle(for: .command)
    XCTAssertEqual(command.color, OverlayPanel.nordAuroraPurpleCG)
    XCTAssertEqual(command.lineWidth, 1)
    XCTAssertFalse(command.glow)
  }

  func testActiveWindowBorderStyleConfigOverrides() {
    // `[overlay] window_border_size` / `window_border_color` apply across
    // every mode; glow (insert's identity) is untouched.
    let red = NSColor.systemRed.cgColor
    let normal = OverlayPanel.activeWindowBorderStyle(
      for: .normal, sizeOverride: 4, colorOverride: red)
    XCTAssertEqual(normal.color, red)
    XCTAssertEqual(normal.lineWidth, 4)
    XCTAssertFalse(normal.glow)
    let insert = OverlayPanel.activeWindowBorderStyle(
      for: .insert, sizeOverride: 4, colorOverride: red)
    XCTAssertEqual(insert.color, red)
    XCTAssertEqual(insert.lineWidth, 4)
    XCTAssertTrue(insert.glow)
    // Zero size / nil color = keep the per-mode defaults.
    let untouched = OverlayPanel.activeWindowBorderStyle(
      for: .insert, sizeOverride: 0, colorOverride: nil)
    XCTAssertEqual(untouched.color, OverlayPanel.nordFrost2CG)
    XCTAssertEqual(untouched.lineWidth, 2)
  }

  func testWindowBorderConfigKeysParse() {
    let c = ConfigLoader.parse(
      """
      [overlay]
      window_border = false
      window_border_size = 3.5
      window_border_color = "#BF616A"
      """)
    XCTAssertFalse(c.overlay.windowBorder)
    XCTAssertEqual(c.overlay.windowBorderSize, 3.5)
    XCTAssertEqual(c.overlay.windowBorderColor, "#BF616A")
    XCTAssertTrue(c.loadingDiagnostics.isEmpty)

    // Defaults: on, per-mode size/color.
    let defaults = ConfigLoader.parse("")
    XCTAssertTrue(defaults.overlay.windowBorder)
    XCTAssertEqual(defaults.overlay.windowBorderSize, 0)
    XCTAssertEqual(defaults.overlay.windowBorderColor, "")

    let invalid = ConfigLoader.parse(
      """
      [overlay]
      window_border_size = -1
      window_border_color = "salmon"
      """)
    XCTAssertEqual(invalid.overlay.windowBorderSize, 0)
    XCTAssertEqual(invalid.overlay.windowBorderColor, "")
    XCTAssertTrue(
      invalid.loadingDiagnostics.contains { $0.message.contains("window_border_size") })
    XCTAssertTrue(
      invalid.loadingDiagnostics.contains { $0.message.contains("window_border_color") })
  }

  func testActiveWindowBorderFrameComparisonIgnoresTinyJitter() {
    let frame = CGRect(x: 10, y: 20, width: 300, height: 200)
    XCTAssertTrue(
      AppDelegate.activeWindowBorderFramesApproximatelyEqual(
        frame,
        CGRect(x: 10.5, y: 19.5, width: 299.5, height: 200.5),
        tolerance: 1))
    XCTAssertFalse(
      AppDelegate.activeWindowBorderFramesApproximatelyEqual(
        frame,
        CGRect(x: 12, y: 20, width: 300, height: 200),
        tolerance: 1))
    XCTAssertFalse(
      AppDelegate.activeWindowBorderFramesApproximatelyEqual(
        frame,
        nil,
        tolerance: 1))
    XCTAssertTrue(
      AppDelegate.activeWindowBorderFramesApproximatelyEqual(
        nil,
        nil,
        tolerance: 1))
  }

  func testActiveWindowBorderReconciliationNeverKeepsAStaleFrame() {
    let tracked = CGRect(x: 10, y: 20, width: 300, height: 200)
    XCTAssertEqual(
      AppDelegate.activeWindowBorderReconciliationAction(
        trackedFrame: tracked, currentFrame: nil, tolerance: 1),
      .hide)
    XCTAssertEqual(
      AppDelegate.activeWindowBorderReconciliationAction(
        trackedFrame: nil, currentFrame: tracked, tolerance: 1),
      .redraw)
    XCTAssertEqual(
      AppDelegate.activeWindowBorderReconciliationAction(
        trackedFrame: tracked,
        currentFrame: CGRect(x: 12, y: 20, width: 300, height: 200),
        tolerance: 1),
      .redraw)
    XCTAssertEqual(
      AppDelegate.activeWindowBorderReconciliationAction(
        trackedFrame: tracked,
        currentFrame: CGRect(x: 10.5, y: 20, width: 300, height: 200),
        tolerance: 1),
      .none)
  }

  private func borderDelegate() -> AppDelegate {
    _ = NSApplication.shared
    let delegate = AppDelegate()
    delegate.registry = SourceRegistry(descriptors: [], runningApplications: [])
    delegate.monitor = AppMonitor(registry: delegate.registry, config: delegate.config)
    delegate.overlay = OverlayPanel()
    return delegate
  }

  /// An activation with a cached frame paints it at once and leaves the
  /// authoritative window-list read to the 80 ms settle pass, after the
  /// activation animation — the immediate read cost 5 ms (p95 18 ms) on main
  /// for a frame the pass re-read anyway. Without a cache the read is this
  /// turn's: nothing else would draw the stroke.
  func testAnActivationWithACachedFramePaintsItAndDefersTheReadToTheSettlePass() {
    let delegate = borderDelegate()
    let frame = CGRect(x: 10, y: 20, width: 300, height: 200)
    delegate.activeWindowBorderFrameCache[4242] = frame
    delegate.paintActiveWindowBorder(pid: 4242, reason: "app_activated", read: .onlyWithoutCache)
    XCTAssertEqual(delegate.overlay.activeWindowBorderFrame, frame)
    XCTAssertNil(delegate.activeWindowBorderPendingRead, "the 80 ms pass is the first read")

    delegate.paintActiveWindowBorder(pid: 4343, reason: "app_activated", read: .onlyWithoutCache)
    XCTAssertEqual(delegate.activeWindowBorderPendingRead?.pid, 4343, "nothing cached: read now")

    delegate.activeWindowBorderFrameCache[4242] = frame
    delegate.paintActiveWindowBorder(pid: 4242, reason: "AXWindowCreated", read: .nextTurn)
    XCTAssertEqual(
      delegate.activeWindowBorderPendingRead?.pid, 4242, "an event's cache is only a guess")
    delegate.activeWindowBorderPendingRead = nil
    delegate.overlay.setActiveWindowBorder(around: nil)
  }

  /// The settle pass that finds the window where the stroke already is ends
  /// the series: the 250 and 750 ms passes would read the same window list.
  func testASettlePassThatFindsTheDrawnFrameEndsTheSeries() {
    let delegate = borderDelegate()
    let frame = CGRect(x: 10, y: 20, width: 300, height: 200)
    delegate.overlay.setActiveWindowBorder(around: frame)
    delegate.activeWindowBorderFrameReader = { _ in
      CGRect(x: 10.5, y: 20, width: 300, height: 199.5)
    }
    let series = delegate.activeWindowBorderReconciliationGeneration
    delegate.activeWindowBorderPendingRead = ActiveWindowBorderRead(
      pid: 4242, reason: "app_activated_settled_80ms",
      generation: delegate.activeWindowBorderUpdateGeneration, reconciles: true,
      endsSettleSeries: series)
    delegate.performActiveWindowBorderRead()
    XCTAssertNotEqual(
      delegate.activeWindowBorderReconciliationGeneration, series, "later passes are stale")
    XCTAssertEqual(delegate.overlay.activeWindowBorderFrame, frame, "within a point: no redraw")
    XCTAssertEqual(
      delegate.activeWindowBorderFrameCache[4242]?.minX, 10.5, "the read refreshes the cache")
    delegate.overlay.setActiveWindowBorder(around: nil)
  }

  /// A pass that finds the window elsewhere redraws and keeps the later
  /// passes: the app is still settling. A series that does not end on a
  /// match (the AX-event settle) keeps its passes even when the read matches.
  func testASettlePassThatFindsTheWindowElsewhereRedrawsAndKeepsTheSeries() {
    let delegate = borderDelegate()
    let drawn = CGRect(x: 10, y: 20, width: 300, height: 200)
    let moved = CGRect(x: 40, y: 20, width: 300, height: 200)
    delegate.overlay.setActiveWindowBorder(around: drawn)
    delegate.activeWindowBorderFrameReader = { _ in moved }
    let series = delegate.activeWindowBorderReconciliationGeneration
    delegate.activeWindowBorderPendingRead = ActiveWindowBorderRead(
      pid: 4242, reason: "app_activated_settled_80ms",
      generation: delegate.activeWindowBorderUpdateGeneration, reconciles: true,
      endsSettleSeries: series)
    delegate.performActiveWindowBorderRead()
    XCTAssertEqual(delegate.activeWindowBorderReconciliationGeneration, series)
    XCTAssertEqual(delegate.overlay.activeWindowBorderFrame, moved)

    delegate.activeWindowBorderPendingRead = ActiveWindowBorderRead(
      pid: 4242, reason: "AXWindowCreated_settled_45ms",
      generation: delegate.activeWindowBorderUpdateGeneration, reconciles: true,
      endsSettleSeries: nil)
    delegate.performActiveWindowBorderRead()
    XCTAssertEqual(delegate.activeWindowBorderReconciliationGeneration, series)
    delegate.overlay.setActiveWindowBorder(around: nil)
  }

  func testActiveWindowBorderRecognizesSecureSystemSurfaces() {
    XCTAssertTrue(
      AppDelegate.activeWindowBorderSecureUISuspendsSession(
        bundleIdentifier: "com.apple.loginwindow"))
    XCTAssertTrue(
      AppDelegate.activeWindowBorderSecureUISuspendsSession(
        bundleIdentifier: "com.apple.ScreenSaver.Engine"))
    XCTAssertFalse(
      AppDelegate.activeWindowBorderSecureUISuspendsSession(
        bundleIdentifier: "com.apple.finder"))
    XCTAssertFalse(
      AppDelegate.activeWindowBorderSecureUISuspendsSession(bundleIdentifier: nil))
  }

  func testCommandSurfacesPublishCommandStatusLabel() {
    let labels = Config.Mode.Labels(normal: "N", insert: "I", command: "C")
    XCTAssertEqual(AppDelegate.commandSurfaceModeLabel(labels: labels), "C")
  }

  func testWindowLifecycleNotificationsRefreshActiveBorder() {
    XCTAssertTrue(
      AppMonitor.notificationMayChangeActiveWindowBorder(
        kAXWindowMovedNotification, observedElementIsFocusedWindow: false))
    XCTAssertTrue(
      AppMonitor.notificationMayChangeActiveWindowBorder(
        kAXWindowResizedNotification, observedElementIsFocusedWindow: false))
    XCTAssertTrue(
      AppMonitor.notificationMayChangeActiveWindowBorder(
        kAXFocusedWindowChangedNotification, observedElementIsFocusedWindow: false))
    XCTAssertTrue(
      AppMonitor.notificationMayChangeActiveWindowBorder(
        kAXMainWindowChangedNotification, observedElementIsFocusedWindow: false))
    XCTAssertTrue(
      AppMonitor.notificationMayChangeActiveWindowBorder(
        kAXWindowCreatedNotification, observedElementIsFocusedWindow: false))
    XCTAssertTrue(
      AppMonitor.notificationMayChangeActiveWindowBorder(
        kAXWindowMiniaturizedNotification, observedElementIsFocusedWindow: false))
    XCTAssertTrue(
      AppMonitor.notificationMayChangeActiveWindowBorder(
        kAXWindowDeminiaturizedNotification, observedElementIsFocusedWindow: false))
    XCTAssertTrue(
      AppMonitor.notificationMayChangeActiveWindowBorder(
        kAXUIElementDestroyedNotification, observedElementIsFocusedWindow: true))
    XCTAssertFalse(
      AppMonitor.notificationMayChangeActiveWindowBorder(
        kAXUIElementDestroyedNotification, observedElementIsFocusedWindow: false))
    XCTAssertFalse(
      AppMonitor.notificationMayChangeActiveWindowBorder(
        kAXValueChangedNotification, observedElementIsFocusedWindow: false))
  }

  func testFocusedWindowObserverTracksWindowOwnedNotifications() {
    let focusedWindowNotifications: Set<String> = [
      kAXWindowMovedNotification as String,
      kAXWindowResizedNotification as String,
      kAXWindowMiniaturizedNotification as String,
      kAXWindowDeminiaturizedNotification as String,
      kAXUIElementDestroyedNotification as String,
    ]
    XCTAssertEqual(Set(AppMonitor.focusedWindowObservedNotifications), focusedWindowNotifications)

    // Even bundles with background warming disabled still need every cheap
    // window lifecycle signal so their border cannot go stale.
    let appWindowLifecycleNotifications: Set<String> = [
      kAXWindowCreatedNotification as String,
      kAXWindowMiniaturizedNotification as String,
      kAXWindowDeminiaturizedNotification as String,
      kAXApplicationHiddenNotification as String,
      kAXApplicationShownNotification as String,
      kAXUIElementDestroyedNotification as String,
    ]
    XCTAssertTrue(
      appWindowLifecycleNotifications.isSubset(of: Set(AppMonitor.observedNotifications)))
    XCTAssertTrue(
      appWindowLifecycleNotifications.isSubset(of: Set(AppMonitor.lightObservedNotifications)))
  }

  func testNormalModeRecaptureScheduleStartsImmediatelyAndRetriesAggressively() {
    XCTAssertEqual(AppDelegate.normalModeRecaptureDelaysMs.first, 0)
    XCTAssertEqual(AppDelegate.normalModeRecaptureDelaysMs.prefix(4), [0, 10, 30, 60])
    XCTAssertEqual(AppDelegate.normalModeRecaptureDelaysMs.last, 1_400)
  }

  func testFocusChangingNormalModeRecaptureScheduleClosesAppActivationGaps() {
    XCTAssertEqual(AppDelegate.normalModeFocusChangingRecaptureDelaysMs.first, 0)
    XCTAssertEqual(
      AppDelegate.normalModeFocusChangingRecaptureDelaysMs.prefix(6), [0, 1, 4, 8, 16, 30])
    XCTAssertEqual(AppDelegate.normalModeFocusChangingRecaptureDelaysMs.last, 1_400)
  }

  func testWorkspaceActivationRecaptureSkipsRecentMenuBarInteractions() {
    let now = Date(timeIntervalSince1970: 1_000)
    let activeSuppression = now.addingTimeInterval(0.5)
    let expiredSuppression = now.addingTimeInterval(-0.1)

    XCTAssertFalse(
      AppDelegate.workspaceActivationShouldScheduleNormalModeRecapture(
        mode: .normal,
        menuBarInteractionRecaptureSuppressedUntil: activeSuppression,
        now: now))
    XCTAssertTrue(
      AppDelegate.workspaceActivationShouldScheduleNormalModeRecapture(
        mode: .normal,
        menuBarInteractionRecaptureSuppressedUntil: expiredSuppression,
        now: now))
    XCTAssertTrue(
      AppDelegate.workspaceActivationShouldScheduleNormalModeRecapture(
        mode: .normal,
        menuBarInteractionRecaptureSuppressedUntil: nil,
        now: now))
    XCTAssertFalse(
      AppDelegate.workspaceActivationShouldScheduleNormalModeRecapture(
        mode: .insert,
        menuBarInteractionRecaptureSuppressedUntil: nil,
        now: now))
  }

  func testMenuBarPointerClicksSuspendNativeSurfacesWithoutInsert() {
    for action in [JumpAction.leftClick, .rightClick, .doubleClick] {
      let decision = NormalModePointerPolicy.pointerDecision(
        mode: .normal,
        overlayInputMode: .normal,
        hasHints: false,
        activationInFlight: false,
        intent: .click(
          OverlayPointerClick(
            action: action,
            location: CGPoint(x: 10, y: 10),
            modifiers: [])),
        pointIsInMenuBar: true)
      XCTAssertEqual(
        decision,
        .menuBar(dismissHints: false))
    }
  }

  /// `/` (`app find`) and `t` (`tab new`) keep NORMAL like every other app
  /// action: typing into the find field or the new tab starts from an
  /// explicit INSERT entry, so the Mappings page promises no mode change.
  func testFindAndNewTabDoNotPromiseInsert() {
    for command: URLCommand in [.find, .tabNew, .focusInput, .tabNext, .selection(.copy)] {
      XCTAssertFalse(command.explanation.contains("INSERT"), "\(command): \(command.explanation)")
    }
    XCTAssertEqual(URLCommand.insertMode.explanation, "Enters INSERT mode.")
  }

  func testTypingSurfacesAreJudgedByRoleAndSearchSubrole() {
    XCTAssertTrue(JumpTarget.isTextInput(role: "AXTextField", subrole: nil))
    XCTAssertTrue(JumpTarget.isTextInput(role: "AXTextField", subrole: "AXSecureTextField"))
    XCTAssertFalse(JumpTarget.isTextInput(role: "AXButton", subrole: nil))
    // A search field is typed into whatever role carries it.
    XCTAssertTrue(JumpTarget.isTextInput(role: "AXButton", subrole: "AXSearchField"))
    XCTAssertFalse(JumpTarget.isTextInput(role: "AXStaticText", subrole: nil))
  }

  func testNormalModePointerPolicyMatrixForAppClicks() {
    XCTAssertEqual(
      NormalModePointerPolicy.appClickDecision(
        mode: .normal,
        wasCommandLine: false,
        hasHints: false,
        action: .leftClick),
      NormalModePointerPolicy.AppClickDecision.keepNormal)
    XCTAssertEqual(
      NormalModePointerPolicy.appClickDecision(
        mode: .normal,
        wasCommandLine: false,
        hasHints: false,
        action: .doubleClick),
      NormalModePointerPolicy.AppClickDecision.keepNormal)
    // Right-click never flips the mode: it suspends normal capture so the
    // native context menu owns the keyboard, and drops any transient hints
    // showing behind it (so `dismissHints` tracks hasHints).
    XCTAssertEqual(
      NormalModePointerPolicy.appClickDecision(
        mode: .normal,
        wasCommandLine: false,
        hasHints: true,
        action: .rightClick),
      NormalModePointerPolicy.AppClickDecision.suspendForNativeSurface(dismissHints: true))
    XCTAssertEqual(
      NormalModePointerPolicy.appClickDecision(
        mode: .normal,
        wasCommandLine: false,
        hasHints: false,
        action: .rightClick),
      NormalModePointerPolicy.AppClickDecision.suspendForNativeSurface(dismissHints: false))
    XCTAssertEqual(
      NormalModePointerPolicy.appClickDecision(
        mode: .insert,
        wasCommandLine: false,
        hasHints: false,
        action: .leftClick),
      NormalModePointerPolicy.AppClickDecision.ignore)
    XCTAssertEqual(
      NormalModePointerPolicy.appClickDecision(
        mode: .normal,
        wasCommandLine: true,
        hasHints: false,
        action: .leftClick),
      NormalModePointerPolicy.AppClickDecision.ignore)
  }

  func testNormalAppRightClickSuspendsForContextMenu() {
    // Top-level decision: a physical right-click on the app body resolves to an
    // app decision that suspends for the native surface (the context menu) —
    // uniform with the `f`/`F` right-click commits.
    let decision = NormalModePointerPolicy.pointerDecision(
      mode: .normal,
      overlayInputMode: .normal,
      hasHints: false,
      activationInFlight: false,
      intent: .click(
        OverlayPointerClick(
          action: .rightClick,
          location: CGPoint(x: 200, y: 200),
          modifiers: [])),
      pointIsInMenuBar: false)
    XCTAssertEqual(
      decision,
      .app(
        NormalModePointerPolicy.AppClickDecision.suspendForNativeSurface(dismissHints: false)))
  }

  func testPhysicalPointerClickForwardingOnlyCoversActivationOnlyPrimaryClicks() {
    let released = NormalModePointerPolicy.AppClickDecision.keepNormal
    let notReleased = NormalModePointerPolicy.AppClickDecision.ignore

    XCTAssertTrue(
      AppDelegate.physicalPointerClickShouldBeForwarded(
        decision: released,
        click: pointerClick(.leftClick, flashWasActive: true),
        targetPID: nil))
    XCTAssertTrue(
      AppDelegate.physicalPointerClickShouldBeForwarded(
        decision: released,
        click: pointerClick(.doubleClick, flashWasActive: true),
        targetPID: nil))
    XCTAssertFalse(
      AppDelegate.physicalPointerClickShouldBeForwarded(
        decision: released,
        click: pointerClick(.leftClick, flashWasActive: false),
        targetPID: nil))
    XCTAssertFalse(
      AppDelegate.physicalPointerClickShouldBeForwarded(
        decision: released,
        click: pointerClick(.rightClick, flashWasActive: true),
        targetPID: nil))
    XCTAssertFalse(
      AppDelegate.physicalPointerClickShouldBeForwarded(
        decision: notReleased,
        click: pointerClick(.leftClick, flashWasActive: true),
        targetPID: nil))
    XCTAssertFalse(
      AppDelegate.physicalPointerClickShouldBeForwarded(
        decision: released,
        click: nil,
        targetPID: nil))

    // Clicking a window owned by an app that was NOT frontmost at click time:
    // the physical click is consumed activating that app, so Flash must forward
    // a synthetic click even though Flash itself was never active.
    XCTAssertTrue(
      AppDelegate.physicalPointerClickShouldBeForwarded(
        decision: released,
        click: pointerClick(.leftClick, flashWasActive: false, frontmostPIDAtClick: 111),
        targetPID: 222))
    // Clicking the already-frontmost app: the physical click landed directly,
    // so forwarding would double-deliver — don't.
    XCTAssertFalse(
      AppDelegate.physicalPointerClickShouldBeForwarded(
        decision: released,
        click: pointerClick(.leftClick, flashWasActive: false, frontmostPIDAtClick: 222),
        targetPID: 222))
  }

  func testNormalModePointerPolicyTopLevelDecisions() {
    XCTAssertEqual(
      NormalModePointerPolicy.pointerDecision(
        mode: .normal,
        overlayInputMode: .normal,
        hasHints: false,
        activationInFlight: false,
        intent: .scroll,
        pointIsInMenuBar: false),
      .passThrough)
    XCTAssertEqual(
      NormalModePointerPolicy.pointerDecision(
        mode: .normal,
        overlayInputMode: .normal,
        hasHints: true,
        activationInFlight: false,
        intent: .scroll,
        pointIsInMenuBar: false),
      .cancelOverlay)
    // A scroll over the command bar passes through (it must not tear the prompt
    // down — the user dismisses it with Esc), unlike a scroll over hints.
    XCTAssertEqual(
      NormalModePointerPolicy.pointerDecision(
        mode: .normal,
        overlayInputMode: .commandLine,
        hasHints: false,
        activationInFlight: false,
        intent: .scroll,
        pointIsInMenuBar: false),
      .passThrough)
    XCTAssertEqual(
      NormalModePointerPolicy.pointerDecision(
        mode: .normal,
        overlayInputMode: .normal,
        hasHints: true,
        activationInFlight: false,
        intent: .click(
          OverlayPointerClick(
            action: .rightClick,
            location: CGPoint(x: 20, y: 20),
            modifiers: [])),
        pointIsInMenuBar: true),
      .menuBar(dismissHints: true))
  }

  func testPointerFocusLossDeferralIsBriefSoNormalModeReclaimsFocus() {
    // The deferral only needs to outlast the pointer monitor delivering the
    // click; it must be far shorter than the suppression windows so an app
    // that spontaneously steals focus in NORMAL is reclaimed almost
    // immediately instead of sitting there while the badge still reads NORMAL.
    XCTAssertEqual(AppDelegate.pointerFocusLossRecaptureDeferralMs, 120)
    XCTAssertLessThan(
      AppDelegate.pointerFocusLossRecaptureDeferralMs,
      AppDelegate.contextMenuInteractionRecaptureSuppressionMs)
  }

  func testWorkspaceActivationRecaptureSkipsContextMenuInteraction() {
    let now = Date(timeIntervalSince1970: 1_000)
    let activeSuppression = now.addingTimeInterval(0.5)
    let expiredSuppression = now.addingTimeInterval(-0.1)

    XCTAssertFalse(
      AppDelegate.workspaceActivationShouldScheduleNormalModeRecapture(
        mode: .normal,
        menuBarInteractionRecaptureSuppressedUntil: nil,
        contextMenuInteractionRecaptureSuppressedUntil: activeSuppression,
        now: now))
    XCTAssertTrue(
      AppDelegate.workspaceActivationShouldScheduleNormalModeRecapture(
        mode: .normal,
        menuBarInteractionRecaptureSuppressedUntil: nil,
        contextMenuInteractionRecaptureSuppressedUntil: expiredSuppression,
        now: now))
  }

  func testCommandLineBufferIncludesPrompt() {
    XCTAssertEqual(AppDelegate.commandLineBuffer(from: ""), ":")
    XCTAssertEqual(AppDelegate.commandLineBuffer(from: "open "), ":open ")
    XCTAssertEqual(AppDelegate.commandLineBuffer(from: ":open "), ":open ")
  }

  /// The command-line-only words, and the lines the resolver rejects. The
  /// ex commands and the prefixes are `CommandLineResolverTests`.
  func testCommandLineParser() {
    let inventory = NormalModeDispatcher.CommandLineInventory.core()
    func resolve(_ raw: String) -> NormalModeDispatcher.CommandLineResolution {
      NormalModeDispatcher.resolveCommandLine(raw, inventory: inventory)
    }
    XCTAssertEqual(resolve("  quit  "), .commands([.appClose]))
    XCTAssertEqual(resolve("  QUIT  "), .unknown, "case matters, as in vim")
    XCTAssertEqual(resolve(":plugins show"), .commands([.showPlugins]))
    XCTAssertEqual(resolve(":plugins reload"), .commands([.reloadPlugins]))
    XCTAssertEqual(resolve(":plugins bogus"), .unknown)
    XCTAssertEqual(resolve(":plugins doctor"), .unknown)
    XCTAssertEqual(resolve(":plugins reload extra"), .unknown)
    XCTAssertEqual(resolve(":doctor"), .query(.doctor, arguments: [:]))
    XCTAssertEqual(resolve(":logs"), .commands([.showLogs]))
    XCTAssertEqual(resolve(":commands"), .commands([.showCommands]))
    XCTAssertEqual(resolve(":mappings"), .commands([.showMappings]))
    XCTAssertEqual(resolve(":map"), .commands([.showMappings]))
    XCTAssertEqual(resolve(":about"), .commands([.showAbout]))
    XCTAssertEqual(resolve("%y"), .unknown)
    XCTAssertEqual(resolve(":%yan"), .unknown)
    XCTAssertEqual(resolve("q!!"), .unknown)
    XCTAssertEqual(resolve("e!"), .commands([.documentRevert]), "vim's revert")
    XCTAssertEqual(resolve("qu!it"), .unknown)
  }

  func testCommandLineClipboardModifierParser() {
    let plain = NormalModeDispatcher.commandLineClipboardModifier(":aws whoami")
    XCTAssertFalse(plain.capture)
    XCTAssertEqual(plain.raw, ":aws whoami")

    let afterColon = NormalModeDispatcher.commandLineClipboardModifier(":#aws whoami")
    XCTAssertTrue(afterColon.capture)
    XCTAssertEqual(afterColon.raw, ":aws whoami")

    let spaced = NormalModeDispatcher.commandLineClipboardModifier(": # aws whoami")
    XCTAssertTrue(spaced.capture)
    XCTAssertEqual(spaced.raw, ":aws whoami")

    let noColon = NormalModeDispatcher.commandLineClipboardModifier("#calc 2 + 2")
    XCTAssertTrue(noColon.capture)
    XCTAssertEqual(noColon.raw, "calc 2 + 2")
  }

  private static let qwertyGrid = MouseGrid.Shape.keyboard(
    Alphabet.gridKeys(layoutName: "qwerty"))
  private static let gridChip = CGSize(width: 14, height: 16)

  private func gridHints(
    _ region: CGRect, depth: Int, shape: MouseGrid.Shape = qwertyGrid, steps: Int = 3
  ) -> [AssignedHint] {
    MouseGrid.hints(
      region: region, depth: depth, shape: shape, steps: steps, chipSize: Self.gridChip)
  }

  func testMouseGridLabelsFollowTheKeyboardRowMajor() {
    // The screen is the left half of the keyboard: `1` top-left, `b`
    // bottom-right, rows top to bottom (NSScreen: top is maxY).
    let area = CGRect(x: 0, y: 0, width: 1512, height: 945)
    let hints = gridHints(area, depth: 0)
    XCTAssertEqual(hints.map(\.label).joined(), "12345qwertasdfgzxcvb")
    let first = hints[0].target.frame
    let last = hints[19].target.frame
    XCTAssertEqual(first.minX, area.minX, accuracy: 0.001)
    XCTAssertEqual(first.maxY, area.maxY, accuracy: 0.001)
    XCTAssertEqual(last.maxX, area.maxX, accuracy: 0.001)
    XCTAssertEqual(last.minY, area.minY, accuracy: 0.001)
    for hint in hints {
      XCTAssertEqual(hint.target.frame.width, 1512 / 5, accuracy: 0.001)
      XCTAssertEqual(hint.target.frame.height, 945 / 4, accuracy: 0.001)
      XCTAssertEqual(hint.target.role, MouseGrid.cellRole)
    }
  }

  func testMouseGridKeepsTheSameShapeAtEveryDepth() {
    let area = CGRect(x: 0, y: 0, width: 1512, height: 945)
    var region = area
    for depth in 0..<3 {
      let hints = gridHints(region, depth: depth)
      XCTAssertEqual(hints.map(\.label).joined(), "12345qwertasdfgzxcvb", "depth \(depth)")
      region = hints[7].target.frame
    }
    // Depth 1 cells on a laptop are about 60 × 59 points.
    let depthOne = gridHints(gridHints(area, depth: 0)[0].target.frame, depth: 1)
    XCTAssertEqual(depthOne[0].target.frame.width, 1512 / 25, accuracy: 0.001)
    XCTAssertEqual(depthOne[0].target.frame.height, 945 / 16, accuracy: 0.001)
  }

  func testMouseGridCentreCellConvergesOnTheRegionCentre() {
    let area = CGRect(x: 100, y: 50, width: 1512, height: 945)
    let centre = MouseGrid.centreCell(of: area, shape: Self.qwertyGrid)
    XCTAssertEqual(centre.width, area.width / 5, accuracy: 0.001)
    XCTAssertEqual(centre.height, area.height / 4, accuracy: 0.001)
    XCTAssertEqual(centre.midX, area.midX, accuracy: 0.001)
    XCTAssertEqual(centre.midY, area.midY, accuracy: 0.001)
    var region = area
    for _ in 0..<4 {
      region = MouseGrid.centreCell(of: region, shape: Self.qwertyGrid)
    }
    XCTAssertEqual(region.midX, area.midX, accuracy: 0.001)
    XCTAssertEqual(region.midY, area.midY, accuracy: 0.001)
    XCTAssertLessThan(region.width, 3)
  }

  func testMouseGridFinalStepCoversThePreviousRectWithAClusterOnALaptop() {
    // 1512 × 945 → 302 × 236 → 60 × 59: the last cells are 12 × 15, smaller
    // than a chip, so the step becomes a glued cluster that still covers the
    // whole previous rect and never overlaps.
    let past = CGRect(x: 604.8, y: 472.5, width: 1512 / 25, height: 945 / 16)
    XCTAssertTrue(
      MouseGrid.selectionCommits(region: past, depth: 2, steps: 3, shape: Self.qwertyGrid))
    let hints = gridHints(past, depth: 2)
    XCTAssertEqual(hints.map(\.label).joined(), "12345qwertasdfgzxcvb")
    XCTAssertTrue(hints.allSatisfy { $0.target.role == MouseGrid.finalChipRole })
    let union = hints.reduce(CGRect.null) { $0.union($1.target.frame) }
    XCTAssertTrue(union.contains(past), "\(union) must cover \(past)")
    XCTAssertEqual(union.midX, past.midX, accuracy: 0.001)
    XCTAssertEqual(union.midY, past.midY, accuracy: 0.001)
    for hint in hints {
      XCTAssertGreaterThanOrEqual(hint.target.frame.width, Self.gridChip.width)
      XCTAssertGreaterThanOrEqual(hint.target.frame.height, Self.gridChip.height)
    }
    for (index, hint) in hints.enumerated() where index % 5 != 4 {
      XCTAssertGreaterThanOrEqual(
        hints[index + 1].target.frame.minX, hint.target.frame.maxX - 0.001)
    }
  }

  func testMouseGridFinalStepKeepsTilesOnA4KDisplay() {
    // 3840 × 2100 → 768 × 525 → 154 × 131: the last cells are 31 × 26, larger
    // than a chip, so they stay tiles and every point of the rect is reachable.
    let past = CGRect(x: 0, y: 0, width: 3840 / 25, height: 2100 / 16)
    XCTAssertTrue(
      MouseGrid.selectionCommits(region: past, depth: 2, steps: 3, shape: Self.qwertyGrid))
    let hints = gridHints(past, depth: 2)
    XCTAssertTrue(hints.allSatisfy { $0.target.role == MouseGrid.finalCellRole })
    let union = hints.reduce(CGRect.null) { $0.union($1.target.frame) }
    XCTAssertEqual(union.minX, past.minX, accuracy: 0.001)
    XCTAssertEqual(union.minY, past.minY, accuracy: 0.001)
    XCTAssertEqual(union.width, past.width, accuracy: 0.001)
    XCTAssertEqual(union.height, past.height, accuracy: 0.001)
  }

  func testMouseGridCommitsAfterTheConfiguredSteps() {
    let area = CGRect(x: 0, y: 0, width: 3840, height: 2100)
    let shape = Self.qwertyGrid
    XCTAssertFalse(MouseGrid.selectionCommits(region: area, depth: 0, steps: 3, shape: shape))
    let second = gridHints(area, depth: 0)[0].target.frame
    XCTAssertFalse(MouseGrid.selectionCommits(region: second, depth: 1, steps: 3, shape: shape))
    let third = gridHints(second, depth: 1)[0].target.frame
    XCTAssertTrue(MouseGrid.selectionCommits(region: third, depth: 2, steps: 3, shape: shape))
    XCTAssertFalse(MouseGrid.selectionCommits(region: third, depth: 2, steps: 4, shape: shape))
  }

  func testMouseGridWithFourStepsTerminatesAtTheSizeFloor() {
    // On a laptop the third selection already lands below 18 points, so a
    // larger step count stops there instead of stacking unreadable cells.
    let area = CGRect(x: 0, y: 0, width: 1512, height: 945)
    let shape = Self.qwertyGrid
    let second = gridHints(area, depth: 0, steps: 4)[0].target.frame
    XCTAssertFalse(MouseGrid.selectionCommits(region: second, depth: 1, steps: 4, shape: shape))
    let third = gridHints(second, depth: 1, steps: 4)[0].target.frame
    XCTAssertTrue(MouseGrid.selectionCommits(region: third, depth: 2, steps: 4, shape: shape))
    XCTAssertTrue(
      gridHints(third, depth: 2, steps: 4).allSatisfy {
        $0.target.role == MouseGrid.finalChipRole
      })
  }

  func testFinalMouseGridCellsTouchWithoutGaps() {
    // Adjacent cells share an edge — no gap, no overlap. The user's promise:
    // clicking *anywhere* in a cell commits the hint.
    let first = gridHints(CGRect(x: 0, y: 0, width: 1440, height: 900), depth: 0)
    XCTAssertEqual(first.count, 20)
    // Cells laid out left-to-right within a row share a vertical edge.
    let topLeft = first[0].target.frame
    let topNext = first[1].target.frame
    XCTAssertEqual(topLeft.maxX, topNext.minX, accuracy: 0.001)
    XCTAssertEqual(topLeft.minY, topNext.minY, accuracy: 0.001)
    XCTAssertEqual(topLeft.maxY, topNext.maxY, accuracy: 0.001)
    // Rows stack without a gap either.
    XCTAssertEqual(first[5].target.frame.maxY, topLeft.minY, accuracy: 0.001)
  }

  func testMouseGridBisectDrawsQuadrantsAndKeepsHalves() {
    let area = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let hints = gridHints(area, depth: 0, shape: .qwertyBisect)
    XCTAssertEqual(hints.map(\.label), ["y", "u", "b", "n"])
    XCTAssertEqual(hints[0].target.frame, CGRect(x: 0, y: 400, width: 500, height: 400))
    XCTAssertEqual(hints[3].target.frame, CGRect(x: 500, y: 0, width: 500, height: 400))
    XCTAssertEqual(
      MouseGrid.half(of: area, .left), CGRect(x: 0, y: 0, width: 500, height: 800))
    XCTAssertEqual(
      MouseGrid.half(of: area, .right), CGRect(x: 500, y: 0, width: 500, height: 800))
    XCTAssertEqual(
      MouseGrid.half(of: area, .up), CGRect(x: 0, y: 400, width: 1000, height: 400))
    XCTAssertEqual(
      MouseGrid.half(of: area, .down), CGRect(x: 0, y: 0, width: 1000, height: 400))
    // Bisect ignores the step count and commits once a kept region is at the
    // size floor on both sides.
    XCTAssertFalse(
      MouseGrid.selectionCommits(region: area, depth: 9, steps: 2, shape: .qwertyBisect))
    XCTAssertFalse(MouseGrid.keepCommits(CGRect(x: 0, y: 0, width: 10, height: 40)))
    XCTAssertTrue(MouseGrid.keepCommits(CGRect(x: 0, y: 0, width: 18, height: 12)))
    XCTAssertTrue(
      MouseGrid.selectionCommits(
        region: CGRect(x: 0, y: 0, width: 36, height: 30), depth: 0, steps: 3, shape: .qwertyBisect)
    )
  }

  func testPluginCommandLineInvocationParser() {
    let inventory = NormalModeDispatcher.CommandLineInventory.core(
      pluginCommands: ["screenshot": ["window", "screen"], "calc": ["*"]])
    XCTAssertEqual(
      NormalModeDispatcher.resolveCommandLine(":screenshot window quiet now", inventory: inventory),
      .plugin(command: "screenshot", subcommand: "window", args: ["quiet", "now"]))
    // A plugin command needs its subcommand, as a mapping and the CLI do; a
    // wildcard takes the words as typed.
    XCTAssertEqual(
      NormalModeDispatcher.resolveCommandLine(":screenshot", inventory: inventory),
      .incomplete("screenshot"))
    XCTAssertEqual(
      NormalModeDispatcher.resolveCommandLine(":calc 2 + 2", inventory: inventory),
      .plugin(command: "calc", subcommand: "2", args: ["+", "2"]))
    XCTAssertEqual(NormalModeDispatcher.resolveCommandLine(":", inventory: inventory), .empty)
  }

  func testCommandLineOpenForwardsTheRestOfTheLine() {
    let inventory = NormalModeDispatcher.CommandLineInventory.core()
    func resolve(_ raw: String) -> NormalModeDispatcher.CommandLineResolution {
      NormalModeDispatcher.resolveCommandLine(raw, inventory: inventory)
    }
    // Bare `:open` needs its words.
    XCTAssertEqual(resolve("open"), .incomplete("open"))
    XCTAssertEqual(resolve("open "), .incomplete("open"))
    // Args are split on whitespace and forwarded verbatim to `open`.
    XCTAssertEqual(resolve(":open https://example.com"), .open(["https://example.com"]))
    XCTAssertEqual(resolve(":open -a Firefox file.txt"), .open(["-a", "Firefox", "file.txt"]))
    XCTAssertEqual(resolve("  open   Firefox  "), .open(["Firefox"]))
    XCTAssertEqual(resolve("opening firefox"), .unknown)
  }

  func testCommandLineCompletionsTopLevelEmptyBody() throws {
    let context = try XCTUnwrap(
      NormalModeDispatcher.commandLineCompletions(
        ":",
        pluginCommands: ["spotify", "github"],
        pluginSubcommands: ["spotify": ["play", "pause"], "github": ["prs"]]))
    XCTAssertEqual(context.prefix, ":")
    XCTAssertEqual(context.query, "")
    let labels = context.items.map(\.label)
    XCTAssertTrue(labels.contains("quit"))
    XCTAssertTrue(labels.contains("write"))
    XCTAssertTrue(labels.contains("open"), "`:open` (dumb forward to /usr/bin/open)")
    XCTAssertTrue(labels.contains("edit"), "`:e[dit]` (Cmd+O document open) is its own command")
    XCTAssertTrue(labels.contains("help"))
    XCTAssertTrue(labels.contains("flashlight"))
    XCTAssertTrue(labels.contains("spotify"))
    XCTAssertTrue(labels.contains("github"))
    XCTAssertFalse(labels.contains { $0.hasPrefix("%") })
    // Every ex spelling is listed in full, with what it runs; the shorter
    // forms are how it is typed, not rows.
    XCTAssertTrue(labels.contains("tabedit"))
    XCTAssertFalse(labels.contains("tabe"))
    XCTAssertEqual(context.items.first { $0.label == "tabedit" }?.detail, "tab new")
    XCTAssertFalse(labels.contains("copy"), "`:clipboard copy` has no ex alias")
    XCTAssertEqual(
      labels, labels.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
      "completions should be sorted alphabetically")
    let spotify = try XCTUnwrap(context.items.first { $0.label == "spotify" })
    XCTAssertEqual(spotify.insertion, "spotify ")
    XCTAssertEqual(spotify.kind, .acceptsArgs)
    let quit = try XCTUnwrap(context.items.first { $0.label == "quit" })
    XCTAssertEqual(quit.insertion, "quit")
    XCTAssertEqual(quit.kind, .terminal)
    let open = try XCTUnwrap(context.items.first { $0.label == "open" })
    XCTAssertEqual(open.insertion, "open ")
    XCTAssertEqual(open.kind, .acceptsArgs)
  }

  func testCommandLineCompletionsTopLevelWithPartialQuery() throws {
    let context = try XCTUnwrap(
      NormalModeDispatcher.commandLineCompletions(
        ":sp",
        pluginCommands: ["spotify"],
        pluginSubcommands: ["spotify": ["play"]]))
    XCTAssertEqual(context.prefix, ":")
    XCTAssertEqual(context.query, "sp")
    // `sp` is `sp[lit]` at its minimum, so the alias is selected over the
    // plugin command it also prefixes.
    XCTAssertEqual(context.items.map(\.label), ["split", "spotify"])
    XCTAssertEqual(context.selectedLabel, "split")

    let typo = try XCTUnwrap(
      NormalModeDispatcher.commandLineCompletions(
        ":helps",
        pluginCommands: ["spotify"],
        pluginSubcommands: ["spotify": ["play"]]))
    XCTAssertEqual(typo.prefix, ":")
    XCTAssertEqual(typo.query, "helps")
    XCTAssertTrue(typo.items.isEmpty)

    let exact = try XCTUnwrap(
      NormalModeDispatcher.commandLineCompletions(
        ":flashlight",
        pluginCommands: [],
        pluginSubcommands: [:]))
    XCTAssertEqual(exact.prefix, ":")
    XCTAssertEqual(exact.query, "flashlight")
    XCTAssertEqual(exact.items.map(\.label), ["flashlight"])
  }

  func testCommandLineCompletionsPluginSubcommands() throws {
    let context = try XCTUnwrap(
      NormalModeDispatcher.commandLineCompletions(
        ":spotify ",
        pluginCommands: ["spotify"],
        pluginSubcommands: ["spotify": ["play", "pause", "next"]]))
    XCTAssertEqual(context.prefix, ":spotify ")
    XCTAssertEqual(context.query, "")
    XCTAssertEqual(Set(context.items.map(\.label)), ["play", "pause", "next"])
    XCTAssertTrue(context.items.allSatisfy { $0.kind == .pluginSubcommand })
  }

  func testCommandLineCompletionsSkipBarePluginCommandRegistration() throws {
    let context = try XCTUnwrap(
      NormalModeDispatcher.commandLineCompletions(
        ":lights ",
        pluginCommands: ["lights"],
        pluginSubcommands: ["lights": ["", "on", "off", "dim"]]))
    XCTAssertEqual(context.prefix, ":lights ")
    XCTAssertEqual(context.query, "")
    XCTAssertEqual(Set(context.items.map(\.label)), ["on", "off", "dim"])
    XCTAssertFalse(context.items.contains { $0.label.isEmpty })
  }

  func testCommandLineCompletionsPluginSubcommandsWithFilter() throws {
    let context = try XCTUnwrap(
      NormalModeDispatcher.commandLineCompletions(
        ":spotify pa",
        pluginCommands: ["spotify"],
        pluginSubcommands: ["spotify": ["play", "pause", "next"]]))
    XCTAssertEqual(context.prefix, ":spotify ")
    XCTAssertEqual(context.query, "pa")
  }

  func testCommandLineCompletionsReturnsNilWhenNoMatch() {
    XCTAssertNil(
      NormalModeDispatcher.commandLineCompletions(
        ":spotify play extra",
        pluginCommands: ["spotify"],
        pluginSubcommands: ["spotify": ["play"]]))
    XCTAssertNil(
      NormalModeDispatcher.commandLineCompletions(
        ":unknown ",
        pluginCommands: ["spotify"],
        pluginSubcommands: ["spotify": ["play"]]))
    XCTAssertNil(
      NormalModeDispatcher.commandLineCompletions(
        "no colon",
        pluginCommands: [],
        pluginSubcommands: [:]))
  }

  /// `plugins reload` is a command like `plugins show`: both complete, in the
  /// order every topic's actions do.
  func testCommandLineCompletionsListThePluginsActions() throws {
    let context = try XCTUnwrap(
      NormalModeDispatcher.commandLineCompletions(
        ":plugins ",
        pluginCommands: [],
        pluginSubcommands: [:]))
    XCTAssertEqual(context.prefix, ":plugins ")
    XCTAssertEqual(context.query, "")
    XCTAssertEqual(context.items.map(\.label), ["reload", "show"])
    XCTAssertTrue(context.items.allSatisfy { $0.kind == .pluginSubcommand })
  }

  func testCommandLineCompletionsTopLevelIncludesPlugins() throws {
    let context = try XCTUnwrap(
      NormalModeDispatcher.commandLineCompletions(
        ":",
        pluginCommands: [],
        pluginSubcommands: [:]))
    let plugins = try XCTUnwrap(context.items.first { $0.label == "plugins" })
    XCTAssertEqual(plugins.insertion, "plugins ")
    XCTAssertEqual(plugins.kind, .acceptsArgs)
    XCTAssertTrue(context.items.contains { $0.label == "about" })
  }

  func testCommandLineCandidateQueryAcceptsFlashlight() {
    // `:open` is a dumb forward, not a candidate finder — it must not feed
    // the candidate query path.
    XCTAssertNil(NormalModeDispatcher.commandLineCandidateQuery(":open firefox"))
    XCTAssertNil(
      NormalModeDispatcher.commandLineCandidateQuery(":flashlight"),
      "candidate rows must wait for the command-delimiting space")
    XCTAssertEqual(NormalModeDispatcher.commandLineCandidateQuery(":flashlight "), "")
    XCTAssertEqual(
      NormalModeDispatcher.commandLineCandidateQuery(":flashlight gmail.com"), "gmail.com")
    XCTAssertEqual(
      NormalModeDispatcher.commandLineCandidateQuery(":flashlight = 10 * 10"), "= 10 * 10")
    XCTAssertEqual(
      NormalModeDispatcher.commandLineCandidateQuery(":flashlight   =10 euros + 10 euros"),
      "=10 euros + 10 euros")
    // Trailing whitespace is preserved on purpose — `parseBangState`
    // uses it as the signal that the user committed to a bang. Leading
    // whitespace + tabs between the verb and the argument are still
    // collapsed because they're syntactic, not part of the query.
    XCTAssertEqual(
      NormalModeDispatcher.commandLineCandidateQuery("  FLASHLIGHT   Slack  "), "Slack  ")
    XCTAssertNil(NormalModeDispatcher.commandLineCandidateQuery(":flashlightgmail"))
  }

  func testCommandLineBodyIsEmptyDetectsBarePrompt() {
    XCTAssertTrue(NormalModeDispatcher.commandLineBodyIsEmpty(":"))
    XCTAssertTrue(NormalModeDispatcher.commandLineBodyIsEmpty(": "))
    XCTAssertTrue(NormalModeDispatcher.commandLineBodyIsEmpty("  :  "))
    XCTAssertFalse(NormalModeDispatcher.commandLineBodyIsEmpty(":a"))
    XCTAssertFalse(NormalModeDispatcher.commandLineBodyIsEmpty(":flashlight "))
  }

  func testCommandLineMoveTargetPrefersHistoryOnEmptyPromptAndDuringRecall() {
    typealias Target = NormalModeDispatcher.CommandLineMoveTarget
    // Empty prompt recalls history even though the verb-completion list is shown.
    XCTAssertEqual(
      NormalModeDispatcher.commandLineMoveTarget(
        bodyIsEmpty: true, isRecalling: false,
        hasCandidateQuery: false, hasCompletions: true),
      Target.history)
    // An in-progress recall keeps history even when the recalled entry looks
    // like a flashlight query or a completable command, so ↑/↓ keep cycling.
    XCTAssertEqual(
      NormalModeDispatcher.commandLineMoveTarget(
        bodyIsEmpty: false, isRecalling: true,
        hasCandidateQuery: true, hasCompletions: true),
      Target.history)
    // A live flashlight query keeps the arrows on candidate selection.
    XCTAssertEqual(
      NormalModeDispatcher.commandLineMoveTarget(
        bodyIsEmpty: false, isRecalling: false,
        hasCandidateQuery: true, hasCompletions: false),
      Target.candidates)
    // A typed command with completions navigates the completion list.
    XCTAssertEqual(
      NormalModeDispatcher.commandLineMoveTarget(
        bodyIsEmpty: false, isRecalling: false,
        hasCandidateQuery: false, hasCompletions: true),
      Target.completions)
    // A typed command that matches nothing falls back to history.
    XCTAssertEqual(
      NormalModeDispatcher.commandLineMoveTarget(
        bodyIsEmpty: false, isRecalling: false,
        hasCandidateQuery: false, hasCompletions: false),
      Target.history)
  }

  func testCommandLineListTopEntersHistoryOnlyWhenMovingUpFromTop() {
    // Up (delta < 0) from the first row crosses into history.
    XCTAssertTrue(
      NormalModeDispatcher.commandLineListTopEntersHistory(delta: -1, selectedIndex: 0))
    // Up below the top stays in the list.
    XCTAssertFalse(
      NormalModeDispatcher.commandLineListTopEntersHistory(delta: -1, selectedIndex: 3))
    // Down never crosses into history from the list.
    XCTAssertFalse(
      NormalModeDispatcher.commandLineListTopEntersHistory(delta: 1, selectedIndex: 0))
  }

  func testCandidateFinderQueryParsesAtTypeNarrow() {
    // `@<type>` is the only filter syntax — narrows the pool to one resource
    // type and leaves the residual text as the actual fuzzy query.
    let parsed = NormalModeDispatcher.candidateFinderQuery("@tabs github repo")
    XCTAssertEqual(parsed.scope, .type("tabs"))
    XCTAssertEqual(parsed.text, "github repo")

    let none = NormalModeDispatcher.candidateFinderQuery("github repo")
    XCTAssertNil(none.scope)
    XCTAssertEqual(none.text, "github repo")

    let bareDoubleDash = NormalModeDispatcher.candidateFinderQuery("--notes inbox")
    XCTAssertNil(bareDoubleDash.scope)
    XCTAssertEqual(bareDoubleDash.text, "--notes inbox")
  }

  func testFlashlightAliasExpansionRequiresWordBoundaryAndTrailingWhitespace() {
    let aliases = [
      "!g": "!google",
      "@ft": "@tabs",
      "gh": "!github",
    ]

    XCTAssertNil(
      CandidateFinder.expandFlashlightAlias(
        text: ":flashlight !g", cursorIndex: 14, aliases: aliases),
      "alias should not expand until the user types whitespace")
    XCTAssertNil(
      CandidateFinder.expandFlashlightAlias(
        text: ":flashlight big ", cursorIndex: 16, aliases: aliases),
      "alias keys are whole words, not suffix matches")

    let bare = CandidateFinder.expandFlashlightAlias(
      text: ":flashlight gh ", cursorIndex: 15, aliases: aliases)
    XCTAssertEqual(bare?.text, ":flashlight !github ")
    XCTAssertEqual(bare?.cursorIndex, 20)

    let source = CandidateFinder.expandFlashlightAlias(
      text: ":flashlight @ft inbox", cursorIndex: 16, aliases: aliases)
    XCTAssertEqual(source?.text, ":flashlight @tabs inbox")
    XCTAssertEqual(source?.cursorIndex, 18)
  }

  func testFuzzyScoreMatchesOrderedCharacters() {
    XCTAssertNotNil(NormalModeDispatcher.fuzzyScore(query: "ff", candidate: "Firefox"))
    XCTAssertNotNil(NormalModeDispatcher.fuzzyScore(query: "alc", candidate: "Alacritty"))
    XCTAssertNotNil(NormalModeDispatcher.fuzzyScore(query: "firfox", candidate: "Firefox"))
    XCTAssertNotNil(NormalModeDispatcher.fuzzyScore(query: "slak", candidate: "Slack"))
    XCTAssertNotNil(NormalModeDispatcher.fuzzyScore(query: "pstico", candidate: "Postico 2"))
    XCTAssertNil(NormalModeDispatcher.fuzzyScore(query: "fx", candidate: "Safari"))

    let compact = NormalModeDispatcher.fuzzyScore(query: "saf", candidate: "Safari") ?? 0
    let spread =
      NormalModeDispatcher.fuzzyScore(query: "saf", candidate: "System Settings Safari") ?? 0
    XCTAssertGreaterThan(compact, spread)
  }

  func testFuzzyScoreMatchesHashPrefixedCandidateByName() {
    let candidate = CandidateFinder.prepare(
      Candidate(
        kind: .plugin("project"),
        sourceID: "projects",
        source: "projects",
        pid: 123,
        title: "#schedule",
        subtitle: "Project location",
        bundleIdentifier: "com.example.projects"))

    XCTAssertEqual(candidate.normalizedSearchText, "projects #schedule project location")
    XCTAssertNotNil(
      NormalModeDispatcher.fuzzyScore(
        normalizedQuery: NormalModeDispatcher.normalizedSearchText("#schedule"),
        normalizedCandidate: candidate.normalizedSearchText))
    XCTAssertNotNil(
      NormalModeDispatcher.fuzzyScore(
        normalizedQuery: NormalModeDispatcher.normalizedSearchText("schedule"),
        normalizedCandidate: candidate.normalizedSearchText))
  }

  func testFuzzyHighlightRangesUseVisibleTitleCharacters() {
    XCTAssertEqual(
      NormalModeDispatcher.fuzzyHighlightRanges(query: "fire", candidate: "Firefox"),
      [0..<4])
    XCTAssertEqual(
      NormalModeDispatcher.fuzzyHighlightRanges(query: "slak", candidate: "Slack"),
      [0..<3, 4..<5])
    XCTAssertEqual(
      NormalModeDispatcher.fuzzyHighlightRanges(query: "tm 2", candidate: "tmux work:2 server"),
      [0..<2, 10..<11])
  }

  func testCandidateFinderDisplayTitleIncludesSourceName() {
    XCTAssertEqual(
      AppDelegate.candidateFinderDisplayTitle(source: "tmux", title: "scratch gors"),
      "[tmux] scratch gors")
    XCTAssertEqual(
      AppDelegate.candidateFinderDisplayTitle(source: "firefox", title: "Gmail"),
      "[firefox] Gmail")
  }

  func testCandidateFinderMergeKeepsRunningAppOverInstalledBundle() {
    let installed = candidateFinderCandidate(
      name: "Firefox",
      pid: nil,
      bundleIdentifier: "org.mozilla.firefox",
      path: "/Applications/Firefox.app")
    let running = candidateFinderCandidate(
      name: "Firefox",
      pid: 123,
      bundleIdentifier: "org.mozilla.firefox",
      path: "/Applications/Firefox.app")

    let merged = CandidateFinder.mergeAppCandidates(running: [running], installed: [installed])

    XCTAssertEqual(merged.count, 1)
    XCTAssertEqual(merged[0].pid, 123)
    XCTAssertEqual(merged[0].url?.path, "/Applications/Firefox.app")
  }

  func testIgnoredAppMatcherMatchesCommonAppIdentifiers() {
    let flash = candidateFinderCandidate(
      name: "Flash",
      pid: nil,
      bundleIdentifier: "com.flash.app",
      path: "/Applications/Flash.app")
    let titledDifferently = candidateFinderCandidate(
      name: "Flash Helper",
      pid: nil,
      bundleIdentifier: "com.example.helper",
      path: "/Applications/Flash.app")

    XCTAssertTrue(IgnoredAppMatcher(["Flash"]).contains(flash))
    XCTAssertTrue(IgnoredAppMatcher(["flash"]).contains(flash))
    XCTAssertTrue(IgnoredAppMatcher(["com.flash.app"]).contains(flash))
    XCTAssertTrue(IgnoredAppMatcher(["/Applications/Flash.app"]).contains(flash))
    XCTAssertTrue(IgnoredAppMatcher(["Flash.app"]).contains(flash))
    XCTAssertTrue(IgnoredAppMatcher(["Flash"]).contains(titledDifferently))
    XCTAssertFalse(IgnoredAppMatcher(["Messages"]).contains(flash))
  }

  func testCandidateFinderPrepareBuildsDisplayAndSearchText() {
    let prepared = CandidateFinder.prepare(
      candidateFinderCandidate(
        name: "Postico 2",
        pid: nil,
        bundleIdentifier: "com.eggerapps.Postico",
        path: "/Applications/Postico 2.app"))

    XCTAssertEqual(prepared.displayTitle, "[core.apps] Postico 2")
    XCTAssertEqual(
      prepared.normalizedSearchText,
      "core apps postico 2 app postico 2 com eggerapps postico")
  }

  func testCandidateFinderPreparedBrowserTabIncludesBrowserTitleAndURL() {
    let prepared = CandidateFinder.prepare(
      Candidate(
        kind: .plugin("browser_tab"),
        sourceID: "firefox-tabs",
        source: "firefox",
        pid: 123,
        title: "Gmail",
        subtitle: "browser tab",
        bundleIdentifier: "org.mozilla.firefox",
        url: URL(string: "https://mail.google.com/mail/u/0/#inbox")))

    XCTAssertEqual(
      prepared.displayTitle, "[firefox] Gmail · https://mail.google.com/mail/u/0/#inbox")
    XCTAssertEqual(prepared.source, "firefox")
    XCTAssertEqual(prepared.title, "Gmail")
    XCTAssertEqual(prepared.url?.absoluteString, "https://mail.google.com/mail/u/0/#inbox")
    XCTAssertNotNil(
      NormalModeDispatcher.fuzzyScore(
        normalizedQuery: NormalModeDispatcher.normalizedSearchText("firefox inbox"),
        normalizedCandidate: prepared.normalizedSearchText))
  }

  func testCandidateFinderPreparedTmuxWindowMatchesSourcePrefixedQuery() {
    let prepared = CandidateFinder.prepare(
      Candidate(
        kind: .plugin("tmux_window"),
        sourceID: "tmux",
        source: "tmux",
        pid: 123,
        title: "beside-agentic",
        subtitle: "beside:1 · claude · ~/workspace/beside",
        bundleIdentifier: ""))

    XCTAssertEqual(
      prepared.displayTitle,
      "[tmux] beside-agentic · beside:1 · claude · ~/workspace/beside")
    XCTAssertNotNil(
      NormalModeDispatcher.fuzzyScore(
        normalizedQuery: NormalModeDispatcher.normalizedSearchText("tmux agentic"),
        normalizedCandidate: prepared.normalizedSearchText))
  }

  /// A terminal writes an unbound Command chord's base character to the pty,
  /// so NORMAL refuses to synthesize one: `n` (find next, cmd+g) must never
  /// type a `g` into the shell.
  func testTerminalTargetsRefuseCommandChordsTheEmulatorWouldType() {
    func unsafe(_ key: Int, _ flags: CGEventFlags, declared: Bool = false) -> Bool {
      AppDelegate.commandChordTypesTextInTerminal(key: CGKeyCode(key), flags: flags) { declared }
    }
    // The reported bug: `n` / `N` resolve to cmd+g / cmd+shift+g, which no
    // terminal binds.
    XCTAssertTrue(unsafe(kVK_ANSI_G, .maskCommand))
    XCTAssertTrue(unsafe(kVK_ANSI_G, [.maskCommand, .maskShift]))
    // Undo/redo stay refused, as they were before the gate became chord-shaped.
    XCTAssertTrue(unsafe(kVK_ANSI_Z, .maskCommand))
    XCTAssertTrue(unsafe(kVK_ANSI_Z, [.maskCommand, .maskShift]))
    // Cut and the window-cycle backtick are unbound in terminals too.
    XCTAssertTrue(unsafe(kVK_ANSI_X, .maskCommand))
    XCTAssertTrue(unsafe(kVK_ANSI_Grave, .maskCommand))
    // Chords every emulator binds still go through.
    for key in [kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_T, kVK_ANSI_N, kVK_ANSI_F, kVK_ANSI_3]
    {
      XCTAssertFalse(unsafe(key, .maskCommand), "cmd chord \(key)")
    }
    // Shift-bracket is the macOS tab traversal; the bare brackets are split
    // traversal only where a plugin declares them for the emulator.
    XCTAssertFalse(unsafe(kVK_ANSI_LeftBracket, [.maskCommand, .maskShift]))
    XCTAssertTrue(unsafe(kVK_ANSI_RightBracket, .maskCommand))
    XCTAssertFalse(unsafe(kVK_ANSI_RightBracket, .maskCommand, declared: true))
    // Unmodified keys and chords without Command are never gated; the Firefox
    // reorder chord carries no Command.
    XCTAssertFalse(unsafe(kVK_ANSI_G, []))
    XCTAssertFalse(unsafe(kVK_ANSI_G, .maskControl))
    XCTAssertFalse(unsafe(kVK_PageDown, [.maskControl, .maskShift]))
  }

  func testUIKitAppsGetEachChordWithItsModifierPresses() {
    XCTAssertTrue(UIKitApps.hostsUIKit(infoDictionary: ["UIDeviceFamily": [2]]))
    XCTAssertFalse(
      UIKitApps.hostsUIKit(infoDictionary: ["CFBundleIdentifier": "org.mozilla.firefox"]))
    XCTAssertEqual(
      UIKitApps.modifierKeys(in: [.maskCommand, .maskShift]).map(\.key),
      [CGKeyCode(kVK_Shift), CGKeyCode(kVK_Command)])
    XCTAssertEqual(
      UIKitApps.modifierKeys(in: [.maskControl, .maskAlternate]).map(\.key),
      [CGKeyCode(kVK_Control), CGKeyCode(kVK_Option)])
    XCTAssertTrue(UIKitApps.modifierKeys(in: [.maskSecondaryFn, .maskNumericPad]).isEmpty)
  }

  func testTerminalTargetsKeepTheirExistingPixelWheelFallbackPolicy() {
    XCTAssertTrue(TerminalEmulatorFixture.official.contains("org.alacritty"))
    for bundle in TerminalEmulatorFixture.official {
      XCTAssertTrue(
        NormalModeDispatcher.pixelWheelSynthesisIsUnsafeInTerminal(bundleIdentifier: bundle), bundle
      )
    }
    for bundle in ["org.mozilla.firefox", "com.tinyspeck.slackmacgap", ""] {
      XCTAssertFalse(
        NormalModeDispatcher.pixelWheelSynthesisIsUnsafeInTerminal(bundleIdentifier: bundle), bundle
      )
    }
  }

  func testHorizontalAndEdgeScrollsDoNotPostPixelWheelEventsIntoTerminals() {
    let restore = NormalModeDispatcher.wheelEventPoster
    defer { NormalModeDispatcher.wheelEventPoster = restore }
    var continuous: [Int64] = []
    NormalModeDispatcher.wheelEventPoster = {
      continuous.append($0.getIntegerValueField(.scrollWheelEventIsContinuous))
    }
    let pid = ProcessInfo.processInfo.processIdentifier
    let frame = CGRect(x: 0, y: 0, width: 1200, height: 900)
    for kind in [
      NormalModeDispatcher.ScrollKind.top, .bottom, .left, .right,
    ] {
      _ = NormalModeDispatcher.scroll(kind, pid: pid, bundleID: "org.alacritty", windowFrame: frame)
    }
    // Only the edges' bounded line scrolls; no pixel wheel reaches a terminal.
    XCTAssertEqual(continuous, [0, 0])
  }

  func testMappingRowsListResolvedScopesAndLeaderMappings() {
    var config = Config.default
    config.mode.all = [
      ModeMapping(
        key: "cmd+space",
        action: .flashCommand(.enterCommand(input: "flashlight ", restoreMode: false)))
    ]
    config.mode.normal = [
      ModeMapping(key: "\\c", action: .shellCommand(["sh", "/tmp/toggle_caffeinate.sh"]))
    ]
    config.mode.insert = [
      ModeMapping(
        key: "ctrl+space",
        action: .flashCommand(.mouseTarget(.click(.leftClick, modifiers: []))))
    ]
    let rows = NormalModeDispatcher.mappingsJSON(mode: config.mode)
    let row = { (scope: String, key: String) in
      rows.first { $0["scope"] == scope && $0["key"] == key }
    }
    XCTAssertNotNil(row("all", "cmd+<space>"))
    XCTAssertEqual(row("normal", "\\c")?["action"], "[\"sh\", \"/tmp/toggle_caffeinate.sh\"]")
    XCTAssertNotNil(row("insert", "ctrl+<space>"))
  }

  func testMappingRowsDisplayNamedKeySequencesAsAtoms() {
    var config = Config.default
    config.mode.normalLeader = "<space>"
    config.mode.all = [
      ModeMapping(
        key: "cmd+space",
        action: .flashCommand(.enterCommand(input: "flashlight ", restoreMode: false)))
    ]
    config.mode.normal = [
      ModeMapping(key: "cmd+right", action: .flashCommand(.scroll(.down))),
      ModeMapping(key: key("<space>m"), action: .shellCommand(["sh", "/tmp/toggle_mute.sh"])),
      ModeMapping(key: key("<space>s"), action: .shellCommand(["sh", "/tmp/toggle_sleep.sh"])),
      ModeMapping(key: key("<space>w"), action: .shellCommand(["sh", "/tmp/toggle_wifi.sh"])),
      ModeMapping(
        key: key("\\<space>"),
        action: .flashCommand(.enterCommand(input: "flashlight ", restoreMode: false))),
      ModeMapping(key: "tab", action: .flashCommand(.movementForward)),
    ]
    let text = NormalModeDispatcher.mappingsJSON(mode: config.mode).compactMap { $0["key"] }
      .joined(separator: "\n")

    XCTAssertTrue(text.contains("<space>m"))
    XCTAssertTrue(text.contains("<space>s"))
    XCTAssertTrue(text.contains("<space>w"))
    XCTAssertTrue(text.contains("\\<space>"))
    XCTAssertTrue(text.contains("cmd+<space>"))
    XCTAssertTrue(text.contains("cmd+<right>"))
    XCTAssertTrue(text.contains("<tab>"))
    XCTAssertFalse(text.contains("spacem"))
    XCTAssertFalse(text.contains("spaces"))
    XCTAssertFalse(text.contains("spacew"))
  }

  func testConfiguredMappingsOverrideDefaults() {
    let mappings = [
      ModeMapping(key: "j", action: .flashCommand(.scroll(.up))),
      ModeMapping(key: key("zz"), action: .flashCommand(.reload(force: false))),
      ModeMapping(key: "tab", action: .flashCommand(.movementForward)),
      ModeMapping(key: "delete_forward", action: .flashCommand(.scroll(.halfPageDown))),
    ]
    XCTAssertEqual(command(chars: "j", mappings: mappings), .scroll(.up))
    XCTAssertEqual(transition(chars: "z", mappings: mappings).pending, "z")
    XCTAssertEqual(command(pending: "z", chars: "z", mappings: mappings), .reload(force: false))
    XCTAssertEqual(
      transition(keyCode: kVK_Tab, chars: "\t", mappings: mappings).command,
      .movementForward)
    XCTAssertEqual(
      transition(keyCode: kVK_ForwardDelete, chars: "", mappings: mappings).command,
      .scroll(.halfPageDown))
  }

  // MARK: - Yank / paste registers

  func testBareYankAndPasteUseTheUnnamedRegister() {
    XCTAssertEqual(command(chars: "p"), .paste(register: nil))
    let yanked = transition(chars: "y")
    XCTAssertEqual(yanked.command, .yankSelection(register: nil))
    XCTAssertEqual(yanked.pending, "")
  }

  func testRegisterPrefixRoutesPasteToANamedRegister() {
    let quote = transition(chars: "\"")
    XCTAssertNil(quote.command)
    XCTAssertEqual(quote.pending, "\"")
    let named = transition(pending: quote.pending, chars: "a")
    XCTAssertEqual(named.pending, "\"a")
    XCTAssertEqual(
      transition(pending: named.pending, chars: "p").command,
      .paste(register: "a"))
  }

  func testRegisterPrefixRoutesYankToANamedRegisterImmediately() {
    let named = transition(pending: "\"", chars: "a")
    let yanked = transition(pending: named.pending, chars: "y")
    XCTAssertEqual(yanked.command, .yankSelection(register: "a"))
    XCTAssertEqual(yanked.pending, "")
  }

  func testRegisterPrefixRoutesDragCopyAndPasteToNamedRegisters() {
    let mappings = Config.default.mode.hold
    XCTAssertEqual(
      command(pending: "\"a", chars: "y", mappings: mappings),
      .selection(.copy, register: "a"))
    XCTAssertEqual(
      command(pending: "\"a", chars: "p", mappings: mappings),
      .selection(.paste, register: "a"))
  }

  func testRegisterPrefixRoutesDragCopyToNamedRegister() {
    XCTAssertEqual(
      command(pending: "\"a", chars: "y", mappings: Config.default.mode.hold),
      .selection(.copy, register: "a"))
  }

  func testRegisterNameDigitIsNotMistakenForACount() {
    // `"1p` is register 1, not a one-times paste — the leading `"` disambiguates.
    let named = transition(pending: "\"", chars: "1")
    XCTAssertEqual(named.pending, "\"1")
    XCTAssertEqual(
      transition(pending: named.pending, chars: "p").command,
      .paste(register: "1"))
  }

  func testClipboardSynonymRegisterIsCaptured() {
    let named = transition(pending: "\"", chars: "+")
    XCTAssertEqual(named.pending, "\"+")
    XCTAssertEqual(
      transition(pending: named.pending, chars: "p").command,
      .paste(register: "+"))
  }

  func testRegisterPrefixIsSuppressedWhenQuoteIsMapped() {
    // A user who binds `"` keeps their mapping; register prefixing steps aside.
    let mappings = [ModeMapping(key: "\"", action: .flashCommand(.scroll(.up)))]
    XCTAssertEqual(command(chars: "\"", mappings: mappings), .scroll(.up))
  }

  func testRegisterStoreNamedBufferRoundTrips() {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let store = RegisterStore(pasteboard: pasteboard)
    store.write("hello", register: "a")
    XCTAssertEqual(store.read(register: "a"), "hello")
    // A different register is independent.
    XCTAssertNil(store.read(register: "b"))
  }

  func testRegisterStoreUppercaseNameAppends() {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let store = RegisterStore(pasteboard: pasteboard)
    store.write("foo", register: "a")
    store.write("bar", register: "A")
    XCTAssertEqual(store.read(register: "a"), "foobar")
    // Reads are case-insensitive.
    XCTAssertEqual(store.read(register: "A"), "foobar")
  }

  func testRegisterStoreRecognizesSystemClipboardSynonyms() {
    XCTAssertTrue(RegisterStore.isSystemClipboard(nil))
    XCTAssertTrue(RegisterStore.isSystemClipboard("+"))
    XCTAssertTrue(RegisterStore.isSystemClipboard("*"))
    XCTAssertTrue(RegisterStore.isSystemClipboard("\""))
    XCTAssertFalse(RegisterStore.isSystemClipboard("a"))
  }

  func testYankRegistersFollowVimNumberedAndUnnamedRules() {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let store = RegisterStore(pasteboard: pasteboard)

    store.write("first", register: nil)
    XCTAssertEqual(store.read(register: "0"), "first")
    XCTAssertEqual(store.read(register: nil), "first")

    // A named yank writes its register alone, as Vim's `unnamedplus`.
    store.write("second", register: "a")
    XCTAssertEqual(store.read(register: "0"), "first")
    XCTAssertEqual(store.read(register: "a"), "second")
    XCTAssertEqual(store.read(register: nil), "first")

    store.write(" more", register: "A")
    XCTAssertEqual(store.read(register: "a"), "second more")
    XCTAssertEqual(store.read(register: nil), "first")
    XCTAssertEqual(store.read(register: "0"), "first")

    store.write("discarded", register: "_")
    XCTAssertEqual(store.read(register: nil), "first")
    XCTAssertNil(store.read(register: "_"))
    XCTAssertEqual(store.snapshot().first?.name, "\"")
    XCTAssertTrue(
      store.snapshot().contains(.init(name: "0", text: "first", kind: "yank", truncated: false)))
  }

  func testBlackHoleRegisterPrefixIsCaptured() {
    let named = transition(pending: "\"", chars: "_")
    XCTAssertEqual(named.pending, "\"_")
    XCTAssertEqual(
      transition(pending: named.pending, chars: "y").command,
      .yankSelection(register: "_"))
  }

  func testRegisterSnapshotBoundsInspectorPayloadWithoutTruncatingPaste() {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let store = RegisterStore(pasteboard: pasteboard)
    let text = String(repeating: "a", count: 16 * 1024 + 10)
    store.write(text, register: "b")
    XCTAssertEqual(store.read(register: "b"), text)
    let entry = store.snapshot().first { $0.name == "b" }
    XCTAssertEqual(entry?.text.utf8.count, 16 * 1024)
    XCTAssertEqual(entry?.truncated, true)
  }

  func testCommandModifiedMappingsDispatchConfiguredActionsInNormalMode() {
    let mappings = [
      ModeMapping(key: "cmd+delete", action: .flashCommand(.scroll(.halfPageUp))),
      ModeMapping(key: "cmd+tab", action: .flashCommand(.movementForward)),
    ]
    XCTAssertEqual(
      transition(
        keyCode: kVK_Delete,
        chars: "\u{7F}",
        flags: [.command],
        mappings: mappings
      ).command,
      .scroll(.halfPageUp))
    XCTAssertEqual(
      transition(
        keyCode: kVK_Tab,
        chars: "\t",
        flags: [.command],
        mappings: mappings
      ).command,
      .movementForward)
  }

  func testModifiedMappingsParticipateInNormalModeSequences() {
    let action = MappingCommand.shellCommand(["sh", "/tmp/chord-prefix"])
    let mappings = [
      ModeMapping(key: key("cmd+kx"), action: action),
      ModeMapping(key: key("cmd+shift+]"), action: .flashCommand(.tabNext)),
      ModeMapping(key: key("ctrl+<space>"), action: .flashCommand(.commandMode)),
    ]

    let prefix = transition(
      keyCode: kVK_ANSI_K,
      chars: "k",
      flags: [.command],
      mappings: mappings)
    XCTAssertEqual(prefix.pending, "cmd+k")
    XCTAssertNil(prefix.action)

    let resolved = transition(
      pending: prefix.pending,
      keyCode: kVK_ANSI_X,
      chars: "x",
      mappings: mappings)
    XCTAssertEqual(resolved.action, action)
    XCTAssertEqual(resolved.pending, "")

    XCTAssertEqual(
      transition(
        keyCode: kVK_ANSI_RightBracket,
        chars: "}",
        flags: [.command, .shift],
        mappings: mappings
      ).command,
      .tabNext)
    XCTAssertEqual(
      transition(
        keyCode: kVK_Space,
        chars: " ",
        flags: [.control],
        mappings: mappings
      ).command,
      .commandMode)
  }

  func testShiftOnlyStillPrefersTypedCharacters() {
    XCTAssertEqual(command(chars: "G", ignoring: "g", flags: [.shift]), .move(.bottom))
    XCTAssertEqual(command(chars: "?", ignoring: "/", flags: [.shift]), .showMappings)
  }

  func testConfiguredShellMappingsProduceActions() {
    let action = MappingCommand.shellCommand(["sh", "~/bin/toggle-colors"])
    let mappings = [
      ModeMapping(key: key("zz"), action: action)
    ]
    let first = transition(chars: "z", mappings: mappings)
    XCTAssertEqual(first.pending, "z")
    let second = transition(pending: "z", chars: "z", mappings: mappings)
    XCTAssertEqual(second.action, action)
    XCTAssertNil(second.command)
  }

  func testQuoteAppChordsCanBeChainedAsFreshNormalModeSequences() {
    let mappings = [
      ModeMapping(key: key("'a"), action: .flashCommand(.openApp(name: "Alacritty"))),
      ModeMapping(key: key("'s"), action: .flashCommand(.openApp(name: "Slack"))),
    ]

    let firstPrefix = transition(chars: "'", mappings: mappings)
    XCTAssertEqual(firstPrefix.pending, "'")
    let firstAction = transition(pending: firstPrefix.pending, chars: "a", mappings: mappings)
    XCTAssertEqual(firstAction.command, .openApp(name: "Alacritty"))
    XCTAssertEqual(firstAction.pending, "")

    let secondPrefix = transition(pending: firstAction.pending, chars: "'", mappings: mappings)
    XCTAssertEqual(secondPrefix.pending, "'")
    let secondAction = transition(pending: secondPrefix.pending, chars: "s", mappings: mappings)
    XCTAssertEqual(secondAction.command, .openApp(name: "Slack"))
    XCTAssertEqual(secondAction.pending, "")
  }

  func testFocusChangingNormalModeActions() {
    XCTAssertTrue(
      AppDelegate.normalModeActionMayChangeKeyboardFocus(
        .flashCommand(.openApp(name: "Alacritty"))))
    XCTAssertTrue(
      AppDelegate.normalModeActionMayChangeKeyboardFocus(.shellCommand(["open", "-a", "Slack"])))
    XCTAssertTrue(AppDelegate.normalModeCommandMayChangeKeyboardFocus(.appNext))
    XCTAssertTrue(AppDelegate.normalModeCommandMayChangeKeyboardFocus(.movementBack))
    XCTAssertTrue(AppDelegate.normalModeCommandMayChangeKeyboardFocus(.windowState(.minimize)))
    XCTAssertTrue(
      AppDelegate.normalModeCommandMayChangeKeyboardFocus(
        .sendKey(keys: "down", keyCode: CGKeyCode(kVK_DownArrow), flagsRawValue: 0)))
    XCTAssertTrue(
      AppDelegate.normalModeCommandMayChangeKeyboardFocus(
        .sendKeys(
          keys: "g,i", keyCodes: [CGKeyCode(kVK_ANSI_G), CGKeyCode(kVK_ANSI_I)],
          flagsRawValues: [0, 0])))
    XCTAssertFalse(
      AppDelegate.normalModeCommandMayChangeKeyboardFocus(.arrow(direction: .down, shift: false)))
    XCTAssertFalse(AppDelegate.normalModeCommandMayChangeKeyboardFocus(.functionKey(1)))
    XCTAssertFalse(AppDelegate.normalModeCommandMayChangeKeyboardFocus(.scroll(.down)))
    XCTAssertFalse(AppDelegate.normalModeCommandMayChangeKeyboardFocus(.reload(force: false)))
    XCTAssertFalse(
      AppDelegate.normalModeCommandMayChangeKeyboardFocus(
        .sendKey(
          keys: "cmd+f", keyCode: CGKeyCode(kVK_ANSI_F),
          flagsRawValue: CGEventFlags.maskCommand.rawValue)))
  }

  /// Hyper arrows used to go out through `postToPid`. That event has no
  /// window, and a terminal drops it while the hyper key is still down.
  /// Volume kept working because it is not a key event. The stroke now
  /// targets the key window, past the session tap, with the synthetic tag
  /// and the shift flag intact.
  func testFocusedKeyReachesTheKeyWindowPastTheSessionTap() throws {
    let restore = NormalModeDispatcher.focusedKeyPoster
    defer { NormalModeDispatcher.focusedKeyPoster = restore }
    var posted: [CGEvent] = []
    NormalModeDispatcher.focusedKeyPoster = { posted.append($0) }
    XCTAssertTrue(
      NormalModeDispatcher.sendFocusedKey(
        virtualKey: CGKeyCode(kVK_DownArrow), flags: .maskShift))
    XCTAssertEqual(posted.map(\.type), [.keyDown, .keyUp])
    for event in posted {
      XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), Int64(kVK_DownArrow))
      XCTAssertEqual(event.flags, .maskShift)
      XCTAssertEqual(
        event.getIntegerValueField(.eventSourceUserData),
        NormalModeDispatcher.syntheticKeyEventTag)
    }
    let delivered = try XCTUnwrap(NSEvent(cgEvent: posted[0]))
    XCTAssertEqual(delivered.keyCode, UInt16(kVK_DownArrow))
    XCTAssertEqual(delivered.characters, String(UnicodeScalar(NSDownArrowFunctionKey)!))
  }

  func testUnmodifiedNormalModeKeyDispatchRequiresTargetActivation() {
    XCTAssertTrue(AppDelegate.normalModeKeyDispatchNeedsTargetActivation(flags: []))
    XCTAssertFalse(AppDelegate.normalModeKeyDispatchNeedsTargetActivation(flags: .maskCommand))
    XCTAssertFalse(AppDelegate.normalModeKeyDispatchNeedsTargetActivation(flags: .maskControl))
    XCTAssertFalse(AppDelegate.normalModeKeyDispatchNeedsTargetActivation(flags: .maskAlternate))
    XCTAssertFalse(AppDelegate.normalModeKeyDispatchNeedsTargetActivation(flags: .maskShift))
  }

  func testNormalModeKeyDispatchPrefersActiveVisibleNativeWindow() {
    XCTAssertTrue(
      AppDelegate.normalModeKeyDispatchUsesCurrentProcess(
        applicationIsActive: true,
        hasVisibleNonOverlayKeyWindow: true))
    XCTAssertFalse(
      AppDelegate.normalModeKeyDispatchUsesCurrentProcess(
        applicationIsActive: false,
        hasVisibleNonOverlayKeyWindow: true))
    XCTAssertFalse(
      AppDelegate.normalModeKeyDispatchUsesCurrentProcess(
        applicationIsActive: true,
        hasVisibleNonOverlayKeyWindow: false))
  }

  func testNormalModeActionDispatchRecapturesOnlyForIdleNormalSurfaces() {
    XCTAssertTrue(
      AppDelegate.normalModeShouldOwnKeyboardInput(
        mode: .normal,
        overlayInputMode: .normal,
        hasHints: false,
        activationInFlight: false))
    XCTAssertTrue(
      AppDelegate.normalModeShouldOwnKeyboardInput(
        mode: .normal,
        overlayInputMode: .hints,
        hasHints: false,
        activationInFlight: false))
    XCTAssertFalse(
      AppDelegate.normalModeShouldOwnKeyboardInput(
        mode: .insert,
        overlayInputMode: .normal,
        hasHints: false,
        activationInFlight: false))
    XCTAssertFalse(
      AppDelegate.normalModeShouldOwnKeyboardInput(
        mode: .normal,
        overlayInputMode: .commandLine,
        hasHints: false,
        activationInFlight: false))
    XCTAssertFalse(
      AppDelegate.normalModeShouldOwnKeyboardInput(
        mode: .normal,
        overlayInputMode: .normal,
        hasHints: true,
        activationInFlight: false))
    XCTAssertFalse(
      AppDelegate.normalModeShouldOwnKeyboardInput(
        mode: .normal,
        overlayInputMode: .normal,
        hasHints: false,
        activationInFlight: true))
  }

  func testSpaceTokenCanBeUsedInNormalModeSequences() {
    let mappings = [
      ModeMapping(key: key("<space>c"), action: .flashCommand(.reload(force: false)))
    ]
    let first = transition(keyCode: kVK_Space, chars: " ", mappings: mappings)
    XCTAssertEqual(first.pending, "space")
    XCTAssertEqual(
      transition(pending: "space", chars: "c", mappings: mappings).command,
      .reload(force: false))
  }

  func testSpaceLeaderShellMappingDoesNotWaitOnSpaceLeaderSpaceMapping() {
    let action = MappingCommand.shellCommand(["sh", "/tmp/toggle_sleep.sh"])
    let mappings = [
      ModeMapping(key: key("<space>s"), action: action),
      ModeMapping(
        key: key("<space><space>"),
        action: .flashCommand(.enterCommand(input: "flashlight ", restoreMode: false))),
    ]

    let first = transition(keyCode: kVK_Space, chars: " ", mappings: mappings)
    XCTAssertEqual(first.pending, "space")
    let second = transition(pending: first.pending, chars: "s", mappings: mappings)
    XCTAssertEqual(second.action, action)
    XCTAssertEqual(second.pending, "")
  }

  func testBackslashLeaderShellMappingProducesAction() {
    let action = MappingCommand.shellCommand(["sh", "/tmp/toggle"])
    let mappings = [
      ModeMapping(key: key("\\c"), action: action),
      ModeMapping(
        key: key("\\<space>"),
        action: .flashCommand(.enterCommand(input: "flashlight ", restoreMode: false))),
    ]
    let first = transition(chars: "\\", mappings: mappings)
    XCTAssertEqual(first.pending, "\\")
    let second = transition(pending: "\\", chars: "c", mappings: mappings)
    XCTAssertEqual(second.action, action)
  }

  func testShiftHyperNumberRowSendsFunctionKeys() {
    let mappings = Config.Mode.defaultHyperMappings
    let f1 = transition(
      keyCode: 0x12, chars: "!", ignoring: "1", flags: [.shift], mappings: mappings)
    XCTAssertEqual(f1.command, .functionKey(1))
    let f10 = transition(
      keyCode: 0x1D, chars: ")", ignoring: "0", flags: [.shift], mappings: mappings)
    XCTAssertEqual(f10.command, .functionKey(10))
    let f12 = transition(
      keyCode: 0x18, chars: "+", ignoring: "=", flags: [.shift], mappings: mappings)
    XCTAssertEqual(f12.command, .functionKey(12))
    let volume = transition(keyCode: 0x18, chars: "=", mappings: mappings)
    XCTAssertEqual(volume.command, .systemKey(.volumeUp))
  }

  func testAMappedDigitRunsInsteadOfStartingACount() {
    let mute = MappingCommand.flashCommand(.systemKey(.mute))
    let brightness = MappingCommand.flashCommand(.systemKey(.brightnessDown))
    let mappings = [
      ModeMapping(key: "0", action: mute),
      ModeMapping(key: "1", action: brightness),
    ]
    let zero = transition(chars: "0", mappings: mappings)
    XCTAssertEqual(zero.action, mute)
    XCTAssertEqual(zero.pending, "")
    let one = transition(chars: "1", mappings: mappings)
    XCTAssertEqual(one.action, brightness)
    let count = transition(chars: "1")
    XCTAssertNil(count.command)
    XCTAssertEqual(count.pending, "1")
    let bareZero = transition(chars: "0")
    XCTAssertNil(bareZero.command)
    XCTAssertEqual(bareZero.pending, "")
  }

  /// Escape is NORMAL's `app cancel`: the app's own Escape, and NORMAL stays.
  func testEscapeAsksTheAppToCancelWithoutLeavingNormalMode() {
    let t = NormalModeInterpreter.interpret(
      pending: "",
      keyCode: 53,
      modifierFlags: [],
      characters: nil,
      charactersIgnoringModifiers: nil,
      mappings: CompiledMappings(Config.Mode.defaultNormalMappings))
    XCTAssertEqual(t.command, .appCancel)
    XCTAssertEqual(t.pending, "")
  }

  func testEscapeClearsPendingSequence() {
    let t = NormalModeInterpreter.interpret(
      pending: "2g",
      keyCode: 53,
      modifierFlags: [],
      characters: nil,
      charactersIgnoringModifiers: nil,
      mappings: CompiledMappings(Config.Mode.defaultNormalMappings))
    XCTAssertNil(t.command)
    XCTAssertEqual(t.pending, "")
  }

  func testInstantScrollValueAdjustsByFractionAndClamps() {
    XCTAssertEqual(
      NormalModeDispatcher.adjustedScrollValue(
        current: 50, lower: 0, upper: 100, deltaFraction: 0.5),
      100)
    XCTAssertEqual(
      NormalModeDispatcher.adjustedScrollValue(
        current: 4, lower: 0, upper: 100, deltaFraction: -0.5),
      0)
    XCTAssertEqual(
      NormalModeDispatcher.adjustedScrollValue(
        current: 96, lower: 0, upper: 100, deltaFraction: 0.5),
      100)
  }

  func testInstantScrollEdgeValuesUseBounds() {
    XCTAssertEqual(
      NormalModeDispatcher.edgeScrollValue(lower: 10, upper: 90, edge: .minimum),
      10)
    XCTAssertEqual(
      NormalModeDispatcher.edgeScrollValue(lower: 10, upper: 90, edge: .maximum),
      90)
  }

  private var defaultMappings: CompiledMappings {
    CompiledMappings(Config.default.mode.normal)
  }

  private func command(
    pending: String = "",
    repeatAnchor: String? = nil,
    keyCode: Int = 0,
    chars: String,
    ignoring: String? = nil,
    flags: NSEvent.ModifierFlags = [],
    mappings: [ModeMapping] = Config.default.mode.normal
  ) -> URLCommand? {
    transition(
      pending: pending,
      repeatAnchor: repeatAnchor,
      keyCode: keyCode,
      chars: chars,
      ignoring: ignoring,
      flags: flags,
      mappings: mappings
    )
    .command
  }

  private func transition(
    pending: String = "",
    repeatAnchor: String? = nil,
    keyCode: Int = 0,
    chars: String,
    ignoring: String? = nil,
    flags: NSEvent.ModifierFlags = [],
    mappings: [ModeMapping] = Config.default.mode.normal
  ) -> NormalModeTransition {
    NormalModeInterpreter.interpret(
      pending: pending,
      repeatAnchor: repeatAnchor,
      keyCode: UInt16(keyCode),
      modifierFlags: flags,
      characters: chars,
      charactersIgnoringModifiers: ignoring ?? chars.lowercased(),
      mappings: CompiledMappings(mappings))
  }

  private func key(_ raw: String) -> String {
    NormalModeInterpreter.canonicalizeMappingKey(raw)!
  }

  private func editableRepairCandidate(
    role: String?,
    subrole: String? = nil,
    frame: CGRect = CGRect(x: 20, y: 20, width: 180, height: 28),
    enabled: Bool = true,
    hidden: Bool = false,
    isEditable: Bool = true
  ) -> NormalModeDispatcher.EditableFocusRepairCandidate {
    NormalModeDispatcher.EditableFocusRepairCandidate(
      role: role,
      subrole: subrole,
      frame: frame,
      enabled: enabled,
      hidden: hidden,
      isEditable: isEditable)
  }

  private func pointerClick(
    _ action: JumpAction,
    flashWasActive: Bool,
    frontmostPIDAtClick: pid_t = -1
  ) -> OverlayPointerClick {
    OverlayPointerClick(
      action: action,
      location: CGPoint(x: 100, y: 100),
      modifiers: [],
      flashWasActive: flashWasActive,
      frontmostPIDAtClick: frontmostPIDAtClick)
  }

  private func candidateFinderCandidate(
    name: String,
    pid: pid_t?,
    bundleIdentifier: String,
    path: String
  ) -> Candidate {
    Candidate(
      kind: .app,
      sourceID: "core.apps",
      source: "core.apps",
      pid: pid,
      title: name,
      subtitle: "app",
      bundleIdentifier: bundleIdentifier,
      url: URL(fileURLWithPath: path))
  }
}

extension NormalModeTests {
  func testTheBorderFollowsTheActivatedAppNotTheLaggyFrontmostPointer() {
    // The regression: switching from Messages to Alacritty left the stroke
    // around the Messages window because `frontmostApplication` still named
    // Messages when the border update ran.
    XCTAssertEqual(
      AppDelegate.activeWindowBorderTargetPID(activatedPID: 4242, frontmostPID: 99),
      4242)
  }

  func testTheBorderFallsBackToTheFrontmostPointerWithoutAnActivation() {
    XCTAssertEqual(
      AppDelegate.activeWindowBorderTargetPID(activatedPID: nil, frontmostPID: 99),
      99)
  }

  func testTheBorderHasNoTargetWhenNothingIsFocused() {
    XCTAssertNil(
      AppDelegate.activeWindowBorderTargetPID(activatedPID: nil, frontmostPID: nil))
  }
}

extension NormalModeTests {
  /// A key that is both a mapping of its own and the prefix of a longer one is
  /// parked until `sequence_timeout_ms` elapses instead of firing. That is a
  /// full second of apparent deadness on a key the user presses constantly, so
  /// no shipped default may be shaped that way. This is the rule that keeps
  /// triple click off `tf` while `t` opens a tab.
  func testNoDefaultNormalMappingIsBothAnActionAndAPrefix() {
    let mappings = Config().mode.normal
    // Prefixes are whole key atoms, as the interpreter reads them: `a` is no
    // prefix of the `alt+f` chord.
    let compiled = CompiledMappings(mappings)
    let offenders = mappings.map(\.key).filter { compiled.hasStrictPrefix($0) }
    XCTAssertFalse(
      compiled.hasStrictPrefix("a"), "a chord is one atom, never a sequence starting with a")
    XCTAssertTrue(compiled.hasStrictPrefix("d"), "d is the double-click prefix of df")
    XCTAssertEqual(
      offenders.sorted(), [],
      "these default mappings stall for the sequence timeout because a longer "
        + "binding extends them")
  }
}
