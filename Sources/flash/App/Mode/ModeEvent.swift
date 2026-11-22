import Foundation

// Every input that is ALLOWED to change the mode, each classified by origin.
// This is the exhaustive, documented list the audit asked for: if it is not a
// case here, it cannot move the mode. Notably absent — and deliberately so —
// are the old automatic triggers (app/element focus-change exit, browser URL
// polling, timed focus-exit probes, pointer-handoff deferrals). INSERT is
// entered only through `enterInsert`, `mode insert`'s one way in; the only
// other transitions that land there restore a surface or layer opened from
// INSERT (`closeCommand`, `closeTerminal`, a layer's leave). No click, of any
// kind, moves the mode in or out of INSERT; only explicit keyboard requests
// (`enterNormal` / `leaveMode`) and disabling advanced mode leave it.
enum ModeEvent: Equatable {
  // MARK: User-explicit

  /// `mode insert`: release capture so typing stays in the currently
  /// focused app.
  case enterInsert(InsertEntry)

  /// The user's explicit normal-mode hotkey / mapped `.normalMode`. Leaving
  /// a popup this way activates the app it covered, read from the mode.
  case enterNormal

  /// Close the current transient surface, or leave INSERT for NORMAL.
  /// Active hints are dismissed without changing their underlying base mode.
  case leaveMode(hasHints: Bool)

  /// `:` / flashlight / `enterCommand`. `restoreMode` mirrors the old
  /// `restore_mode=1` verbs: when true the surface returns to the entry mode,
  /// otherwise it returns to NORMAL (or to disabled when advanced mode is off).
  case openCommand(restoreMode: Bool)

  /// Command-line submit or cancel — both close the surface to its `restoreTo`.
  case closeCommand(reason: String)

  /// A popup's local view became the input owner: `mode terminal`, a
  /// click on a popup body, or a pinned status label. `returnPID` is the app
  /// the popup covers; it lives in the mode for as long as TERMINAL does.
  case openTerminal(returnPID: pid_t?)

  /// Restore the base mode; an explicit dismissal (`restoresApp`) reactivates
  /// the app the mode captured, a focus loss does not.
  case closeTerminal(restoresApp: Bool)

  // MARK: System

  /// Config reload changed whether a normal-mode hotkey is bound.
  case advancedModeChanged(enabled: Bool)

  /// First config load — pick the initial mode.
  case startup(advancedEnabled: Bool)

  /// Workspace/app/space activation. Updates recapture only; NEVER flips
  /// insert↔normal (mode is global and sticky).
  case focusedAppChanged(pid: pid_t)

  /// A mouse button is now held for `hold` (`mouse button --mode`,
  /// `mode hold`, pointer mode's `v`): HOLD. Accepted from
  /// `.normal` and `.insert`.
  case buttonHeld(ButtonHold)

  /// The held button was released. Ignored outside HOLD.
  case buttonReleased

  /// The hyper key went down. Only accepted from `.normal`.
  case enterHyper

  /// The hyper key was released. Returns to the mode hyper was entered from.
  /// Ignored unless the current mode is `.hyper`.
  case exitHyper

  /// `mode layer --name=<name>`: read keys from that layer's table until
  /// Escape or `mode leave` returns to the base mode it was entered from.
  /// `sticky` is the layer's setting. Refused while advanced mode is off;
  /// entering the layer already active changes nothing.
  case enterLayer(name: String, sticky: Bool)

  /// A mapping is about to run in a layer. A one-shot layer
  /// (`sticky = false`) leaves first, so the command runs in the base mode
  /// as if typed there; a sticky layer stays. The caller does not send it
  /// for a mode command, which decides the mode itself.
  case layerMappingFired

  /// A config load declared these layers (name → `sticky`). The active
  /// layer takes its new setting, or is left when its table is gone.
  case layersChanged([String: Bool])

  /// `mode visual [--line]` began a selection in the focused text: VISUAL
  /// from NORMAL, or the other kind from VISUAL.
  case enterVisual(VisualKind)

  /// VISUAL ended: an operator ran, Escape, `v`/`V` again, or the focus
  /// moved. Back to NORMAL; ignored outside VISUAL.
  case leaveVisual
}

/// The one way into INSERT (AGENTS.md hard constraint 9): an explicit
/// command. Every other command — Find, a new tab, tab switching,
/// `input focus`, the letter jump `s` — every click, made with the mouse,
/// `f` or `F`, whatever it lands on, and every focus change or app
/// activation keeps the mode. Closing a command line, popup or layer opened
/// from INSERT returns there; that restores the mode it covered rather than
/// entering it.
enum InsertEntry: String, CaseIterable, Equatable {
  /// Bare `mode insert` (vim's `i`), or any mapping configured to run it. It
  /// takes no placement or change: Flash never edits text (hard
  /// constraint 11).
  case explicitCommand = "explicit_command"
}
