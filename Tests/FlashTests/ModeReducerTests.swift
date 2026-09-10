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
    .command(scope: .commandLine, restoreTo: .normal),
    .command(scope: .finder(all: true), restoreTo: .insert),
    .command(scope: .finder(all: false), restoreTo: .disabled),
    .terminal(restoreTo: .normal),
    .terminal(restoreTo: .insert),
    .terminal(restoreTo: .disabled),
  ]

  // Representative events covering every case.
  private let allEvents: [ModeEvent] = [
    .enterInsert(targetPID: 7),
    .enterNormal(targetPID: 7),
    .leaveMode(hasHints: false, targetPID: nil),
    .leaveMode(hasHints: true, targetPID: 7),
    .openCommand(scope: .commandLine, restoreMode: false),
    .openCommand(scope: .finder(all: true), restoreMode: true),
    .closeCommand(reason: "submit"),
    .openTerminal,
    .closeTerminal(targetPID: nil),
    .clickResolved(entersInsert: true, targetPID: 7),
    .clickResolved(entersInsert: false, targetPID: 7),
    .advancedModeChanged(enabled: true),
    .advancedModeChanged(enabled: false),
    .startup(advancedEnabled: true),
    .startup(advancedEnabled: false),
    .focusedAppChanged(pid: 7),
  ]

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
      ModeReducer.reduce(.insert, .enterNormal(targetPID: 7)).0, .normal)
    XCTAssertEqual(
      ModeReducer.reduce(.insert, .advancedModeChanged(enabled: false)).0, .disabled)
  }

  func testFocusedAppChangedNeverChangesMode() {
    for state in allStates {
      let (next, effects) = ModeReducer.reduce(state, .focusedAppChanged(pid: 99))
      XCTAssertEqual(next, state, "focusedAppChanged must not change \(state)")
      switch state {
      case .normal, .command:
        XCTAssertEqual(effects, [.scheduleRecapture])
      case .insert, .disabled, .terminal:
        XCTAssertTrue(effects.isEmpty)
      }
    }
  }

  // MARK: Mouse enters only from normal

  func testClickEntersInsertOnlyFromNormal() {
    XCTAssertEqual(
      ModeReducer.reduce(.normal, .clickResolved(entersInsert: true, targetPID: 7)).0,
      .insert)
    XCTAssertEqual(
      ModeReducer.reduce(.normal, .clickResolved(entersInsert: false, targetPID: 7)).0, .normal)
    // From any non-normal state, a click cannot change the mode.
    for state in allStates where !state.isNormal {
      XCTAssertEqual(
        ModeReducer.reduce(state, .clickResolved(entersInsert: true, targetPID: 7)).0, state)
    }
  }

  // MARK: Advanced gate

  func testAdvancedGateRefusesNormalWhenDisabled() {
    XCTAssertEqual(ModeReducer.reduce(.disabled, .enterNormal(targetPID: 7)).0, .disabled)
    XCTAssertEqual(
      ModeReducer.reduce(.disabled, .enterInsert(targetPID: 7)).0,
      .disabled)
    XCTAssertEqual(
      ModeReducer.reduce(.disabled, .advancedModeChanged(enabled: true)).0, .insert)
  }

  // MARK: Command / modal lifecycle + restore fidelity

  func testCommandLifecycleRestores() {
    // Default exit is NORMAL (matches commandLineExitMode).
    var (mode, _) = ModeReducer.reduce(
      .normal, .openCommand(scope: .commandLine, restoreMode: false))
    XCTAssertEqual(mode, .command(scope: .commandLine, restoreTo: .normal))
    XCTAssertEqual(ModeReducer.reduce(mode, .closeCommand(reason: "x")).0, .normal)

    // restoreMode preserves the entry mode (here: insert).
    (mode, _) = ModeReducer.reduce(
      .insert, .openCommand(scope: .finder(all: true), restoreMode: true))
    XCTAssertEqual(mode, .command(scope: .finder(all: true), restoreTo: .insert))
    XCTAssertEqual(ModeReducer.reduce(mode, .closeCommand(reason: "x")).0, .insert)

    // Flashlight from disabled (advanced off) returns to disabled, never a
    // phantom NORMAL.
    (mode, _) = ModeReducer.reduce(
      .disabled, .openCommand(scope: .finder(all: false), restoreMode: false))
    XCTAssertEqual(mode, .command(scope: .finder(all: false), restoreTo: .disabled))
    XCTAssertEqual(ModeReducer.reduce(mode, .closeCommand(reason: "x")).0, .disabled)
  }

  func testCloseCommandFromNonCommandIsNoop() {
    XCTAssertEqual(ModeReducer.reduce(.normal, .closeCommand(reason: "x")).0, .normal)
  }

  func testLeaveModeReturnsInsertToNormal() {
    let (next, effects) = ModeReducer.reduce(.insert, .leaveMode(hasHints: false, targetPID: nil))
    XCTAssertEqual(next, .normal)
    XCTAssertEqual(effects, ModeReducer.enterEffects(for: .normal, targetPID: nil))
  }

  func testLeaveModeRestoresEveryCommandSurface() {
    for scope in [CommandScope.commandLine, .finder(all: true), .finder(all: false)] {
      for origin in [Mode.normal, .insert, .disabled] {
        for restoreMode in [false, true] {
          let (opened, _) = ModeReducer.reduce(
            origin, .openCommand(scope: scope, restoreMode: restoreMode))
          let expected = ModeReducer.reduce(opened, .closeCommand(reason: "cancel"))
          let actual = ModeReducer.reduce(opened, .leaveMode(hasHints: false, targetPID: nil))
          XCTAssertEqual(actual.0, expected.0)
          XCTAssertEqual(actual.1, expected.1)
          XCTAssertTrue(actual.1.contains(.clearTransientHintState))
        }
      }
    }
  }

  func testLeaveModeKeepsNormalAndDisabled() {
    for state in [Mode.normal, .disabled] {
      let (next, effects) = ModeReducer.reduce(state, .leaveMode(hasHints: false, targetPID: nil))
      XCTAssertEqual(next, state)
      XCTAssertTrue(effects.isEmpty)
    }
  }

  func testLeaveModeRestoresTerminalAndPreviousApplication() {
    for origin in [Mode.normal, .insert, .disabled] {
      let (opened, _) = ModeReducer.reduce(origin, .openTerminal)
      let actual = ModeReducer.reduce(opened, .leaveMode(hasHints: false, targetPID: 42))
      let expected = ModeReducer.reduce(opened, .closeTerminal(targetPID: 42))
      XCTAssertEqual(actual.0, origin)
      XCTAssertEqual(actual.1, expected.1)
      XCTAssertTrue(actual.1.contains(.hideTerminalPopup))
      XCTAssertTrue(actual.1.contains(.activateFocusedApp(pid: 42)))
    }
  }

  func testLeaveModeWithHintsDismissesThemAndKeepsTheBaseMode() {
    for state in [Mode.disabled, .normal, .insert] {
      let (next, effects) = ModeReducer.reduce(state, .leaveMode(hasHints: true, targetPID: 7))
      XCTAssertEqual(next, state)
      XCTAssertEqual(effects, ModeReducer.enterEffects(for: state, targetPID: 7))
      XCTAssertTrue(effects.contains(.clearTransientHintState))
    }
  }

  func testLeaveModeVerbRejectsArguments() {
    XCTAssertEqual(URLEventHandler.parse(verb: "leave_mode", args: [:]), .leaveMode)
    XCTAssertNil(URLEventHandler.parse(verb: "leave_mode", args: ["mode": "insert"]))
  }

  func testEnterNormalClosesEveryCommandSurface() {
    let commandStates: [Mode] = [
      .command(scope: .commandLine, restoreTo: .insert),
      .command(scope: .finder(all: true), restoreTo: .insert),
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
      .openCommand(scope: .commandLine, restoreMode: false),
      .openCommand(scope: .finder(all: true), restoreMode: true),
      .openTerminal,
    ]
    for open in surfaces {
      for request in [ModeEvent.enterNormal(targetPID: nil), .enterInsert(targetPID: nil)] {
        let opened = ModeReducer.reduce(.disabled, open).0
        let closed = ModeReducer.reduce(opened, request).0
        XCTAssertEqual(closed, .disabled, "\(open), \(request)")
        XCTAssertEqual(ModeReducer.reduce(closed, .leaveMode(hasHints: false, targetPID: nil)).0, .disabled)
      }
    }
  }

  func testEnablingAdvancedModeReconcilesEveryTransientReturn() {
    for open in [
      ModeEvent.openCommand(scope: .commandLine, restoreMode: false),
      .openCommand(scope: .finder(all: false), restoreMode: true),
      .openTerminal,
    ] {
      let opened = ModeReducer.reduce(.disabled, open).0
      let enabled = ModeReducer.reduce(opened, .advancedModeChanged(enabled: true)).0
      XCTAssertEqual(ModeReducer.reduce(enabled, .leaveMode(hasHints: false, targetPID: nil)).0, .insert)
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

    let insert = ModeReducer.enterEffects(for: .insert, targetPID: 42)
    XCTAssertEqual(
      insert,
      [
        .prepareModeEntry, .setMappingScope(.insert), .clearTransientHintState, .hideOverlayIfIdle,
        .renderSurface,
        .activateFocusedApp(pid: 42),
      ])
    XCTAssertFalse(insert.contains(.scheduleRecapture), "insert must not grab the keyboard")

    let command = ModeReducer.enterEffects(
      for: .command(scope: .commandLine, restoreTo: .normal), targetPID: nil)
    XCTAssertEqual(
      command, [.prepareModeEntry, .setMappingScope(.command), .renderSurface, .scheduleRecapture])
  }

  // MARK: Projection correctness — the anti-drift table

  func testProjectionTable() {
    XCTAssertEqual(Mode.disabled.flashMode, .insert)
    XCTAssertEqual(Mode.insert.flashMode, .insert)
    XCTAssertEqual(Mode.normal.flashMode, .normal)
    XCTAssertEqual(Mode.command(scope: .commandLine, restoreTo: .normal).flashMode, .normal)

    XCTAssertEqual(Mode.disabled.label, .insert)
    XCTAssertEqual(Mode.insert.label, .insert)
    XCTAssertEqual(Mode.normal.label, .normal)
    XCTAssertEqual(Mode.command(scope: .commandLine, restoreTo: .normal).label, .command)

    // overlay input mode (idle, no hints / activation)
    XCTAssertEqual(
      Mode.insert.overlayInputMode(hasHints: false, activationInFlight: false),
      .hints)
    XCTAssertEqual(
      Mode.normal.overlayInputMode(hasHints: false, activationInFlight: false), .normal)
    // normal with hints up routes hint letters, not commands
    XCTAssertEqual(Mode.normal.overlayInputMode(hasHints: true, activationInFlight: false), .hints)
    XCTAssertEqual(Mode.normal.overlayInputMode(hasHints: false, activationInFlight: true), .hints)
    XCTAssertEqual(
      Mode.command(scope: .commandLine, restoreTo: .normal)
        .overlayInputMode(hasHints: false, activationInFlight: false), .commandLine)
    XCTAssertEqual(
      Mode.command(scope: .finder(all: true), restoreTo: .normal)
        .overlayInputMode(hasHints: false, activationInFlight: false), .candidateFinder)

    XCTAssertFalse(
      Mode.insert.ownsKeyboard(hasHints: false, activationInFlight: false))
    XCTAssertTrue(Mode.normal.ownsKeyboard(hasHints: false, activationInFlight: false))
    XCTAssertFalse(Mode.normal.ownsKeyboard(hasHints: true, activationInFlight: false))
    XCTAssertTrue(
      Mode.command(scope: .commandLine, restoreTo: .normal)
        .ownsKeyboard(hasHints: false, activationInFlight: false))

    // Native-surface suspension (context menu up): never capture, in any base
    // mode; NORMAL stays `.normal`-routed so the cursor stays visible under the
    // menu (the `.hints` routing would hide it).
    XCTAssertFalse(
      Mode.normal.ownsKeyboard(
        hasHints: false, activationInFlight: false, nativeSurfaceSuspended: true))
    XCTAssertFalse(
      Mode.command(scope: .commandLine, restoreTo: .normal)
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
    XCTAssertEqual(Mode.command(scope: .commandLine, restoreTo: .normal).badgeStyle, .command)
    XCTAssertEqual(Mode.command(scope: .finder(all: true), restoreTo: .normal).badgeStyle, .command)
    XCTAssertEqual(Mode.normal.badgeStyle, .normal)
    XCTAssertEqual(Mode.insert.badgeStyle, .insert)
    XCTAssertEqual(Mode.disabled.badgeStyle, .insert)
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
