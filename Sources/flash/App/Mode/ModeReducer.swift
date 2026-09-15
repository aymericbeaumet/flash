import Foundation

// The pure, total transition function — the entire decision authority for the
// mode. Given the current `Mode` and a classified `ModeEvent`, it returns the
// next `Mode` plus the AppKit effects to apply. No AppKit, no clock, no I/O.
//
// Invariants guaranteed here (and pinned by `ModeReducerTests`):
//  - Passthrough stickiness: only explicit keyboard requests and disabling
//    advanced mode leave `.passthrough`.
//  - Mouse enters only: `.clickResolved` acts only from `.normal`; it can move
//    NORMAL→passthrough but can never move passthrough→anything.
//  - Global/sticky: `.focusedAppChanged` never flips passthrough↔normal.
//  - Advanced gate: `.enterNormal` is refused while `.disabled`.
enum ModeReducer {
  static func reduce(_ state: Mode, _ event: ModeEvent) -> (Mode, [ModeEffect]) {
    switch event {
    case .enterPassthrough(let targetPID):
      // Advanced mode off → no normal mode exists, so there is nothing to
      // enter passthrough *from*; stay put.
      guard state.advancedEnabled else { return closeDisabledSurface(state, targetPID: targetPID) }
      let next = Mode.passthrough
      return (next, terminalDeparture(state) + enterEffects(for: next, targetPID: targetPID))

    case .enterNormal(let persistent, let targetPID):
      // The advanced gate: cannot enter NORMAL when the feature is off.
      guard state.advancedEnabled else { return closeDisabledSurface(state, targetPID: targetPID) }
      let departure: [ModeEffect] =
        state.isTerminal
        ? [.hideTerminalPopup, .activateFocusedApp(pid: targetPID)] : []
      let next = Mode.normal(persistent: persistent)
      return (next, departure + enterEffects(for: next, targetPID: targetPID))

    case .normalActionStarted:
      guard case .normal(persistent: false, action: _) = state else { return (state, []) }
      return (.normal(persistent: false, action: .dispatching), [])

    case .normalActionDispatched(let hasTransientInput):
      guard case .normal(persistent: false, action: .dispatching) = state else {
        return (state, [])
      }
      if hasTransientInput {
        return (.normal(persistent: false, action: .waitingForInteraction), [])
      }
      return (.passthrough, enterEffects(for: .passthrough, targetPID: nil))

    case .normalInteractionChanged(let hasTransientInput):
      guard case .normal(persistent: false, action: .waitingForInteraction) = state,
        !hasTransientInput
      else { return (state, []) }
      return (.passthrough, enterEffects(for: .passthrough, targetPID: nil))

    case .leaveMode(let hasHints, let targetPID):
      switch state {
      case .terminal:
        return reduce(state, .closeTerminal(targetPID: targetPID))
      case .command:
        return reduce(state, .closeCommand(reason: "leave_mode"))
      case .passthrough where !hasHints:
        return reduce(state, .enterNormal(persistent: false, targetPID: targetPID))
      case .normal where !hasHints:
        return reduce(state, .enterPassthrough(targetPID: targetPID))
      case .normal(persistent: false, action: .waitingForInteraction):
        return reduce(state, .enterPassthrough(targetPID: targetPID))
      case .passthrough, .normal, .disabled:
        // Active hints are dismissed in place; disabled idle input stays native.
        guard hasHints else { return (state, []) }
        return (state, enterEffects(for: state, targetPID: targetPID))
      }

    case .openCommand(let scope):
      let next = Mode.command(scope: scope, restoreTo: state.asReturnMode)
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

    case .clickResolved(let entersPassthrough, let targetPID):
      // The mouse only acts in NORMAL and can never leave PASSTHROUGH.
      guard case .normal = state else { return (state, []) }
      if entersPassthrough {
        let next = Mode.passthrough
        return (next, enterEffects(for: next, targetPID: targetPID))
      }
      // A non-editable click does not force a handoff. One-shot completion
      // separately ends the entry once its entire interaction finishes.
      return (state, [.scheduleRecapture])

    case .advancedModeChanged(let enabled):
      if case .command(let scope, _) = state {
        let base: ReturnMode = enabled ? .passthrough : .disabled
        return (.command(scope: scope, restoreTo: base), [.renderSurface])
      }
      if case .terminal = state {
        let base: ReturnMode = enabled ? .passthrough : .disabled
        return (.terminal(restoreTo: base), [.renderSurface])
      }
      if enabled {
        // Hot-enabling advanced mode lands in PASSTHROUGH; the user opts into NORMAL
        // with their hotkey. If it was already on, just refresh the badge/label
        // (labels may have changed in the reload).
        if case .disabled = state {
          let next = Mode.passthrough
          return (next, enterEffects(for: next, targetPID: nil))
        }
        return (state, [.renderSurface])
      }
      return (.disabled, enterEffects(for: .disabled, targetPID: nil))

    case .startup(let advancedEnabled):
      let next: Mode = advancedEnabled ? .passthrough : .disabled
      return (next, [.prepareKeyboardCapture] + enterEffects(for: next, targetPID: nil))

    case .focusedAppChanged:
      // Sticky/global: never flips the mode. Only the command surfaces need to
      // reclaim key focus after an app switch.
      switch state {
      case .normal, .command:
        return (state, [.scheduleRecapture])
      case .passthrough, .disabled, .terminal:
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
        .prepareModeEntry, .setMappingScope(.normal), .clearTransientHintState, .renderSurface,
        .scheduleRecapture,
      ]
    case .passthrough, .disabled:
      // Hide transient content before restoring the quiet status bar.
      return [
        .prepareModeEntry, .setMappingScope(.passthrough), .clearTransientHintState,
        .hideOverlayIfIdle,
        .renderSurface,
        .activateFocusedApp(pid: targetPID),
      ]
    case .command:
      // Command surfaces keep all-mode and command-specific modified mappings.
      // Hint cleanup belongs to their content setup (`enterCommandLineMode`).
      return [.prepareModeEntry, .setMappingScope(.command), .renderSurface, .scheduleRecapture]
    case .terminal:
      return [
        .prepareModeEntry, .setMappingScope(.terminal), .clearTransientHintState,
        .hideOverlayIfIdle, .renderSurface,
      ]
    }
  }

  private static func terminalDeparture(_ state: Mode) -> [ModeEffect] {
    state.isTerminal ? [.hideTerminalPopup] : []
  }

  private static func closeDisabledSurface(_ state: Mode, targetPID: pid_t?) -> (Mode, [ModeEffect])
  {
    switch state {
    case .terminal: return reduce(state, .closeTerminal(targetPID: targetPID))
    case .command: return reduce(state, .closeCommand(reason: "advanced_disabled"))
    case .disabled: return (state, [])
    case .normal, .passthrough: preconditionFailure("Enabled mode has disabled eligibility")
    }
  }
}
