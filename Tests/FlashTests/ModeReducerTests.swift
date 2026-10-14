import AppKit
import CoreGraphics
import Foundation
import XCTest

@testable import flash

/// Exhaustive tests for the pure mode state machine. These pin the invariants
/// the audit asked for: deterministic transitions, no mouse/focus-driven exit
/// from insert, projection correctness (no badge/label drift), and the shared
/// editable-click decision.
final class ModeReducerTests: XCTestCase {
  // Representative states covering every case + payload variation.
  private let allStates: [Mode] = [
    .disabled,
    .insert,
    .normal,
    .command(restoreTo: .normal),
    .command(restoreTo: .insert),
    .command(restoreTo: .disabled),
    .terminal(restoreTo: .normal, returnPID: nil),
    .terminal(restoreTo: .insert, returnPID: nil),
    .terminal(restoreTo: .disabled, returnPID: nil),
    .hyper(restoreTo: .normal),
    .visual,
    .drag,
  ]

  // Representative events covering every case.
  private let allEvents: [ModeEvent] = [
    .enterInsert(targetPID: 7),
    .enterNormal,
    .leaveMode(hasHints: false),
    .leaveMode(hasHints: true),
    .openCommand(restoreMode: false),
    .openCommand(restoreMode: true),
    .closeCommand(reason: "submit"),
    .openTerminal(returnPID: nil),
    .closeTerminal(restoresApp: false),
    .clickResolved(entersInsert: true, targetPID: 7),
    .clickResolved(entersInsert: false, targetPID: 7),
    .advancedModeChanged(enabled: true),
    .advancedModeChanged(enabled: false),
    .startup(advancedEnabled: true),
    .startup(advancedEnabled: false),
    .focusedAppChanged(pid: 7),
    .enterHyper,
    .exitHyper,
    .buttonHeld(.visual),
    .buttonHeld(.drag),
    .buttonReleased,
  ]

  // MARK: Hyper hold

  /// Every exit from HYPER ends the hold — the release, `leave_mode`, the
  /// command line, a focus change — because the transition itself is the
  /// reset point. A stale hold would swallow the next leader press and carry
  /// a pending sequence into NORMAL.
  func testEveryExitFromHyperEndsTheHold() {
    let hyper = Mode.hyper(restoreTo: .normal)
    for event in allEvents {
      var hold = HyperHoldState()
      XCTAssertEqual(hold.leaderHold.step(.leaderDown), .enter)
      XCTAssertEqual(hold.leaderHold.step(.otherKey), .key)
      hold.pending = "x"
      hold.fallbackPending = "<leader>"
      let next = ModeReducer.reduce(hyper, event).0
      hold.modeChanged(from: hyper, to: next)
      if next.isHyper {
        XCTAssertTrue(hold.leaderHold.holding, "staying in HYPER keeps the hold: \(event)")
        XCTAssertEqual(hold.pending, "x")
      } else {
        XCTAssertEqual(hold, HyperHoldState(), "leaving HYPER by \(event) ends the hold")
        XCTAssertEqual(hold.leaderHold.step(.leaderDown), .enter, "the next press enters")
      }
    }
    var hold = HyperHoldState()
    hold.pending = "x"
    hold.modeChanged(from: .normal, to: .insert)
    XCTAssertEqual(hold.pending, "x", "a change between other modes is not an exit")
  }

  // MARK: Initialization

  func testStartupPicksInitialMode() {
    XCTAssertEqual(ModeReducer.reduce(.disabled, .startup(advancedEnabled: true)).0, .normal)
    XCTAssertEqual(ModeReducer.reduce(.normal, .startup(advancedEnabled: false)).0, .disabled)
  }

  func testStartupResolvesCaptureBeforeAnySurfaceEffect() {
    for advancedEnabled in [true, false] {
      for tapAvailable in [true, false] {
        let store = ModeStore()
        var capturePrepared = false
        var tapActive = false
        var fallbackCaptures = 0
        var renders = 0
        store.perform = { effects, _, mode in
          for effect in effects {
            switch effect {
            case .prepareKeyboardCapture:
              XCTAssertFalse(capturePrepared)
              capturePrepared = true
              tapActive = tapAvailable
            case .clearTransientHintState, .hideOverlayIfIdle, .renderSurface, .scheduleRecapture:
              XCTAssertTrue(capturePrepared, "Startup \(effect) ran before capture was prepared")
              if effect == .renderSurface {
                renders += 1
                if mode.ownsKeyboard(hasHints: false, activationInFlight: false), !tapActive {
                  fallbackCaptures += 1
                }
              }
            default:
              break
            }
          }
        }
        store.dispatch(.startup(advancedEnabled: advancedEnabled))
        XCTAssertTrue(
          capturePrepared, "Hint capture also needs a tap when advanced mode is disabled")
        XCTAssertEqual(renders, 1)
        XCTAssertEqual(fallbackCaptures, advancedEnabled && !tapAvailable ? 1 : 0)
      }
    }
  }

  func testOrdinaryModeTransitionsDoNotPrepareKeyboardCaptureAgain() {
    for state in allStates {
      for event in allEvents {
        if case .startup = event { continue }
        XCTAssertFalse(ModeReducer.reduce(state, event).1.contains(.prepareKeyboardCapture))
      }
    }
  }

  // MARK: Insert stickiness — the central invariant

  func testMouseAndFocusNeverLeaveInsert() {
    for event in [
      ModeEvent.clickResolved(entersInsert: true, targetPID: 7),
      .clickResolved(entersInsert: false, targetPID: 7),
      .focusedAppChanged(pid: 7),
      .enterInsert(targetPID: 7),
    ] {
      let next = ModeReducer.reduce(.insert, event).0
      XCTAssertTrue(next.isInsert, "\(event) must keep INSERT, got \(next)")
    }
  }

  func testOnlyKeyboardAndConfigLeaveInsert() {
    XCTAssertEqual(
      ModeReducer.reduce(.insert, .enterNormal).0, .normal)
    XCTAssertEqual(
      ModeReducer.reduce(.insert, .advancedModeChanged(enabled: false)).0, .disabled)
  }

  func testFocusedAppChangedNeverChangesMode() {
    for state in allStates {
      let (next, effects) = ModeReducer.reduce(state, .focusedAppChanged(pid: 99))
      XCTAssertEqual(next, state, "focusedAppChanged must not change \(state)")
      switch state {
      case .normal, .command, .hyper, .visual, .drag:
        XCTAssertEqual(effects, [.scheduleRecapture])
      case .insert, .disabled, .terminal:
        XCTAssertTrue(effects.isEmpty)
      }
    }
  }

  func testEnteredNormalPersistsAcrossFocusHintsAndCommandSubmissions() {
    var mode = ModeReducer.reduce(.insert, .enterNormal).0
    XCTAssertEqual(mode, .normal)

    for event in [
      ModeEvent.focusedAppChanged(pid: 42),
      .focusedAppChanged(pid: 7),
      .leaveMode(hasHints: true),
      .advancedModeChanged(enabled: true),
      .leaveMode(hasHints: false),
    ] {
      let next = ModeReducer.reduce(mode, event).0
      XCTAssertEqual(next, .normal, "\(event) must preserve explicit NORMAL")
      XCTAssertEqual(next.mappingScope, .normal)
      mode = next
    }

    for restoreMode in [false, true] {
      mode = ModeReducer.reduce(mode, .openCommand(restoreMode: restoreMode)).0
      mode = ModeReducer.reduce(mode, .focusedAppChanged(pid: 7)).0
      mode = ModeReducer.reduce(mode, .closeCommand(reason: "submit")).0
      XCTAssertEqual(mode, .normal)
    }

    mode = ModeReducer.reduce(mode, .enterInsert(targetPID: 7)).0
    XCTAssertEqual(mode, .insert)
    mode = ModeReducer.reduce(mode, .leaveMode(hasHints: false)).0
    XCTAssertEqual(mode, .normal)
  }

  // MARK: Mouse enters only from normal

  func testClickEntersInsertOnlyFromNormal() {
    XCTAssertEqual(
      ModeReducer.reduce(.normal, .clickResolved(entersInsert: true, targetPID: 7)).0,
      .insert)
    XCTAssertEqual(
      ModeReducer.reduce(.normal, .clickResolved(entersInsert: false, targetPID: 7)).0, .normal)
    // A click while a button is held (VISUAL, DRAG) still enters INSERT on an
    // input.
    for held in [Mode.visual, .drag] {
      XCTAssertEqual(
        ModeReducer.reduce(held, .clickResolved(entersInsert: true, targetPID: 7)).0, .insert)
    }
    // From any other state, a click cannot change the mode.
    for state in allStates where !state.isNormal && state.buttonHold == nil {
      XCTAssertEqual(
        ModeReducer.reduce(state, .clickResolved(entersInsert: true, targetPID: 7)).0, state)
    }
  }

  // MARK: Advanced gate

  func testAdvancedGateRefusesNormalWhenDisabled() {
    XCTAssertEqual(ModeReducer.reduce(.disabled, .enterNormal).0, .disabled)
    XCTAssertEqual(
      ModeReducer.reduce(.disabled, .enterInsert(targetPID: 7)).0,
      .disabled)
  }

  func testEnablingAdvancedModeStartsPersistentNormal() {
    let (mode, effects) = ModeReducer.reduce(.disabled, .advancedModeChanged(enabled: true))
    XCTAssertEqual(mode, .normal)
    XCTAssertEqual(effects, ModeReducer.enterEffects(for: .normal, targetPID: nil))
    XCTAssertEqual(ModeReducer.reduce(mode, .focusedAppChanged(pid: 42)).0, .normal)
  }

  // MARK: Command / modal lifecycle + restore fidelity

  func testCommandLifecycleRestores() {
    // Default exit is NORMAL.
    var (mode, _) = ModeReducer.reduce(
      .normal, .openCommand(restoreMode: false))
    XCTAssertEqual(mode, .command(restoreTo: .normal))
    XCTAssertEqual(ModeReducer.reduce(mode, .closeCommand(reason: "x")).0, .normal)

    // restoreMode preserves the entry mode (here: insert).
    (mode, _) = ModeReducer.reduce(
      .insert, .openCommand(restoreMode: true))
    XCTAssertEqual(mode, .command(restoreTo: .insert))
    XCTAssertEqual(ModeReducer.reduce(mode, .closeCommand(reason: "x")).0, .insert)

    // Flashlight from disabled (advanced off) returns to disabled, never a
    // phantom NORMAL.
    (mode, _) = ModeReducer.reduce(
      .disabled, .openCommand(restoreMode: false))
    XCTAssertEqual(mode, .command(restoreTo: .disabled))
    XCTAssertEqual(ModeReducer.reduce(mode, .closeCommand(reason: "x")).0, .disabled)
  }

  func testCloseCommandFromNonCommandIsNoop() {
    XCTAssertEqual(ModeReducer.reduce(.normal, .closeCommand(reason: "x")).0, .normal)
  }

  func testLeaveModeReturnsInsertToNormal() {
    let (next, effects) = ModeReducer.reduce(.insert, .leaveMode(hasHints: false))
    XCTAssertEqual(next, .normal)
    XCTAssertEqual(effects, ModeReducer.enterEffects(for: .normal, targetPID: nil))
  }

  func testLeaveModeRestoresEveryCommandSurface() {
    do {
      for origin in [Mode.normal, .insert, .disabled] {
        for restoreMode in [false, true] {
          let (opened, _) = ModeReducer.reduce(
            origin, .openCommand(restoreMode: restoreMode))
          let expected = ModeReducer.reduce(opened, .closeCommand(reason: "cancel"))
          let actual = ModeReducer.reduce(opened, .leaveMode(hasHints: false))
          XCTAssertEqual(actual.0, expected.0)
          XCTAssertEqual(actual.1, expected.1)
          XCTAssertTrue(actual.1.contains(.clearTransientHintState))
        }
      }
    }
  }

  func testLeaveModeKeepsNormalAndDisabled() {
    for state in [Mode.normal, .disabled] {
      let (next, effects) = ModeReducer.reduce(state, .leaveMode(hasHints: false))
      XCTAssertEqual(next, state)
      XCTAssertTrue(effects.isEmpty)
    }
  }

  /// The app a popup covers is part of the TERMINAL value: an explicit close
  /// activates it, a focus loss does not, and nothing of it outlives the
  /// mode — the next popup captures its own, and leaving INSERT with hints
  /// up activates no app a popup once covered.
  func testTerminalReturnAppLivesOnlyInTerminalMode() {
    let first = ModeReducer.reduce(.normal, .openTerminal(returnPID: 42)).0
    XCTAssertEqual(first, .terminal(restoreTo: .normal, returnPID: 42))
    let silent = ModeReducer.reduce(first, .closeTerminal(restoresApp: false))
    XCTAssertEqual(silent.0, .normal)
    XCTAssertFalse(
      silent.1.contains {
        if case .activateFocusedApp = $0 { return true }
        return false
      }, "a focus loss activates nothing")

    let second = ModeReducer.reduce(silent.0, .openTerminal(returnPID: 7)).0
    XCTAssertEqual(second.terminalReturnPID, 7)
    let left = ModeReducer.reduce(second, .leaveMode(hasHints: false))
    XCTAssertTrue(left.1.contains(.activateFocusedApp(pid: 7)))
    XCTAssertFalse(left.1.contains(.activateFocusedApp(pid: 42)), "the first popup's app is gone")
    XCTAssertEqual(
      Array(ModeReducer.reduce(second, .enterNormal).1.prefix(2)),
      [.hideTerminalPopup, .activateFocusedApp(pid: 7)])
    XCTAssertEqual(
      ModeReducer.reduce(second, .openTerminal(returnPID: 99)).0, second,
      "a popup focused from TERMINAL keeps the app captured first")

    let hints = ModeReducer.reduce(.insert, .leaveMode(hasHints: true))
    XCTAssertEqual(hints.0, .insert)
    XCTAssertTrue(hints.1.contains(.activateFocusedApp(pid: nil)))
  }

  func testLeaveModeRestoresTerminalAndPreviousApplication() {
    for origin in [Mode.normal, .insert, .disabled] {
      let (opened, _) = ModeReducer.reduce(origin, .openTerminal(returnPID: 42))
      let actual = ModeReducer.reduce(opened, .leaveMode(hasHints: false))
      let expected = ModeReducer.reduce(opened, .closeTerminal(restoresApp: true))
      XCTAssertEqual(actual.0, origin)
      XCTAssertEqual(actual.1, expected.1)
      XCTAssertTrue(actual.1.contains(.hideTerminalPopup))
      XCTAssertTrue(actual.1.contains(.activateFocusedApp(pid: 42)))
    }
  }

  func testLeaveModeWithHintsDismissesThemAndKeepsTheBaseMode() {
    for state in [Mode.disabled, .normal, .insert] {
      let (next, effects) = ModeReducer.reduce(state, .leaveMode(hasHints: true))
      XCTAssertEqual(next, state)
      XCTAssertEqual(effects, ModeReducer.enterEffects(for: state, targetPID: nil))
      XCTAssertTrue(effects.contains(.clearTransientHintState))
    }
  }

  func testLeaveModeVerbRejectsArguments() {
    XCTAssertEqual(URLEventHandler.parse(verb: "leave_mode", args: [:]), .leaveMode)
    XCTAssertNil(URLEventHandler.parse(verb: "leave_mode", args: ["mode": "insert"]))
  }

  func testEnterNormalClosesEveryCommandSurface() {
    let commandStates: [Mode] = [
      .command(restoreTo: .insert)
    ]
    let expectedEffects = ModeReducer.enterEffects(for: .normal, targetPID: nil)
    XCTAssertTrue(expectedEffects.contains(.clearTransientHintState))

    for state in commandStates {
      let (next, effects) = ModeReducer.reduce(state, .enterNormal)
      XCTAssertEqual(next, .normal)
      XCTAssertEqual(effects, expectedEffects)
    }
  }

  // MARK: Determinism + totality

  func testDisabledEligibilitySurvivesExplicitRequestsInsideEverySurface() {
    let surfaces: [ModeEvent] = [
      .openCommand(restoreMode: false),
      .openCommand(restoreMode: true),
      .openTerminal(returnPID: nil),
    ]
    for open in surfaces {
      for request in [ModeEvent.enterNormal, .enterInsert(targetPID: nil)] {
        let opened = ModeReducer.reduce(.disabled, open).0
        let closed = ModeReducer.reduce(opened, request).0
        XCTAssertEqual(closed, .disabled, "\(open), \(request)")
        XCTAssertEqual(
          ModeReducer.reduce(closed, .leaveMode(hasHints: false)).0, .disabled)
      }
    }
  }

  func testEnablingAdvancedModeReconcilesEveryTransientReturn() {
    for open in [
      ModeEvent.openCommand(restoreMode: false),
      .openCommand(restoreMode: true),
      .openTerminal(returnPID: nil),
    ] {
      let opened = ModeReducer.reduce(.disabled, open).0
      let enabled = ModeReducer.reduce(opened, .advancedModeChanged(enabled: true)).0
      XCTAssertEqual(
        ModeReducer.reduce(enabled, .leaveMode(hasHints: false)).0, .normal)
    }
  }

  func testConfigRefreshPreservesExplicitInsertAndItsTransientReturn() {
    let states: [Mode] = [
      .insert,
      .command(restoreTo: .insert),
      .terminal(restoreTo: .insert, returnPID: nil),
    ]
    for state in states {
      let (refreshed, effects) = ModeReducer.reduce(state, .advancedModeChanged(enabled: true))
      XCTAssertEqual(refreshed, state)
      XCTAssertEqual(effects, [.renderSurface])
      if !state.isInsert {
        XCTAssertEqual(
          ModeReducer.reduce(refreshed, .leaveMode(hasHints: false)).0, .insert)
      }
    }
  }

  func testReducerIsDeterministicAndTotal() {
    for state in allStates {
      for event in allEvents {
        let a = ModeReducer.reduce(state, event)
        let b = ModeReducer.reduce(state, event)
        XCTAssertEqual(a.0, b.0, "non-deterministic mode for \(state) + \(event)")
        XCTAssertEqual(a.1, b.1, "non-deterministic effects for \(state) + \(event)")
      }
    }
  }

  // MARK: Effect contract

  func testEnterEffectsContract() {
    let normal = ModeReducer.enterEffects(for: .normal, targetPID: nil)
    XCTAssertEqual(
      normal,
      [
        .prepareModeEntry, .clearTransientHintState, .renderSurface,
        .scheduleRecapture,
      ])

    let insert = ModeReducer.enterEffects(for: .insert, targetPID: 42)
    XCTAssertEqual(
      insert,
      [
        .prepareModeEntry, .clearTransientHintState, .hideOverlayIfIdle,
        .renderSurface,
        .activateFocusedApp(pid: 42),
      ])
    XCTAssertFalse(insert.contains(.scheduleRecapture), "insert must not grab the keyboard")

    let command = ModeReducer.enterEffects(
      for: .command(restoreTo: .normal), targetPID: nil)
    XCTAssertEqual(
      command, [.prepareModeEntry, .renderSurface, .scheduleRecapture])
  }

  // MARK: Projection correctness — the anti-drift table

  func testProjectionTable() {
    XCTAssertEqual(Mode.disabled.flashMode, .insert)
    XCTAssertEqual(Mode.insert.flashMode, .insert)
    XCTAssertEqual(Mode.normal.flashMode, .normal)
    XCTAssertEqual(Mode.command(restoreTo: .normal).flashMode, .normal)

    XCTAssertEqual(Mode.disabled.label, .insert)
    XCTAssertEqual(Mode.insert.label, .insert)
    XCTAssertEqual(Mode.normal.label, .normal)
    XCTAssertEqual(Mode.command(restoreTo: .normal).label, .command)

    // overlay input mode (idle, no hints / activation): INSERT and disabled
    // are passive until a hint session or its walk takes the keys.
    XCTAssertEqual(
      Mode.insert.overlayInputMode(hasHints: false, activationInFlight: false), .passive)
    XCTAssertEqual(
      Mode.disabled.overlayInputMode(hasHints: false, activationInFlight: false), .passive)
    XCTAssertEqual(Mode.insert.overlayInputMode(hasHints: true, activationInFlight: false), .hints)
    XCTAssertEqual(
      Mode.disabled.overlayInputMode(hasHints: false, activationInFlight: true), .hints)
    XCTAssertEqual(
      Mode.normal.overlayInputMode(hasHints: false, activationInFlight: false), .normal)
    // normal with hints up routes hint letters, not commands
    XCTAssertEqual(Mode.normal.overlayInputMode(hasHints: true, activationInFlight: false), .hints)
    XCTAssertEqual(Mode.normal.overlayInputMode(hasHints: false, activationInFlight: true), .hints)
    XCTAssertEqual(
      Mode.command(restoreTo: .normal)
        .overlayInputMode(hasHints: false, activationInFlight: false), .commandLine)

    XCTAssertFalse(
      Mode.insert.ownsKeyboard(hasHints: false, activationInFlight: false))
    XCTAssertTrue(Mode.normal.ownsKeyboard(hasHints: false, activationInFlight: false))
    XCTAssertFalse(Mode.normal.ownsKeyboard(hasHints: true, activationInFlight: false))
    XCTAssertTrue(
      Mode.command(restoreTo: .normal)
        .ownsKeyboard(hasHints: false, activationInFlight: false))

    // Native-surface suspension (context menu up): never capture, in any base
    // mode; NORMAL stays `.normal`-routed so the cursor stays visible under the
    // menu (the `.hints` routing would hide it).
    XCTAssertFalse(
      Mode.normal.ownsKeyboard(
        hasHints: false, activationInFlight: false, nativeSurfaceSuspended: true))
    XCTAssertFalse(
      Mode.command(restoreTo: .normal)
        .ownsKeyboard(hasHints: false, activationInFlight: false, nativeSurfaceSuspended: true))
    XCTAssertEqual(
      Mode.normal.overlayInputMode(
        hasHints: false, activationInFlight: false, nativeSurfaceSuspended: true), .normal)
    XCTAssertEqual(
      Mode.normal.overlayInputMode(
        hasHints: true, activationInFlight: false, nativeSurfaceSuspended: true), .normal)
  }

  /// The "COMMAND is a lie" regression: the command surface must produce the
  /// `.command` badge style from the MODE, and base modes must never produce it.
  func testCommandBadgeStyleComesFromMode() {
    XCTAssertEqual(Mode.command(restoreTo: .normal).badgeStyle, .command)
    XCTAssertEqual(Mode.normal.badgeStyle, .normal)
    XCTAssertEqual(Mode.insert.badgeStyle, .insert)
    XCTAssertEqual(Mode.disabled.badgeStyle, .insert)
    XCTAssertEqual(Mode.hyper(restoreTo: .normal).badgeStyle, .hyper)
    XCTAssertEqual(Mode.hyper(restoreTo: .normal).label, .hyper)
    XCTAssertEqual(Mode.visual.badgeStyle, .visual)
    XCTAssertEqual(Mode.visual.label, .visual)
  }

  /// VISUAL is the held mouse button over NORMAL: entered only from NORMAL,
  /// left when the button goes, NORMAL in every projection, and `leave_mode`
  /// or an explicit base mode leaves it too.
  /// VISUAL (a visual selection) and DRAG (a drag) are what a held button is
  /// for: each enters from NORMAL with its own mapping table, and the
  /// release returns to NORMAL, whichever path let go.
  func testAHeldButtonEntersVisualOrDragByItsPurpose() {
    for (hold, mode) in [(ButtonHold.visual, Mode.visual), (.drag, .drag)] {
      let entered = ModeReducer.reduce(.normal, .buttonHeld(hold))
      XCTAssertEqual(entered.0, mode)
      XCTAssertEqual(entered.1, [.renderSurface])
      XCTAssertEqual(mode.buttonHold, hold)
      let left = ModeReducer.reduce(mode, .buttonReleased)
      XCTAssertEqual(left.0, .normal)
      XCTAssertEqual(left.1, [.renderSurface])
      for state in allStates where state != .normal {
        XCTAssertEqual(
          ModeReducer.reduce(state, .buttonHeld(hold)).0, state, "\(state) ignores the hold")
      }
      XCTAssertEqual(mode.flashMode, .normal)
      XCTAssertEqual(mode.asReturnMode, .normal)
      XCTAssertTrue(mode.ownsKeyboard(hasHints: false, activationInFlight: false))
      XCTAssertEqual(mode.overlayInputMode(hasHints: true, activationInFlight: false), .hints)
      XCTAssertEqual(ModeReducer.reduce(mode, .leaveMode(hasHints: false)).0, .normal)
      XCTAssertEqual(ModeReducer.reduce(mode, .enterNormal).0, .normal)
      XCTAssertEqual(ModeReducer.reduce(mode, .enterInsert(targetPID: 7)).0, .insert)
      XCTAssertEqual(
        ModeReducer.reduce(mode, .clickResolved(entersInsert: false, targetPID: 7)).0, mode)
      XCTAssertEqual(
        ModeReducer.reduce(mode, .openCommand(restoreMode: true)).0, .command(restoreTo: .normal))
      XCTAssertEqual(
        ModeReducer.reduce(mode, .focusedAppChanged(pid: 7)).1, [.scheduleRecapture])
    }
    for state in allStates where state.buttonHold == nil {
      XCTAssertEqual(ModeReducer.reduce(state, .buttonReleased).0, state)
    }
    XCTAssertEqual(FlashStatusReport.modeName(.visual), "visual")
    XCTAssertEqual(FlashStatusReport.modeName(.drag), "drag")
    XCTAssertEqual(Mode.visual.label, .visual)
    XCTAssertEqual(Mode.drag.label, .drag)
    XCTAssertEqual(Mode.drag.badgeStyle, .drag)
    let labels = ConfigLoader.parse(
      "[mode]\nlabels = { normal = \"N\", insert = \"I\", command = \"C\", visual = \"V\", drag = \"D\" }"
    )
    XCTAssertEqual(labels.mode.labels.visual, "V")
    XCTAssertEqual(labels.mode.labels.drag, "D")
    XCTAssertEqual(Config().mode.labels.visual, "VISUAL")
    XCTAssertEqual(Config().mode.labels.drag, "DRAG")
  }

  func testHyperIsALeaderHoldOnNormal() {
    let (entered, enterEffects) = ModeReducer.reduce(.normal, .enterHyper)
    XCTAssertEqual(entered, .hyper(restoreTo: .normal))
    XCTAssertEqual(enterEffects, [.renderSurface])
    XCTAssertEqual(entered.flashMode, .normal)
    XCTAssertEqual(
      entered.overlayInputMode(hasHints: false, activationInFlight: false), .normal)
    XCTAssertTrue(entered.ownsKeyboard(hasHints: false, activationInFlight: false))

    let (left, leaveEffects) = ModeReducer.reduce(entered, .exitHyper)
    XCTAssertEqual(left, .normal)
    XCTAssertEqual(leaveEffects, [.renderSurface])

    XCTAssertEqual(ModeReducer.reduce(.insert, .enterHyper).0, .insert)
    XCTAssertEqual(
      ModeReducer.reduce(.command(restoreTo: .normal), .enterHyper).0, .command(restoreTo: .normal))
    XCTAssertEqual(ModeReducer.reduce(.normal, .exitHyper).0, .normal)
    XCTAssertEqual(
      ModeReducer.reduce(.hyper(restoreTo: .normal), .leaveMode(hasHints: false)).0,
      .normal)
    let command = ModeReducer.reduce(.hyper(restoreTo: .normal), .openCommand(restoreMode: true)).0
    XCTAssertEqual(command, .command(restoreTo: .normal))
  }

  func testLeaderHoldArmsPrefixOnlyOnACleanTap() {
    var hold = LeaderHold()
    XCTAssertEqual(hold.step(.leaderDown), .enter)
    XCTAssertEqual(hold.step(.leaderDown), .ignore)
    XCTAssertEqual(hold.step(.leaderUp), .exit(armPrefix: true))

    XCTAssertEqual(hold.step(.leaderDown), .enter)
    XCTAssertEqual(hold.step(.otherKey), .key)
    XCTAssertEqual(hold.step(.leaderUp), .exit(armPrefix: false))
    XCTAssertEqual(hold.step(.leaderUp), .passthrough)
    XCTAssertEqual(hold.step(.otherKey), .passthrough)
  }

  /// The session tap can drop the hyper key's key-up after a swallowed press
  /// and a synthetic post. Two consecutive "latched, but the key is up"
  /// readings leave; one flicker, a key that is still down, or a hold that
  /// already ended does not.
  func testHyperHoldLeavesWhenTheKeyStaysUp() {
    var watch = HyperHoldWatch()
    XCTAssertEqual(watch.sample(holding: true, keyIsDown: true), .stay)
    XCTAssertEqual(watch.sample(holding: true, keyIsDown: false), .stay)
    XCTAssertEqual(watch.sample(holding: true, keyIsDown: false), .exit)

    // A down between two ups starts the count over. An ended hold does too,
    // so the next single up reading does not leave.
    XCTAssertEqual(watch.sample(holding: true, keyIsDown: false), .stay)
    XCTAssertEqual(watch.sample(holding: true, keyIsDown: true), .stay)
    XCTAssertEqual(watch.sample(holding: true, keyIsDown: false), .stay)
    XCTAssertEqual(watch.sample(holding: true, keyIsDown: false), .exit)
    XCTAssertEqual(watch.sample(holding: false, keyIsDown: false), .stay)
    XCTAssertEqual(watch.sample(holding: true, keyIsDown: false), .stay)

    XCTAssertTrue(HyperHoldWatch.keyArrivedWhileUp(holding: true, keyIsDown: false))
    XCTAssertFalse(HyperHoldWatch.keyArrivedWhileUp(holding: true, keyIsDown: true))
    XCTAssertFalse(HyperHoldWatch.keyArrivedWhileUp(holding: false, keyIsDown: false))
  }

  /// A chord is down only when every part of it is down. Shift on an
  /// unmodified space hold does not release it.
  func testHyperKeyChordRequiresEveryKey() {
    let space = HyperKeyChord.parse("space")
    XCTAssertEqual(space?.key, CGKeyCode(HotkeySyntax.parseKey("space")!))
    XCTAssertEqual(space?.modifiers, [])
    let spaceDown: (CGKeyCode) -> Bool = { $0 == space!.key }
    XCTAssertTrue(HyperKeyChord.isDown(space!, keyIsDown: spaceDown, flags: []))
    XCTAssertTrue(HyperKeyChord.isDown(space!, keyIsDown: spaceDown, flags: .maskShift))
    XCTAssertFalse(HyperKeyChord.isDown(space!, keyIsDown: { _ in false }, flags: .maskShift))

    let chord = HyperKeyChord.parse("cmd+space")
    XCTAssertEqual(chord?.modifiers, .maskCommand)
    XCTAssertFalse(HyperKeyChord.isDown(chord!, keyIsDown: spaceDown, flags: []))
    XCTAssertFalse(HyperKeyChord.isDown(chord!, keyIsDown: { _ in false }, flags: .maskCommand))
    XCTAssertTrue(HyperKeyChord.isDown(chord!, keyIsDown: spaceDown, flags: .maskCommand))

    let letter = HyperKeyChord.parse("ctrl-a")
    XCTAssertEqual(letter?.key, CGKeyCode(HotkeySyntax.parseKey("a")!))
    XCTAssertEqual(letter?.modifiers, .maskControl)
    XCTAssertNil(HyperKeyChord.parse("ctrl-"))
    XCTAssertNil(HyperKeyChord.parse("cmd+nope"))
  }

  /// The prepared matcher settles every key that cannot be the hyper key
  /// from its key code or typed character, and agrees with the full test on
  /// every key that can.
  func testHyperKeyMatcherAgreesWithTheFullTestAndFiltersReleases() {
    let space = CGKeyCode(HotkeySyntax.parseKey("space")!)
    let a = CGKeyCode(HotkeySyntax.parseKey("a")!)
    let f = CGKeyCode(HotkeySyntax.parseKey("f")!)
    struct Key {
      var code: CGKeyCode
      var flags: NSEvent.ModifierFlags = []
      var characters: String?
      var ignoring: String?
    }
    let keys: [Key] = [
      Key(code: space, characters: " ", ignoring: " "),
      Key(code: space, flags: .shift, characters: " ", ignoring: " "),
      Key(code: space, flags: .command, characters: " ", ignoring: " "),
      Key(code: space, characters: nil, ignoring: nil),
      Key(code: a, characters: "a", ignoring: "a"),
      Key(code: a, flags: .control, characters: "\u{01}", ignoring: "a"),
      Key(code: a, flags: .shift, characters: "A", ignoring: "a"),
      Key(code: f, characters: "f", ignoring: "f"),
      // A remapped layout types `f` on the ANSI `a` position.
      Key(code: a, characters: "f", ignoring: "f"),
      Key(code: f, flags: .shift, characters: "?", ignoring: "/"),
    ]
    for atom in ["space", "cmd+space", "ctrl-a", "f", "?", "tab"] {
      let matcher = HyperKeyMatcher(atom: atom)
      for key in keys {
        let full = NormalModeInterpreter.isHyperKey(
          atom: atom, keyCode: key.code, modifierFlags: key.flags,
          characters: key.characters, charactersIgnoringModifiers: key.ignoring)
        let fast = NormalModeInterpreter.isHyperKey(
          matcher: matcher, keyCode: key.code, modifierFlags: key.flags,
          characters: key.characters, charactersIgnoringModifiers: key.ignoring)
        XCTAssertEqual(fast, full, "atom=\(atom) code=\(key.code) flags=\(key.flags)")
        if full {
          XCTAssertTrue(matcher.mayMatch(keyCode: Int64(key.code)), "atom=\(atom)")
        }
      }
    }
    let spaceMatcher = HyperKeyMatcher(atom: "space")
    XCTAssertTrue(spaceMatcher.mayMatch(keyCode: Int64(space)))
    XCTAssertFalse(spaceMatcher.mayMatch(keyCode: Int64(a)), "other releases need no event")
    let letterMatcher = HyperKeyMatcher(atom: "f")
    XCTAssertTrue(letterMatcher.mayMatch(keyCode: Int64(a)), "a layout may type f anywhere")
    XCTAssertEqual(letterMatcher.characters, ["f", "F"])
  }

  func testConfigPreparesTheHyperMatcherAndLeaderAtom() {
    var mode = Config.Mode()
    // As configured: a bare `space` would be five keys, not the space bar.
    mode.normalLeader = "<space>"
    mode.hyperKey = "<leader>"
    mode.refreshLeaderDerivedDefaults()
    XCTAssertEqual(mode.resolvedHyperKey, "space")
    XCTAssertEqual(mode.resolvedHyperMatcher?.atom, "space")
    XCTAssertEqual(mode.resolvedHyperMatcher?.chord, HyperKeyChord.parse("space"))
    XCTAssertEqual(mode.resolvedLeaderAtom, NormalModeInterpreter.translateLeader("<space>"))
    XCTAssertEqual(mode.resolvedLeaderAtom, "space")
    mode.normalLeader = nil
    mode.refreshLeaderDerivedDefaults()
    XCTAssertNil(mode.resolvedHyperMatcher)
    XCTAssertNil(mode.resolvedLeaderAtom)
  }

  func testASecondLeaderHoldEntersHyperWhileItsPrefixIsArmed() {
    XCTAssertTrue(
      LeaderHold.canEnter(
        pending: "", leaderRepeatsAnchor: false, leaderAtom: " ", leaderContinuesPending: false,
        isRepeat: false))
    // Releasing the leader armed `<space>`. Holding it again still enters.
    XCTAssertTrue(
      LeaderHold.canEnter(
        pending: " ", leaderRepeatsAnchor: false, leaderAtom: " ", leaderContinuesPending: false,
        isRepeat: false))
    // `<leader><leader>` is a real sequence, so the second press stays in it.
    XCTAssertFalse(
      LeaderHold.canEnter(
        pending: " ", leaderRepeatsAnchor: false, leaderAtom: " ", leaderContinuesPending: true,
        isRepeat: false))
    XCTAssertFalse(
      LeaderHold.canEnter(
        pending: "g", leaderRepeatsAnchor: false, leaderAtom: " ", leaderContinuesPending: false,
        isRepeat: false))
    XCTAssertFalse(
      LeaderHold.canEnter(
        pending: "", leaderRepeatsAnchor: false, leaderAtom: " ", leaderContinuesPending: false,
        isRepeat: true))
  }

  /// `]t` arms a repeat of `t`. Any other key drops that anchor, the leader
  /// included, so holding it right after enters HYPER; only a mapping whose
  /// final key is the leader keeps the press as its repeat.
  func testALeaderHoldAfterARepeatableSequenceEntersHyper() {
    XCTAssertFalse(LeaderHold.leaderRepeats(anchor: "]t", leaderAtom: " "))
    XCTAssertTrue(
      LeaderHold.canEnter(
        pending: "", leaderRepeatsAnchor: LeaderHold.leaderRepeats(anchor: "]t", leaderAtom: " "),
        leaderAtom: " ", leaderContinuesPending: false, isRepeat: false))
    XCTAssertFalse(LeaderHold.leaderRepeats(anchor: nil, leaderAtom: " "))
    XCTAssertTrue(LeaderHold.leaderRepeats(anchor: "g\u{1F} ", leaderAtom: " "))
    XCTAssertFalse(
      LeaderHold.canEnter(
        pending: "", leaderRepeatsAnchor: true, leaderAtom: " ", leaderContinuesPending: false,
        isRepeat: false))
  }

  /// `[mode.visual.mappings]` is read before NORMAL while a button is held:
  /// `j` `k` `h` `l` step the pointer there and nowhere else, and every key
  /// VISUAL leaves alone keeps NORMAL's meaning, Carbon chords included.
  func testVisualMappingsLayerOverNormal() throws {
    let config = ConfigLoader.parse(
      """
      [mode.visual.mappings]
      "ctrl+o" = ["flash", "scroll_top"]
      "x" = false
      """)
    XCTAssertTrue(config.diagnostics.isEmpty, "\(config.diagnostics)")
    let visual = config.mode.compiledVisual
    let normal = config.mode.compiledNormal
    XCTAssertEqual(
      visual.mapping(for: NormalModeInterpreter.canonicalizeMappingKey("j")!)?.action,
      .flashCommand(.mouseStep(.down)))
    XCTAssertNil(normal.mapping(for: NormalModeInterpreter.canonicalizeMappingKey("j")!))
    XCTAssertEqual(
      visual.mapping(for: NormalModeInterpreter.canonicalizeMappingKey("h")!)?.action,
      .flashCommand(.mouseStep(.left)))
    XCTAssertEqual(
      normal.mapping(for: NormalModeInterpreter.canonicalizeMappingKey("h")!)?.action,
      .flashCommand(.scroll(.left)))
    // A key VISUAL leaves alone keeps NORMAL's meaning; a picked target
    // extends the selection instead of clicking.
    let t = try XCTUnwrap(NormalModeInterpreter.canonicalizeMappingKey("t"))
    XCTAssertEqual(visual.mapping(for: t)?.action, normal.mapping(for: t)?.action)
    let f = try XCTUnwrap(NormalModeInterpreter.canonicalizeMappingKey("f"))
    XCTAssertEqual(visual.mapping(for: f)?.action, .flashCommand(.mouseTarget(.move)))
    // `false` in VISUAL removes NORMAL's key there only.
    let x = try XCTUnwrap(NormalModeInterpreter.canonicalizeMappingKey("x"))
    XCTAssertNil(visual.mapping(for: x))
    XCTAssertNotNil(normal.mapping(for: x))
    // A VISUAL chord wins over NORMAL's only while the button is held.
    let chord = try XCTUnwrap(ModeMapping.parseNativeHotkey("ctrl+o"))
    XCTAssertEqual(
      MappingsCoordinator.activeMappingTable(in: config.mode, scope: .visual)[chord]?.action,
      .flashCommand(.scroll(.top)))
    XCTAssertNotEqual(
      MappingsCoordinator.activeMappingTable(in: config.mode, scope: .normal)[chord]?.action,
      .flashCommand(.scroll(.top)))
    XCTAssertEqual(
      ConfigLoader.parse("[mode.apps.\"com.example.app\".visual.mappings]\n\"q\" = false")
        .diagnostics, [])
  }

  /// DRAG moves what the button grabbed: `h` `j` `k` `l` nudge it, Return
  /// and `D` drop it, Escape puts it back, and `f` picks where it goes. `D`
  /// and `cD` grab with the left and right buttons from NORMAL.
  func testDragMappingsMoveDropAndCancel() throws {
    let config = ConfigLoader.parse("")
    func key(_ raw: String) throws -> String {
      try XCTUnwrap(NormalModeInterpreter.canonicalizeMappingKey(raw))
    }
    let drag = config.mode.compiledDrag
    XCTAssertEqual(
      drag.mapping(for: try key("j"))?.action, .flashCommand(.mouseNudge(.down, distance: 16)))
    XCTAssertEqual(
      drag.mapping(for: try key("L"))?.action, .flashCommand(.mouseNudge(.right, distance: 96)))
    XCTAssertEqual(
      drag.mapping(for: try key("<return>"))?.action,
      .flashCommand(.mouseButton(.init(state: .release, button: .primary, hold: .drag))))
    XCTAssertEqual(
      drag.mapping(for: try key("<esc>"))?.action,
      .flashCommand(.mouseButton(.init(state: .cancel, button: .primary, hold: .drag))))
    XCTAssertEqual(drag.mapping(for: try key("f"))?.action, .flashCommand(.mouseTarget(.move)))
    let normal = config.mode.compiledNormal
    XCTAssertEqual(
      normal.mapping(for: try key("D"))?.action,
      .flashCommand(.mouseButton(.init(state: .toggle, button: .primary, hold: .drag))))
    XCTAssertEqual(
      normal.mapping(for: try key("cD"))?.action,
      .flashCommand(.mouseButton(.init(state: .toggle, button: .secondary, hold: .drag))))
    XCTAssertEqual(
      normal.mapping(for: try key("v"))?.action,
      .flashCommand(.mouseButton(.init(state: .toggle, button: .primary, hold: .visual))))
  }

  /// A held mode's own key hides every NORMAL binding it starts, so it fires
  /// at once instead of waiting for the sequence timeout.
  func testAHeldModeKeyHidesTheNormalSequencesItStarts() throws {
    let config = ConfigLoader.parse(
      """
      [mode.drag.mappings]
      "d" = ["flash", "scroll_top"]
      """)
    XCTAssertTrue(config.diagnostics.isEmpty, "\(config.diagnostics)")
    let d = try XCTUnwrap(NormalModeInterpreter.canonicalizeMappingKey("d"))
    let df = try XCTUnwrap(NormalModeInterpreter.canonicalizeMappingKey("df"))
    XCTAssertNil(config.mode.compiledDrag.mapping(for: df))
    XCTAssertFalse(config.mode.compiledDrag.hasStrictPrefix(d))
    XCTAssertNotNil(config.mode.compiledNormal.mapping(for: df))
    XCTAssertNil(
      config.mode.compiledVisual.mapping(for: df), "VISUAL's own d (cut) hides NORMAL's df too")
  }

  /// The mapping scope is a projection of the mode, applied on every
  /// transition, so no path can leave INSERT reading NORMAL's chords (a
  /// Command chord NORMAL maps would be swallowed in the app) or VISUAL's
  /// table outside VISUAL. HYPER reads NORMAL's; advanced mode off reads
  /// INSERT's.
  func testEachModeReadsItsOwnMappingScope() {
    let expected: [(Mode, MappingScope)] = [
      (.disabled, .insert), (.insert, .insert), (.normal, .normal),
      (.hyper(restoreTo: .normal), .normal), (.visual, .visual), (.drag, .drag),
      (.command(restoreTo: .insert), .command), (.command(restoreTo: .normal), .command),
      (.terminal(restoreTo: .insert, returnPID: nil), .terminal),
    ]
    for (mode, scope) in expected {
      XCTAssertEqual(mode.mappingScope, scope, "\(mode)")
    }
    for state in allStates {
      for event in allEvents {
        let next = ModeReducer.reduce(state, event).0
        XCTAssertEqual(
          next.mappingScope == .insert, next == .disabled || next.isInsert,
          "\(state) + \(event): only INSERT and disabled read INSERT's chords")
      }
    }
  }

  // MARK: Structural purity

  /// The whole point of `Sources/flash/App/Mode/` is to be AppKit-free so the
  /// state machine is exhaustively testable. Enforce it.
  func testModeCoreIsAppKitFree() {
    let modeDir = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // FlashTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // repo root
      .appendingPathComponent("Sources/flash/App/Mode")
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: modeDir, includingPropertiesForKeys: nil)
    else {
      return XCTFail("Mode core directory not found at \(modeDir.path)")
    }
    let swiftFiles = files.filter { $0.pathExtension == "swift" }
    XCTAssertFalse(swiftFiles.isEmpty, "expected Mode core .swift files")
    for file in swiftFiles {
      let source = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
      XCTAssertFalse(
        source.contains("import AppKit") || source.contains("import Cocoa"),
        "\(file.lastPathComponent) must stay AppKit-free")
    }
  }
}
