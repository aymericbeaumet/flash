import Foundation

/// Who owns the keyboard while NORMAL capture is suspended for a native
/// surface — a context menu, the system's own popup — as one value rather
/// than a flag cleared by whichever recapture comes next.
///
/// Ownership ends on evidence: the menu's own close notification, the user's
/// explicit mode entry, or another app coming forward. A recapture a system
/// event asks for — an app launching in the background, a Space change, the
/// panel resigning key — never ends a surface Flash saw open. Apps that post
/// no menu notifications keep the bounded window that stood in for a close
/// signal before: without a sighting, a recapture after that window ends the
/// ownership as it always did, and a recapture inside it is skipped.
struct NativeSurfaceOwnership: Equatable {
  enum State: Equatable {
    case none
    /// `menuPID` is the app whose menu reported opening; nil until one did.
    case owned(menuPID: pid_t?)
  }

  private(set) var state: State = .none

  var isOwned: Bool { state != .none }

  /// Capture was suspended for a native surface.
  mutating func begin() { state = .owned(menuPID: nil) }

  /// App `pid` reported a menu opening while the surface is owned.
  mutating func menuOpened(pid: pid_t) {
    if case .owned = state { state = .owned(menuPID: pid) }
  }

  /// The app whose menu is open, once it reported opening: `f` walks that
  /// menu instead of the window behind it.
  var openMenuPID: pid_t? {
    if case .owned(let pid) = state { return pid }
    return nil
  }

  /// Whether the native surface keeps the keyboard. A hint session started
  /// over it (`f` on an open context menu) takes the keyboard while it runs,
  /// through the session tap only: Flash's key-window fallback would close
  /// the menu by becoming key.
  static func ownsKeyboard(
    owned: Bool, hintSessionActive: Bool, activationInFlight: Bool, tapLive: Bool
  ) -> Bool {
    owned && !(tapLive && (hintSessionActive || activationInFlight))
  }

  /// Evidence the surface is gone: its menu closed, the user entered a mode,
  /// or another app came forward.
  mutating func end() { state = .none }

  /// A recapture was requested. `windowActive` is the bounded window armed
  /// when the surface appeared. Returns true when the recapture may proceed,
  /// ending the ownership if the window alone stood for it; false while the
  /// surface still owns the keyboard.
  mutating func recaptureRequested(windowActive: Bool) -> Bool {
    switch state {
    case .none:
      return !windowActive
    case .owned(.some):
      return false
    case .owned(nil):
      if windowActive { return false }
      state = .none
      return true
    }
  }
}
