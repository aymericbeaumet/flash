import Foundation

// The pure, total transition function — the entire decision authority for the
// mode. Given the current `Mode` and a classified `ModeEvent`, it returns the
// next `Mode` plus the AppKit effects to apply. No AppKit, no clock, no I/O.
//
// Invariants guaranteed here (and pinned by `ModeReducerTests`):
//  - Insert stickiness: only explicit keyboard requests and disabling
//    advanced mode leave `.insert`.
//  - Mouse enters only: `.clickResolved` acts only from `.normal`; it can move
//    NORMAL→insert but can never move insert→anything.
//  - Global/sticky: `.focusedAppChanged` never flips insert↔normal.
//  - Advanced gate: `.enterNormal` is refused while `.disabled`.
enum ModeReducer {
  static func reduce(_ state: Mode, _ event: ModeEvent) -> (Mode, [ModeEffect]) {
    switch event {
    case .enterInsert(let reason, let targetPID):
      // Advanced mode off → no normal mode exists, so there is nothing to
      // enter insert *from*; stay put.
      if case .disabled = state { return (state, []) }
      let next = Mode.insert(locked: reason.locksInsertMode)
      return (next, terminalDeparture(state) + enterEffects(for: next, targetPID: targetPID))

    case .enterNormal(let targetPID):
      // The advanced gate: cannot enter NORMAL when the feature is off.
      if state == .disabled || (state.isTerminal && state.asReturnMode == .disabled) {
        if state.isTerminal { return reduce(state, .closeTerminal(targetPID: targetPID)) }
        return (state, [])
      }
      let departure: [ModeEffect] =
        state.isTerminal
        ? [.hideTerminalPopup, .activateFocusedApp(pid: targetPID)] : []
      return (.normal, departure + enterEffects(for: .normal, targetPID: targetPID))

    case .leaveMode(let hasHints, let targetPID):
      switch state {
      case .terminal:
        return reduce(state, .closeTerminal(targetPID: targetPID))
      case .command:
        return reduce(state, .closeCommand(reason: "leave_mode"))
      case .insert where !hasHints:
        return reduce(state, .enterNormal(targetPID: targetPID))
      case .insert, .normal, .disabled:
        return (state, enterEffects(for: state, targetPID: targetPID))
      }

    case .openCommand(let scope, let restoreMode):
      let restoreTo = restoreMode ? state.asReturnMode : defaultSurfaceReturn(from: state)
      let next = Mode.command(scope: scope, restoreTo: restoreTo)
      return (next, terminalDeparture(state) + enterEffects(for: next, targetPID: nil))

    case .openTerminal:
      guard !state.isTerminal else { return (state, []) }
      let next = Mode.terminal(restoreTo: state.asReturnMode)
      return (next, enterEffects(for: next, targetPID: nil))

    case .closeTerminal(let targetPID):
      guard case .terminal(let restoreTo) = state else { return (state, []) }
      let effects = enterEffects(for: restoreTo.mode, targetPID: nil).filter {
        if case .activateFocusedApp = $0 { return false }
        return true
      }
      let activation: [ModeEffect] = targetPID.map { [.activateFocusedApp(pid: $0)] } ?? []
      return (restoreTo.mode, [.hideTerminalPopup] + activation + effects)

    case .closeCommand:
      guard case .command(_, let restoreTo) = state else { return (state, []) }
      let next = restoreTo.mode
      return (next, enterEffects(for: next, targetPID: nil))

    case .clickResolved(let entersInsert, let targetPID):
      // The mouse only acts in NORMAL and can never leave INSERT.
      guard case .normal = state else { return (state, []) }
      if entersInsert {
        let next = Mode.insert(locked: false)
        return (next, enterEffects(for: next, targetPID: targetPID))
      }
      // A non-editable click in NORMAL keeps NORMAL; just make sure the overlay
      // keeps key focus if the click stole it.
      return (state, [.scheduleRecapture])

    case .advancedModeChanged(let enabled):
      if case .terminal(let restoreTo) = state {
        let base: ReturnMode =
          enabled
          ? (restoreTo == .disabled ? .insert(locked: false) : restoreTo) : .disabled
        return (.terminal(restoreTo: base), [.renderSurface])
      }
      if enabled {
        // Hot-enabling advanced mode lands in INSERT; the user opts into NORMAL
        // with their hotkey. If it was already on, just refresh the badge/label
        // (labels may have changed in the reload).
        if case .disabled = state {
          let next = Mode.insert(locked: false)
          return (next, enterEffects(for: next, targetPID: nil))
        }
        return (state, [.renderSurface])
      }
      return (.disabled, enterEffects(for: .disabled, targetPID: nil))

    case .startup(let advancedEnabled):
      let next: Mode = advancedEnabled ? .normal : .disabled
      return (next, enterEffects(for: next, targetPID: nil))

    case .focusedAppChanged:
      // Sticky/global: never flips the mode. Only the command surfaces need to
      // reclaim key focus after an app switch.
      switch state {
      case .normal, .command:
        return (state, [.scheduleRecapture])
      case .insert, .disabled, .terminal:
        return (state, [])
      }
    }
  }

  /// The effects to apply when landing in a given mode. Uniform across every
  /// path that reaches that mode — how you got there does not change the sync
  /// work, which is what makes behavior predictable.
  static func enterEffects(for mode: Mode, targetPID: pid_t?) -> [ModeEffect] {
    switch mode {
    case .normal:
      return [
        .setMappingScope(.normal), .clearTransientHintState, .renderSurface, .scheduleRecapture,
      ]
    case .insert:
      // Hide transient hint content BEFORE rendering so the surface (badge +
      // active-window border) is drawn last and survives the hide.
      return [
        .setMappingScope(.insert), .clearTransientHintState, .hideOverlayIfIdle, .renderSurface,
        .activateFocusedApp(pid: targetPID),
      ]
    case .disabled:
      return [
        .setMappingScope(.insert), .clearTransientHintState, .hideOverlayIfIdle, .renderSurface,
      ]
    case .command:
      // Command surfaces own every key. Hint cleanup is owned by the
      // surface's content setup (`enterCommandLineMode`).
      return [.setMappingScope(.command), .renderSurface, .scheduleRecapture]
    case .terminal:
      return [
        .setMappingScope(.terminal), .clearTransientHintState, .hideOverlayIfIdle, .renderSurface,
      ]
    }
  }

  /// Default close target for a surface opened without `restoreMode`: NORMAL,
  /// or disabled when advanced mode is off (so flashlight works without a
  /// normal-mode binding and never strands the user in a phantom NORMAL).
  private static func defaultSurfaceReturn(from state: Mode) -> ReturnMode {
    if state.asReturnMode == .disabled { return .disabled }
    return .normal
  }

  private static func terminalDeparture(_ state: Mode) -> [ModeEffect] {
    state.isTerminal ? [.hideTerminalPopup] : []
  }
}
