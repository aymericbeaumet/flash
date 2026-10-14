import ApplicationServices
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
  /// The menus one app reported opening, outermost first: the elements its
  /// `AXMenuOpened` notifications named.
  struct OpenMenus: Equatable {
    var pid: pid_t
    var menus: [AXUIElement]
  }

  enum State: Equatable {
    case none
    /// `open` is the app whose menus reported opening; nil until one did.
    case owned(open: OpenMenus?)
  }

  private(set) var state: State = .none

  var isOwned: Bool { state != .none }

  /// Capture was suspended for a native surface.
  mutating func begin() { state = .owned(open: nil) }

  /// App `pid` reported `menu` opening while the surface is owned: a context
  /// menu, or a submenu of one. Another app's menu replaces the record.
  mutating func menuOpened(pid: pid_t, menu: AXUIElement) {
    guard case .owned(let open) = state else { return }
    var record = open?.pid == pid ? open! : OpenMenus(pid: pid, menus: [])
    if !record.menus.contains(menu) { record.menus.append(menu) }
    state = .owned(open: record)
  }

  /// `menu` reported closing. Returns true when that ended the surface: the
  /// last recorded menu closed, or a menu Flash never recorded did. A
  /// submenu closing leaves the menu it hangs from, and the keyboard, open.
  mutating func menuClosed(_ menu: AXUIElement) -> Bool {
    guard case .owned(let open) = state else { return false }
    guard var record = open, let index = record.menus.firstIndex(of: menu) else {
      state = .none
      return true
    }
    record.menus.remove(at: index)
    if record.menus.isEmpty {
      state = .none
      return true
    }
    state = .owned(open: record)
    return false
  }

  /// The app whose menu is open, once it reported opening: `f` walks that
  /// menu instead of the window behind it.
  var openMenuPID: pid_t? {
    if case .owned(let open) = state { return open?.pid }
    return nil
  }

  /// The open menus `f` walks, outermost first.
  var openMenus: [AXUIElement] {
    if case .owned(let open) = state { return open?.menus ?? [] }
    return []
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
    case .owned(open: .some):
      return false
    case .owned(open: nil):
      if windowActive { return false }
      state = .none
      return true
    }
  }
}
