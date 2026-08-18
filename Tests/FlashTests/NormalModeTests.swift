import AppKit
import ApplicationServices
import Carbon.HIToolbox
import FlashCore
import XCTest

@testable import flash

final class NormalModeTests: XCTestCase {
  func testDirectionalScrollKeys() {
    XCTAssertEqual(command(chars: "h"), .scroll(.left))
    assertSendKey(command(chars: "j"), keys: "down", keyCode: CGKeyCode(kVK_DownArrow))
    assertSendKey(command(chars: "k"), keys: "up", keyCode: CGKeyCode(kVK_UpArrow))
    XCTAssertEqual(command(chars: "l"), .scroll(.right))
    XCTAssertEqual(command(chars: "e", flags: [.control]), .scroll(.down))
    XCTAssertEqual(command(chars: "y", flags: [.control]), .scroll(.up))
  }

  func testHalfPageKeysUseBareAndControlForms() {
    // Vimium parity: bare `d` / `u` scroll a half page; the `ctrl+`
    // forms remain as vim-style aliases.
    XCTAssertEqual(command(chars: "d"), .scroll(.halfPageDown))
    XCTAssertEqual(command(chars: "u"), .scroll(.halfPageUp))
    XCTAssertEqual(command(chars: "u", flags: [.control]), .scroll(.halfPageUp))
    XCTAssertEqual(command(chars: "d", flags: [.control]), .scroll(.halfPageDown))
  }

  func testRedoKey() {
    // Undo is no longer bound to bare `u` — Vimium reuses it for
    // half-page scroll-up — but stays reachable via `:undo`. Redo
    // keeps `ctrl+r`.
    XCTAssertEqual(command(chars: "r", flags: [.control]), .redo)
  }

  func testScrollWheelDeltasUseExpectedJumpSizes() {
    let down = NormalModeDispatcher.scrollWheelDelta(
      for: .down,
      viewportSize: CGSize(width: 1200, height: 900))
    XCTAssertEqual(down?.vertical, -60)
    XCTAssertEqual(down?.horizontal, 0)

    let up = NormalModeDispatcher.scrollWheelDelta(
      for: .up,
      viewportSize: CGSize(width: 1200, height: 900))
    XCTAssertEqual(up?.vertical, 60)
    XCTAssertEqual(up?.horizontal, 0)

    let halfDown = NormalModeDispatcher.scrollWheelDelta(
      for: .halfPageDown,
      viewportSize: CGSize(width: 1200, height: 900))
    XCTAssertEqual(halfDown?.vertical, -450)
    XCTAssertEqual(halfDown?.horizontal, 0)

    let halfUp = NormalModeDispatcher.scrollWheelDelta(
      for: .halfPageUp,
      viewportSize: CGSize(width: 1200, height: 900))
    XCTAssertEqual(halfUp?.vertical, 450)
    XCTAssertEqual(halfUp?.horizontal, 0)
  }

  func testTopBottomUseExtremeWheelDeltasForWheelFallback() {
    // AX scrollbar value-setters are the primary path for gg/G, but
    // they don't move every app (tmux has none, some Electron apps
    // ignore the AX-set). For those apps the dispatcher falls back to
    // a synthetic wheel event with a huge delta — large enough to
    // exceed any realistic document height while still fitting Int32.
    let top = NormalModeDispatcher.scrollWheelDelta(
      for: .top,
      viewportSize: CGSize(width: 1200, height: 900))
    XCTAssertNotNil(top)
    XCTAssertGreaterThanOrEqual(top?.vertical ?? 0, 100_000)
    XCTAssertEqual(top?.horizontal, 0)

    let bottom = NormalModeDispatcher.scrollWheelDelta(
      for: .bottom,
      viewportSize: CGSize(width: 1200, height: 900))
    XCTAssertNotNil(bottom)
    XCTAssertLessThanOrEqual(bottom?.vertical ?? 0, -100_000)
    XCTAssertEqual(bottom?.horizontal, 0)
  }

  func testTopBottomAndNavigationSequences() {
    XCTAssertEqual(transition(chars: "g").pending, "g")
    XCTAssertEqual(command(pending: "g", chars: "g"), .scroll(.top))
    XCTAssertEqual(command(chars: "G", ignoring: "g", flags: [.shift]), .scroll(.bottom))
    // History: `H`/`L`, with `[h`/`]h` as unimpaired-style aliases.
    XCTAssertEqual(command(chars: "H", ignoring: "h", flags: [.shift]), .historyBack)
    XCTAssertEqual(command(chars: "L", ignoring: "l", flags: [.shift]), .historyForward)
    XCTAssertEqual(command(pending: "[", chars: "h"), .historyBack)
    XCTAssertEqual(command(pending: "]", chars: "h"), .historyForward)
    XCTAssertEqual(command(pending: "]", chars: "t"), .tabNext)
    XCTAssertEqual(command(pending: "[", chars: "t"), .tabPrev)
    XCTAssertEqual(command(pending: "[", chars: "a"), .appPrev)
    XCTAssertEqual(command(pending: "]", chars: "a"), .appNext)
    XCTAssertEqual(command(pending: "g", chars: "4"), .tabSelect(index: 4))
    assertSendKeyKeys(command(chars: "n"), "cmd+g")
    XCTAssertEqual(command(chars: "t"), .tabNew)
    XCTAssertEqual(command(chars: "e"), .archive)
  }

  func testRepeatCountsApplyToSingleAndMultiKeyCommands() {
    XCTAssertEqual(transition(chars: "1").pending, "1")
    XCTAssertEqual(transition(pending: "1", chars: "0").pending, "10")

    let halfPageUp = transition(pending: "10", chars: "u")
    XCTAssertEqual(halfPageUp.command, .scroll(.halfPageUp))
    XCTAssertEqual(halfPageUp.repeatCount, 10)

    let previousTab = transition(pending: "2[", chars: "t")
    XCTAssertEqual(previousTab.command, .tabPrev)
    XCTAssertEqual(previousTab.repeatCount, 2)

    let nextTab = transition(pending: "2]", chars: "t")
    XCTAssertEqual(nextTab.command, .tabNext)
    XCTAssertEqual(nextTab.repeatCount, 2)

    let selectTab = transition(pending: "g", chars: "3")
    XCTAssertEqual(selectTab.command, .tabSelect(index: 3))
    XCTAssertEqual(selectTab.repeatCount, 1)

    let leadingZero = transition(chars: "0")
    XCTAssertNil(leadingZero.command)
    XCTAssertEqual(leadingZero.pending, "")
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

  func testCopySequences() {
    XCTAssertNil(command(chars: "y"))
    XCTAssertEqual(command(pending: "y", chars: "y"), .copyURL)
  }

  func testMoveMouseSequence() {
    XCTAssertEqual(transition(chars: "m").pending, "m")
    XCTAssertEqual(command(pending: "m", chars: "f"), .mouseTarget(.move))
    XCTAssertEqual(
      command(pending: "m", chars: "F", ignoring: "f", flags: [.shift]), .mouseGrid(.move))
    // `m<letter>` / `` `<letter> `` route to the marks plugin via the
    // `set_mark` / `jump_to_mark` plugin verbs.
    XCTAssertEqual(
      command(pending: "m", chars: "x"),
      .pluginVerb(name: "set_mark", args: ["letter": "x"]))
    XCTAssertEqual(
      command(pending: "`", chars: "x"),
      .pluginVerb(name: "jump_to_mark", args: ["letter": "x"]))
  }

  func testMouseTargetAndGridCurrentAndNewTabMappings() {
    XCTAssertEqual(
      command(chars: "f"),
      .mouseTarget(.click(.leftClick, modifiers: [])))
    XCTAssertEqual(
      command(chars: "F", ignoring: "f", flags: [.shift]),
      .mouseTarget(.click(.leftClick, modifiers: .command)))
    XCTAssertEqual(
      command(keyCode: kVK_ANSI_F, chars: "f", flags: [.control]),
      .mouseGrid(.click(.leftClick, modifiers: [])))
    XCTAssertEqual(
      command(keyCode: kVK_ANSI_F, chars: "F", ignoring: "f", flags: [.control, .shift]),
      .mouseGrid(.click(.leftClick, modifiers: .command)))
    // `s` is now the secondary-click prefix (`sf`/`sF`), so it leaves a
    // pending sequence rather than yielding `nil`.
    XCTAssertEqual(transition(chars: "s").pending, "s")
  }

  func testSecondaryAndDoubleClickHintModeSequences() {
    // `r` stays bound to `reload`; the secondary-click prefix is `s`
    // (renamed from the old `r*` to drop the sequence-timeout delay on
    // a bare `r`).
    XCTAssertEqual(command(chars: "r"), .reload(force: false))
    XCTAssertEqual(command(chars: "R", ignoring: "r", flags: [.shift]), .reload(force: true))
    XCTAssertEqual(transition(chars: "s").pending, "s")
    XCTAssertEqual(
      command(pending: "s", chars: "f"),
      .mouseTarget(.click(.rightClick, modifiers: [])))
    XCTAssertEqual(
      command(pending: "s", chars: "F", ignoring: "f", flags: [.shift]),
      .mouseGrid(.click(.rightClick, modifiers: [])))
    // Bare `d` is half-page scroll; double-click hints moved to the
    // `D` prefix so `d` fires instantly without a sequence-timeout wait.
    XCTAssertEqual(command(chars: "d"), .scroll(.halfPageDown))
    XCTAssertEqual(transition(chars: "D", ignoring: "d", flags: [.shift]).pending, "D")
    XCTAssertEqual(
      command(pending: "D", chars: "f"),
      .mouseTarget(.click(.doubleClick, modifiers: [])))
    XCTAssertEqual(
      command(pending: "D", chars: "F", ignoring: "f", flags: [.shift]),
      .mouseGrid(.click(.doubleClick, modifiers: [])))
  }

  // `f` and `F` clicks no longer auto-enter insert from generic provider
  // metadata. Virtual and physical primary clicks use the same post-click
  // terminal/input handoff check.

  func testHelpReloadCommandLineAndModifiedKeyConsumption() {
    XCTAssertEqual(command(chars: "i"), .insertMode)
    XCTAssertEqual(command(chars: "I", ignoring: "i", flags: [.shift]), .lockedInsertMode)
    XCTAssertEqual(command(chars: "?"), .showUsage(topic: nil))
    XCTAssertEqual(command(chars: "?", ignoring: "/", flags: [.shift]), .showUsage(topic: nil))
    XCTAssertNil(
      NormalModeInterpreter.interpret(
        pending: "",
        keyCode: UInt16(kVK_Space),
        modifierFlags: [.command],
        characters: " ",
        charactersIgnoringModifiers: " ",
        mappings: CompiledMappings(Config.Mode.defaultNormalMappings)
      ).command)
    // With right-click hints moved to the `s` prefix, `r` no longer prefixes
    // any pending sequence — it resolves to reload on the first keystroke (no
    // sequence-timeout delay).
    XCTAssertEqual(command(chars: "r"), .reload(force: false))
    XCTAssertEqual(command(chars: ":"), .commandMode)
    XCTAssertEqual(command(chars: "x"), .close)
    XCTAssertEqual(command(chars: "/"), .find)
    XCTAssertEqual(transition(chars: "\\").pending, "\\")
    XCTAssertEqual(
      transition(pending: "\\", keyCode: kVK_Space, chars: " ").command,
      .enterCommand(input: "flashlight ", restoreMode: false))
    XCTAssertNil(command(chars: "o"))
    XCTAssertNil(command(chars: "O", ignoring: "o", flags: [.shift]))
    let modified = transition(chars: "r", flags: [.command])
    XCTAssertNil(modified.command)
    // Hermetic normal mode: any Cmd/Opt chord without an explicit
    // mapping is swallowed, never forwarded to the focused app.
    XCTAssertEqual(modified.pending, "")
  }

  func testPendingPrefixBrokenByUnmappableKeyFallsBackToFreshInterpretation() {
    // `g` is a prefix (gg/gt/g1…) but `gi` is unmapped — falling back
    // to interpreting `i` from scratch lands on insert mode instead of
    // silently swallowing the keystroke. Same for any other prefix.
    XCTAssertEqual(command(pending: "g", chars: "i"), .insertMode)
    XCTAssertEqual(command(pending: "[", chars: "i"), .insertMode)
    XCTAssertEqual(command(pending: "]", chars: "i"), .insertMode)
    assertSendKeyKeys(command(pending: "g", chars: "n"), "cmd+g")
    XCTAssertEqual(command(pending: "g", chars: "r"), .reload(force: false))
    // Valid sequence continuations still resolve to the mapped action.
    XCTAssertEqual(command(pending: "g", chars: "t"), .tabNext)
    XCTAssertEqual(
      command(pending: "m", chars: "i"),
      .pluginVerb(name: "set_mark", args: ["letter": "i"]))
    // No mapping at any depth — the prefix is dropped and the fresh
    // key is also unmapped, so the result is a clean consume (no
    // command, no carried-over pending).
    let unmappable = transition(pending: "g", chars: "z")
    XCTAssertNil(unmappable.command)
    XCTAssertEqual(unmappable.pending, "")
  }

  func testNormalModeMayEnterInsertOnAnyUserDrivenTrigger() {
    XCTAssertTrue(AppDelegate.normalModeMayEnterInsert(reason: .hintCommit))
    XCTAssertTrue(AppDelegate.normalModeMayEnterInsert(reason: .normalModeInput))
    XCTAssertTrue(AppDelegate.normalModeMayEnterInsert(reason: .lockedNormalModeInput))
    XCTAssertTrue(AppDelegate.normalModeMayEnterInsert(reason: .pointerClick))
    // `.explicitCommand` is the reason `/` (app_find) and `t` (tab_new)
    // pass when they want the side-effect followed by a switch to
    // INSERT. They're user-driven, so the gate must let them through.
    XCTAssertTrue(AppDelegate.normalModeMayEnterInsert(reason: .explicitCommand))
    // `.passthroughFocus` only fires inside the window an explicit
    // `passthrough_modifiers` chord armed, so it is user-driven too.
    XCTAssertTrue(AppDelegate.normalModeMayEnterInsert(reason: .passthroughFocus))
    // `.advancedModeDisabled` stays out of the user-driven set — config
    // reload uses `force: true` to bypass the gate when it needs to
    // leave NORMAL because the user removed the normal-mode binding.
    XCTAssertFalse(AppDelegate.normalModeMayEnterInsert(reason: .advancedModeDisabled))
  }

  func testPassthroughFocusFollowFiresOnlyForTheArmedFrontmostAppInIdleNormal() {
    func mayFire(
      armedPID: pid_t = 7,
      eventPID: pid_t = 7,
      frontmostPID: pid_t? = 7,
      mode: FlashMode = .normal,
      overlayInputMode: OverlayInputMode = .normal,
      hasHints: Bool = false,
      activationInFlight: Bool = false,
      bundleIdentifier: String? = "org.mozilla.firefox"
    ) -> Bool {
      AppDelegate.passthroughFocusFollowMayFire(
        armedPID: armedPID,
        eventPID: eventPID,
        frontmostPID: frontmostPID,
        mode: mode,
        overlayInputMode: overlayInputMode,
        hasHints: hasHints,
        activationInFlight: activationInFlight,
        bundleIdentifier: bundleIdentifier)
    }

    XCTAssertTrue(mayFire())
    // The follow is pinned to the app that received the chord: an event from
    // another pid, or a frontmost change (⌘Tab inside the window), keeps the
    // mode sticky.
    XCTAssertFalse(mayFire(eventPID: 8, frontmostPID: 8))
    XCTAssertFalse(mayFire(frontmostPID: 8))
    XCTAssertFalse(mayFire(frontmostPID: nil))
    // Only idle NORMAL follows — INSERT, hints, surfaces, and in-flight
    // activations own the keyboard story already.
    XCTAssertFalse(mayFire(mode: .insert))
    XCTAssertFalse(mayFire(overlayInputMode: .hints))
    XCTAssertFalse(mayFire(overlayInputMode: .commandLine))
    XCTAssertFalse(mayFire(hasHints: true))
    XCTAssertFalse(mayFire(activationInFlight: true))
    // Terminals report every focus as editable, so there is no signal.
    XCTAssertFalse(mayFire(bundleIdentifier: "com.apple.Terminal"))
    XCTAssertTrue(mayFire(bundleIdentifier: nil))
  }

  func testPassthroughFocusFollowDoesNotArmForMessagesConversationTraversal() {
    XCTAssertFalse(
      AppDelegate.passthroughChordMayArmFocusFollow(
        virtualKey: UInt32(kVK_ANSI_LeftBracket),
        flags: [.maskCommand, .maskShift],
        bundleIdentifier: "com.apple.MobileSMS"))
    XCTAssertFalse(
      AppDelegate.passthroughChordMayArmFocusFollow(
        virtualKey: UInt32(kVK_ANSI_RightBracket),
        flags: [.maskCommand, .maskShift],
        bundleIdentifier: "com.apple.Messages"))

    XCTAssertTrue(
      AppDelegate.passthroughChordMayArmFocusFollow(
        virtualKey: UInt32(kVK_ANSI_F),
        flags: .maskCommand,
        bundleIdentifier: "com.apple.MobileSMS"))
    XCTAssertTrue(
      AppDelegate.passthroughChordMayArmFocusFollow(
        virtualKey: UInt32(kVK_ANSI_LeftBracket),
        flags: [.maskCommand, .maskShift],
        bundleIdentifier: "org.mozilla.firefox"))
  }

  func testInsertModeExitsWhenFocusedElementStopsBeingEditable() {
    XCTAssertTrue(shouldExitAfterFocusedElementChange(focusedElementIsEditable: false))
    XCTAssertFalse(shouldExitAfterFocusedElementChange(focusedElementIsEditable: true))
    XCTAssertFalse(
      shouldExitAfterFocusedElementChange(
        focusedElementIsEditable: false,
        insertModeLocked: true))
  }

  func testInsertModeDoesNotExitWhenFocusedAppChangesWhileLocked() {
    XCTAssertTrue(shouldExitAfterFocusedAppChange(focusedPID: pid_t(7)))
    XCTAssertFalse(shouldExitAfterFocusedAppChange(focusedPID: pid_t(7), insertModeLocked: true))
  }

  func testInsertFocusMachineCoversTextEntryStableControlsAndTransientSurfaces() {
    struct Scenario {
      var name: String
      var snapshot: InputFocusSnapshot
      var pointerPressed = false
      var expected: InputFocusExitDecision
    }

    let scenarios = [
      Scenario(
        name: "true text input stays in INSERT",
        snapshot: focusSnapshot(.editable, role: "AXTextField"),
        expected: .stay),
      Scenario(
        name: "web checkbox toggles and exits to NORMAL",
        snapshot: focusSnapshot(.stableNonEditable, role: "AXCheckBox"),
        expected: .exitToNormal),
      Scenario(
        name: "native checkbox toggles and exits to NORMAL",
        snapshot: focusSnapshot(.stableNonEditable, role: "AXCheckBox"),
        expected: .exitToNormal),
      Scenario(
        name: "button click exits to NORMAL",
        snapshot: focusSnapshot(.stableNonEditable, role: "AXButton"),
        expected: .exitToNormal),
      Scenario(
        name: "link click exits to NORMAL",
        snapshot: focusSnapshot(.stableNonEditable, role: "AXLink"),
        expected: .exitToNormal),
      Scenario(
        name: "AX focus unavailable exits to NORMAL",
        snapshot: focusSnapshot(.unavailable),
        expected: .exitToNormal),
      Scenario(
        name: "custom dropdown option waits for popup settle",
        snapshot: focusSnapshot(
          .transientInteraction(reason: .role("AXListItem")), role: "AXListItem"),
        expected: .resampleAfter(milliseconds: InsertModeFocusMachine.transientResampleMs)),
      Scenario(
        name: "Bitwarden/extension popup waits for popup settle",
        snapshot: focusSnapshot(
          .transientInteraction(reason: .extensionDocument(scheme: "moz-extension")),
          role: "AXWebArea",
          documentURL: "moz-extension://vault/popup.html"),
        expected: .resampleAfter(milliseconds: InsertModeFocusMachine.transientResampleMs)),
      Scenario(
        name: "mouse selection waits until release before deciding",
        snapshot: focusSnapshot(.stableNonEditable, role: "AXStaticText"),
        pointerPressed: true,
        expected: .waitForPointerRelease),
    ]

    for scenario in scenarios {
      let actual = InsertModeFocusMachine.insertFocusChangeDecision(
        focusedPID: pid_t(42),
        eventPID: pid_t(42),
        armedEditablePID: pid_t(42),
        snapshot: scenario.snapshot,
        pointerPressed: scenario.pointerPressed)
      XCTAssertEqual(actual, scenario.expected, scenario.name)
    }
  }

  func testInputFocusSnapshotClassifiesBrowserNativeAndExtensionSurfaces() {
    struct Scenario {
      var name: String
      var isEditable = false
      var role: String?
      var expanded = false
      var ancestorRoles: [String] = []
      var windowSubrole: String?
      var documentURL: String?
      var expected: InputFocusSnapshot.Surface
    }

    let scenarios = [
      Scenario(
        name: "editable browser text field",
        isEditable: true,
        role: "AXTextField",
        expected: .editable),
      Scenario(
        name: "web checkbox is stable non-editable",
        role: "AXCheckBox",
        expected: .stableNonEditable),
      Scenario(
        name: "native checkbox is stable non-editable",
        role: "AXCheckBox",
        expected: .stableNonEditable),
      Scenario(
        name: "web button is stable non-editable",
        role: "AXButton",
        expected: .stableNonEditable),
      Scenario(
        name: "web link is stable non-editable",
        role: "AXLink",
        expected: .stableNonEditable),
      Scenario(
        name: "ordinary table row is stable non-editable",
        role: "AXRow",
        ancestorRoles: ["AXTable"],
        expected: .stableNonEditable),
      Scenario(
        name: "ordinary table cell is stable non-editable",
        role: "AXCell",
        ancestorRoles: ["AXRow", "AXTable"],
        expected: .stableNonEditable),
      Scenario(
        name: "browser listbox option is transient",
        role: "AXOption",
        expected: .transientInteraction(reason: .role("AXOption"))),
      Scenario(
        name: "native menu item is transient",
        role: "AXMenuItem",
        expected: .transientInteraction(reason: .role("AXMenuItem"))),
      Scenario(
        name: "row under a listbox ancestor is transient",
        role: "AXStaticText",
        ancestorRoles: ["AXList"],
        expected: .transientInteraction(reason: .ancestorRole("AXList"))),
      Scenario(
        name: "expanded popup button is transient",
        role: "AXPopUpButton",
        expanded: true,
        expected: .transientInteraction(reason: .expandedRole("AXPopUpButton"))),
      Scenario(
        name: "closed popup button is stable non-editable",
        role: "AXPopUpButton",
        expanded: false,
        expected: .stableNonEditable),
      Scenario(
        name: "browser extension popup is transient",
        role: "AXWebArea",
        documentURL: "moz-extension://abc/popup.html",
        expected: .transientInteraction(reason: .extensionDocument(scheme: "moz-extension"))),
      Scenario(
        name: "chromium extension popup is transient",
        role: "AXWebArea",
        documentURL: "chrome-extension://abc/popup.html",
        expected: .transientInteraction(reason: .extensionDocument(scheme: "chrome-extension"))),
      Scenario(
        name: "native floating popup window is transient",
        role: "AXGroup",
        windowSubrole: "AXFloatingWindow",
        expected: .transientInteraction(reason: .windowSubrole("AXFloatingWindow"))),
    ]

    for scenario in scenarios {
      let actual = InputFocusSnapshot.classifySurface(
        isEditable: scenario.isEditable,
        role: scenario.role,
        expanded: scenario.expanded,
        ancestorRoles: scenario.ancestorRoles,
        windowSubrole: scenario.windowSubrole,
        documentURL: scenario.documentURL)
      XCTAssertEqual(actual, scenario.expected, scenario.name)
    }
  }

  func testInsertFocusMachineIgnoresUnarmedOrUnrelatedFocusEvents() {
    let checkbox = focusSnapshot(.stableNonEditable, role: "AXCheckBox")
    XCTAssertEqual(
      InsertModeFocusMachine.insertFocusChangeDecision(
        focusedPID: pid_t(42),
        eventPID: pid_t(42),
        armedEditablePID: nil,
        snapshot: checkbox,
        pointerPressed: false),
      .stay)
    XCTAssertEqual(
      InsertModeFocusMachine.insertFocusChangeDecision(
        focusedPID: pid_t(43),
        eventPID: pid_t(42),
        armedEditablePID: pid_t(42),
        snapshot: checkbox,
        pointerPressed: false),
      .stay)
  }

  func testNormalPointerHandoffMachineCoversEditableControlsAndPopups() {
    XCTAssertEqual(
      InsertModeFocusMachine.normalPointerHandoffDecision(
        snapshot: focusSnapshot(.editable, role: "AXTextField")),
      .enterInsert)
    XCTAssertEqual(
      InsertModeFocusMachine.normalPointerHandoffDecision(
        snapshot: focusSnapshot(.stableNonEditable, role: "AXCheckBox")),
      .recaptureNormal)
    XCTAssertEqual(
      InsertModeFocusMachine.normalPointerHandoffDecision(
        snapshot: focusSnapshot(.stableNonEditable, role: "AXButton")),
      .recaptureNormal)
    XCTAssertEqual(
      InsertModeFocusMachine.normalPointerHandoffDecision(snapshot: focusSnapshot(.unavailable)),
      .recaptureNormal)
    XCTAssertEqual(
      InsertModeFocusMachine.normalPointerHandoffDecision(
        snapshot: focusSnapshot(
          .transientInteraction(reason: .role("AXMenuItem")), role: "AXMenuItem")),
      .resampleAfter(milliseconds: InsertModeFocusMachine.transientResampleMs))
    XCTAssertEqual(
      InsertModeFocusMachine.normalPointerHandoffDecision(snapshot: nil), .recaptureNormal)
  }

  func testSelectOptionPointerHandoffSuspendsNativeSurfaceWithoutInsert() {
    let maxAttempts = InsertModeFocusMachine.transientResampleMaxAttempts
    let expandedSelect = focusSnapshot(
      .transientInteraction(reason: .expandedRole("AXPopUpButton")),
      role: "AXPopUpButton")
    let selectList = focusSnapshot(
      .transientInteraction(reason: .role("AXList")),
      role: "AXList")
    let option = focusSnapshot(
      .transientInteraction(reason: .role("AXOption")),
      role: "AXOption")

    for snapshot in [expandedSelect, selectList, option] {
      XCTAssertEqual(
        InsertModeFocusMachine.normalPointerHandoffDecision(
          snapshot: snapshot,
          attempt: maxAttempts - 1),
        .resampleAfter(milliseconds: InsertModeFocusMachine.transientResampleMs))
      XCTAssertEqual(
        InsertModeFocusMachine.normalPointerHandoffDecision(
          snapshot: snapshot,
          attempt: maxAttempts),
        .suspendNativeSurface)
    }
  }

  func testToolbarPopoverHandoffUsesFocusedTransientSurfaceWithoutStaleEditableFocus() {
    let maxAttempts = InsertModeFocusMachine.transientResampleMaxAttempts
    let clickedShieldButton = focusSnapshot(.stableNonEditable, role: "AXButton")
    let focusedPopover = focusSnapshot(
      .transientInteraction(reason: .windowSubrole("AXPopover")),
      role: "AXGroup",
      windowSubrole: "AXPopover")
    let staleFocusedTextInput = focusSnapshot(.editable, role: "AXTextField")

    XCTAssertEqual(
      InsertModeFocusMachine.normalPointerHandoffDecision(
        clickedSnapshot: clickedShieldButton,
        focusedSnapshot: focusedPopover,
        attempt: maxAttempts),
      .suspendNativeSurface)
    XCTAssertEqual(
      InsertModeFocusMachine.normalPointerHandoffDecision(
        clickedSnapshot: clickedShieldButton,
        focusedSnapshot: staleFocusedTextInput,
        attempt: 0),
      .recaptureNormal)
  }

  func testTransientResampleBudgetRecapturesAfterExhaustion() {
    let maxAttempts = InsertModeFocusMachine.transientResampleMaxAttempts
    // Firefox web content: focused AXStaticText nested under an AXList. This
    // classifies as transient but is persistent — pre-budget it spun the
    // resamplers forever. It must not become INSERT unless it resolves to a
    // genuinely editable focus target.
    let persistentTransient = focusSnapshot(
      .transientInteraction(reason: .ancestorRole("AXList")), role: "AXStaticText")

    // Pointer handoff: resample while within budget, then recapture NORMAL.
    XCTAssertEqual(
      InsertModeFocusMachine.normalPointerHandoffDecision(
        snapshot: persistentTransient, attempt: maxAttempts - 1),
      .resampleAfter(milliseconds: InsertModeFocusMachine.transientResampleMs))
    XCTAssertEqual(
      InsertModeFocusMachine.normalPointerHandoffDecision(
        snapshot: persistentTransient, attempt: maxAttempts),
      .recaptureNormal)

    // Insert-mode exit probe: resample while within budget, then STAY — never
    // kick the user out of a persistent surface they are typing into.
    func insertDecision(attempt: Int) -> InputFocusExitDecision {
      InsertModeFocusMachine.insertFocusChangeDecision(
        focusedPID: pid_t(42),
        eventPID: pid_t(42),
        armedEditablePID: pid_t(42),
        snapshot: persistentTransient,
        pointerPressed: false,
        attempt: attempt)
    }
    XCTAssertEqual(
      insertDecision(attempt: maxAttempts - 1),
      .resampleAfter(milliseconds: InsertModeFocusMachine.transientResampleMs))
    XCTAssertEqual(insertDecision(attempt: maxAttempts), .stay)

    // The budget governs only the transient branch: a genuinely stable
    // non-editable surface still exits to NORMAL immediately, no matter how
    // many attempts have elapsed.
    XCTAssertEqual(
      InsertModeFocusMachine.insertFocusChangeDecision(
        focusedPID: pid_t(42),
        eventPID: pid_t(42),
        armedEditablePID: pid_t(42),
        snapshot: focusSnapshot(.stableNonEditable, role: "AXButton"),
        pointerPressed: false,
        attempt: maxAttempts + 10),
      .exitToNormal)
  }

  func testExtensionPopupTransientBudgetSuspendsOrExitsAfterExhaustion() {
    let maxAttempts = InsertModeFocusMachine.transientResampleMaxAttempts
    let extensionPopup = focusSnapshot(
      .transientInteraction(reason: .extensionDocument(scheme: "chrome-extension")),
      role: "AXListItem",
      documentURL: "chrome-extension://vault/popup.html")

    XCTAssertEqual(
      InsertModeFocusMachine.normalPointerHandoffDecision(
        snapshot: extensionPopup,
        attempt: maxAttempts - 1),
      .resampleAfter(milliseconds: InsertModeFocusMachine.transientResampleMs))
    XCTAssertEqual(
      InsertModeFocusMachine.normalPointerHandoffDecision(
        snapshot: extensionPopup,
        attempt: maxAttempts),
      .suspendNativeSurface)

    XCTAssertEqual(
      InsertModeFocusMachine.insertFocusChangeDecision(
        focusedPID: pid_t(42),
        eventPID: pid_t(42),
        armedEditablePID: pid_t(42),
        snapshot: extensionPopup,
        pointerPressed: false,
        attempt: maxAttempts - 1),
      .resampleAfter(milliseconds: InsertModeFocusMachine.transientResampleMs))
    XCTAssertEqual(
      InsertModeFocusMachine.insertFocusChangeDecision(
        focusedPID: pid_t(42),
        eventPID: pid_t(42),
        armedEditablePID: pid_t(42),
        snapshot: extensionPopup,
        pointerPressed: false,
        attempt: maxAttempts),
      .exitToNormal)
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

  func testInsertEntryMayArmEditableFocusExitSkipsTerminalsAndLockedInsert() {
    XCTAssertFalse(
      AppDelegate.insertModeMayArmEditableFocusExit(
        bundleIdentifier: "org.alacritty",
        insertModeLocked: false))
    XCTAssertFalse(
      AppDelegate.insertModeMayArmEditableFocusExit(
        bundleIdentifier: "com.apple.Terminal",
        insertModeLocked: false))
    XCTAssertFalse(
      AppDelegate.insertModeMayArmEditableFocusExit(
        bundleIdentifier: "com.apple.MobileSMS",
        insertModeLocked: true))
    XCTAssertFalse(
      AppDelegate.insertModeMayArmEditableFocusExit(
        bundleIdentifier: nil,
        insertModeLocked: false))
    XCTAssertTrue(
      AppDelegate.insertModeMayArmEditableFocusExit(
        bundleIdentifier: "com.apple.MobileSMS",
        insertModeLocked: false))
  }

  func testInsertEntryOnlyRepairsEditableFocusAfterPointerOrHintEditableHandoff() {
    XCTAssertTrue(
      AppDelegate.insertModeMayRepairEditableFocus(
        reason: .pointerClick,
        bundleIdentifier: "com.apple.MobileSMS",
        insertModeLocked: false))
    XCTAssertTrue(
      AppDelegate.insertModeMayRepairEditableFocus(
        reason: .hintCommit,
        bundleIdentifier: "org.mozilla.firefox",
        insertModeLocked: false))
    XCTAssertFalse(
      AppDelegate.insertModeMayRepairEditableFocus(
        reason: .normalModeInput,
        bundleIdentifier: "com.apple.MobileSMS",
        insertModeLocked: false))
    XCTAssertFalse(
      AppDelegate.insertModeMayRepairEditableFocus(
        reason: .explicitCommand,
        bundleIdentifier: "org.mozilla.firefox",
        insertModeLocked: false))
    XCTAssertFalse(
      AppDelegate.insertModeMayRepairEditableFocus(
        reason: .lockedNormalModeInput,
        bundleIdentifier: "com.apple.MobileSMS",
        insertModeLocked: true))
    XCTAssertFalse(
      AppDelegate.insertModeMayRepairEditableFocus(
        reason: .pointerClick,
        bundleIdentifier: "org.alacritty",
        insertModeLocked: false))
    XCTAssertFalse(
      AppDelegate.insertModeMayRepairEditableFocus(
        reason: nil,
        bundleIdentifier: "com.apple.MobileSMS",
        insertModeLocked: false))
  }

  func testInsertEntryCarriesNormalModeTargetUnlessExplicitTargetIsProvided() {
    XCTAssertEqual(
      AppDelegate.insertEntryTargetPID(
        explicitTargetPID: nil,
        currentMode: .normal,
        normalModeTargetPID: pid_t(42)),
      pid_t(42))
    XCTAssertEqual(
      AppDelegate.insertEntryTargetPID(
        explicitTargetPID: pid_t(7),
        currentMode: .normal,
        normalModeTargetPID: pid_t(42)),
      pid_t(7))
    XCTAssertNil(
      AppDelegate.insertEntryTargetPID(
        explicitTargetPID: nil,
        currentMode: .insert,
        normalModeTargetPID: pid_t(42)))
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

  func testInsertModeFocusLossExitRequiresArmedEditablePID() {
    XCTAssertFalse(shouldExitAfterFocusedElementChange(editableFocusExitPID: nil))
    XCTAssertFalse(shouldExitAfterFocusedElementChange(editableFocusExitPID: pid_t(43)))
  }

  func testInsertModeExitsWhenOwningAppLosesFocus() {
    XCTAssertTrue(shouldExitAfterFocusedAppChange(focusedPID: pid_t(43)))
    XCTAssertFalse(shouldExitAfterFocusedAppChange(focusedPID: pid_t(42)))
    XCTAssertFalse(shouldExitAfterFocusedAppChange(insertFocusOwnerPID: nil, focusedPID: pid_t(43)))
    XCTAssertFalse(shouldExitAfterFocusedAppChange(focusedPID: nil))
  }

  func testInsertModeFocusLossExitRespectsModeGuards() {
    XCTAssertFalse(shouldExitAfterFocusedElementChange(mode: .normal))
    XCTAssertFalse(shouldExitAfterFocusedElementChange(modeBadgeEnabled: false))
    XCTAssertFalse(shouldExitAfterFocusedElementChange(overlayInputMode: .commandLine))
    XCTAssertFalse(shouldExitAfterFocusedElementChange(hasHints: true))
    XCTAssertFalse(shouldExitAfterFocusedElementChange(activationInFlight: true))
    XCTAssertFalse(shouldExitAfterFocusedElementChange(focusedPID: pid_t(43)))

    XCTAssertFalse(shouldExitAfterFocusedAppChange(mode: .normal, focusedPID: pid_t(43)))
    XCTAssertFalse(shouldExitAfterFocusedAppChange(modeBadgeEnabled: false, focusedPID: pid_t(43)))
    XCTAssertFalse(
      shouldExitAfterFocusedAppChange(overlayInputMode: .commandLine, focusedPID: pid_t(43)))
    XCTAssertFalse(shouldExitAfterFocusedAppChange(hasHints: true, focusedPID: pid_t(43)))
    XCTAssertFalse(shouldExitAfterFocusedAppChange(activationInFlight: true, focusedPID: pid_t(43)))
  }

  func testInsertFocusExitWaitsForPointerRelease() {
    XCTAssertFalse(AppDelegate.insertFocusExitShouldWaitForPointerRelease(pressedMouseButtons: 0))
    XCTAssertTrue(AppDelegate.insertFocusExitShouldWaitForPointerRelease(pressedMouseButtons: 1))
    XCTAssertTrue(AppDelegate.insertFocusExitShouldWaitForPointerRelease(pressedMouseButtons: 2))
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
    XCTAssertTrue(AppMonitor.backgroundModelRefreshShouldThrottle(reason: "ax:AXValueChanged"))
    XCTAssertTrue(AppMonitor.backgroundModelRefreshShouldThrottle(reason: "queued"))
    XCTAssertTrue(AppMonitor.backgroundModelRefreshShouldThrottle(reason: "maintenance"))
    XCTAssertFalse(AppMonitor.backgroundModelRefreshShouldThrottle(reason: "focus"))
    XCTAssertFalse(AppMonitor.backgroundModelRefreshShouldThrottle(reason: "config"))
  }

  func testAXEventStormSuppressesOnlySpeculativePreparedModelRefreshes() {
    let registry = SourceRegistry(descriptors: [], runningApplications: [])
    let monitor = AppMonitor(registry: registry, config: .default)
    let pid = pid_t(42)
    monitor.scheduleModelRefresh(for: pid, reason: "ax:AXUIElementDestroyed")
    XCTAssertTrue(monitor.modelRefreshArmed.contains(pid))

    for _ in 0..<AppMonitor.axEventStormCountThreshold {
      monitor.noteAXEventForStormDetection(
        pid: pid, notification: kAXUIElementDestroyedNotification as String)
    }

    XCTAssertTrue(monitor.axEventStormingPIDs.contains(pid))
    XCTAssertFalse(monitor.modelRefreshArmed.contains(pid))
    monitor.scheduleModelRefresh(for: pid, reason: "ax:AXUIElementDestroyed")
    XCTAssertFalse(monitor.modelRefreshArmed.contains(pid))
    monitor.scheduleModelRefresh(for: pid, reason: "maintenance")
    XCTAssertFalse(monitor.modelRefreshArmed.contains(pid))

    monitor.scheduleModelRefresh(for: pid, reason: "focus")
    XCTAssertTrue(monitor.modelRefreshArmed.contains(pid))
    monitor.cancelRefreshWork(for: pid)
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

  func testSlowAutomaticPreparedModelRefreshBacksOffOnlySpeculativeWork() {
    XCTAssertTrue(
      AppMonitor.automaticModelRefreshIsSlow(
        elapsedMs: AppMonitor.slowAutomaticModelRefreshThresholdMs))
    XCTAssertFalse(
      AppMonitor.automaticModelRefreshIsSlow(
        elapsedMs: AppMonitor.slowAutomaticModelRefreshThresholdMs - 0.01))

    let registry = SourceRegistry(descriptors: [], runningApplications: [])
    let monitor = AppMonitor(registry: registry, config: .default)
    let pid = pid_t(43)
    monitor.slowAutomaticModelRefreshPIDs.insert(pid)

    monitor.scheduleModelRefresh(for: pid, reason: "ax:AXLayoutChanged")
    XCTAssertFalse(monitor.modelRefreshArmed.contains(pid))
    monitor.scheduleModelRefresh(for: pid, reason: "queued")
    XCTAssertFalse(monitor.modelRefreshArmed.contains(pid))
    monitor.scheduleModelRefresh(for: pid, reason: "maintenance")
    XCTAssertFalse(monitor.modelRefreshArmed.contains(pid))
    monitor.scheduleModelRefresh(for: pid, reason: "focus")
    XCTAssertTrue(monitor.modelRefreshArmed.contains(pid))
    monitor.cancelRefreshWork(for: pid)
  }

  func testAutomaticPreparedModelRefreshSkipsNotes() {
    XCTAssertFalse(
      AppMonitor.shouldRunAutomaticPreparedModelRefresh(bundleIdentifier: "com.apple.Notes"))
    XCTAssertTrue(
      AppMonitor.shouldRunAutomaticPreparedModelRefresh(bundleIdentifier: "com.apple.TextEdit"))
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

  func testBrowserTabNavigationExitRecognizesCommittedWebURLsOnly() {
    XCTAssertTrue(
      AppDelegate.insertNavigationExitShouldExit(
        currentURL: "https://example.com/path",
        initialURL: "about:blank"))
    XCTAssertTrue(
      AppDelegate.insertNavigationExitShouldExit(
        currentURL: "http://localhost:3000",
        initialURL: "chrome://newtab/"))
    XCTAssertFalse(
      AppDelegate.insertNavigationExitShouldExit(
        currentURL: "https://example.com/path",
        initialURL: "https://example.com/path"))
    XCTAssertFalse(
      AppDelegate.insertNavigationExitShouldExit(
        currentURL: "chrome://newtab/",
        initialURL: "https://previous.example"))
    XCTAssertFalse(
      AppDelegate.insertNavigationExitShouldExit(
        currentURL: "about:blank",
        initialURL: nil))
    XCTAssertFalse(
      AppDelegate.insertNavigationExitShouldExit(
        currentURL: nil,
        initialURL: nil))
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
      AppDelegate.pointerFocusLossShouldDeferRecaptureForPointerMonitor(
        inputMode: .normal,
        modeBadgeVisible: true,
        modeBadgeCapturesInput: true))
    XCTAssertTrue(
      AppDelegate.pointerFocusLossShouldDeferRecaptureForPointerMonitor(
        inputMode: .commandLine,
        modeBadgeVisible: false,
        modeBadgeCapturesInput: false))
    // Idle NORMAL classifies clicks via the monitor even when keyboard capture
    // is temporarily suppressed.
    XCTAssertTrue(
      AppDelegate.pointerFocusLossShouldDeferRecaptureForPointerMonitor(
        inputMode: .normal,
        modeBadgeVisible: true,
        modeBadgeCapturesInput: false))
    XCTAssertFalse(
      AppDelegate.pointerFocusLossShouldDeferRecaptureForPointerMonitor(
        inputMode: .hints,
        modeBadgeVisible: false,
        modeBadgeCapturesInput: true))
  }

  func testCommandLineEntryIsAllowedFromInsertAndNormalModeEvenWithTransientHints() {
    XCTAssertTrue(
      AppDelegate.commandLineEntryIsAllowed(
        mode: .insert,
        hasHints: false,
        activationInFlight: false))
    XCTAssertTrue(
      AppDelegate.commandLineEntryIsAllowed(
        mode: .normal,
        hasHints: false,
        activationInFlight: false))
    XCTAssertTrue(
      AppDelegate.commandLineEntryIsAllowed(
        mode: .insert,
        hasHints: true,
        activationInFlight: false))
    XCTAssertTrue(
      AppDelegate.commandLineEntryIsAllowed(
        mode: .normal,
        hasHints: false,
        activationInFlight: true))
  }

  func testCommandLineExitAlwaysReturnsToNormalMode() {
    XCTAssertEqual(
      AppDelegate.commandLineExitMode(currentMode: .insert),
      .normal)
    XCTAssertEqual(
      AppDelegate.commandLineExitMode(currentMode: .normal),
      .normal)
  }

  func testModeOverlayCaptureIsOnlyPossibleInIdleNormalMode() {
    let labels = Config.Mode.Labels(normal: "NORMAL", insert: "INSERT", command: "COMMAND")
    XCTAssertEqual(
      AppDelegate.modeOverlaySnapshot(
        mode: .insert,
        labels: labels,
        visible: true,
        hasHints: false,
        activationInFlight: false,
        captureOverride: true),
      ModeOverlaySnapshot(
        text: "INSERT",
        visible: true,
        captureInput: false,
        inputMode: .hints,
        refreshActiveWindowBorder: true))
    XCTAssertEqual(
      AppDelegate.modeOverlaySnapshot(
        mode: .normal,
        labels: labels,
        visible: true,
        hasHints: false,
        activationInFlight: false,
        captureOverride: true),
      ModeOverlaySnapshot(
        text: "NORMAL",
        visible: true,
        captureInput: true,
        inputMode: .normal,
        refreshActiveWindowBorder: true))
    XCTAssertFalse(
      AppDelegate.modeOverlaySnapshot(
        mode: .normal,
        labels: labels,
        visible: true,
        hasHints: false,
        activationInFlight: false,
        captureOverride: false
      ).captureInput)
    XCTAssertFalse(
      AppDelegate.modeOverlaySnapshot(
        mode: .normal,
        labels: labels,
        visible: true,
        hasHints: true,
        activationInFlight: false,
        captureOverride: true
      ).captureInput)
    XCTAssertFalse(
      AppDelegate.modeOverlaySnapshot(
        mode: .normal,
        labels: labels,
        visible: true,
        hasHints: false,
        activationInFlight: true,
        captureOverride: true
      ).captureInput)
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
        overlayInputMode: .hints,
        hasHints: false,
        activationInFlight: false))
  }

  func testModeStatusBarVisibleInInsertWithoutCapturing() {
    let labels = Config.Mode.Labels(normal: "NORMAL", insert: "INSERT", command: "COMMAND")
    let snapshot = AppDelegate.modeOverlaySnapshot(
      mode: .insert,
      labels: labels,
      visible: true,
      hasHints: false,
      activationInFlight: false,
      captureOverride: nil)
    XCTAssertTrue(snapshot.visible)
    XCTAssertEqual(snapshot.text, "INSERT")
    XCTAssertFalse(snapshot.captureInput)
    // NORMAL keeps respecting the advanced-mode flag.
    XCTAssertTrue(
      AppDelegate.modeOverlaySnapshot(
        mode: .normal,
        labels: labels,
        visible: true,
        hasHints: false,
        activationInFlight: false,
        captureOverride: nil
      ).visible)
    XCTAssertFalse(
      AppDelegate.modeOverlaySnapshot(
        mode: .normal,
        labels: labels,
        visible: false,
        hasHints: false,
        activationInFlight: false,
        captureOverride: nil
      ).visible)
  }

  func testActiveWindowBorderVisibility() {
    // The border shows in BOTH modes (thin green normal / thicker blue insert)
    // when advanced mode is on, no hints are up, and the desktop session is
    // active — so the active window is always identifiable.
    XCTAssertTrue(
      AppDelegate.activeWindowBorderShouldBeVisible(
        modeBadgeEnabled: true,
        hasHints: false,
        sessionActive: true))
    // No advanced mode → no normal/insert distinction to draw.
    XCTAssertFalse(
      AppDelegate.activeWindowBorderShouldBeVisible(
        modeBadgeEnabled: false,
        hasHints: false,
        sessionActive: true))
    // Lock/session switch/sleep hides the border immediately.
    XCTAssertFalse(
      AppDelegate.activeWindowBorderShouldBeVisible(
        modeBadgeEnabled: true,
        hasHints: false,
        sessionActive: false))
    // Hints suppress the border so chips aren't double-framed.
    XCTAssertFalse(
      AppDelegate.activeWindowBorderShouldBeVisible(
        modeBadgeEnabled: true,
        hasHints: true,
        sessionActive: true))
  }

  func testActiveWindowBorderStyleIsGreenInNormalAndBlueInInsert() {
    // Normal = thin green (no glow); insert = thicker, glowing blue. Both share
    // the same outer edge — insert grows inward.
    let normal = AppDelegate.activeWindowBorderStyle(for: .normal)
    let insert = AppDelegate.activeWindowBorderStyle(for: .insert)
    XCTAssertEqual(normal.color, OverlayPanel.nordAuroraGreenCG)
    XCTAssertEqual(normal.lineWidth, 1)
    XCTAssertFalse(normal.glow)
    XCTAssertEqual(insert.color, OverlayPanel.nordFrost2CG)
    XCTAssertEqual(insert.lineWidth, 2)
    XCTAssertTrue(insert.glow)
    XCTAssertGreaterThan(insert.lineWidth, normal.lineWidth)

    // Command = thin purple (1px like normal), no glow.
    let command = AppDelegate.activeWindowBorderStyle(for: .command)
    XCTAssertEqual(command.color, OverlayPanel.nordAuroraPurpleCG)
    XCTAssertEqual(command.lineWidth, 1)
    XCTAssertFalse(command.glow)
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

  func testNormalModeCaptureRecoveryScheduleIsBoundedAndStartsAfterFastRamp() {
    XCTAssertEqual(AppDelegate.normalModeCaptureRecoveryDelaysMs, [250, 750, 1_500, 3_000])
    XCTAssertGreaterThan(AppDelegate.normalModeCaptureRecoveryDelaysMs.first ?? 0, 0)
    XCTAssertEqual(AppDelegate.normalModeCaptureRecoveryDelaysMs.count, 4)
  }

  func testNormalModeCaptureRecoveryRetriesOnlyWhenNormalCaptureIsStillMissing() {
    let now = Date(timeIntervalSince1970: 1_000)

    XCTAssertTrue(
      AppDelegate.normalModeCaptureRecoveryShouldRetry(
        mode: .normal,
        overlayInputMode: .normal,
        hasHints: false,
        activationInFlight: false,
        keyboardCaptureIsActive: false,
        menuBarInteractionRecaptureSuppressedUntil: nil,
        contextMenuInteractionRecaptureSuppressedUntil: nil,
        pointerInsertHandoffRecaptureSuppressedUntil: nil,
        now: now))
    XCTAssertTrue(
      AppDelegate.normalModeCaptureRecoveryShouldRetry(
        mode: .normal,
        overlayInputMode: .hints,
        hasHints: false,
        activationInFlight: false,
        keyboardCaptureIsActive: false,
        menuBarInteractionRecaptureSuppressedUntil: nil,
        contextMenuInteractionRecaptureSuppressedUntil: nil,
        pointerInsertHandoffRecaptureSuppressedUntil: nil,
        now: now))
    XCTAssertFalse(
      AppDelegate.normalModeCaptureRecoveryShouldRetry(
        mode: .insert,
        overlayInputMode: .hints,
        hasHints: false,
        activationInFlight: false,
        keyboardCaptureIsActive: false,
        menuBarInteractionRecaptureSuppressedUntil: nil,
        contextMenuInteractionRecaptureSuppressedUntil: nil,
        pointerInsertHandoffRecaptureSuppressedUntil: nil,
        now: now))
    XCTAssertFalse(
      AppDelegate.normalModeCaptureRecoveryShouldRetry(
        mode: .normal,
        overlayInputMode: .commandLine,
        hasHints: false,
        activationInFlight: false,
        keyboardCaptureIsActive: false,
        menuBarInteractionRecaptureSuppressedUntil: nil,
        contextMenuInteractionRecaptureSuppressedUntil: nil,
        pointerInsertHandoffRecaptureSuppressedUntil: nil,
        now: now))
    XCTAssertFalse(
      AppDelegate.normalModeCaptureRecoveryShouldRetry(
        mode: .normal,
        overlayInputMode: .normal,
        hasHints: true,
        activationInFlight: false,
        keyboardCaptureIsActive: false,
        menuBarInteractionRecaptureSuppressedUntil: nil,
        contextMenuInteractionRecaptureSuppressedUntil: nil,
        pointerInsertHandoffRecaptureSuppressedUntil: nil,
        now: now))
    XCTAssertFalse(
      AppDelegate.normalModeCaptureRecoveryShouldRetry(
        mode: .normal,
        overlayInputMode: .normal,
        hasHints: false,
        activationInFlight: true,
        keyboardCaptureIsActive: false,
        menuBarInteractionRecaptureSuppressedUntil: nil,
        contextMenuInteractionRecaptureSuppressedUntil: nil,
        pointerInsertHandoffRecaptureSuppressedUntil: nil,
        now: now))
    XCTAssertFalse(
      AppDelegate.normalModeCaptureRecoveryShouldRetry(
        mode: .normal,
        overlayInputMode: .normal,
        hasHints: false,
        activationInFlight: false,
        keyboardCaptureIsActive: true,
        menuBarInteractionRecaptureSuppressedUntil: nil,
        contextMenuInteractionRecaptureSuppressedUntil: nil,
        pointerInsertHandoffRecaptureSuppressedUntil: nil,
        now: now))
  }

  func testNormalModeCaptureRecoveryRespectsNativeSurfaceSuppressions() {
    let now = Date(timeIntervalSince1970: 1_000)
    let activeSuppression = now.addingTimeInterval(0.5)
    let expiredSuppression = now.addingTimeInterval(-0.1)

    XCTAssertFalse(
      AppDelegate.normalModeCaptureRecoveryShouldRetry(
        mode: .normal,
        overlayInputMode: .normal,
        hasHints: false,
        activationInFlight: false,
        keyboardCaptureIsActive: false,
        menuBarInteractionRecaptureSuppressedUntil: activeSuppression,
        contextMenuInteractionRecaptureSuppressedUntil: nil,
        pointerInsertHandoffRecaptureSuppressedUntil: nil,
        now: now))
    XCTAssertFalse(
      AppDelegate.normalModeCaptureRecoveryShouldRetry(
        mode: .normal,
        overlayInputMode: .normal,
        hasHints: false,
        activationInFlight: false,
        keyboardCaptureIsActive: false,
        menuBarInteractionRecaptureSuppressedUntil: nil,
        contextMenuInteractionRecaptureSuppressedUntil: activeSuppression,
        pointerInsertHandoffRecaptureSuppressedUntil: nil,
        now: now))
    XCTAssertFalse(
      AppDelegate.normalModeCaptureRecoveryShouldRetry(
        mode: .normal,
        overlayInputMode: .normal,
        hasHints: false,
        activationInFlight: false,
        keyboardCaptureIsActive: false,
        menuBarInteractionRecaptureSuppressedUntil: nil,
        contextMenuInteractionRecaptureSuppressedUntil: nil,
        pointerInsertHandoffRecaptureSuppressedUntil: activeSuppression,
        now: now))
    XCTAssertTrue(
      AppDelegate.normalModeCaptureRecoveryShouldRetry(
        mode: .normal,
        overlayInputMode: .normal,
        hasHints: false,
        activationInFlight: false,
        keyboardCaptureIsActive: false,
        menuBarInteractionRecaptureSuppressedUntil: expiredSuppression,
        contextMenuInteractionRecaptureSuppressedUntil: expiredSuppression,
        pointerInsertHandoffRecaptureSuppressedUntil: expiredSuppression,
        now: now))
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
        .menuBar(
          NormalModePointerPolicy.MenuBarClickDecision(
            suspendForNativeSurface: true,
            dismissTransientHintsWithoutRekey: false)))
    }
  }

  func testNormalModePointerPolicyMatrixForAppClicks() {
    XCTAssertEqual(
      NormalModePointerPolicy.appClickDecision(
        mode: .normal,
        wasCommandLine: false,
        hasHints: false,
        action: .leftClick),
      NormalModePointerPolicy.AppClickDecision(
        releaseCapture: true,
        probeForInsert: true,
        suspendForNativeSurface: false,
        dismissTransientHintsWithoutRekey: false))
    XCTAssertEqual(
      NormalModePointerPolicy.appClickDecision(
        mode: .normal,
        wasCommandLine: false,
        hasHints: false,
        action: .doubleClick),
      NormalModePointerPolicy.AppClickDecision(
        releaseCapture: true,
        probeForInsert: true,
        suspendForNativeSurface: false,
        dismissTransientHintsWithoutRekey: false))
    // Right-click never flips the mode: it suspends normal capture so the
    // native context menu owns the keyboard, and drops any transient hints
    // showing behind it (so `dismissTransientHintsWithoutRekey` tracks hasHints).
    XCTAssertEqual(
      NormalModePointerPolicy.appClickDecision(
        mode: .normal,
        wasCommandLine: false,
        hasHints: true,
        action: .rightClick),
      NormalModePointerPolicy.AppClickDecision(
        releaseCapture: false,
        probeForInsert: false,
        suspendForNativeSurface: true,
        dismissTransientHintsWithoutRekey: true))
    XCTAssertEqual(
      NormalModePointerPolicy.appClickDecision(
        mode: .normal,
        wasCommandLine: false,
        hasHints: false,
        action: .rightClick),
      NormalModePointerPolicy.AppClickDecision(
        releaseCapture: false,
        probeForInsert: false,
        suspendForNativeSurface: true,
        dismissTransientHintsWithoutRekey: false))
    XCTAssertEqual(
      NormalModePointerPolicy.appClickDecision(
        mode: .insert,
        wasCommandLine: false,
        hasHints: false,
        action: .leftClick),
      NormalModePointerPolicy.AppClickDecision(
        releaseCapture: false,
        probeForInsert: false,
        suspendForNativeSurface: false,
        dismissTransientHintsWithoutRekey: false))
    XCTAssertEqual(
      NormalModePointerPolicy.appClickDecision(
        mode: .normal,
        wasCommandLine: true,
        hasHints: false,
        action: .leftClick),
      NormalModePointerPolicy.AppClickDecision(
        releaseCapture: false,
        probeForInsert: false,
        suspendForNativeSurface: false,
        dismissTransientHintsWithoutRekey: false))
  }

  func testPointerActionMayEnterInsertExcludesRightClick() {
    // Left / double click can hand the keyboard to the app (subject to the
    // editability probe at commit); right-click only ever opens a context menu
    // and must keep the current mode, so it is excluded here. This is what keeps
    // the `f`-hint right-click commit on the suspend path instead of insert.
    XCTAssertTrue(NormalModePointerPolicy.pointerActionMayEnterInsert(.leftClick))
    XCTAssertTrue(NormalModePointerPolicy.pointerActionMayEnterInsert(.doubleClick))
    XCTAssertFalse(NormalModePointerPolicy.pointerActionMayEnterInsert(.rightClick))
  }

  func testNormalAppRightClickSuspendsForContextMenuInsteadOfInsert() {
    // Top-level decision: a physical right-click on the app body resolves to an
    // app decision that suspends for the native surface (the context menu) and
    // never releases capture into an insert handoff — uniform with the `f`/`F`
    // right-click commits.
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
        NormalModePointerPolicy.AppClickDecision(
          releaseCapture: false,
          probeForInsert: false,
          suspendForNativeSurface: true,
          dismissTransientHintsWithoutRekey: false)))
  }

  func testPhysicalPointerClickForwardingOnlyCoversActivationOnlyPrimaryClicks() {
    let released = NormalModePointerPolicy.AppClickDecision(
      releaseCapture: true,
      probeForInsert: true,
      suspendForNativeSurface: false,
      dismissTransientHintsWithoutRekey: false)
    let notReleased = NormalModePointerPolicy.AppClickDecision(
      releaseCapture: false,
      probeForInsert: false,
      suspendForNativeSurface: false,
      dismissTransientHintsWithoutRekey: false)

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
      .menuBar(
        NormalModePointerPolicy.MenuBarClickDecision(
          suspendForNativeSurface: true,
          dismissTransientHintsWithoutRekey: true)))
  }

  func testWorkspaceActivationRecaptureSkipsPointerInsertHandoff() {
    let now = Date(timeIntervalSince1970: 1_000)
    let activeSuppression = now.addingTimeInterval(0.5)
    let expiredSuppression = now.addingTimeInterval(-0.1)

    XCTAssertFalse(
      AppDelegate.workspaceActivationShouldScheduleNormalModeRecapture(
        mode: .normal,
        menuBarInteractionRecaptureSuppressedUntil: nil,
        pointerInsertHandoffRecaptureSuppressedUntil: activeSuppression,
        now: now))
    XCTAssertTrue(
      AppDelegate.workspaceActivationShouldScheduleNormalModeRecapture(
        mode: .normal,
        menuBarInteractionRecaptureSuppressedUntil: nil,
        pointerInsertHandoffRecaptureSuppressedUntil: expiredSuppression,
        now: now))
  }

  func testPointerFocusLossDeferralIsBriefSoNormalModeReclaimsFocus() {
    // The deferral only needs to outlast the pointer monitor turning a click
    // into INSERT; it must be far shorter than the suppression windows so an
    // app that spontaneously steals focus in NORMAL is reclaimed almost
    // immediately instead of sitting there while the badge still reads NORMAL.
    XCTAssertEqual(AppDelegate.pointerFocusLossRecaptureDeferralMs, 120)
    XCTAssertLessThan(
      AppDelegate.pointerFocusLossRecaptureDeferralMs,
      AppDelegate.pointerInsertHandoffRecaptureSuppressionMs)
  }

  func testPointerInsertHandoffTokenRejectsStaleAndExpiredProbes() {
    let now = Date(timeIntervalSince1970: 1_000)
    let activeSuppression = now.addingTimeInterval(0.5)
    let expiredSuppression = now.addingTimeInterval(-0.1)

    XCTAssertTrue(
      AppDelegate.pointerInsertHandoffIsCurrent(
        token: 7,
        currentToken: 7,
        pointerInsertHandoffRecaptureSuppressedUntil: activeSuppression,
        now: now))
    XCTAssertFalse(
      AppDelegate.pointerInsertHandoffIsCurrent(
        token: 6,
        currentToken: 7,
        pointerInsertHandoffRecaptureSuppressedUntil: activeSuppression,
        now: now))
    XCTAssertFalse(
      AppDelegate.pointerInsertHandoffIsCurrent(
        token: 7,
        currentToken: 7,
        pointerInsertHandoffRecaptureSuppressedUntil: expiredSuppression,
        now: now))
    XCTAssertTrue(
      AppDelegate.pointerInsertHandoffIsCurrent(
        token: nil,
        currentToken: 7,
        pointerInsertHandoffRecaptureSuppressedUntil: nil,
        now: now))
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

  func testCommandLineParser() {
    // `:q` closes the focused window (force is irrelevant to a window close);
    // `:qa[ll]` quits the whole app.
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("q"), .closeWindow)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("qu"), .closeWindow)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("qui"), .closeWindow)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("quit"), .closeWindow)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("  QUIT  "), .closeWindow)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("q!"), .closeWindow)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("qu!"), .closeWindow)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("quit!"), .closeWindow)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("qa"), .quit(force: false))
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("qall"), .quit(force: false))
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("qa!"), .quit(force: true))
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("w"), .save)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("wr"), .save)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("wri"), .save)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("write!"), .save)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("wq"), .saveAndQuit(force: false))
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("xit"), .saveAndQuit(force: false))
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("x!"), .saveAndQuit(force: true))
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("p"), .print)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("pr"), .print)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("print"), .print)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("e"), .open)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("edi"), .open)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("new"), .newWindow)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("tabnew"), .newTab)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("bd"), .close)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("bdel"), .close)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("cl"), .close)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("find"), .find)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("u"), .undo)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("undo"), .undo)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("red"), .redo)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("redo"), .redo)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("y"), .copy)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("yank"), .copy)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("d"), .cut)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("delete"), .cut)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("put"), .paste)
    XCTAssertNil(NormalModeDispatcher.commandLineCommand("%y"))
    XCTAssertNil(NormalModeDispatcher.commandLineCommand(":%yan"))
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand(":plugins"), .plugins(.modal))
    XCTAssertEqual(
      NormalModeDispatcher.commandLineCommand(":plugins reload"), .plugins(.reload))
    XCTAssertNil(NormalModeDispatcher.commandLineCommand(":plugins bogus"))
    XCTAssertNil(NormalModeDispatcher.commandLineCommand(":plugins reload extra"))
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand(":mappings"), .mappings)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand(":map"), .mappings)
    XCTAssertNil(NormalModeDispatcher.commandLineCommand("q!!"))
    XCTAssertNil(NormalModeDispatcher.commandLineCommand("p!"))
    XCTAssertNil(NormalModeDispatcher.commandLineCommand("qu!it"))
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

  func testCommandLineHelpTopicParser() throws {
    XCTAssertEqual(try XCTUnwrap(NormalModeDispatcher.commandLineHelpTopic(":help")), nil)
    XCTAssertEqual(try XCTUnwrap(NormalModeDispatcher.commandLineHelpTopic(":h")), nil)
    XCTAssertEqual(
      try XCTUnwrap(NormalModeDispatcher.commandLineHelpTopic(":help plugins")),
      "plugins")
    XCTAssertEqual(
      try XCTUnwrap(NormalModeDispatcher.commandLineHelpTopic("  HELP   normal-mode  ")),
      "normal-mode")
    XCTAssertTrue(NormalModeDispatcher.commandLineHelpTopic(":hello") == nil)
  }

  func testHelpDocsRenderIndexAndTopic() {
    // The marks help topic moved into the marks plugin's manifest, so the
    // test surfaces it the way the host does at runtime: by feeding a
    // simulated `pluginTopics` slice into the renderer. The plugin topic
    // matches its `Plugins/marks/manifest.json`'s `help.topics[]` entry.
    let marksTopic = HelpTopic(
      name: "marks",
      title: "Marks",
      summary: "Vim-style marks: `m<letter>` to set, `` `<letter> `` to jump.",
      body:
        "# Marks\n\nFlash carries a Vim-style mark register. Each letter `a`-`z` holds one mark.\nSet a mark with `m<letter>` (e.g. `ma`); jump with `` `<letter> ``.\n",
      aliases: ["mark"])
    let index = HelpDocs.render(
      topic: nil, config: .default, showModes: true, pluginTopics: [marksTopic])
    XCTAssertTrue(index.contains("`plugins`"))
    XCTAssertTrue(index.contains("`normal-mode`"))
    XCTAssertTrue(index.contains("`marks`"), "marks topic should appear in the index")
    XCTAssertTrue(index.contains("`mark`"), "marks alias should be visible in the index")
    XCTAssertTrue(index.contains("`flashlight`"), "flashlight topic should appear in the index")

    let plugins = HelpDocs.render(topic: "plugins", config: .default, showModes: true)
    XCTAssertTrue(plugins.contains("# Plugins"))
    XCTAssertTrue(plugins.contains("manifest.json"))

    let marks = HelpDocs.render(
      topic: "marks", config: .default, showModes: true, pluginTopics: [marksTopic])
    XCTAssertTrue(marks.contains("# Marks"))
    XCTAssertTrue(marks.contains("m<letter>") || marks.contains("`ma`") || marks.contains("ma "))

    let mark = HelpDocs.render(
      topic: "mark", config: .default, showModes: true, pluginTopics: [marksTopic])
    XCTAssertEqual(
      mark, marks,
      ":help mark must resolve to the same body as :help marks")

    let unknown = HelpDocs.render(topic: "missing", config: .default, showModes: true)
    XCTAssertTrue(unknown.contains("Unknown Help Topic"))
  }

  func testMouseGridIsSquareWithLargestOddNAlphabetSquare() {
    // 16-letter alphabet → largest odd N with N² ≤ 16 is 3 → 3x3 (= 9
    // cells). The grid stays square regardless of region aspect ratio.
    let region = MouseGrid.Region(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
    let hints = MouseGrid.hints(
      in: region,
      depth: 0,
      alphabet: Array("abcdefghijklmnop"))

    XCTAssertEqual(hints.count, 9)
    XCTAssertEqual(hints.first?.label, "a")
    XCTAssertEqual(hints.last?.label, "i")
    // 3x3 over a 400x200 region → cell ≈ 133.33 x 66.67. Cells touch
    // edge-to-edge (no gap).
    let cellW = 400.0 / 3.0
    let cellH = 200.0 / 3.0
    XCTAssertEqual(hints[0].target.frame.width, cellW, accuracy: 0.01)
    XCTAssertEqual(hints[0].target.frame.height, cellH, accuracy: 0.01)
  }

  func testMouseGridUses5x5For25LetterAlphabet() {
    // qwerty homerow + toprow = 20 letters; not enough for 5x5 (= 25).
    // A 25-letter alphabet (homerow+toprow with an extra) lands on 5x5.
    let alphabet = Array("abcdefghijklmnopqrstuvwxy")  // 25 letters
    let region = MouseGrid.preparedRegion(
      MouseGrid.Region(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
      alphabet: alphabet)
    XCTAssertEqual(region.grid, MouseGrid.Grid(columns: 5, rows: 5))
  }

  func testMouseGridCenterCellIsTheRegionMiddle() throws {
    // `<space>` commits `grid.centerCellIndex`; for the odd-N square grids
    // the enum produces that hint must sit dead-centre on the region so
    // repeated `<space>` converges on the exact middle.
    XCTAssertEqual(MouseGrid.Grid(columns: 3, rows: 3).centerCellIndex, 4)
    XCTAssertEqual(MouseGrid.Grid(columns: 5, rows: 5).centerCellIndex, 12)

    let alphabet = Array("abcdefghijklmnopqrstuvwxy")  // 25 letters → 5x5
    let region = MouseGrid.preparedRegion(
      MouseGrid.Region(frame: CGRect(x: 0, y: 0, width: 1000, height: 600)),
      alphabet: alphabet)
    let grid = try XCTUnwrap(region.grid)
    let hints = MouseGrid.hints(in: region, depth: 0, alphabet: alphabet)
    let center = hints[grid.centerCellIndex]
    XCTAssertEqual(center.target.frame.midX, region.frame.midX, accuracy: 0.01)
    XCTAssertEqual(center.target.frame.midY, region.frame.midY, accuracy: 0.01)
  }

  func testMouseGridFinalStepRendersCompactClusterCenteredOnPastRect() {
    // 9-cell alphabet → 3x3. Past rectangle is small enough that tile
    // cells would be smaller than the chip — exactly the case the
    // compact-cluster layout exists to fix.
    let alphabet = Array("abcdefghi")
    let past = CGRect(x: 100, y: 200, width: 60, height: 40)
    let region = MouseGrid.preparedRegion(
      MouseGrid.Region(frame: past), alphabet: alphabet)
    XCTAssertEqual(region.grid, MouseGrid.Grid(columns: 3, rows: 3))
    let chip = CGSize(width: 14, height: 18)
    let hints = MouseGrid.hints(
      in: region,
      depth: MouseGrid.defaultSteps - 1,
      alphabet: alphabet,
      finalChipSize: chip)
    XCTAssertEqual(hints.count, 9)
    for hint in hints {
      XCTAssertEqual(hint.target.role, MouseGrid.finalChipRole)
      XCTAssertEqual(hint.target.frame.width, chip.width, accuracy: 0.01)
      XCTAssertEqual(hint.target.frame.height, chip.height, accuracy: 0.01)
    }
    // Adjacent chips never overlap: each chip's left edge is at least at
    // its row neighbour's right edge.
    let inRowOrder = hints.prefix(3).map(\.target.frame)
    XCTAssertGreaterThanOrEqual(inRowOrder[1].minX, inRowOrder[0].maxX)
    XCTAssertGreaterThanOrEqual(inRowOrder[2].minX, inRowOrder[1].maxX)
    // The cluster is centered on the past rectangle's midpoint.
    let union = hints.reduce(CGRect.null) { $0.union($1.target.frame) }
    XCTAssertEqual(union.midX, past.midX, accuracy: 0.01)
    XCTAssertEqual(union.midY, past.midY, accuracy: 0.01)
  }

  func testMouseGridIntermediateStepKeepsTileLayoutEvenWithChipSize() {
    // Sanity check: passing finalChipSize at a non-final depth does
    // *not* swap layouts — the compact cluster is the user-facing
    // "we've zoomed in enough" affordance, not an early replacement
    // for the tile path.
    let alphabet = Array("abcdefghi")
    let past = CGRect(x: 0, y: 0, width: 600, height: 600)
    let region = MouseGrid.preparedRegion(
      MouseGrid.Region(frame: past), alphabet: alphabet)
    let hints = MouseGrid.hints(
      in: region,
      depth: 0,
      alphabet: alphabet,
      finalChipSize: CGSize(width: 14, height: 18))
    XCTAssertTrue(hints.allSatisfy { $0.target.role == MouseGrid.cellRole })
    XCTAssertEqual(hints[0].target.frame.width, past.width / 3, accuracy: 0.01)
  }

  func testMouseGridCommitsAfterThreeSelections() {
    let alphabet = Array("abcdefghijklmnop")  // 16 letters → 3x3
    let region = MouseGrid.preparedRegion(
      MouseGrid.Region(frame: CGRect(x: 0, y: 0, width: 1440, height: 900)),
      alphabet: alphabet)
    XCTAssertEqual(region.grid, MouseGrid.Grid(columns: 3, rows: 3))
    let first = MouseGrid.hints(in: region, depth: 0, alphabet: alphabet)
    XCTAssertEqual(first.count, region.grid?.cellCount)
    let secondRegion = MouseGrid.Region(frame: first[0].target.frame, grid: region.grid)
    XCTAssertFalse(MouseGrid.shouldCommit(region: secondRegion, depth: 1))

    let second = MouseGrid.hints(in: secondRegion, depth: 1, alphabet: alphabet)
    XCTAssertEqual(second.count, region.grid?.cellCount)
    let finalRegion = MouseGrid.Region(frame: second[0].target.frame, grid: region.grid)
    XCTAssertTrue(MouseGrid.isFinalDisplayDepth(2))

    let final = MouseGrid.hints(in: finalRegion, depth: 2, alphabet: alphabet)
    XCTAssertEqual(final.count, region.grid?.cellCount)
    // After 3 steps, shouldCommit must return true so the next selection
    // synthesizes the click.
    for hint in final {
      XCTAssertTrue(
        MouseGrid.shouldCommit(
          region: MouseGrid.Region(frame: hint.target.frame, grid: region.grid),
          depth: 3))
    }
  }

  func testFinalMouseGridCellsTouchWithoutGaps() {
    // Adjacent final cells share an edge — no gap, no overlap. The
    // user's promise: clicking *anywhere* in a cell commits the hint.
    let alphabet = Array("abcdefghijklmnop")
    let region = MouseGrid.preparedRegion(
      MouseGrid.Region(frame: CGRect(x: 0, y: 0, width: 1440, height: 900)),
      alphabet: alphabet)
    let first = MouseGrid.hints(in: region, depth: 0, alphabet: alphabet)
    XCTAssertGreaterThanOrEqual(first.count, 4)
    // Cells laid out left-to-right within a row share a vertical edge.
    let topLeft = first[0].target.frame
    let topMid = first[1].target.frame
    XCTAssertEqual(topLeft.maxX, topMid.minX, accuracy: 0.001)
    XCTAssertEqual(topLeft.minY, topMid.minY, accuracy: 0.001)
    XCTAssertEqual(topLeft.maxY, topMid.maxY, accuracy: 0.001)
  }

  func testPluginCommandLineInvocationParser() throws {
    let invocation = try XCTUnwrap(
      NormalModeDispatcher.pluginCommandLineInvocation(":spotify pause quiet now"))
    XCTAssertEqual(invocation.command, "spotify")
    XCTAssertEqual(invocation.subcommand, "pause")
    XCTAssertEqual(invocation.args, ["quiet", "now"])

    // A single token is a top-level command (`:copy`): the verb with an empty
    // subcommand and no args.
    let topLevel = try XCTUnwrap(NormalModeDispatcher.pluginCommandLineInvocation(":copy"))
    XCTAssertEqual(topLevel.command, "copy")
    XCTAssertEqual(topLevel.subcommand, "")
    XCTAssertEqual(topLevel.args, [])

    XCTAssertNil(NormalModeDispatcher.pluginCommandLineInvocation(":"))
  }

  func testCommandLineOpenForward() {
    // Bare `:open` (with or without trailing whitespace) forwards no args.
    XCTAssertEqual(NormalModeDispatcher.commandLineOpenForward("open"), [])
    XCTAssertEqual(NormalModeDispatcher.commandLineOpenForward("open "), [])
    // Args are split on whitespace and forwarded verbatim to `open`.
    XCTAssertEqual(
      NormalModeDispatcher.commandLineOpenForward(":open https://example.com"),
      ["https://example.com"])
    XCTAssertEqual(
      NormalModeDispatcher.commandLineOpenForward(":open -a Firefox file.txt"),
      ["-a", "Firefox", "file.txt"])
    XCTAssertEqual(
      NormalModeDispatcher.commandLineOpenForward("  OPEN   Firefox  "), ["Firefox"])
    // Non-`open` lines are not forwarded.
    XCTAssertNil(NormalModeDispatcher.commandLineOpenForward("opening firefox"))
    XCTAssertNil(NormalModeDispatcher.commandLineOpenForward("edit firefox"))
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
    XCTAssertFalse(labels.contains("tabedit"), "alias of tabnew should not appear")
    XCTAssertFalse(labels.contains("tabe"), "short alias of tabnew should not appear")
    XCTAssertFalse(labels.contains("grep"), "alias of find should not appear")
    XCTAssertFalse(labels.contains("vimgrep"), "alias of find should not appear")
    XCTAssertFalse(labels.contains("copy"), "alias of yank should not appear")
    XCTAssertFalse(labels.contains("cut"), "alias of delete should not appear")
    XCTAssertFalse(labels.contains("paste"), "alias of put should not appear")
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
    XCTAssertEqual(context.items.map(\.label), ["spotify"])

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
        ":system ",
        pluginCommands: ["system"],
        pluginSubcommands: ["system": ["", "lock", "restart", "shutdown"]]))
    XCTAssertEqual(context.prefix, ":system ")
    XCTAssertEqual(context.query, "")
    XCTAssertEqual(Set(context.items.map(\.label)), ["lock", "restart", "shutdown"])
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

  func testCommandLineCompletionsPluginsBuiltinSubcommands() throws {
    let context = try XCTUnwrap(
      NormalModeDispatcher.commandLineCompletions(
        ":plugins ",
        pluginCommands: [],
        pluginSubcommands: [:]))
    XCTAssertEqual(context.prefix, ":plugins ")
    XCTAssertEqual(context.query, "")
    XCTAssertEqual(Set(context.items.map(\.label)), ["reload"])
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

  func testCandidateFinderSourceFilterParsesAtSourceNarrow() {
    // `@<source>` is the only filter syntax — narrows the pool to one source
    // and leaves the residual text as the actual fuzzy query.
    let parsed = NormalModeDispatcher.candidateFinderSourceFilter("@firefox.tabs github repo")
    XCTAssertEqual(parsed.sourceFilter, "firefox.tabs")
    XCTAssertEqual(parsed.text, "github repo")

    let none = NormalModeDispatcher.candidateFinderSourceFilter("github repo")
    XCTAssertNil(none.sourceFilter)
    XCTAssertEqual(none.text, "github repo")

    let bareDoubleDash = NormalModeDispatcher.candidateFinderSourceFilter("--notes inbox")
    XCTAssertNil(bareDoubleDash.sourceFilter)
    XCTAssertEqual(bareDoubleDash.text, "--notes inbox")
  }

  func testFlashlightAliasExpansionRequiresWordBoundaryAndTrailingWhitespace() {
    let aliases = [
      "!g": "!google",
      "@ft": "@firefox.tabs",
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
    XCTAssertEqual(source?.text, ":flashlight @firefox.tabs inbox")
    XCTAssertEqual(source?.cursorIndex, 26)
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

  func testTerminalTargetsSuppressUndoRedoCommandKeyShortcuts() {
    XCTAssertTrue(
      AppDelegate.normalModeCommandKeyShortcutIsUnsafeInTerminal(
        .undo,
        bundleIdentifier: "org.alacritty"))
    XCTAssertTrue(
      AppDelegate.normalModeCommandKeyShortcutIsUnsafeInTerminal(
        .redo,
        bundleIdentifier: "com.apple.Terminal"))
    XCTAssertFalse(
      AppDelegate.normalModeCommandKeyShortcutIsUnsafeInTerminal(
        .undo,
        bundleIdentifier: "org.mozilla.firefox"))
    XCTAssertFalse(
      AppDelegate.normalModeCommandKeyShortcutIsUnsafeInTerminal(
        .tabNew,
        bundleIdentifier: "org.alacritty"))
  }

  func testBrowserIndexedTabSelectionUsesNativeShortcut() {
    XCTAssertEqual(
      AppDelegate.nativeBrowserTabIndexKey(
        index: 1,
        bundleIdentifier: "org.mozilla.firefox"),
      CGKeyCode(kVK_ANSI_1))
    XCTAssertEqual(
      AppDelegate.nativeBrowserTabIndexKey(
        index: 3,
        bundleIdentifier: "com.apple.Safari"),
      CGKeyCode(kVK_ANSI_3))
    XCTAssertEqual(
      AppDelegate.nativeBrowserTabIndexKey(
        index: 9,
        bundleIdentifier: "com.google.Chrome"),
      CGKeyCode(kVK_ANSI_9))
  }

  func testNativeBrowserIndexedTabSelectionDoesNotHandleOtherApps() {
    XCTAssertNil(
      AppDelegate.nativeBrowserTabIndexKey(
        index: 1,
        bundleIdentifier: "org.alacritty"))
    XCTAssertNil(
      AppDelegate.nativeBrowserTabIndexKey(
        index: 10,
        bundleIdentifier: "org.mozilla.firefox"))
  }

  func testTabTraversalFallbackEmitsNativeShortcutsForBrowsersAndMessages() throws {
    let firefoxPrevious = try XCTUnwrap(
      AppDelegate.tabTraversalFallbackShortcut(
        direction: .back,
        bundleIdentifier: "org.mozilla.firefox"))
    let safariNext = try XCTUnwrap(
      AppDelegate.tabTraversalFallbackShortcut(
        direction: .forward,
        bundleIdentifier: "com.apple.Safari"))

    XCTAssertEqual(firefoxPrevious.key, CGKeyCode(kVK_ANSI_LeftBracket))
    XCTAssertEqual(firefoxPrevious.flags, [.maskCommand, .maskShift])
    XCTAssertEqual(safariNext.key, CGKeyCode(kVK_ANSI_RightBracket))
    XCTAssertEqual(safariNext.flags, [.maskCommand, .maskShift])
    let messagesPrevious = try XCTUnwrap(
      AppDelegate.tabTraversalFallbackShortcut(
        direction: .back,
        bundleIdentifier: "com.apple.MobileSMS"))
    let messagesNext = try XCTUnwrap(
      AppDelegate.tabTraversalFallbackShortcut(
        direction: .forward,
        bundleIdentifier: "com.apple.MobileSMS"))
    XCTAssertEqual(messagesPrevious.key, CGKeyCode(kVK_ANSI_LeftBracket))
    XCTAssertEqual(messagesPrevious.flags, [.maskCommand, .maskShift])
    XCTAssertEqual(messagesNext.key, CGKeyCode(kVK_ANSI_RightBracket))
    XCTAssertEqual(messagesNext.flags, [.maskCommand, .maskShift])
    XCTAssertNil(
      AppDelegate.tabTraversalFallbackShortcut(
        direction: .back,
        bundleIdentifier: "org.alacritty"))
    XCTAssertNil(
      AppDelegate.tabTraversalFallbackShortcut(
        direction: .forward,
        bundleIdentifier: "com.example.TextEditor"))
  }

  func testBrowserReloadFallbackIsBrowserOnlyAndUsesSafariHardRefreshChord() {
    XCTAssertNil(
      AppDelegate.browserReloadFallbackShortcut(
        force: false,
        bundleIdentifier: "com.apple.MobileSMS"))
    XCTAssertNil(
      AppDelegate.browserReloadFallbackShortcut(
        force: false,
        bundleIdentifier: "org.alacritty"))

    let chrome = AppDelegate.browserReloadFallbackShortcut(
      force: true,
      bundleIdentifier: "com.google.Chrome")
    XCTAssertEqual(chrome?.key, CGKeyCode(kVK_ANSI_R))
    XCTAssertEqual(chrome?.flags, [.maskCommand, .maskShift])

    let safari = AppDelegate.browserReloadFallbackShortcut(
      force: true,
      bundleIdentifier: "com.apple.Safari")
    XCTAssertEqual(safari?.key, CGKeyCode(kVK_ANSI_R))
    XCTAssertEqual(safari?.flags, [.maskCommand, .maskAlternate])
  }

  func testHelpTextListsNormalModeMappings() {
    let help = NormalModeDispatcher.helpText(config: .default, showModes: true)
    for mapping in [
      "h", "j", "k", "l", "ctrl-e", "ctrl-y", "ctrl-d", "ctrl-u",
      "gg", "G", "H", "L", "f", "F", "ctrl-f", "ctrl+shift+f", "sf", "Df", "mf", "sF",
      "DF", "mF", "u", "ctrl-r", "x", "n",
      "/", "\\<space>", "r", "R", "e", "t", "MAPPINGS",
      "ctrl-o", "ctrl-i", "ACTION", "NORMAL", "INSERT", "i", ":", "g^", "g$", "[t", "]t", "[a",
      "]a", "g1", "g9", "N{mapping}",
      ":q[uit]", ":q[uit]!", ":w[rite]", ":wq", ":x[it]", ":p[rint]", ":e[dit]", ":new", ":tabnew",
      ":bd[elete]", ":cl[ose]", ":find", ":u[ndo]", ":red[o]", ":y[ank]", ":pu[t]",
      ":open <args>", ":flashlight <query>", "flash mouse_target",
      "flash mouse_target --modifiers=cmd", "flash mouse_grid --modifiers=cmd",
      "flash enter_command_mode --input=flashlight ", "flash mouse_target --secondary",
      "flash mouse_target --double", "flash mouse_grid", "flash history_back",
      "flash history_forward", "flash resource_next", "flash resource_previous",
      "flash app_previous", "flash app_next",
      "flash app_reload --force", "flash tab_select --index=1", "flash tab_new", "?",
    ] {
      XCTAssertTrue(
        help.contains(mapping),
        "missing \(mapping)")
    }
    XCTAssertFalse(help.contains("flash enter_normal_mode"))
  }

  func testNormalModeHelpTopicOmitsTerminalOwnedMappings() {
    let topic = NormalModeDispatcher.helpTopic(config: .default, showModes: true)
    XCTAssertFalse(topic.body.contains("cmd+d"))
    XCTAssertFalse(topic.body.contains("cmd+shift+d"))
    XCTAssertFalse(topic.body.contains("cmd+w"))
  }

  func testHelpTextIsDerivedFromConfiguredMappings() {
    var config = Config.default
    config.mode.normal = [
      ModeMapping(key: "zz", action: .flashCommand(.reload(force: false)))
    ]
    let help = NormalModeDispatcher.helpText(config: config, showModes: true)
    XCTAssertTrue(help.contains("zz"))
    XCTAssertTrue(help.contains("flash app_reload"))
    XCTAssertFalse(help.contains("flash mouse_target"))
    XCTAssertFalse(help.contains(":q[uit]"))
  }

  func testHelpTextListsShellCommandMappings() {
    var config = Config.default
    config.mode.normal = [
      ModeMapping(key: "zz", action: .shellCommand(["sh", "~/bin/toggle-colors"]))
    ]
    let help = NormalModeDispatcher.helpText(config: config, showModes: true)
    XCTAssertTrue(help.contains("zz"))
    XCTAssertTrue(help.contains("[\"sh\", \"~/bin/toggle-colors\"]"))
  }

  func testHelpTextWithoutModeCellUsesSimpleMappingColumn() {
    let help = NormalModeDispatcher.helpText(config: .default, showModes: false)
    XCTAssertTrue(help.contains("ACTION"))
    XCTAssertTrue(help.contains("MAPPING"))
    XCTAssertTrue(help.contains("flash mouse_target"))
    XCTAssertTrue(help.contains("f"))
    XCTAssertFalse(help.contains("NORMAL"))
    XCTAssertFalse(help.contains("INSERT"))
  }

  func testMappingsTextListsResolvedScopesAndLeaderMappings() {
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
    let text = NormalModeDispatcher.mappingsText(config: config)
    XCTAssertTrue(text.contains("# Mappings"))
    XCTAssertTrue(text.contains("Normal leader: `\\`"))
    XCTAssertTrue(text.contains("all"))
    XCTAssertTrue(text.contains("normal"))
    XCTAssertTrue(text.contains("insert"))
    XCTAssertTrue(text.contains("cmd+<space>"))
    XCTAssertTrue(text.contains("\\c"))
    XCTAssertTrue(text.contains("[\"sh\", \"/tmp/toggle_caffeinate.sh\"]"))
  }

  func testMappingsTextDisplaysNamedKeySequencesAsAtoms() {
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
    let text = NormalModeDispatcher.mappingsText(config: config)

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
    // `p` has no longer mapping, so it commits immediately with no register.
    XCTAssertEqual(command(chars: "p"), .paste(register: nil))
    // `y` is a one-key prefix of `yy`, so it pends and resolves on timeout.
    let yanked = transition(chars: "y")
    XCTAssertNil(yanked.command)
    XCTAssertEqual(yanked.pending, "y")
    XCTAssertEqual(
      NormalModeInterpreter.pendingCommand(
        pending: yanked.pending, mappings: defaultMappings)?.action.command,
      .yankSelection(register: nil))
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

  func testRegisterPrefixRoutesYankToANamedRegisterOnTimeout() {
    let named = transition(pending: "\"", chars: "a")
    let yanked = transition(pending: named.pending, chars: "y")
    XCTAssertNil(yanked.command)
    XCTAssertEqual(yanked.pending, "\"ay")
    XCTAssertEqual(
      NormalModeInterpreter.pendingCommand(
        pending: yanked.pending, mappings: defaultMappings)?.action.command,
      .yankSelection(register: "a"))
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
    let store = RegisterStore()
    store.write("hello", register: "a")
    XCTAssertEqual(store.read(register: "a"), "hello")
    // A different register is independent.
    XCTAssertNil(store.read(register: "b"))
  }

  func testRegisterStoreUppercaseNameAppends() {
    let store = RegisterStore()
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
    XCTAssertEqual(command(chars: "G", ignoring: "g", flags: [.shift]), .scroll(.bottom))
    XCTAssertEqual(command(chars: "?", ignoring: "/", flags: [.shift]), .showUsage(topic: nil))
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

  func testAppOpenMappingsAreTreatedAsFocusChangingNormalModeActions() {
    XCTAssertTrue(
      AppDelegate.normalModeActionMayChangeKeyboardFocus(
        .flashCommand(.openApp(name: "Alacritty"))))
    XCTAssertTrue(
      AppDelegate.normalModeActionMayChangeKeyboardFocus(.shellCommand(["open", "-a", "Slack"])))
    XCTAssertTrue(AppDelegate.normalModeCommandMayChangeKeyboardFocus(.appNext))
    XCTAssertTrue(AppDelegate.normalModeCommandMayChangeKeyboardFocus(.movementBack))
    XCTAssertTrue(
      AppDelegate.normalModeCommandMayChangeKeyboardFocus(
        .sendKey(keys: "down", keyCode: CGKeyCode(kVK_DownArrow), flagsRawValue: 0)))
    XCTAssertTrue(
      AppDelegate.normalModeCommandMayChangeKeyboardFocus(
        .sendKeys(
          keys: "g,i", keyCodes: [CGKeyCode(kVK_ANSI_G), CGKeyCode(kVK_ANSI_I)],
          flagsRawValues: [0, 0])))
    XCTAssertFalse(AppDelegate.normalModeCommandMayChangeKeyboardFocus(.scroll(.down)))
    XCTAssertFalse(AppDelegate.normalModeCommandMayChangeKeyboardFocus(.reload(force: false)))
    XCTAssertFalse(
      AppDelegate.normalModeCommandMayChangeKeyboardFocus(
        .sendKey(
          keys: "cmd+f", keyCode: CGKeyCode(kVK_ANSI_F),
          flagsRawValue: CGEventFlags.maskCommand.rawValue)))
  }

  func testUnmodifiedNormalModeKeyDispatchRequiresTargetActivation() {
    XCTAssertTrue(AppDelegate.normalModeKeyDispatchNeedsTargetActivation(flags: []))
    XCTAssertFalse(AppDelegate.normalModeKeyDispatchNeedsTargetActivation(flags: .maskCommand))
    XCTAssertFalse(AppDelegate.normalModeKeyDispatchNeedsTargetActivation(flags: .maskControl))
    XCTAssertFalse(AppDelegate.normalModeKeyDispatchNeedsTargetActivation(flags: .maskAlternate))
    XCTAssertFalse(AppDelegate.normalModeKeyDispatchNeedsTargetActivation(flags: .maskShift))
  }

  func testNormalModeActionDispatchRecapturesOnlyForIdleNormalSurfaces() {
    XCTAssertTrue(
      AppDelegate.normalModeShouldRecaptureAfterActionDispatch(
        mode: .normal,
        overlayInputMode: .normal,
        hasHints: false,
        activationInFlight: false))
    XCTAssertTrue(
      AppDelegate.normalModeShouldRecaptureAfterActionDispatch(
        mode: .normal,
        overlayInputMode: .hints,
        hasHints: false,
        activationInFlight: false))
    XCTAssertFalse(
      AppDelegate.normalModeShouldRecaptureAfterActionDispatch(
        mode: .insert,
        overlayInputMode: .normal,
        hasHints: false,
        activationInFlight: false))
    XCTAssertFalse(
      AppDelegate.normalModeShouldRecaptureAfterActionDispatch(
        mode: .normal,
        overlayInputMode: .commandLine,
        hasHints: false,
        activationInFlight: false))
    XCTAssertFalse(
      AppDelegate.normalModeShouldRecaptureAfterActionDispatch(
        mode: .normal,
        overlayInputMode: .normal,
        hasHints: true,
        activationInFlight: false))
    XCTAssertFalse(
      AppDelegate.normalModeShouldRecaptureAfterActionDispatch(
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

  func testEscapeConsumesWithoutLeavingNormalMode() {
    let t = NormalModeInterpreter.interpret(
      pending: "",
      keyCode: 53,
      modifierFlags: [],
      characters: nil,
      charactersIgnoringModifiers: nil,
      mappings: CompiledMappings(Config.Mode.defaultNormalMappings))
    XCTAssertNil(t.command)
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
    keyCode: Int = 0,
    chars: String,
    ignoring: String? = nil,
    flags: NSEvent.ModifierFlags = [],
    mappings: [ModeMapping] = Config.default.mode.normal
  ) -> URLCommand? {
    transition(
      pending: pending,
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
    keyCode: Int = 0,
    chars: String,
    ignoring: String? = nil,
    flags: NSEvent.ModifierFlags = [],
    mappings: [ModeMapping] = Config.default.mode.normal
  ) -> NormalModeTransition {
    NormalModeInterpreter.interpret(
      pending: pending,
      keyCode: UInt16(keyCode),
      modifierFlags: flags,
      characters: chars,
      charactersIgnoringModifiers: ignoring ?? chars.lowercased(),
      mappings: CompiledMappings(mappings))
  }

  private func assertSendKey(
    _ command: URLCommand?,
    keys: String,
    keyCode: CGKeyCode,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard case .sendKey(let actualKeys, let actualKeyCode, let flagsRawValue) = command else {
      return XCTFail("expected send_key \(keys)", file: file, line: line)
    }
    XCTAssertEqual(actualKeys, keys, file: file, line: line)
    XCTAssertEqual(actualKeyCode, keyCode, file: file, line: line)
    XCTAssertEqual(flagsRawValue, 0, file: file, line: line)
  }

  private func key(_ raw: String) -> String {
    NormalModeInterpreter.canonicalizeMappingKey(raw)!
  }

  /// Assert a command is a `send_key` for the given hotkey, checking only
  /// the hotkey string (the keyCode / flags are derived from it). Used for
  /// modified sends like `cmd+g` where the flags raw value is non-zero.
  private func assertSendKeyKeys(
    _ command: URLCommand?,
    _ keys: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard case .sendKey(let actualKeys, _, _) = command else {
      return XCTFail("expected send_key \(keys)", file: file, line: line)
    }
    XCTAssertEqual(actualKeys, keys, file: file, line: line)
  }

  private func focusSnapshot(
    _ surface: InputFocusSnapshot.Surface,
    role: String? = nil,
    windowSubrole: String? = nil,
    documentURL: String? = nil
  ) -> InputFocusSnapshot {
    InputFocusSnapshot(surface: surface)
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

  private func shouldExitAfterFocusedElementChange(
    mode: FlashMode = .insert,
    modeBadgeEnabled: Bool = true,
    overlayInputMode: OverlayInputMode = .hints,
    hasHints: Bool = false,
    activationInFlight: Bool = false,
    focusedPID: pid_t? = pid_t(42),
    eventPID: pid_t = pid_t(42),
    editableFocusExitPID: pid_t? = pid_t(42),
    focusedElementIsEditable: Bool = false,
    insertModeLocked: Bool = false
  ) -> Bool {
    AppDelegate.insertModeShouldExitAfterFocusedElementChange(
      mode: mode,
      modeBadgeEnabled: modeBadgeEnabled,
      overlayInputMode: overlayInputMode,
      hasHints: hasHints,
      activationInFlight: activationInFlight,
      focusedPID: focusedPID,
      eventPID: eventPID,
      editableFocusExitPID: editableFocusExitPID,
      focusedElementIsEditable: focusedElementIsEditable,
      insertModeLocked: insertModeLocked)
  }

  private func shouldExitAfterFocusedAppChange(
    mode: FlashMode = .insert,
    modeBadgeEnabled: Bool = true,
    overlayInputMode: OverlayInputMode = .hints,
    hasHints: Bool = false,
    activationInFlight: Bool = false,
    insertFocusOwnerPID: pid_t? = pid_t(42),
    focusedPID: pid_t? = pid_t(42),
    insertModeLocked: Bool = false
  ) -> Bool {
    AppDelegate.insertModeShouldExitAfterFocusedAppChange(
      mode: mode,
      modeBadgeEnabled: modeBadgeEnabled,
      overlayInputMode: overlayInputMode,
      hasHints: hasHints,
      activationInFlight: activationInFlight,
      insertFocusOwnerPID: insertFocusOwnerPID,
      focusedPID: focusedPID,
      insertModeLocked: insertModeLocked)
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
