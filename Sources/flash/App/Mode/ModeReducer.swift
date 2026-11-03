import Foundation

// The pure, total transition function — the entire decision authority for the
// mode. Given the current `Mode` and a classified `ModeEvent`, it returns the
// next `Mode` plus the AppKit effects to apply. No AppKit, no clock, no I/O.
//
// Invariants guaranteed here (and pinned by `ModeReducerTests`):
//  - Insert stickiness: only explicit keyboard requests and disabling
//    advanced mode leave `.insert`.
//  - Explicit entry: only `.enterInsert` (`mode insert`) moves a mode into
//    `.insert`; every other transition that lands there restores a surface
//    or layer that was opened from INSERT. No click enters or leaves it.
//  - Global/sticky: `.focusedAppChanged` never flips insert↔normal.
//  - Advanced gate: `.enterNormal` is refused while `.disabled`.
//  - Layers return: Escape, `mode leave` and a one-shot mapping leave a
//    layer for exactly the base mode it was entered from.
enum ModeReducer {

  static func reduce(_ state: Mode, _ event: ModeEvent) -> (Mode, [ModeEffect]) {
    switch event {
    case .enterInsert:
      // Advanced mode off → no normal mode exists, so there is nothing to
      // enter insert *from*; stay put.
      guard state.advancedEnabled else { return closeDisabledSurface(state) }
      let next = Mode.insert
      return (next, terminalDeparture(state) + enterEffects(for: next))

    case .enterNormal:
      // The advanced gate: cannot enter NORMAL when the feature is off.
      guard state.advancedEnabled else { return closeDisabledSurface(state) }
      let departure =
        terminalDeparture(state)
        + (state.isTerminal
          ? state.terminalReturnPID.map { [ModeEffect.restoreCoveredApp(pid: $0)] } ?? [] : [])
      return (.normal, departure + enterEffects(for: .normal))

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
      case .hold:
        return reduce(state, .buttonReleased)
      case .visual:
        return reduce(state, .leaveVisual)
      case .layer(let layer):
        // Active hints are dismissed in place, as in the base modes; the
        // layer keeps the keyboard.
        guard !hasHints else { return (state, enterEffects(for: state)) }
        return leave(layer)
      case .insert, .normal, .disabled:
        // Active hints are dismissed in place; without hints there is no
        // enclosing mode to leave, so nothing re-renders.
        guard hasHints else { return (state, []) }
        return (state, enterEffects(for: state))
      }

    case .openCommand(let restoreMode):
      let restoreTo = restoreMode ? state.asReturnMode : defaultSurfaceReturn(from: state)
      let next = Mode.command(restoreTo: restoreTo)
      return (next, terminalDeparture(state) + enterEffects(for: next))

    case .openTerminal(let returnPID):
      // A popup focused from TERMINAL replaces the shown one and keeps the
      // app captured first: the mode value already holds it.
      guard !state.isTerminal else { return (state, []) }
      let next = Mode.terminal(restoreTo: state.asReturnMode, returnPID: returnPID)
      return (next, enterEffects(for: next))

    case .closeTerminal(let restoresApp):
      guard case .terminal(let restoreTo, let returnPID) = state else { return (state, []) }
      let effects = enterEffects(for: restoreTo.mode)
      let activation: [ModeEffect] =
        restoresApp ? returnPID.map { [.restoreCoveredApp(pid: $0)] } ?? [] : []
      return (restoreTo.mode, [.hideTerminalPopup] + activation + effects)

    case .closeCommand:
      guard case .command(let restoreTo) = state else { return (state, []) }
      let next = restoreTo.mode
      return (next, enterEffects(for: next))

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
          return (next, enterEffects(for: next))
        }
        return (state, [.renderSurface])
      }
      return (.disabled, enterEffects(for: .disabled))

    case .startup(let advancedEnabled):
      let next: Mode = advancedEnabled ? .normal : .disabled
      return (next, [.prepareKeyboardCapture] + enterEffects(for: next))

    case .focusedAppChanged:
      // Sticky/global: never flips the mode. Only the command surfaces need to
      // reclaim key focus after an app switch.
      switch state {
      case .normal, .command, .hyper, .hold, .layer:
        return (state, [.scheduleRecapture])
      case .visual:
        // The selection belonged to the app that had the focus.
        return (.normal, [.renderSurface, .scheduleRecapture])
      case .insert, .disabled, .terminal:
        return (state, [])
      }

    case .enterHyper:
      // HYPER is entered from idle NORMAL. INSERT keeps typing the key,
      // and command / terminal surfaces keep their own input.
      guard case .normal = state else { return (state, []) }
      let next = Mode.hyper(restoreTo: .normal)
      return (next, enterEffects(for: next))

    case .exitHyper:
      guard case .hyper(let restoreTo) = state else { return (state, []) }
      // Paint the restored label only. The full enter-effects of NORMAL
      // would dismiss hints and recapture on every leader release.
      return (restoreTo.mode, [.renderSurface])

    case .buttonHeld(let hold):
      // HOLD is NORMAL with a button held: the pill and the
      // mapping table (`Mode.mappingScope`) change, nothing else — a pointer
      // or grid session that pressed the button keeps its keys. From INSERT
      // (an all-mode `mode hold` chord) the hold takes the keyboard as
      // NORMAL entry does; the release still returns to NORMAL. A layer
      // captures as NORMAL does, so a hold from it (an all-mode chord)
      // changes the pill and leaves the layer.
      switch state {
      case .normal, .layer: return (hold.mode, [.renderSurface])
      case .insert: return (hold.mode, enterEffects(for: .normal))
      default: return (state, [])
      }

    case .buttonReleased:
      guard state.buttonHold != nil else { return (state, []) }
      return (.normal, [.renderSurface])

    case .enterLayer(let name, let sticky):
      // A layer captures like NORMAL, so it needs advanced mode as NORMAL
      // does.
      guard state.advancedEnabled else { return closeDisabledSurface(state) }
      if state.layer?.name == name { return (state, []) }
      let next = Mode.layer(
        LayerMode(name: name, sticky: sticky, restoreTo: state.asReturnMode))
      // Leaving a popup this way activates the app it covered, as
      // `mode normal` does: the layer reads keys over that app.
      let departure =
        terminalDeparture(state)
        + (state.terminalReturnPID.map { [ModeEffect.restoreCoveredApp(pid: $0)] } ?? [])
      return (next, departure + enterEffects(for: next))

    case .layerMappingFired:
      guard let layer = state.layer, !layer.sticky else { return (state, []) }
      return leave(layer)

    case .layersChanged(let declared):
      guard let layer = state.layer else { return (state, []) }
      guard let sticky = declared[layer.name] else { return leave(layer) }
      guard sticky != layer.sticky else { return (state, []) }
      var next = layer
      next.sticky = sticky
      return (.layer(next), [])

    case .enterVisual(let kind):
      // VISUAL is NORMAL with a selection: it starts from NORMAL (the text
      // table's `v` and `V`) and switches kind within itself; only the pill
      // and the table change.
      switch state {
      case .normal, .visual: return (.visual(kind), [.renderSurface])
      default: return (state, [])
      }

    case .leaveVisual:
      guard state.isVisual else { return (state, []) }
      return (.normal, [.renderSurface])
    }
  }

  /// Leave a layer for the base mode it was entered from. Both capture
  /// NORMAL's way, so back in NORMAL only the pill changes, as when HYPER
  /// ends; INSERT hands the keyboard back. Neither drops a hint session: a
  /// one-shot layer leaves just before its command runs, and that command
  /// may be the one that starts it.
  private static func leave(_ layer: LayerMode) -> (Mode, [ModeEffect]) {
    switch layer.restoreTo {
    case .normal:
      return (.normal, [.renderSurface])
    case .insert:
      return (.insert, [.prepareModeEntry, .hideOverlayIfIdle, .renderSurface])
    case .disabled:
      return (.disabled, enterEffects(for: .disabled))
    }
  }

  /// The effects to apply when landing in a given mode. Uniform across every
  /// path that reaches that mode — how you got there does not change the sync
  /// work, which is what makes behavior predictable.
  static func enterEffects(for mode: Mode) -> [ModeEffect] {
    switch mode {
    case .normal:
      return [
        .prepareModeEntry, .clearTransientHintState, .renderSurface,
        .scheduleRecapture,
      ]
    case .insert:
      // Hide transient hint content BEFORE rendering so the surface (badge +
      // active-window border) is drawn last and survives the hide.
      return [
        .prepareModeEntry, .clearTransientHintState, .hideOverlayIfIdle,
        .renderSurface,
      ]
    case .disabled:
      return [
        .prepareModeEntry, .clearTransientHintState, .hideOverlayIfIdle,
        .renderSurface,
      ]
    case .command:
      // Command surfaces keep all-mode and command-specific modified mappings.
      // Hint cleanup belongs to their content setup (`enterCommandLineMode`).
      return [.prepareModeEntry, .renderSurface, .scheduleRecapture]
    case .layer:
      // A layer takes the keyboard as NORMAL does, from whichever mode it
      // was entered.
      return enterEffects(for: .normal)
    case .terminal:
      return [
        .prepareModeEntry, .clearTransientHintState,
        .hideOverlayIfIdle, .renderSurface,
      ]
    case .hyper, .hold, .visual:
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

  private static func closeDisabledSurface(_ state: Mode) -> (Mode, [ModeEffect]) {
    switch state {
    case .terminal: return reduce(state, .closeTerminal(restoresApp: true))
    case .command: return reduce(state, .closeCommand(reason: "advanced_disabled"))
    case .hyper, .layer, .visual: return (.disabled, enterEffects(for: .disabled))
    case .disabled: return (state, [])
    case .normal, .insert, .hold:
      preconditionFailure("Enabled mode has disabled eligibility")
    }
  }
}
