import Foundation
import XCTest

@testable import flash

/// Exhaustive tests for the pure mode state machine. These pin the invariants
/// the audit asked for: deterministic transitions, no mouse/focus-driven exit
/// from passthrough, projection correctness (no badge/label drift), and the shared
/// editable-click decision.
final class ModeReducerTests: XCTestCase {
  // Representative states covering every case + payload variation.
  private let allStates: [Mode] = [
    .disabled,
    .passthrough,
    .normal,
    .command(scope: .commandLine, restoreTo: .passthrough),
    .command(scope: .finder(all: true), restoreTo: .passthrough),
    .command(scope: .finder(all: false), restoreTo: .disabled),
    .terminal(restoreTo: .passthrough),
    .terminal(restoreTo: .disabled),
  ]

  // Representative events covering every case.
  private let allEvents: [ModeEvent] = [
    .enterPassthrough(targetPID: 7),
    .enterNormal(targetPID: 7),
    .leaveMode(hasHints: false, targetPID: nil),
    .leaveMode(hasHints: true, targetPID: 7),
    .openCommand(scope: .commandLine),
    .openCommand(scope: .finder(all: true)),
    .closeCommand(reason: "submit"),
    .openTerminal,
    .closeTerminal(targetPID: nil),
    .clickResolved(entersPassthrough: true, targetPID: 7),
    .clickResolved(entersPassthrough: false, targetPID: 7),
    .advancedModeChanged(enabled: true),
    .advancedModeChanged(enabled: false),
    .startup(advancedEnabled: true),
    .startup(advancedEnabled: false),
    .focusedAppChanged(pid: 7),
  ]

  // MARK: Initialization

  func testStartupPicksInitialMode() {
    XCTAssertEqual(ModeReducer.reduce(.disabled, .startup(advancedEnabled: true)).0, .passthrough)
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
        XCTAssertEqual(fallbackCaptures, 0, "Startup must leave app input ownership intact")
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

  // MARK: Passthrough stickiness — the central invariant

  func testMouseAndFocusNeverLeavePassthrough() {
    for event in [
      ModeEvent.clickResolved(entersPassthrough: true, targetPID: 7),
      .clickResolved(entersPassthrough: false, targetPID: 7),
      .focusedAppChanged(pid: 7),
      .enterPassthrough(targetPID: 7),
    ] {
      let next = ModeReducer.reduce(.passthrough, event).0
      XCTAssertTrue(next.isPassthrough, "\(event) must keep PASSTHROUGH, got \(next)")
    }
  }

  func testOnlyKeyboardAndConfigLeavePassthrough() {
    XCTAssertEqual(
      ModeReducer.reduce(.passthrough, .enterNormal(targetPID: 7)).0, .normal)
    XCTAssertEqual(
      ModeReducer.reduce(.passthrough, .advancedModeChanged(enabled: false)).0, .disabled)
  }

  func testFocusedAppChangedNeverChangesMode() {
    for state in allStates {
      let (next, effects) = ModeReducer.reduce(state, .focusedAppChanged(pid: 99))
      XCTAssertEqual(next, state, "focusedAppChanged must not change \(state)")
      switch state {
      case .normal, .command:
        XCTAssertEqual(effects, [.scheduleRecapture])
      case .passthrough, .disabled, .terminal:
        XCTAssertTrue(effects.isEmpty)
      }
    }
  }

  // MARK: Mouse enters only from normal

  func testClickEntersPassthroughOnlyFromNormal() {
    XCTAssertEqual(
      ModeReducer.reduce(.normal, .clickResolved(entersPassthrough: true, targetPID: 7)).0,
      .passthrough)
    XCTAssertEqual(
      ModeReducer.reduce(.normal, .clickResolved(entersPassthrough: false, targetPID: 7)).0, .normal
    )
    // From any non-normal state, a click cannot change the mode.
    for state in allStates where !state.isNormal {
      XCTAssertEqual(
        ModeReducer.reduce(state, .clickResolved(entersPassthrough: true, targetPID: 7)).0, state)
    }
  }

  // MARK: Advanced gate

  func testAdvancedGateRefusesNormalWhenDisabled() {
    XCTAssertEqual(ModeReducer.reduce(.disabled, .enterNormal(targetPID: 7)).0, .disabled)
    XCTAssertEqual(
      ModeReducer.reduce(.disabled, .enterPassthrough(targetPID: 7)).0,
      .disabled)
    XCTAssertEqual(
      ModeReducer.reduce(.disabled, .advancedModeChanged(enabled: true)).0, .passthrough)
  }

  // MARK: Command / modal lifecycle + restore fidelity

  func testEveryCommandSurfaceClosesToPassthroughOrDisabled() {
    for scope in [CommandScope.commandLine, .finder(all: true), .finder(all: false)] {
      for origin in [Mode.normal, .passthrough, .disabled] {
        let (mode, _) = ModeReducer.reduce(
          origin, .openCommand(scope: scope))
        let expected: Mode = origin.advancedEnabled ? .passthrough : .disabled
        for reason in ["submit", "cancel"] {
          let (closed, effects) = ModeReducer.reduce(mode, .closeCommand(reason: reason))
          XCTAssertEqual(closed, expected, "\(scope) from \(origin) after \(reason)")
          XCTAssertFalse(effects.contains(.scheduleRecapture))
        }
      }
    }
  }

  func testCloseCommandFromNonCommandIsNoop() {
    XCTAssertEqual(ModeReducer.reduce(.normal, .closeCommand(reason: "x")).0, .normal)
  }

  func testCommandDismissalReturnsNativeInputWithAdvancedModeDisabled() {
    let (opened, _) = ModeReducer.reduce(.disabled, .openCommand(scope: .commandLine))
    let (closed, effects) = ModeReducer.reduce(opened, .closeCommand(reason: "cancel"))
    XCTAssertEqual(closed, .disabled)
    XCTAssertTrue(effects.contains(.activateFocusedApp(pid: nil)))
    XCTAssertFalse(effects.contains(.scheduleRecapture))
  }

  func testLeaveModeReturnsPassthroughToNormal() {
    let (next, effects) = ModeReducer.reduce(
      .passthrough, .leaveMode(hasHints: false, targetPID: nil))
    XCTAssertEqual(next, .normal)
    XCTAssertEqual(effects, ModeReducer.enterEffects(for: .normal, targetPID: nil))
  }

  func testLeaveModeRestoresEveryCommandSurface() {
    for scope in [CommandScope.commandLine, .finder(all: true), .finder(all: false)] {
      for origin in [Mode.normal, .passthrough, .disabled] {
        let (opened, _) = ModeReducer.reduce(origin, .openCommand(scope: scope))
        let expected = ModeReducer.reduce(opened, .closeCommand(reason: "cancel"))
        let actual = ModeReducer.reduce(opened, .leaveMode(hasHints: false, targetPID: nil))
        XCTAssertEqual(actual.0, expected.0)
        XCTAssertEqual(actual.1, expected.1)
        XCTAssertTrue(actual.1.contains(.clearTransientHintState))
      }
    }
  }

  func testLeaveModeExitsIdleNormalToPassthrough() {
    let (next, effects) = ModeReducer.reduce(.normal, .leaveMode(hasHints: false, targetPID: 42))
    XCTAssertEqual(next, .passthrough)
    XCTAssertEqual(effects, ModeReducer.enterEffects(for: .passthrough, targetPID: 42))
  }

  func testLeaveModeKeepsDisabled() {
    let (next, effects) = ModeReducer.reduce(.disabled, .leaveMode(hasHints: false, targetPID: nil))
    XCTAssertEqual(next, .disabled)
    XCTAssertTrue(effects.isEmpty)
  }

  func testLeaveModeRestoresTerminalAndPreviousApplication() {
    for origin in [Mode.normal, .passthrough, .disabled] {
      let (opened, _) = ModeReducer.reduce(origin, .openTerminal)
      let actual = ModeReducer.reduce(opened, .leaveMode(hasHints: false, targetPID: 42))
      let expected = ModeReducer.reduce(opened, .closeTerminal(targetPID: 42))
      XCTAssertEqual(actual.0, origin.advancedEnabled ? .passthrough : .disabled)
      XCTAssertEqual(actual.1, expected.1)
      XCTAssertTrue(actual.1.contains(.hideTerminalPopup))
      XCTAssertTrue(actual.1.contains(.activateFocusedApp(pid: 42)))
    }
  }

  func testLeaveModeWithHintsDismissesThemAndKeepsTheBaseMode() {
    for state in [Mode.disabled, .normal, .passthrough] {
      let (next, effects) = ModeReducer.reduce(state, .leaveMode(hasHints: true, targetPID: 7))
      XCTAssertEqual(next, state)
      XCTAssertEqual(effects, ModeReducer.enterEffects(for: state, targetPID: 7))
      XCTAssertTrue(effects.contains(.clearTransientHintState))
    }
  }

  func testLeaveModeVerbRejectsArguments() {
    XCTAssertEqual(URLEventHandler.parse(verb: "leave_mode", args: [:]), .leaveMode)
    XCTAssertNil(URLEventHandler.parse(verb: "leave_mode", args: ["mode": "passthrough"]))
  }

  func testEnterNormalClosesEveryCommandSurface() {
    let commandStates: [Mode] = [
      .command(scope: .commandLine, restoreTo: .passthrough),
      .command(scope: .finder(all: true), restoreTo: .passthrough),
    ]
    let expectedEffects = ModeReducer.enterEffects(for: .normal, targetPID: nil)
    XCTAssertTrue(expectedEffects.contains(.clearTransientHintState))

    for state in commandStates {
      let (next, effects) = ModeReducer.reduce(state, .enterNormal(targetPID: nil))
      XCTAssertEqual(next, .normal)
      XCTAssertEqual(effects, expectedEffects)
    }
  }

  // MARK: Determinism + totality

  func testDisabledEligibilitySurvivesExplicitRequestsInsideEverySurface() {
    let surfaces: [ModeEvent] = [
      .openCommand(scope: .commandLine),
      .openCommand(scope: .finder(all: true)),
      .openTerminal,
    ]
    for open in surfaces {
      for request in [ModeEvent.enterNormal(targetPID: nil), .enterPassthrough(targetPID: nil)] {
        let opened = ModeReducer.reduce(.disabled, open).0
        let closed = ModeReducer.reduce(opened, request).0
        XCTAssertEqual(closed, .disabled, "\(open), \(request)")
        XCTAssertEqual(
          ModeReducer.reduce(closed, .leaveMode(hasHints: false, targetPID: nil)).0, .disabled)
      }
    }
  }

  func testEnablingAdvancedModeReconcilesEveryTransientReturn() {
    for open in [
      ModeEvent.openCommand(scope: .commandLine),
      .openCommand(scope: .finder(all: false)),
      .openTerminal,
    ] {
      let opened = ModeReducer.reduce(.disabled, open).0
      let enabled = ModeReducer.reduce(opened, .advancedModeChanged(enabled: true)).0
      XCTAssertEqual(
        ModeReducer.reduce(enabled, .leaveMode(hasHints: false, targetPID: nil)).0, .passthrough)
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
        .prepareModeEntry, .setMappingScope(.normal), .clearTransientHintState, .renderSurface,
        .scheduleRecapture,
      ])

    let passthrough = ModeReducer.enterEffects(for: .passthrough, targetPID: 42)
    XCTAssertEqual(
      passthrough,
      [
        .prepareModeEntry, .setMappingScope(.passthrough), .clearTransientHintState,
        .hideOverlayIfIdle,
        .renderSurface,
        .activateFocusedApp(pid: 42),
      ])
    XCTAssertFalse(
      passthrough.contains(.scheduleRecapture), "passthrough must not grab the keyboard")

    let command = ModeReducer.enterEffects(
      for: .command(scope: .commandLine, restoreTo: .passthrough), targetPID: nil)
    XCTAssertEqual(
      command, [.prepareModeEntry, .setMappingScope(.command), .renderSurface, .scheduleRecapture])
  }

  // MARK: Projection correctness — the anti-drift table

  func testProjectionTable() {
    XCTAssertEqual(Mode.disabled.flashMode, .passthrough)
    XCTAssertEqual(Mode.passthrough.flashMode, .passthrough)
    XCTAssertEqual(Mode.normal.flashMode, .normal)
    XCTAssertEqual(Mode.command(scope: .commandLine, restoreTo: .passthrough).flashMode, .normal)

    XCTAssertEqual(Mode.disabled.label, .passthrough)
    XCTAssertEqual(Mode.passthrough.label, .passthrough)
    XCTAssertEqual(Mode.normal.label, .normal)
    XCTAssertEqual(Mode.command(scope: .commandLine, restoreTo: .passthrough).label, .command)

    // overlay input mode (idle, no hints / activation)
    XCTAssertEqual(
      Mode.passthrough.overlayInputMode(hasHints: false, activationInFlight: false),
      .hints)
    XCTAssertEqual(
      Mode.normal.overlayInputMode(hasHints: false, activationInFlight: false), .normal)
    // normal with hints up routes hint letters, not commands
    XCTAssertEqual(Mode.normal.overlayInputMode(hasHints: true, activationInFlight: false), .hints)
    XCTAssertEqual(Mode.normal.overlayInputMode(hasHints: false, activationInFlight: true), .hints)
    XCTAssertEqual(
      Mode.command(scope: .commandLine, restoreTo: .passthrough)
        .overlayInputMode(hasHints: false, activationInFlight: false), .commandLine)
    XCTAssertEqual(
      Mode.command(scope: .finder(all: true), restoreTo: .passthrough)
        .overlayInputMode(hasHints: false, activationInFlight: false), .candidateFinder)

    XCTAssertFalse(
      Mode.passthrough.ownsKeyboard(hasHints: false, activationInFlight: false))
    XCTAssertTrue(Mode.normal.ownsKeyboard(hasHints: false, activationInFlight: false))
    XCTAssertFalse(Mode.normal.ownsKeyboard(hasHints: true, activationInFlight: false))
    XCTAssertTrue(
      Mode.command(scope: .commandLine, restoreTo: .passthrough)
        .ownsKeyboard(hasHints: false, activationInFlight: false))

    // Native-surface suspension (context menu up): never capture, in any base
    // mode; NORMAL stays `.normal`-routed so the cursor stays visible under the
    // menu (the `.hints` routing would hide it).
    XCTAssertFalse(
      Mode.normal.ownsKeyboard(
        hasHints: false, activationInFlight: false, nativeSurfaceSuspended: true))
    XCTAssertFalse(
      Mode.command(scope: .commandLine, restoreTo: .passthrough)
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
    XCTAssertEqual(Mode.command(scope: .commandLine, restoreTo: .passthrough).badgeStyle, .command)
    XCTAssertEqual(
      Mode.command(scope: .finder(all: true), restoreTo: .passthrough).badgeStyle, .command)
    XCTAssertEqual(Mode.normal.badgeStyle, .normal)
    XCTAssertEqual(Mode.passthrough.badgeStyle, .passthrough)
    XCTAssertEqual(Mode.disabled.badgeStyle, .passthrough)
  }

  func testTerminalHighlightDoesNotClaimGlobalInput() {
    for restoreTo in [ReturnMode.passthrough, .disabled] {
      let mode = Mode.terminal(restoreTo: restoreTo)
      XCTAssertEqual(mode.label, .terminal)
      XCTAssertEqual(mode.badgeStyle, .terminal)
      XCTAssertEqual(mode.flashMode, .passthrough)
      XCTAssertFalse(mode.ownsKeyboard(hasHints: false, activationInFlight: false))
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
