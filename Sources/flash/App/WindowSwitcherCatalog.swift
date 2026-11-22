import AppKit
import ApplicationServices
import FlashCore

/// A window the switcher can focus: its app and its Accessibility element.
/// Two reads of the same window are one key (`CFEqual` on the element).
struct WindowSwitcherKey: Hashable {
  let pid: pid_t
  let element: AXUIElement
}

/// The switcher's prepared window list: the order windows were focused in
/// (`WindowRecency`, fed by focus events on main) and every window of every
/// regular app, read per app on the window-navigation build queue whenever an
/// event says that app's windows may have changed. Opening the switcher reads
/// both from memory on main; nothing on that path asks an app or WindowServer
/// anything.
///
/// Accessibility lists an app's windows on the active Space only (and its
/// minimized ones). A window read once stays cataloged while it is alive, so
/// a window on another Space is known once Flash has seen it: it was focused,
/// or its Space was active during a read.
final class WindowSwitcherCatalog {
  typealias Window = WindowSwitcherWindow<WindowSwitcherKey>
  /// Reads one app's windows: the ones `kAXWindows` lists, then each
  /// `remembered` window it no longer lists that is still alive. Nil when the
  /// app did not answer, which keeps its last good windows. Runs on the build
  /// queue.
  typealias Reader = (_ pid: pid_t, _ remembered: [AXUIElement]) -> [Window]?
  /// An app's name and icon, read once per app on the build queue.
  struct AppInfo {
    let name: String
    let icon: CGImage?
  }
  typealias AppInfoLoader = (_ pid: pid_t) -> AppInfo?

  /// How long AX window events for one app coalesce before it is read again.
  /// A closing window destroys its whole subtree and a loading page retitles
  /// its window several times; one read after the burst covers them all.
  static let eventCoalescingMs = 250

  private(set) var recency = WindowRecency<WindowSwitcherKey>()
  private var windowsByApp: [pid_t: [Window]] = [:]
  /// The running-app order of the last full refresh: where apps never
  /// activated while Flash ran are listed.
  private var appOrder: [pid_t] = []
  /// The regular apps whose windows are listed. Focus and AX events of any
  /// other process (an agent's panel) read nothing.
  private var listed: Set<pid_t> = []
  /// Bumped when an app quits, so a read still in flight for it installs
  /// nothing.
  private var lifetimes: [pid_t: UInt64] = [:]
  private var reading: Set<pid_t> = []
  private var stale: Set<pid_t> = []
  private var eventPIDs: Set<pid_t> = []
  private var apps: [pid_t: AppInfo] = [:]
  private let eventDeadline: PollDeadline
  private let coalescingMs: Int
  private let queue: DispatchQueue
  private let reader: Reader
  private let appInfoLoader: AppInfoLoader

  init(
    queue: DispatchQueue,
    scheduler: PollScheduler = .shared,
    coalescingMs: Int = WindowSwitcherCatalog.eventCoalescingMs,
    reader: @escaping Reader = WindowSwitcherCatalog.readWindows,
    appInfoLoader: @escaping AppInfoLoader = WindowSwitcherCatalog.loadAppInfo
  ) {
    self.queue = queue
    self.coalescingMs = coalescingMs
    self.reader = reader
    self.appInfoLoader = appInfoLoader
    // `.normal`: a closed window lingering in the list is visible only if the
    // switcher opens within the burst; armed only by an AX window event.
    eventDeadline = PollDeadline(
      "core:window_switcher_refresh", priority: .normal, on: .main, scheduler: scheduler)
  }

  /// Every window the switcher lists, most recently focused first.
  var rows: [Window] {
    WindowSwitcherPlanner.rows(recency: recency, catalog: windowsByApp, catalogOrder: appOrder)
  }

  /// The window the user is in, when Flash has seen it resolve.
  var current: WindowSwitcherKey? { recency.current }

  /// The app's name as read with its first windows; AppKit's when a row
  /// shows before that read landed.
  func appName(for pid: pid_t) -> String? {
    apps[pid]?.name ?? NSRunningApplication(processIdentifier: pid)?.localizedName
  }

  func icon(for pid: pid_t) -> CGImage? { apps[pid]?.icon }

  // MARK: Events (main)

  /// An app's focused window resolved. Read the app again when the window is
  /// new to the catalog.
  func focusResolved(pid: pid_t, window: AXUIElement) {
    let key = WindowSwitcherKey(pid: pid, element: window)
    recency.focusResolved(key, pid: pid)
    if listed.contains(pid), !(windowsByApp[pid]?.contains { $0.id == key } ?? false) {
      read(pid)
    }
  }

  func appActivated(pid: pid_t) {
    recency.appActivated(pid)
  }

  /// A regular app launched: its first windows are read once the launch's
  /// burst settles.
  func appLaunched(pid: pid_t) {
    listed.insert(pid)
    windowsMayHaveChanged(pid: pid)
  }

  func appTerminated(pid: pid_t) {
    listed.remove(pid)
    lifetimes[pid, default: 0] &+= 1
    windowsByApp.removeValue(forKey: pid)
    apps.removeValue(forKey: pid)
    appOrder.removeAll { $0 == pid }
    reading.remove(pid)
    stale.remove(pid)
    eventPIDs.remove(pid)
    recency.removeApp(pid, windows: Set(recency.windows.filter { $0.pid == pid }))
  }

  /// An AX notification that can add, remove, retitle, minimize or hide one of
  /// `pid`'s windows. Bursts coalesce into one read per app.
  func windowsMayHaveChanged(pid: pid_t) {
    guard listed.contains(pid) else { return }
    eventPIDs.insert(pid)
    guard !eventDeadline.isArmed else { return }
    eventDeadline.arm(afterMs: coalescingMs) { [weak self] in
      guard let self else { return }
      let pids = self.eventPIDs
      self.eventPIDs.removeAll()
      for pid in pids.sorted() where self.listed.contains(pid) { self.read(pid) }
    }
  }

  /// Read every app in `pids` (the regular running apps): at launch, when
  /// apps launch or quit, and when the active Space changes. `order` lists
  /// apps never activated while Flash ran, most likely first.
  func refresh(pids: [pid_t], order: [pid_t]) {
    appOrder = order
    let running = Set(pids)
    listed = running
    for pid in Array(windowsByApp.keys) where !running.contains(pid) {
      appTerminated(pid: pid)
    }
    for pid in pids { read(pid) }
  }

  // MARK: Reads

  private func read(_ pid: pid_t) {
    guard !reading.contains(pid) else {
      stale.insert(pid)
      return
    }
    reading.insert(pid)
    let lifetime = lifetimes[pid, default: 0]
    var remembered = (windowsByApp[pid] ?? []).map(\.id)
    for key in recency.windows where key.pid == pid && !remembered.contains(key) {
      remembered.append(key)
    }
    let elements = remembered.map(\.element)
    let needsApp = apps[pid] == nil
    queue.async { [weak self, reader, appInfoLoader] in
      let windows = reader(pid, elements)
      let app = needsApp ? appInfoLoader(pid) : nil
      DispatchQueue.main.async {
        self?.install(windows, app: app, pid: pid, lifetime: lifetime, remembered: remembered)
      }
    }
  }

  private func install(
    _ windows: [Window]?, app: AppInfo?, pid: pid_t, lifetime: UInt64,
    remembered: [WindowSwitcherKey]
  ) {
    guard lifetimes[pid, default: 0] == lifetime else { return }
    reading.remove(pid)
    if let app { apps[pid] = app }
    if let windows {
      let alive = Set(windows.map(\.id))
      for key in remembered where !alive.contains(key) {
        recency.remove(key)
      }
      windowsByApp[pid] = windows
    }
    if stale.remove(pid) != nil { read(pid) }
  }

  // MARK: Accessibility

  /// Off main: `NSRunningApplication` reads atomically and the icon is
  /// rendered once, at the size a row draws it on a Retina display.
  static func loadAppInfo(pid: pid_t) -> AppInfo? {
    guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
    var rect = CGRect(x: 0, y: 0, width: 40, height: 40)
    return AppInfo(
      name: app.localizedName ?? app.bundleIdentifier ?? "",
      icon: app.icon?.cgImage(forProposedRect: &rect, context: nil, hints: nil))
  }

  static func readWindows(pid: pid_t, remembered: [AXUIElement]) -> [Window]? {
    let app = AXApp.make(pid: pid, messagingTimeout: 1)
    var raw: CFTypeRef?
    let listed: [AXUIElement]
    switch AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) {
    case .success: listed = raw as? [AXUIElement] ?? []
    case .noValue, .attributeUnsupported: listed = []
    default: return nil
    }
    return windows(pid: pid, listed: listed, remembered: remembered, read: readWindow)
  }

  /// What one window read found: its title, whether it is minimized, and
  /// whether its subrole is one the switcher lists.
  struct WindowRead: Equatable {
    let title: String
    let minimized: Bool
    let switchable: Bool
  }

  /// How a window element answered.
  enum WindowAnswer: Equatable {
    case window(WindowRead)
    /// It is no window any more: it closed.
    case gone
    /// Its app did not answer in time.
    case unresponsive
  }

  /// An app's windows from what Accessibility answered: the `listed` ones
  /// (`kAXWindows`: the active Space's and the minimized ones), then each
  /// `remembered` window it did not list that still reads as a window, on
  /// another Space. Nil as soon as one element goes unanswered: a busy app
  /// keeps its last good windows instead of holding the build queue one
  /// timeout per window.
  static func windows(
    pid: pid_t, listed: [AXUIElement], remembered: [AXUIElement],
    read: (AXUIElement) -> WindowAnswer
  ) -> [Window]? {
    var windows: [Window] = []
    var seen = Set<WindowSwitcherKey>()
    for (element, isListed) in listed.map({ ($0, true) }) + remembered.map({ ($0, false) }) {
      let key = WindowSwitcherKey(pid: pid, element: element)
      guard seen.insert(key).inserted else { continue }
      switch read(element) {
      case .window(let window) where window.switchable:
        windows.append(
          Window(
            id: key, pid: pid, title: window.title, minimized: window.minimized,
            onActiveSpace: isListed || window.minimized))
      case .window, .gone:
        continue
      case .unresponsive:
        return nil
      }
    }
    return windows
  }

  private static let windowAttributes =
    [
      kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXMinimizedAttribute,
    ] as CFArray

  /// Subroles of a window a person switches to (`WindowMover.userWindowSubroles`).
  private static let switchableSubroles = WindowMover.userWindowSubroles

  /// One IPC per window.
  private static func readWindow(_ element: AXUIElement) -> WindowAnswer {
    AXUIElementSetMessagingTimeout(element, 1)
    var raw: CFArray?
    let status = AXUIElementCopyMultipleAttributeValues(
      element, windowAttributes, AXCopyMultipleAttributeOptions(rawValue: 0), &raw)
    guard status != .cannotComplete else { return .unresponsive }
    guard status == .success, let values = raw as? [Any], values.count == 4,
      values[0] as? String == kAXWindowRole as String
    else { return .gone }
    let subrole = values[1] as? String
    return .window(
      WindowRead(
        title: values[2] as? String ?? "",
        minimized: values[3] as? Bool ?? false,
        switchable: subrole.map { switchableSubroles.contains($0) } ?? true))
  }
}
