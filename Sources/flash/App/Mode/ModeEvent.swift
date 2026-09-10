import Foundation

// Every input that is ALLOWED to change the mode, each classified by origin.
// This is the exhaustive, documented list the audit asked for: if it is not a
// case here, it cannot move the mode. Notably absent — and deliberately so —
// are the old automatic triggers (app/element focus-change exit, browser URL
// polling, timed focus-exit probes, pointer-handoff deferrals). The mouse
// never changes the base mode; INSERT entry requires an explicit command or a
// configured passthrough keypress.
enum ModeEvent: Equatable {
  // MARK: User-explicit

  /// An explicit insert command or configured passthrough keypress. `reason.locksInsertMode`
  /// decides the `locked` bit. `targetPID` is the app to hand the keyboard to.
  case enterInsert(reason: InsertModeTransitionReason, targetPID: pid_t?)

  /// The user's explicit normal-mode hotkey / mapped `.normalMode`.
  case enterNormal(targetPID: pid_t?)

  /// Close the current transient surface, or leave INSERT for NORMAL.
  /// Active hints are dismissed without changing their underlying base mode.
  case leaveMode(hasHints: Bool, targetPID: pid_t?)

  /// `:` / flashlight / `enterCommand`. `restoreMode` mirrors the old
  /// `restore_mode=1` verbs: when true the surface returns to the entry mode,
  /// otherwise it returns to NORMAL (or to disabled when advanced mode is off).
  case openCommand(scope: CommandScope, restoreMode: Bool)

  /// Command-line submit or cancel — both close the surface to its `restoreTo`.
  case closeCommand(reason: String)

  /// A popup body was clicked and its local view became the input owner.
  case openTerminal

  /// Restore the base mode; an explicit dismissal can reactivate its prior app.
  case closeTerminal(targetPID: pid_t?)

  /// A pointer action completed without changing the base mode.
  case pointerCommitted

  // MARK: System

  /// Config reload changed whether a normal-mode hotkey is bound.
  case advancedModeChanged(enabled: Bool)

  /// First config load — pick the initial mode.
  case startup(advancedEnabled: Bool)

  /// Workspace/app/space activation. Updates recapture only; NEVER flips
  /// insert↔normal (mode is global and sticky).
  case focusedAppChanged(pid: pid_t)
}
