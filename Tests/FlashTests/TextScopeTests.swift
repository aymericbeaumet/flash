import AppKit
import Carbon.HIToolbox
import FlashCore
import XCTest

@testable import flash

/// Text engagement (`TextScope`): NORMAL acts on a focused field only once
/// the user engaged it by an explicit act, so a page that keeps a field
/// focused (Google Docs' hidden editor, a search box focused on load, the
/// address bar) keeps NORMAL's own keys.
final class TextScopeTests: XCTestCase {
  private let field = TextScope.Element(pid: 7, identity: 1)
  private let other = TextScope.Element(pid: 7, identity: 2)
  private let app = "com.example.app"

  private func reading(_ region: FocusRegion, _ element: Int?) -> FocusRegionTracker.Reading {
    FocusRegionTracker.Reading(region: region, element: element)
  }

  private var engaged: TextScope {
    var scope = TextScope()
    _ = scope.engage(field, in: app, reason: .leftInsert)
    return scope
  }

  // MARK: - Engaging

  /// Leaving INSERT engages the field the focus is in; the INSERT, VISUAL,
  /// command-line and HYPER round trips keep the engagement; any other mode
  /// ends it.
  func testModeChangesEngageKeepOrEnd() {
    func effect(_ previous: Mode, _ next: Mode) -> TextScope.ModeChangeEffect {
      TextScope.effect(ofModeChange: previous, to: next)
    }
    XCTAssertEqual(effect(.insert, .normal), .engageFocus)
    XCTAssertEqual(effect(.normal, .insert), .keep)
    XCTAssertEqual(effect(.normal, .visual(.charwise)), .keep)
    XCTAssertEqual(effect(.visual(.charwise), .visual(.linewise)), .keep)
    XCTAssertEqual(effect(.visual(.linewise), .normal), .keep)
    XCTAssertEqual(effect(.visual(.charwise), .insert), .keep, "VISUAL's c and s")
    XCTAssertEqual(effect(.normal, .normal), .keep)
    XCTAssertEqual(effect(.normal, .command(restoreTo: .normal)), .keep, "`:42` in the field")
    XCTAssertEqual(effect(.normal, .hyper(restoreTo: .normal)), .keep, "a `<leader>` sequence")
    for next in [Mode.hold, .disabled, .terminal(restoreTo: .normal, returnPID: nil)] {
      XCTAssertEqual(effect(.normal, next), .disengage, "\(next)")
    }
    XCTAssertEqual(effect(.command(restoreTo: .normal), .normal), .keep, "kept")
    var scope = engaged
    XCTAssertEqual(scope.disengage(.modeChanged), .disengaged(field, .modeChanged))
    XCTAssertFalse(scope.isEngaged)
  }

  func testEachExplicitActEngages() {
    var scope = TextScope()
    XCTAssertEqual(scope.engage(field, in: app, reason: .leftInsert), .engaged(field, .leftInsert))
    XCTAssertNil(scope.engage(field, in: app, reason: .visual), "already engaged")
    XCTAssertEqual(scope.engage(other, in: app, reason: .visual), .engaged(other, .visual))

    // `gi`: the reading after the focus write engages the field it names.
    scope = TextScope()
    scope.awaitFocus(in: 7, reason: .inputFocus)
    XCTAssertEqual(
      scope.focusSettled(pid: 7, bundle: app, reading: reading(.text(.singleLine), 1)),
      .engaged(field, .inputFocus))

    // An `f` commit on a text input waits for its own app.
    scope = TextScope()
    scope.awaitFocus(in: 7, reason: .hint)
    XCTAssertNil(scope.focusSettled(pid: 8, bundle: app, reading: reading(.text(.singleLine), 1)))
    XCTAssertEqual(
      scope.focusSettled(pid: 7, bundle: app, reading: reading(.text(.multiLine), 1)),
      .engaged(field, .hint))
  }

  /// A click engages the editable text its focus settles on, in whichever
  /// app comes forward; a reading from before the click, or of a spot that
  /// is not text, is corrected by the next one until the next key.
  func testAClickEngagesWhereTheFocusSettles() {
    var scope = TextScope()
    scope.awaitFocus(in: nil, reason: .click)
    XCTAssertNil(
      scope.focusSettled(pid: 7, bundle: app, reading: reading(.document, 9)), "not text")
    XCTAssertEqual(
      scope.focusSettled(pid: 7, bundle: app, reading: reading(.text(.multiLine), 1)),
      .engaged(field, .click))
    XCTAssertEqual(
      scope.focusSettled(pid: 7, bundle: app, reading: reading(.text(.multiLine), 2)),
      .engaged(other, .click), "the read from before the click is corrected")
    scope.keyTyped(readPending: false)
    XCTAssertNil(scope.awaiting)
    XCTAssertEqual(
      scope.focusSettled(pid: 7, bundle: app, reading: reading(.text(.multiLine), 1)),
      .disengaged(other, .focusMoved), "after a key the focus moving ends it")

    // A key typed while the click's reading is pending still lets it land.
    scope = TextScope()
    scope.awaitFocus(in: nil, reason: .click)
    scope.keyTyped(readPending: true)
    XCTAssertEqual(
      scope.focusSettled(pid: 8, bundle: app, reading: reading(.text(.singleLine), 4)),
      .engaged(TextScope.Element(pid: 8, identity: 4), .click))
    XCTAssertNil(scope.awaiting)

    // A click on nothing editable engages nothing.
    scope = TextScope()
    scope.awaitFocus(in: nil, reason: .click)
    XCTAssertNil(scope.focusSettled(pid: 7, bundle: app, reading: reading(.collection, 3)))
    XCTAssertNil(scope.focusSettled(pid: 7, bundle: app, reading: reading(.terminal, nil)))
    XCTAssertFalse(scope.isEngaged)
  }

  // MARK: - Where NORMAL engages at all

  /// An app with its own modal editing or partial Accessibility text, which
  /// a plugin declares (`own_text_editing`; the `defaults` plugin lists VS
  /// Code and its forks, the JetBrains IDEs, Zed and Sublime Text), is
  /// never engaged: NORMAL's keys keep their page meaning there, whatever
  /// act the focus followed. `[mode.apps."<bundle>".text] enabled` forces an app
  /// either way.
  func testADeclaredEditorIsNeverEngagedUnlessForced() {
    let previous = OwnTextEditingApps.declared.all
    defer { OwnTextEditingApps.declared.declare(previous) }
    OwnTextEditingApps.declared.declare(["com.example.editor"])
    var scope = TextScope()
    XCTAssertFalse(scope.engages("com.example.editor"))
    XCTAssertTrue(scope.engages(app))
    XCTAssertTrue(scope.engages(nil), "an app without a bundle id is declared by nobody")
    XCTAssertNil(scope.engage(field, in: "com.example.editor", reason: .leftInsert))
    XCTAssertNil(scope.engage(field, in: "com.example.editor", reason: .visual))
    XCTAssertFalse(scope.isEngaged)
    scope.awaitFocus(in: nil, reason: .click)
    XCTAssertNil(
      scope.focusSettled(
        pid: 7, bundle: "com.example.editor", reading: reading(.text(.multiLine), 1)),
      "a click in the editor engages nothing")
    XCTAssertEqual(
      scope.focusSettled(pid: 8, bundle: app, reading: reading(.text(.multiLine), 4)),
      .engaged(TextScope.Element(pid: 8, identity: 4), .click), "another app still does")

    // `text = true` forces an editor on; `text = false` another app off.
    scope = TextScope()
    scope.policy.apps = ["com.example.editor": true, app: false]
    XCTAssertTrue(scope.engages("com.example.editor"))
    XCTAssertFalse(scope.engages(app))
    XCTAssertEqual(
      scope.engage(field, in: "com.example.editor", reason: .click), .engaged(field, .click))
    XCTAssertNil(scope.engage(other, in: app, reason: .click))
  }

  /// `[mode.text] enabled = false`: Flash never engages a field, whatever
  /// the app or its override says, and a reload that turns the switch off,
  /// or refuses the engaged app, ends the engagement.
  func testTheSwitchOffNeverEngages() {
    var scope = TextScope()
    scope.policy = TextScope.Policy(enabled: false, apps: [app: true])
    XCTAssertFalse(scope.engages(app))
    XCTAssertNil(scope.engage(field, in: app, reason: .leftInsert))
    scope.awaitFocus(in: nil, reason: .click)
    XCTAssertNil(
      scope.focusSettled(pid: 7, bundle: app, reading: reading(.text(.singleLine), 1)))
    XCTAssertFalse(scope.isEngaged)

    scope = engaged
    XCTAssertEqual(
      scope.update(policy: TextScope.Policy(enabled: false)) { _ in self.app },
      .disengaged(field, .configChanged))
    XCTAssertFalse(scope.isEngaged)
    XCTAssertNil(scope.update(policy: TextScope.Policy()) { _ in self.app }, "nothing engaged")
    scope = engaged
    XCTAssertNil(scope.update(policy: TextScope.Policy()) { _ in self.app }, "still allowed")
    XCTAssertTrue(scope.isEngaged)
    XCTAssertEqual(
      scope.update(policy: TextScope.Policy(apps: [app: false])) { _ in self.app },
      .disengaged(field, .configChanged))
  }

  /// The policy is the config's: the switch and each app's `text.enabled` key.
  func testThePolicyReadsTheConfig() {
    let config = ConfigLoader.parse(
      """
      [mode.text]
      enabled = false
      [mode.apps."com.example.editor".text]
      enabled = true
      [mode.apps."com.example.app".text]
      enabled = false
      [mode.apps."com.apple.Safari".normal.mappings]
      "r" = false
      """)
    XCTAssertTrue(config.diagnostics.isEmpty, config.diagnostics.map(\.message).joined())
    XCTAssertEqual(
      TextScope.Policy(config.mode),
      TextScope.Policy(enabled: false, apps: ["com.example.editor": true, app: false]),
      "an app with only mappings sets no override")
    XCTAssertEqual(TextScope.Policy(Config.default.mode), TextScope.Policy())
  }

  func testAChangedPolicyInvalidatesPendingEngagement() {
    var scope = TextScope()
    scope.awaitFocus(in: 7, reason: .click)
    XCTAssertNil(scope.update(policy: TextScope.Policy()) { _ in self.app })
    XCTAssertNotNil(scope.awaiting, "an unrelated reload keeps the pending engagement")
    XCTAssertNil(scope.update(policy: TextScope.Policy(enabled: false)) { _ in self.app })
    XCTAssertNil(scope.awaiting)
    _ = scope.update(policy: TextScope.Policy()) { _ in self.app }
    XCTAssertNil(
      scope.focusSettled(pid: 7, bundle: app, reading: reading(.text(.singleLine), 1)),
      "a reading from before the policy changed cannot engage after it is re-enabled")
    XCTAssertFalse(scope.isEngaged)
  }

  func testDisablingTextEndsAnExistingVisualSession() {
    let delegate = AppDelegate()
    delegate.modeStore.dispatch(.startup(advancedEnabled: true))
    delegate.modeStore.dispatch(.enterVisual(.charwise))
    delegate.visualSession = VisualSession(
      pid: 7, kind: .charwise, anchor: 0, cursor: 2, desiredColumn: nil,
      selected: 0..<3, measured: true, element: 1)
    var mode = Config.default.mode
    mode.textEnabled = false
    delegate.applyTextScopePolicy(mode)
    XCTAssertEqual(delegate.modeStore.mode, .normal)
  }

  func testChangedAppDeclarationsInvalidatePendingEngagement() {
    var scope = TextScope()
    scope.awaitFocus(in: 7, reason: .click)
    XCTAssertNil(
      scope.update(policy: TextScope.Policy(), invalidatesPending: true) { _ in self.app })
    XCTAssertNil(scope.awaiting)
    XCTAssertNil(
      scope.focusSettled(pid: 7, bundle: app, reading: reading(.text(.singleLine), 1)))
  }

  // MARK: - Disengaging

  /// The focus settling on another element or app ends the engagement; a
  /// reading naming the engaged element keeps it, whatever its region.
  func testTheFocusMovingDisengages() {
    var scope = engaged
    XCTAssertNil(scope.focusSettled(pid: 7, bundle: app, reading: reading(.text(.multiLine), 1)))
    XCTAssertNil(
      scope.focusSettled(pid: 7, bundle: app, reading: reading(.document, 1)),
      "the same element flapping")
    XCTAssertEqual(
      scope.focusSettled(pid: 7, bundle: app, reading: reading(.text(.multiLine), 2)),
      .disengaged(field, .focusMoved))
    XCTAssertNil(
      scope.focusSettled(pid: 7, bundle: app, reading: reading(.text(.multiLine), 1)), "stays off")

    scope = engaged
    XCTAssertEqual(
      scope.focusSettled(pid: 7, bundle: app, reading: reading(.document, nil)),
      .disengaged(field, .focusMoved))

    scope = engaged
    XCTAssertNil(scope.focusMayHaveChanged(pid: 7), "the same app waits for its reading")
    XCTAssertEqual(scope.focusMayHaveChanged(pid: 8), .disengaged(field, .focusMoved))
  }

  /// Escape in an engaged field hands the keys back to NORMAL's own: the
  /// text table maps it to `mode leave`, which disengages once nothing else
  /// (hints, a popup, the command line) is open.
  func testEscapeDisengages() {
    var scope = engaged
    XCTAssertEqual(scope.disengage(.escape), .disengaged(field, .escape))
    XCTAssertNil(scope.disengage(.escape))
    let mode = Config.default.mode
    XCTAssertEqual(mode.compiledText.mapping(for: key("<esc>"))?.action, .flashCommand(.leaveMode))
    XCTAssertEqual(
      mode.compiledNormal.mapping(for: key("<esc>"))?.action, .flashCommand(.appCancel),
      "NORMAL's own Escape asks the app to cancel")
  }

  /// Escape with a half-typed sequence or a count only abandons it, as in
  /// Vim; alone it disengages.
  func testEscapeAbandonsAHalfTypedSequenceFirst() {
    let table = Config.default.mode.compiledText
    func escape(after pending: String) -> NormalModeTransition {
      NormalModeInterpreter.interpret(
        pending: pending, repeatAnchor: nil, keyCode: UInt16(kVK_Escape), modifierFlags: [],
        characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", mappings: table)
    }
    XCTAssertEqual(escape(after: interpret("g", pending: "", in: table).pending), .consume)
    XCTAssertEqual(escape(after: interpret("3", pending: "", in: table).pending), .consume)
    XCTAssertEqual(escape(after: "").command, .leaveMode)
  }

  // MARK: - D1: one predicate

  func testOnlyTheEngagedEditableFieldIsActive() {
    let text = FocusedText(kind: .multiLine)
    XCTAssertFalse(TextScope().isActive(for: text, pid: 7, element: 1))
    XCTAssertTrue(engaged.isActive(for: text, pid: 7, element: 1))
    XCTAssertFalse(engaged.isActive(for: text, pid: 7, element: 2))
    XCTAssertFalse(engaged.isActive(for: text, pid: 8, element: 1))
    XCTAssertFalse(engaged.isActive(for: text, pid: 7, element: nil))
    XCTAssertFalse(engaged.isActive(for: .uneditable, pid: 7, element: 1))
    XCTAssertFalse(engaged.isActive(for: .terminal, pid: 7, element: 1))
    XCTAssertEqual(engaged.gate(text, pid: 7, element: 1), text)
    XCTAssertEqual(TextScope().gate(text, pid: 7, element: 1), .uneditable)
  }

  // MARK: - A page that keeps a field focused

  /// Google Docs keeps a hidden editable focused; a search box takes the
  /// focus on load. Until the user engages it NORMAL's keys are its own:
  /// `x` closes the tab, `t` opens one, `j` scrolls, and no `input` move
  /// reaches the field.
  func testAnAlwaysFocusedFieldIsAPageUntilEngaged() {
    let scope = TextScope()
    let mode = Config.default.mode
    XCTAssertEqual(AppDelegate.mappingScope(for: .normal, textEngaged: scope.isEngaged), .normal)
    let table = AppDelegate.interpreterTable(for: .normal, in: mode)
    XCTAssertEqual(table.mapping(for: key("x"))?.action.command, .tabClose)
    XCTAssertEqual(table.mapping(for: key("t"))?.action.command, .tabNew)

    let focused = reading(.text(.multiLine), 1)
    XCTAssertEqual(scope.region(of: focused, pid: 7), .document)
    XCTAssertEqual(
      MoveResolution.resolve(.down, in: scope.region(of: focused, pid: 7), pageLines: 15),
      .arrows(.down, times: 1), "j is Down, which the page scrolls on")
    XCTAssertEqual(
      MoveResolution.resolve(
        .down, in: scope.region(of: reading(.collection, 3), pid: 7), pageLines: 15),
      .arrows(.down, times: 1), "a list keeps its arrows")

    var text = FocusedText(kind: .multiLine)
    text.contents = .init(selection: 2..<2, length: 9, text: "one\ntwo\n")
    let gated = scope.gate(text, pid: 7, element: 1)
    XCTAssertEqual(gated, .uneditable)
    for motion in InputMotion.allCases {
      XCTAssertFalse(motion.isPermitted(in: gated), "\(motion) in a search box not engaged")
    }
  }

  /// `]t` completes while the focus readings flap between the hidden
  /// editor and the page: they change no engagement, so the table stays
  /// and the pending `]` survives.
  func testAPendingSequenceSurvivesFocusNoise() {
    var scope = TextScope()
    let table = AppDelegate.interpreterTable(
      for: AppDelegate.mappingScope(for: .normal, textEngaged: scope.isEngaged),
      in: Config.default.mode)
    let first = interpret("]", pending: "", in: table)
    XCTAssertNil(first.action)
    XCTAssertFalse(first.pending.isEmpty)
    for noise in [
      reading(.text(.multiLine), 1), reading(.document, 9), reading(.text(.multiLine), 1),
      reading(.document, nil),
    ] {
      XCTAssertNil(scope.focusSettled(pid: 7, bundle: app, reading: noise), "no engagement change")
    }
    XCTAssertEqual(
      AppDelegate.mappingScope(for: .normal, textEngaged: scope.isEngaged), .normal)
    XCTAssertEqual(interpret("t", pending: first.pending, in: table).command, .tabNext)

    // Engaged, a reading of the same element in another region changes
    // nothing either.
    scope = engaged
    XCTAssertNil(scope.focusSettled(pid: 7, bundle: app, reading: reading(.document, 1)))
    XCTAssertTrue(scope.isEngaged)
  }

  /// After leaving INSERT in the field its keys are Vim's: the text table,
  /// the caret for `j`, `t` no longer the tab's and `r` nothing, while `x`
  /// still closes the tab.
  func testLeavingInsertInTheFieldAppliesTheTextKeys() {
    XCTAssertEqual(TextScope.effect(ofModeChange: .insert, to: .normal), .engageFocus)
    let scope = engaged
    XCTAssertEqual(AppDelegate.mappingScope(for: .normal, textEngaged: scope.isEngaged), .text)
    XCTAssertEqual(
      AppDelegate.mappingScope(for: .insert, textEngaged: scope.isEngaged), .insert,
      "only NORMAL reads the text table")
    let table = AppDelegate.interpreterTable(for: .text, in: Config.default.mode)
    XCTAssertEqual(
      table.mapping(for: key("w"))?.action.command, .cursor(.motion(.nextWord(big: false))))
    XCTAssertEqual(
      table.mapping(for: key("t"))?.action.command, .cursor(.findCharacter(.tillNextChar, nil)))
    XCTAssertEqual(table.mapping(for: key("x"))?.action.command, .tabClose)
    XCTAssertNil(table.mapping(for: key("r")))
    let focused = reading(.text(.multiLine), 1)
    XCTAssertEqual(scope.region(of: focused, pid: 7), .text(.multiLine))
    XCTAssertEqual(
      MoveResolution.resolve(.down, in: scope.region(of: focused, pid: 7), pageLines: 15),
      .text(.lineDown, times: 1))
  }

  // MARK: - v and V

  /// `v` and `V` are NORMAL's: with editable focus they start VISUAL, by
  /// the text or the app's keys; with nothing editable, nothing.
  func testVisualStartsOnlyInEditableText() {
    var text = FocusedText(kind: .multiLine)
    text.contents = .init(selection: 4..<4, length: 8, text: "one\ntwo\n")
    XCTAssertEqual(
      VisualPlan.entry(.charwise, in: text), .measured(anchor: 4, range: 4..<5))
    XCTAssertEqual(VisualPlan.entry(.linewise, in: text), .measured(anchor: 4, range: 4..<8))
    var secure = FocusedText(kind: .singleLine)
    secure.contents = .init(selection: 0..<0, length: 4, text: nil)
    XCTAssertEqual(VisualPlan.entry(.linewise, in: secure), .appKeys)
    XCTAssertEqual(VisualPlan.entry(.charwise, in: FocusedText(kind: .multiLine)), .appKeys)
    XCTAssertEqual(VisualPlan.entry(.charwise, in: .uneditable), .none)
    XCTAssertEqual(VisualPlan.entry(.linewise, in: .terminal), .none)
    XCTAssertEqual(VisualPlan.entryKeys(.linewise), [.lineStart, .selectLineEnd])
    XCTAssertEqual(VisualPlan.entryKeys(.charwise), [])
    let normal = Config.default.mode.compiledNormal
    XCTAssertEqual(normal.mapping(for: key("V"))?.action, .flashCommand(.visualMode(.linewise)))
    XCTAssertEqual(normal.mapping(for: key("v"))?.action, .flashCommand(.visualMode(.charwise)))
  }

  // MARK: - Helpers

  private func interpret(_ chars: String, pending: String, in table: CompiledMappings)
    -> NormalModeTransition
  {
    NormalModeInterpreter.interpret(
      pending: pending, repeatAnchor: nil, keyCode: 0xFFFF, modifierFlags: [],
      characters: chars, charactersIgnoringModifiers: chars.lowercased(), mappings: table)
  }

  private func key(_ raw: String) -> String {
    NormalModeInterpreter.canonicalizeMappingKey(raw)!
  }
}
