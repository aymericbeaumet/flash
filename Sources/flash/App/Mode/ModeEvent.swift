import Foundation

// Every input that is ALLOWED to change the mode, each classified by origin.
// This is the exhaustive, documented list the audit asked for: if it is not a
// case here, it cannot move the mode. Notably absent — and deliberately so —
// are the old automatic triggers (app/element focus-change exit, browser URL
// polling, timed focus-exit probes, pointer-handoff deferrals). The mouse
// can enter passthrough (`clickResolved`) but cannot leave it
// except explicit keyboard requests (`enterNormal` / `leaveMode`).
enum ModeEvent: Equatable {
  // MARK: User-explicit

  /// The user asked to type. `targetPID` is the app to hand the keyboard to.
  case enterPassthrough(targetPID: pid_t?)

  /// The user's explicit normal-mode hotkey / mapped `.normalMode`.
  case enterNormal(targetPID: pid_t?)

  /// Close the current transient surface, or toggle PASSTHROUGH and NORMAL.
  /// Active hints are dismissed without changing their underlying base mode.
  case leaveMode(hasHints: Bool, targetPID: pid_t?)

  /// Open a command surface, preserving whether advanced mode is enabled.
  case openCommand(scope: CommandScope)

  /// Command-line submit or cancel — both close the surface to its `restoreTo`.
  case closeCommand(reason: String)

  /// A popup body was clicked and its local view became the input owner.
  case openTerminal

  /// Return input to the app; an explicit dismissal can reactivate its prior app.
  case closeTerminal(targetPID: pid_t?)

  /// A primary click resolved by its source: physical and mouse-grid clicks
  /// enter PASSTHROUGH, while semantic hints honor `JumpTarget.entersPassthroughMode`.
  /// From PASSTHROUGH this never leaves passthrough.
  case clickResolved(entersPassthrough: Bool, targetPID: pid_t?)

  // MARK: System

  /// Config reload changed whether a normal-mode hotkey is bound.
  case advancedModeChanged(enabled: Bool)

  /// First config load — pick the initial mode.
  case startup(advancedEnabled: Bool)

  /// Workspace/app/space activation. Updates recapture only; NEVER flips
  /// passthrough↔normal (mode is global and sticky).
  case focusedAppChanged(pid: pid_t)
}
