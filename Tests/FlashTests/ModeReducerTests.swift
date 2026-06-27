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
    .insert(locked: false),
    .insert(locked: true),
    .normal,
    .command(scope: .commandLine, restoreTo: .normal),
    .command(scope: .finder(all: true), restoreTo: .insert(locked: false)),
    .command(scope: .finder(all: false), restoreTo: .disabled),
    .modal(restoreTo: .normal),
  ]

  // Representative events covering every case.
  private let allEvents: [ModeEvent] = [
    .enterInsert(reason: .normalModeInput, targetPID: 7),
    .enterInsert(reason: .lockedNormalModeInput, targetPID: 7),
    .enterNormal(targetPID: 7),
    .openCommand(scope: .commandLine, restoreMode: false),
    .openCommand(scope: .finder(all: true), restoreMode: true),
    .closeCommand(reason: "submit"),
    .presentModal,
    .dismissModal,
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

  // MARK: Insert stickiness — the central invariant

  func testMouseAndFocusNeverLeaveInsert() {
    for insert in [Mode.insert(locked: false), .insert(locked: true)] {
      for event in [
        ModeEvent.clickResolved(entersInsert: true, targetPID: 7),
        .clickResolved(entersInsert: false, targetPID: 7),
        .focusedAppChanged(pid: 7),
        .enterInsert(reason: .normalModeInput, targetPID: 7),
      ] {
        let next = ModeReducer.reduce(insert, event).0
        XCTAssertTrue(next.isInsert, "\(event) must keep INSERT, got \(next)")
      }
    }
  }

  func testOnlyKeyboardAndConfigLeaveInsert() {
    XCTAssertEqual(
      ModeReducer.reduce(.insert(locked: false), .enterNormal(targetPID: 7)).0, .normal)
    XCTAssertEqual(
      ModeReducer.reduce(.insert(locked: true), .enterNormal(targetPID: 7)).0, .normal)
    XCTAssertEqual(
      ModeReducer.reduce(.insert(locked: false), .advancedModeChanged(enabled: false)).0, .disabled)
  }

  func testFocusedAppChangedNeverChangesMode() {
    for state in allStates {
      let (next, effects) = ModeReducer.reduce(state, .focusedAppChanged(pid: 99))
      XCTAssertEqual(next, state, "focusedAppChanged must not change \(state)")
      switch state {
      case .normal, .command, .modal:
        XCTAssertEqual(effects, [.scheduleRecapture])
      case .insert, .disabled:
        XCTAssertTrue(effects.isEmpty)
      }
    }
  }

  // MARK: Mouse enters only from normal

  func testClickEntersInsertOnlyFromNormal() {
    XCTAssertEqual(
      ModeReducer.reduce(.normal, .clickResolved(entersInsert: true, targetPID: 7)).0,
      .insert(locked: false))
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
      ModeReducer.reduce(.disabled, .enterInsert(reason: .normalModeInput, targetPID: 7)).0,
      .disabled)
    XCTAssertEqual(
      ModeReducer.reduce(.disabled, .advancedModeChanged(enabled: true)).0, .insert(locked: false))
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
      .insert(locked: false), .openCommand(scope: .finder(all: true), restoreMode: true))
    XCTAssertEqual(mode, .command(scope: .finder(all: true), restoreTo: .insert(locked: false)))
    XCTAssertEqual(ModeReducer.reduce(mode, .closeCommand(reason: "x")).0, .insert(locked: false))

    // Flashlight from disabled (advanced off) returns to disabled, never a
    // phantom NORMAL.
    (mode, _) = ModeReducer.reduce(
      .disabled, .openCommand(scope: .finder(all: false), restoreMode: false))
    XCTAssertEqual(mode, .command(scope: .finder(all: false), restoreTo: .disabled))
    XCTAssertEqual(ModeReducer.reduce(mode, .closeCommand(reason: "x")).0, .disabled)
  }

  func testModalLifecycleRestores() {
    let (mode, _) = ModeReducer.reduce(.normal, .presentModal)
    XCTAssertEqual(mode, .modal(restoreTo: .normal))
    XCTAssertEqual(ModeReducer.reduce(mode, .dismissModal).0, .normal)
  }

  func testCloseCommandFromNonCommandIsNoop() {
    XCTAssertEqual(ModeReducer.reduce(.normal, .closeCommand(reason: "x")).0, .normal)
    XCTAssertEqual(
      ModeReducer.reduce(.insert(locked: false), .dismissModal).0, .insert(locked: false))
  }

  // MARK: Determinism + totality

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
      [.setMappingScope(.normal), .clearTransientHintState, .renderSurface, .scheduleRecapture])

    let insert = ModeReducer.enterEffects(for: .insert(locked: false), targetPID: 42)
    XCTAssertEqual(
      insert,
      [
        .setMappingScope(.insert), .clearTransientHintState, .hideOverlayIfIdle, .renderSurface,
        .activateFocusedApp(pid: 42),
      ])
    XCTAssertFalse(insert.contains(.scheduleRecapture), "insert must not grab the keyboard")

    let command = ModeReducer.enterEffects(
      for: .command(scope: .commandLine, restoreTo: .normal), targetPID: nil)
    XCTAssertEqual(command, [.setMappingScope(.normal), .renderSurface, .scheduleRecapture])
  }

  // MARK: Projection correctness — the anti-drift table

  func testProjectionTable() {
    XCTAssertEqual(Mode.disabled.flashMode, .insert)
    XCTAssertEqual(Mode.insert(locked: false).flashMode, .insert)
    XCTAssertEqual(Mode.normal.flashMode, .normal)
    XCTAssertEqual(Mode.command(scope: .commandLine, restoreTo: .normal).flashMode, .normal)
    XCTAssertEqual(Mode.modal(restoreTo: .normal).flashMode, .normal)

    XCTAssertEqual(Mode.disabled.label, .insert)
    XCTAssertEqual(Mode.insert(locked: true).label, .insert)
    XCTAssertEqual(Mode.normal.label, .normal)
    XCTAssertEqual(Mode.command(scope: .commandLine, restoreTo: .normal).label, .command)
    XCTAssertEqual(Mode.modal(restoreTo: .normal).label, .command)

    // overlay input mode (idle, no hints / activation)
    XCTAssertEqual(
      Mode.insert(locked: false).overlayInputMode(hasHints: false, activationInFlight: false),
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
    XCTAssertEqual(
      Mode.modal(restoreTo: .normal).overlayInputMode(hasHints: false, activationInFlight: false),
      .modal)

    XCTAssertFalse(
      Mode.insert(locked: false).ownsKeyboard(hasHints: false, activationInFlight: false))
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
    XCTAssertEqual(Mode.modal(restoreTo: .normal).badgeStyle, .command)
    XCTAssertEqual(Mode.normal.badgeStyle, .normal)
    XCTAssertEqual(Mode.insert(locked: false).badgeStyle, .insert)
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
