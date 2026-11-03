import AppKit

/// One window the switcher can list, as its catalog last read it.
struct WindowSwitcherWindow<ID: Hashable>: Equatable {
  let id: ID
  let pid: pid_t
  var title: String
  var minimized: Bool
  /// False for a window its app no longer lists in `kAXWindows` although the
  /// window is still alive: Accessibility lists the active Space's windows
  /// (and minimized ones), so a live window missing from it is on another
  /// Space.
  var onActiveSpace: Bool
}

/// The order the user last focused windows in, across every app. Pure value
/// state: the resident feeds it focus events on main (`focusResolved`,
/// `appActivated`) and the catalog's removals, never a scan.
struct WindowRecency<ID: Hashable>: Equatable {
  /// How many windows are remembered; the oldest fall off first.
  static var capacity: Int { 512 }

  /// Most recently focused first.
  private(set) var windows: [ID] = []
  /// Most recently activated app first.
  private(set) var apps: [pid_t] = []
  /// Each app's focused window as last resolved, so an activation that does
  /// not resolve the focused window again still promotes the right one.
  private(set) var focused: [pid_t: ID] = [:]
  /// The frontmost app, as the last activation reported it.
  private(set) var frontmost: pid_t?

  /// The focused window of the frontmost app: the window the user is in.
  var current: ID? { frontmost.flatMap { focused[$0] } }

  /// `pid`'s focused window resolved to `id`. It becomes the most recent
  /// window only while `pid` is frontmost: a background app's focus moving
  /// (one of its windows closed) is not the user's choice.
  mutating func focusResolved(_ id: ID, pid: pid_t) {
    focused[pid] = id
    guard pid == frontmost else { return }
    promote(id)
  }

  /// `pid` came to the front. Its focused window, when known, is now the
  /// most recent one.
  mutating func appActivated(_ pid: pid_t) {
    frontmost = pid
    apps.removeAll { $0 == pid }
    apps.insert(pid, at: 0)
    if let id = focused[pid] { promote(id) }
  }

  /// The window is gone.
  mutating func remove(_ id: ID) {
    windows.removeAll { $0 == id }
    focused = focused.filter { $0.value != id }
  }

  /// The app quit: its windows and its place go with it.
  mutating func removeApp(_ pid: pid_t, windows ids: Set<ID>) {
    windows.removeAll { ids.contains($0) }
    focused.removeValue(forKey: pid)
    apps.removeAll { $0 == pid }
    if frontmost == pid { frontmost = nil }
  }

  private mutating func promote(_ id: ID) {
    if windows.first == id { return }
    windows.removeAll { $0 == id }
    windows.insert(id, at: 0)
    if windows.count > Self.capacity { windows.removeLast(windows.count - Self.capacity) }
  }
}

/// The switcher's pure decisions: which rows, in which order, where the
/// selection starts and how it moves.
enum WindowSwitcherPlanner {
  /// Every cataloged window once: the ones the user focused while Flash ran,
  /// most recent first; then the rest by how recently their app was active,
  /// apps never activated last in `catalogOrder`; within an app, in the app's
  /// own window order.
  static func rows<ID: Hashable>(
    recency: WindowRecency<ID>,
    catalog: [pid_t: [WindowSwitcherWindow<ID>]],
    catalogOrder: [pid_t]
  ) -> [WindowSwitcherWindow<ID>] {
    var byID: [ID: WindowSwitcherWindow<ID>] = [:]
    for windows in catalog.values {
      for window in windows { byID[window.id] = window }
    }
    var rows: [WindowSwitcherWindow<ID>] = []
    rows.reserveCapacity(byID.count)
    var listed = Set<ID>()
    for id in recency.windows {
      guard let window = byID[id], listed.insert(id).inserted else { continue }
      rows.append(window)
    }
    var appOrder: [pid_t] = []
    var seenApps = Set<pid_t>()
    for pid in recency.apps + catalogOrder + catalog.keys.sorted()
    where catalog[pid] != nil && seenApps.insert(pid).inserted {
      appOrder.append(pid)
    }
    for pid in appOrder {
      for window in catalog[pid] ?? [] where listed.insert(window.id).inserted {
        rows.append(window)
      }
    }
    return rows
  }

  /// cmd+tab's first press: the window before the one the user is in. The
  /// first row when the user is in none of them.
  static func initialSelection<ID: Hashable>(
    rows: [WindowSwitcherWindow<ID>], current: ID?
  ) -> Int {
    guard rows.count > 1, let current, rows[0].id == current else { return 0 }
    return 1
  }

  /// The selection `delta` rows on, wrapping.
  static func step(_ selection: Int, by delta: Int, count: Int) -> Int {
    guard count > 0 else { return 0 }
    return ((selection + delta) % count + count) % count
  }
}

extension WindowSwitcherPlanner {
  /// Which row gets which label: the easiest label goes to the row the
  /// selection starts on, the next ones down the list from there, wrapping,
  /// so the window you most likely want is the one easiest to type.
  static func labelOrder(count: Int, first: Int) -> [Int] {
    guard count > 0 else { return [] }
    let start = min(max(0, first), count - 1)
    return (0..<count).map { (start + $0) % count }
  }

  /// Apps in the order their windows are stacked on the active Space, then
  /// the rest in `running` order: the fallback order of windows nobody
  /// focused since Flash started.
  static func appOrder(stacked: [pid_t], running: [pid_t]) -> [pid_t] {
    let alive = Set(running)
    var seen = Set<pid_t>()
    var order: [pid_t] = []
    for pid in stacked + running where alive.contains(pid) && seen.insert(pid).inserted {
      order.append(pid)
    }
    return order
  }
}

/// A row the switcher shows: the window, its hint label and what the badges
/// say about it.
struct WindowSwitcherRow<ID: Hashable>: Equatable {
  enum Badge: String, Equatable {
    case minimized
    case hidden
    case otherSpace = "other Space"
  }

  let window: WindowSwitcherWindow<ID>
  /// Lowercase, as the alphabet produced it.
  let label: String
  let app: String
  /// The window's app is hidden (Cmd-H).
  let appHidden: Bool

  /// A minimized window is in the Dock and a hidden app's windows are on no
  /// Space, so at most one badge applies, in that order.
  var badge: Badge? {
    if window.minimized { return .minimized }
    if appHidden { return .hidden }
    return window.onActiveSpace ? nil : .otherSpace
  }
}

/// One keystroke while the switcher is up.
enum WindowSwitcherKeyCommand: Equatable {
  /// Tab and the arrows: the selection moves.
  case move(Int)
  /// Return: the selected window.
  case choose
  case cancel
  /// Backspace: drop the last typed label character.
  case backspace
  /// A label character, whatever modifier is held with it.
  case type(String)
}

/// Reads the switcher's keys. Labels win over nothing: navigation is on
/// keys no hint alphabet uses (Tab, the arrows, Return, Escape, Backspace),
/// so every other key types a label.
enum WindowSwitcherInterpreter {
  static func command(
    keyCode: UInt16, typed: String?, modifierFlags: NSEvent.ModifierFlags
  ) -> WindowSwitcherKeyCommand? {
    let shift = modifierFlags.contains(.shift)
    switch keyCode {
    case 48: return .move(shift ? -1 : 1)  // tab
    case 124, 125: return .move(1)  // right, down
    case 123, 126: return .move(-1)  // left, up
    case 36, 76: return .choose  // return, keypad enter
    case 53: return .cancel  // escape
    case 51: return .backspace  // delete
    default:
      guard let typed = typed?.lowercased(), typed.count == 1,
        typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
      else { return nil }
      return .type(typed)
    }
  }
}

/// The switcher on screen: its rows, the selection and the typed label
/// prefix. Pure transitions; the resident draws
/// the result and focuses what it chooses.
struct WindowSwitcherState<ID: Hashable>: Equatable {
  enum Outcome: Equatable {
    case redraw
    case choose(WindowSwitcherRow<ID>)
    case cancel
    case ignore
  }

  private(set) var rows: [WindowSwitcherRow<ID>]
  private(set) var selection: Int
  private(set) var typed = ""
  /// A point on the display the list is drawn on, kept for every redraw.
  var anchor: CGPoint?

  init(rows: [WindowSwitcherRow<ID>], selection: Int) {
    self.rows = rows
    self.selection = rows.isEmpty ? 0 : min(max(0, selection), rows.count - 1)
  }

  mutating func apply(_ command: WindowSwitcherKeyCommand) -> Outcome {
    switch command {
    case .move(let delta):
      guard !rows.isEmpty else { return .ignore }
      selection = WindowSwitcherPlanner.step(selection, by: delta, count: rows.count)
      typed = ""
      return .redraw
    case .choose:
      return rows.indices.contains(selection) ? .choose(rows[selection]) : .cancel
    case .cancel:
      return .cancel
    case .backspace:
      guard !typed.isEmpty else { return .ignore }
      typed.removeLast()
      return .redraw
    case .type(let character):
      let prefix = typed + character
      if let row = rows.first(where: { $0.label == prefix }) { return .choose(row) }
      guard rows.contains(where: { $0.label.hasPrefix(prefix) }) else { return .ignore }
      typed = prefix
      return .redraw
    }
  }
}
