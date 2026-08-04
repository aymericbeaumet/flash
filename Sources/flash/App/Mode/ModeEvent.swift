import Foundation

// Every input that is ALLOWED to change the mode, each classified by origin.
// This is the exhaustive, documented list the audit asked for: if it is not a
// case here, it cannot move the mode. Notably absent — and deliberately so —
// are the old automatic triggers (app/element focus-change exit, browser URL
// polling, timed focus-exit probes, pointer-handoff deferrals). The mouse
// can ENTER insert (`clickResolved`) but nothing here can make it LEAVE insert
// except `enterNormal` (a keyboard request).
enum ModeEvent: Equatable {
  // MARK: User-explicit

  /// `i` / `I` / `/` / `t` — the user asked to type. `reason.locksInsertMode`
  /// decides the `locked` bit. `targetPID` is the app to hand the keyboard to.
  case enterInsert(reason: InsertModeTransitionReason, targetPID: pid_t?)

  /// The user's normal-mode hotkey / mapped `.normalMode`. THE ONLY event that
  /// leaves insert.
  case enterNormal(targetPID: pid_t?)

  /// `:` / flashlight / `enterCommand`. `restoreMode` mirrors the old
  /// `restore_mode=1` verbs: when true the surface returns to the entry mode,
  /// otherwise it returns to NORMAL (or to disabled when advanced mode is off).
  case openCommand(scope: CommandScope, restoreMode: Bool)

  /// Command-line submit or cancel — both close the surface to its `restoreTo`.
  case closeCommand(reason: String)

  /// A click — real mouse OR an `f`/`F` hint — resolved by the shared editable
  /// detector. `entersInsert` is the detector's verdict. From NORMAL an
  /// editable target enters insert; from INSERT this never leaves insert.
  case clickResolved(entersInsert: Bool, targetPID: pid_t?)

  // MARK: System

  /// Config reload changed whether a normal-mode hotkey is bound.
  case advancedModeChanged(enabled: Bool)

  /// First config load — pick the initial mode.
  case startup(advancedEnabled: Bool)

  /// Workspace/app/space activation. Updates recapture only; NEVER flips
  /// insert↔normal (mode is global and sticky).
  case focusedAppChanged(pid: pid_t)
}
