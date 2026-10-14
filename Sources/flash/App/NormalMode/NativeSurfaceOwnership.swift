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
    case owned(menuOpenSeen: Bool)
  }

  private(set) var state: State = .none

  var isOwned: Bool { state != .none }

  /// Capture was suspended for a native surface.
  mutating func begin() { state = .owned(menuOpenSeen: false) }

  /// The app reported a menu opening while the surface is owned.
  mutating func menuOpened() {
    if case .owned = state { state = .owned(menuOpenSeen: true) }
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
    case .owned(menuOpenSeen: true):
      return false
    case .owned(menuOpenSeen: false):
      if windowActive { return false }
      state = .none
      return true
    }
  }
}
