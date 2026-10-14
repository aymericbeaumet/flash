import Foundation

// The pure, total transition function — the entire decision authority for the
// mode. Given the current `Mode` and a classified `ModeEvent`, it returns the
// next `Mode` plus the AppKit effects to apply. No AppKit, no clock, no I/O.
//
// Invariants guaranteed here (and pinned by `ModeReducerTests`):
//  - Insert stickiness: only explicit keyboard requests and disabling
//    advanced mode leave `.insert`.
//  - Mouse enters only: `.clickResolved` acts only from `.normal` or
//    a held-button mode (`.visual`, `.drag`); it can move NORMAL→insert but can
//    never move insert→anything.
//  - Global/sticky: `.focusedAppChanged` never flips insert↔normal.
//  - Advanced gate: `.enterNormal` is refused while `.disabled`.
enum ModeReducer {
  static func reduce(_ state: Mode, _ event: ModeEvent) -> (Mode, [ModeEffect]) {
    switch event {
    case .enterInsert(let targetPID):
      // Advanced mode off → no normal mode exists, so there is nothing to
      // enter insert *from*; stay put.
      guard state.advancedEnabled else { return closeDisabledSurface(state, targetPID: targetPID) }
      let next = Mode.insert
      return (next, terminalDeparture(state) + enterEffects(for: next, targetPID: targetPID))

    case .enterNormal:
      // The advanced gate: cannot enter NORMAL when the feature is off.
      guard state.advancedEnabled else { return closeDisabledSurface(state, targetPID: nil) }
      let departure: [ModeEffect] =
        state.isTerminal
        ? [.hideTerminalPopup, .activateFocusedApp(pid: state.terminalReturnPID)] : []
      return (.normal, departure + enterEffects(for: .normal, targetPID: nil))

    case .leaveMode(let hasHints):
      switch state {
      case .terminal:
        return reduce(state, .closeTerminal(restoresApp: true))
      case .command:
        return reduce(state, .closeCommand(reason: "leave_mode"))
      case .insert where !hasHints:
        return reduce(state, .enterNormal)
      case .hyper:
        return reduce(state, .exitHyper)
      case .visual, .drag:
        return reduce(state, .buttonReleased)
      case .insert, .normal, .disabled:
        // Active hints are dismissed in place; without hints there is no
        // enclosing mode to leave, so nothing re-renders.
        guard hasHints else { return (state, []) }
        return (state, enterEffects(for: state, targetPID: nil))
      }

    case .openCommand(let restoreMode):
      let restoreTo = restoreMode ? state.asReturnMode : defaultSurfaceReturn(from: state)
      let next = Mode.command(restoreTo: restoreTo)
      return (next, terminalDeparture(state) + enterEffects(for: next, targetPID: nil))

    case .openTerminal(let returnPID):
      // A popup focused from TERMINAL replaces the shown one and keeps the
      // app captured first: the mode value already holds it.
      guard !state.isTerminal else { return (state, []) }
      let next = Mode.terminal(restoreTo: state.asReturnMode, returnPID: returnPID)
      return (next, enterEffects(for: next, targetPID: nil))

    case .closeTerminal(let restoresApp):
      guard case .terminal(let restoreTo, let returnPID) = state else { return (state, []) }
      let effects = enterEffects(for: restoreTo.mode, targetPID: nil).filter {
        if case .activateFocusedApp = $0 { return false }
        return true
      }
      let activation: [ModeEffect] =
        restoresApp ? returnPID.map { [.activateFocusedApp(pid: $0)] } ?? [] : []
      return (restoreTo.mode, [.hideTerminalPopup] + activation + effects)

    case .closeCommand:
      guard case .command(let restoreTo) = state else { return (state, []) }
      let next = restoreTo.mode
      return (next, enterEffects(for: next, targetPID: nil))

    case .clickResolved(let entersInsert, let targetPID):
      // The mouse only acts in NORMAL (a held button included) and can never
      // leave INSERT.
      guard state == .normal || state.buttonHold != nil else { return (state, []) }
      if entersInsert {
        let next = Mode.insert
        return (next, enterEffects(for: next, targetPID: targetPID))
      }
      // A non-editable click in NORMAL keeps NORMAL; just make sure the overlay
      // keeps key focus if the click stole it.
      return (state, [.scheduleRecapture])

    case .advancedModeChanged(let enabled):
      if case .command(let restoreTo) = state {
        let base: ReturnMode = enabled ? (restoreTo == .disabled ? .normal : restoreTo) : .disabled
        return (.command(restoreTo: base), [.renderSurface])
      }
      if case .terminal(let restoreTo, let returnPID) = state {
        let base: ReturnMode =
          enabled
          ? (restoreTo == .disabled ? .normal : restoreTo) : .disabled
        return (.terminal(restoreTo: base, returnPID: returnPID), [.renderSurface])
      }
      if enabled {
        // Enabling advanced mode starts persistent NORMAL, as startup does.
        // An existing mode survives label/config refreshes.
        if case .disabled = state {
          let next = Mode.normal
          return (next, enterEffects(for: next, targetPID: nil))
        }
        return (state, [.renderSurface])
      }
      return (.disabled, enterEffects(for: .disabled, targetPID: nil))

    case .startup(let advancedEnabled):
      let next: Mode = advancedEnabled ? .normal : .disabled
      return (next, [.prepareKeyboardCapture] + enterEffects(for: next, targetPID: nil))

    case .focusedAppChanged:
      // Sticky/global: never flips the mode. Only the command surfaces need to
      // reclaim key focus after an app switch.
      switch state {
      case .normal, .command, .hyper, .visual, .drag:
        return (state, [.scheduleRecapture])
      case .insert, .disabled, .terminal:
        return (state, [])
      }

    case .enterHyper:
      // HYPER is entered from idle NORMAL. INSERT keeps typing the key,
      // and command / terminal surfaces keep their own input.
      guard case .normal = state else { return (state, []) }
      let next = Mode.hyper(restoreTo: .normal)
      return (next, enterEffects(for: next, targetPID: nil))

    case .exitHyper:
      guard case .hyper(let restoreTo) = state else { return (state, []) }
      // Paint the restored label only. The full enter-effects of NORMAL
      // would dismiss hints and recapture on every leader release.
      return (restoreTo.mode, [.renderSurface])

    case .buttonHeld(let hold):
      // VISUAL and DRAG are NORMAL with a button held: the pill and the
      // mapping table change (their own table over NORMAL), nothing else — a
      // pointer or grid session that pressed the button keeps its keys.
      guard case .normal = state else { return (state, []) }
      return (hold.mode, [.setMappingScope(hold.mappingScope), .renderSurface])

    case .buttonReleased:
      guard state.buttonHold != nil else { return (state, []) }
      return (.normal, [.setMappingScope(.normal), .renderSurface])
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
    case .insert:
      // Hide transient hint content BEFORE rendering so the surface (badge +
      // active-window border) is drawn last and survives the hide.
      return [
        .prepareModeEntry, .setMappingScope(.insert), .clearTransientHintState, .hideOverlayIfIdle,
        .renderSurface,
        .activateFocusedApp(pid: targetPID),
      ]
    case .disabled:
      return [
        .prepareModeEntry, .setMappingScope(.insert), .clearTransientHintState, .hideOverlayIfIdle,
        .renderSurface,
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
    case .hyper, .visual, .drag:
      // Keep the NORMAL mapping scope and the hint session. The pill is the
      // only thing that changes; Carbon registrations stay put so a hold does
      // not churn hotkey registrations.
      return [.renderSurface]
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

  private static func closeDisabledSurface(_ state: Mode, targetPID: pid_t?) -> (Mode, [ModeEffect])
  {
    switch state {
    case .terminal: return reduce(state, .closeTerminal(restoresApp: true))
    case .command: return reduce(state, .closeCommand(reason: "advanced_disabled"))
    case .hyper: return (.disabled, enterEffects(for: .disabled, targetPID: targetPID))
    case .disabled: return (state, [])
    case .normal, .insert, .visual, .drag:
      preconditionFailure("Enabled mode has disabled eligibility")
    }
  }
}
