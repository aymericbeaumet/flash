import AppKit
import ApplicationServices
import FlashCore

struct WindowScreenLayout: Equatable {
  let id: CGDirectDisplayID
  let frame: CGRect
  let usableFrame: CGRect
  /// The display's stable identity, its UUID when macOS has one. A
  /// CGDirectDisplayID can be reassigned when a display reconnects; the UUID
  /// survives it, so it is what a layout's home display is matched by.
  let identity: String

  init(id: CGDirectDisplayID, frame: CGRect, usableFrame: CGRect, identity: String? = nil) {
    self.id = id
    self.frame = frame
    self.usableFrame = usableFrame
    self.identity = identity ?? "display-\(id)"
  }
}

/// A tracked window's semantic layout and the displays it belongs to.
/// `home` is the display the layout was placed on, by a `window move`, a
/// placement rule or the user, named by its stable identity; `screenID` is
/// the display it sits on now. A display change keeps the layout on whatever
/// display the window lands on while home is away, and puts it back on home
/// at the same layout once home returns, as macOS returns windows to a
/// reconnected display. Pure value state.
struct WindowLayoutIntent: Equatable {
  var layout: WindowLayout
  var home: String
  var screenID: CGDirectDisplayID

  init(layout: WindowLayout, placedOn screen: WindowScreenLayout) {
    self.init(layout: layout, home: screen.identity, screenID: screen.id)
  }

  init(layout: WindowLayout, home: String, screenID: CGDirectDisplayID) {
    self.layout = layout
    self.home = home
    self.screenID = screenID
  }

  /// Where the layout goes after a display change: home whenever it is
  /// connected, else the display recovery chose last (so passes do not chase
  /// a window macOS is still moving), else the display macOS moved it to,
  /// else the primary.
  func recoveryPlan(
    currentFrame: CGRect?, screens: [WindowScreenLayout]
  ) -> WindowMover.LayoutRecoveryPlan? {
    guard let primary = screens.first else { return nil }
    let screen =
      screens.first(where: { $0.identity == home })
      ?? screens.first(where: { $0.id == screenID })
      ?? currentFrame.flatMap { WindowMover.screenContaining(frame: $0, screens: screens) }
      ?? primary
    return WindowMover.LayoutRecoveryPlan(
      screen: screen, frame: WindowMover.rectFor(layout: layout, in: screen.usableFrame))
  }

  /// Recovery put the window on `screen`; home stays where it was placed.
  mutating func recovered(on screen: WindowScreenLayout) {
    screenID = screen.id
  }

  /// The intent a window's observed `frame` carries, or nil for a free-form
  /// frame, the user's own placement that Flash leaves alone. The same
  /// layout on home or on the display it already sits on is `existing`
  /// unchanged, so focusing a window recovery left on a fallback display
  /// keeps its home. Another layout, or the same one on another display, is
  /// a new placement there. An untracked window is adopted with its display,
  /// or `home` when a departed display left it behind, as home.
  static func observed(
    frame: CGRect, screens: [WindowScreenLayout], existing: WindowLayoutIntent?,
    declared: [WindowLayout], home: String? = nil
  ) -> WindowLayoutIntent? {
    guard let screen = WindowMover.screenContaining(frame: frame, screens: screens),
      let layout = WindowMover.semanticLayout(
        matching: frame, in: screen.usableFrame, existing: existing?.layout, declared: declared)
    else { return nil }
    if var existing, existing.layout == layout,
      screen.identity == existing.home || screen.id == existing.screenID
    {
      existing.screenID = screen.id
      return existing
    }
    guard existing == nil, let home else {
      return WindowLayoutIntent(layout: layout, placedOn: screen)
    }
    return WindowLayoutIntent(layout: layout, home: home, screenID: screen.id)
  }
}

enum WindowFocusDirection: String, Hashable, CaseIterable {
  case left, right, up, down
}

struct WindowFocusCandidate<ID: Hashable> {
  let id: ID
  let frame: CGRect
}

/// One on-screen window as WindowServer orders it, front first.
struct WindowFocusZEntry: Equatable {
  let pid: pid_t
  let frame: CGRect
}

/// A run of `window next` / `window previous` presses in one app.
struct WindowAppCycleRun<ID: Hashable>: Equatable {
  /// The app's windows in the stacking order the run's first press read.
  let order: [ID]
  /// The window the last press raised.
  let index: Int
  /// The window focused when the last press ran, until its raise is
  /// observed.
  let anchor: ID?

  var selected: ID { order[index] }

  /// The run once focus moved to `focused`: reaching the raised window
  /// settles the last press.
  func observing(_ focused: ID) -> Self {
    focused == selected ? Self(order: order, index: index, anchor: nil) : self
  }
}

enum WindowFocusPlanner {
  /// Two frames of the same window read through Accessibility and through
  /// WindowServer agree within this many points on every edge.
  static let frameMatchTolerance: CGFloat = 2

  /// The catalog's windows in WindowServer order: each z entry claims the
  /// first unclaimed catalog window of its pid with the same frame. Windows
  /// the z-order does not show (another Space, minimized) are left out.
  static func zOrdered<ID: Hashable>(
    _ windows: [WindowFocusCandidate<ID>], zOrder: [WindowFocusZEntry], pid: (ID) -> pid_t
  ) -> [ID] {
    var claimed = Set<ID>()
    var ordered: [ID] = []
    for entry in zOrder {
      guard
        let match = windows.first(where: { candidate in
          !claimed.contains(candidate.id) && pid(candidate.id) == entry.pid
            && framesMatch(candidate.frame, entry.frame)
        })
      else { continue }
      claimed.insert(match.id)
      ordered.append(match.id)
    }
    return ordered
  }

  /// `mouse screens --focus`: the first window in stacking order whose
  /// display (`WindowMover.screenIndex`: its centre's, else the one it
  /// overlaps most) is the one named `identity`.
  static func frontmost<ID: Hashable>(
    onScreen identity: String, screens: [WindowScreenLayout], ordered: [ID],
    frames: [ID: CGRect]
  ) -> ID? {
    guard let index = screens.firstIndex(where: { $0.identity == identity }) else { return nil }
    let display = screens[index].frame
    return ordered.first { id in
      guard let frame = frames[id], frame.intersects(display) else { return false }
      return WindowMover.screenIndex(forFrame: frame, screens: screens) == index
    }
  }

  static func framesMatch(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) <= frameMatchTolerance && abs(a.minY - b.minY) <= frameMatchTolerance
      && abs(a.width - b.width) <= frameMatchTolerance
      && abs(a.height - b.height) <= frameMatchTolerance
  }

  /// `window focus --direction=next|previous|behind` over the z-ordered
  /// catalog: the window below or above the focused one in the stacking
  /// order, wrapping, or the frontmost window below it that overlaps it.
  static func cycle<ID: Hashable>(
    _ cycle: WindowFocusCycle, from sourceID: ID, ordered: [ID],
    frames: [ID: CGRect]
  ) -> ID? {
    guard let index = ordered.firstIndex(of: sourceID), ordered.count > 1 else { return nil }
    switch cycle {
    case .next:
      return ordered[(index + 1) % ordered.count]
    case .previous:
      return ordered[(index - 1 + ordered.count) % ordered.count]
    case .behind:
      guard let source = frames[sourceID] else { return nil }
      return ordered.dropFirst(index + 1).first { id in
        frames[id].map { $0.intersects(source) } ?? false
      }
    }
  }

  /// `window next` / `window previous` over the focused app's z-ordered
  /// windows. A raised window rises to the top of the stacking order, so a
  /// run of presses keeps the order its first press read while the app's
  /// windows stay the same; otherwise every press would trade the top two.
  static func appCycle<ID: Hashable>(
    _ cycle: WindowAppCycle, focused: ID, ordered: [ID], run: WindowAppCycleRun<ID>?
  ) -> WindowAppCycleRun<ID>? {
    let current = ordered.contains(focused) ? ordered : [focused] + ordered
    let order: [ID]
    let index: Int
    if let run, Set(run.order) == Set(current) {
      order = run.order
      // Until the last raise is observed, focus still reports the window
      // that press started from.
      index =
        run.anchor == focused ? run.index : (order.firstIndex(of: focused) ?? run.index)
    } else {
      order = current
      index = current.firstIndex(of: focused) ?? 0
    }
    guard order.count > 1 else { return nil }
    let step = cycle == .next ? 1 : order.count - 1
    return WindowAppCycleRun(order: order, index: (index + step) % order.count, anchor: focused)
  }

  static func nearest<ID: Hashable>(
    _ direction: WindowFocusDirection, from sourceID: ID,
    in windows: [WindowFocusCandidate<ID>]
  ) -> ID? {
    guard let source = windows.first(where: { $0.id == sourceID }) else { return nil }
    let origin = CGPoint(x: source.frame.midX, y: source.frame.midY)
    return windows.enumerated().compactMap { index, candidate -> (ID, CGFloat, Int)? in
      guard candidate.id != sourceID else { return nil }
      let point = CGPoint(x: candidate.frame.midX, y: candidate.frame.midY)
      let primary: CGFloat
      let crossGap: CGFloat
      switch direction {
      case .left:
        primary = origin.x - point.x
        crossGap = max(
          0,
          max(
            source.frame.minY - candidate.frame.maxY,
            candidate.frame.minY - source.frame.maxY))
      case .right:
        primary = point.x - origin.x
        crossGap = max(
          0,
          max(
            source.frame.minY - candidate.frame.maxY,
            candidate.frame.minY - source.frame.maxY))
      case .up:
        primary = point.y - origin.y
        crossGap = max(
          0,
          max(
            source.frame.minX - candidate.frame.maxX,
            candidate.frame.minX - source.frame.maxX))
      case .down:
        primary = origin.y - point.y
        crossGap = max(
          0,
          max(
            source.frame.minX - candidate.frame.maxX,
            candidate.frame.minX - source.frame.maxX))
      }
      guard primary > 0 else { return nil }
      return (candidate.id, primary + crossGap * 4, index)
    }.min { lhs, rhs in
      lhs.1 == rhs.1 ? lhs.2 < rhs.2 : lhs.1 < rhs.1
    }?.0
  }
}

struct WindowPlacementRule: Equatable {
  let bundleID: String
  let titleContains: String?
  let move: MoveWindowParams

  func matches(bundleID: String, title: String?) -> Bool {
    guard self.bundleID == bundleID else { return false }
    guard let titleContains else { return true }
    return title?.range(of: titleContains, options: .caseInsensitive) != nil
  }

  /// The first rule in file order matching a window of `bundleID`. `title`
  /// is an Accessibility round trip into the app, on the layout queue every
  /// move waits behind, so it is read only when one of the app's rules,
  /// ahead of any that matches every title, needs it.
  static func first(
    in rules: [WindowPlacementRule], bundleID: String, title: () -> String?
  ) -> WindowPlacementRule? {
    let candidates = rules.filter { $0.bundleID == bundleID }
    guard let first = candidates.first else { return nil }
    guard first.titleContains != nil else { return first }
    let title = title()
    return candidates.first { $0.matches(bundleID: bundleID, title: title) }
  }
}

/// Which windows the placement rules already judged: each AX window identity
/// once per rule set. A window no rule matched stays checked even if its
/// title changes to match later, so a rule never moves a window the user has
/// been arranging; a matched rule whose move did not land stays due.
struct PlacementRuleChecks<Key: Hashable>: Equatable {
  private(set) var checked: Set<Key> = []

  /// The rule to apply to `key`; nil when it was checked already or no rule
  /// matches, which checks it.
  mutating func rule(
    for key: Key, in rules: [WindowPlacementRule], bundleID: String, title: () -> String?
  ) -> WindowPlacementRule? {
    guard !checked.contains(key) else { return nil }
    guard let rule = WindowPlacementRule.first(in: rules, bundleID: bundleID, title: title)
    else {
      checked.insert(key)
      return nil
    }
    return rule
  }

  /// The rule's move landed.
  mutating func applied(_ key: Key) { checked.insert(key) }

  /// A new rule set: every window is due again.
  mutating func reset() { checked.removeAll() }

  /// The window is gone.
  mutating func forget(_ key: Key) { checked.remove(key) }

  mutating func forget(where predicate: (Key) -> Bool) {
    checked = checked.filter { !predicate($0) }
  }
}

/// Owns interactive window moves and the semantic layout attached to each
/// window. AX requests run on a dedicated serial queue: a slow target app must
/// not stall Flash's main run loop (and therefore its keyboard tap) while it
/// answers a window resize request.
final class WindowLayoutManager {
  typealias ScreenLayoutsProvider =
    (Bool, Config.StatusBar.Monitor) -> [WindowScreenLayout]

  /// Bounded passes after a display change. AppKit reports the change before
  /// `NSScreen` settles, and the apps themselves relocate their windows over
  /// the following seconds — a reconnected or woken display is the slow case,
  /// well past where the earlier ladder stopped looking. The last entry also
  /// sets how long observed frames are treated as macOS's doing rather than
  /// the user's.
  static let defaultScreenRecoveryDelaysMs = [80, 250, 750, 1_500, 3_000]

  /// A window's identity: its app and its AX element, compared by
  /// CFEqual. It carries the element so tiling can reach a window it parked.
  struct WindowKey: Hashable {
    let pid: pid_t
    let element: AnyHashable
    let window: AXUIElement

    init(pid: pid_t, window: AXUIElement) {
      self.pid = pid
      self.element = AnyHashable(window)
      self.window = window
    }

    static func == (lhs: WindowKey, rhs: WindowKey) -> Bool {
      lhs.pid == rhs.pid && lhs.element == rhs.element
    }

    func hash(into hasher: inout Hasher) {
      hasher.combine(pid)
      hasher.combine(element)
    }
  }

  private struct TrackedLayout {
    let pid: pid_t
    let window: AXUIElement
    var intent: WindowLayoutIntent
  }

  private struct NavigationWindow {
    let key: WindowKey
    let window: AXUIElement
    let frame: CGRect
    /// nil when unread (a focus or move event); tiling floats any window
    /// that is not `AXStandardWindow`.
    var subrole: String? = nil
    let updatedAt: DispatchTime = .now()
  }

  private let queue = DispatchQueue(label: "flash.window-layout", qos: .userInitiated)
  /// Catalog walks: the directional-focus catalog here and the window
  /// switcher's (`WindowSwitcherCatalog`). Nobody waits on them.
  let navigationBuildQueue = DispatchQueue(
    label: "flash.window-navigation-build", qos: .utility)
  private var tracked: [WindowKey: TrackedLayout] = [:]
  private var currentScreens: [WindowScreenLayout] = []
  private var screenChangeGeneration: UInt64 = 0
  private var screenChangeKeys: Set<WindowKey> = []
  /// Displays as they were before this change. Recovery uses them to scale a
  /// window that macOS left on a display that is gone.
  private var screenChangeBaseline: [WindowScreenLayout] = []
  private var screenChangeTopologyChanged = false
  private var screenChangeActiveUntil = DispatchTime(uptimeNanoseconds: 0)
  private var selfAuthoredChangesUntil: [WindowKey: DispatchTime] = [:]
  /// Accessibility cannot read or move windows while the session is locked or
  /// asleep, which is exactly when a wake reports the new displays. Restores
  /// wait for the session instead of failing against it.
  private var sessionSuspended = false
  /// The displays from before the first change that arrived while the
  /// session was suspended. Passes then only defer, so resuming compares the
  /// displays with these: a display that left while the Mac slept is still a
  /// topology change, and its stranded windows still get fitted.
  private var suspendedTopologyBaseline: [WindowScreenLayout]?
  /// Windows whose layout has not landed because their frame could not be
  /// read. They are restored when the session resumes, and when focused.
  private var pendingRestoreKeys: Set<WindowKey> = []
  /// The proportional layouts the config's `window move` mappings apply, so a
  /// window placed by one is recognized again after Flash restarts.
  private var declaredLayouts: [WindowLayout] = []
  /// LIFO restores still find the intended window after minimizing the last
  /// window of an app moves focus to another process.
  private var minimizedByFlash: [(pid: pid_t, window: AXUIElement)] = []
  private var navigationWindows: [WindowKey: NavigationWindow] = [:]
  private var focusedWindowKey: WindowKey?
  /// The `window next` / `window previous` run in progress.
  private var appCycleRun: WindowAppCycleRun<WindowKey>?
  private var placementRules: [WindowPlacementRule] = []
  /// Windows checked against the placement rules, once each per rule set.
  private var ruleChecks = PlacementRuleChecks<WindowKey>()
  /// `[tiling]` while enabled. The windows it manages are its own: layout
  /// tracking, display recovery and placement rules leave them alone.
  private var tiling: TilingEngine<WindowLayoutManager>?
  private let tilingStore = TilingLayoutStore()
  /// Workspace state for the bar and host events, on main; nil once tiling
  /// stops.
  var tilingStatusDidChange: ((TilingStatus?) -> Void)?
  /// The tiled window a hand drag is moving, settled once the mouse is up.
  private var tilingDragKey: WindowKey?
  /// Whether the drag in progress resized the window (an AX resized
  /// notification fired): judged as a resize when it ends, else as a move.
  private var tilingDragResized = false

  private let screenRecoveryDelaysMs: [Int]
  private let screenLayoutsProvider: ScreenLayoutsProvider
  private let recoveryApplications: () -> [NSRunningApplication]
  private static let authoredChangeGraceMs = 300

  init(
    screenRecoveryDelaysMs: [Int] = WindowLayoutManager.defaultScreenRecoveryDelaysMs,
    recoveryApplications: @escaping () -> [NSRunningApplication] = {
      NSWorkspace.shared.runningApplications
    },
    screenLayouts: @escaping ScreenLayoutsProvider = { statusBarVisible, monitor in
      WindowMover.screenLayouts(
        statusBarReservesSpace: statusBarVisible,
        statusBarMonitor: monitor)
    }
  ) {
    self.screenRecoveryDelaysMs = screenRecoveryDelaysMs
    self.screenLayoutsProvider = screenLayouts
    self.recoveryApplications = recoveryApplications
  }

  func move(
    _ params: MoveWindowParams,
    statusBarReservesSpace: Bool,
    statusBarMonitor: Config.StatusBar.Monitor,
    targetPID: pid_t
  ) {
    let screens = screenLayoutsProvider(statusBarReservesSpace, statusBarMonitor)
    queue.async { [weak self] in
      guard let self else { return }
      self.currentScreens = screens
      guard
        let result = WindowMover.move(
          params,
          targetPID: targetPID,
          screens: screens,
          existingLayout: { window in
            self.tracked[WindowKey(pid: targetPID, window: window)]?.intent.layout
          })
      else { return }
      let key = WindowKey(pid: targetPID, window: result.window)
      if let layout = result.layout {
        self.tracked[key] = TrackedLayout(
          pid: targetPID,
          window: result.window,
          intent: WindowLayoutIntent(layout: layout, placedOn: result.screen))
        self.selfAuthoredChangesUntil[key] =
          .now() + .milliseconds(Self.authoredChangeGraceMs)
      } else {
        self.tracked.removeValue(forKey: key)
        self.selfAuthoredChangesUntil.removeValue(forKey: key)
      }
    }
  }

  func setWindowState(_ action: WindowStateAction, targetPID: pid_t) {
    queue.async { [weak self] in
      guard let self else { return }
      if case .restore = action {
        while let prior = self.minimizedByFlash.popLast() {
          if WindowMover.setWindowState(
            action, targetPID: prior.pid, restoreWindow: prior.window) != nil
          {
            return
          }
        }
      }
      if let window = WindowMover.setWindowState(action, targetPID: targetPID),
        case .minimize = action
      {
        self.minimizedByFlash.append((targetPID, window))
      }
    }
  }

  func setDeclaredLayouts(_ layouts: [WindowLayout]) {
    queue.async { [weak self] in self?.declaredLayouts = layouts }
  }

  func setPlacementRules(_ rules: [WindowPlacementRule]) {
    queue.async { [weak self] in
      guard let self, self.placementRules != rules else { return }
      self.placementRules = rules
      self.ruleChecks.reset()
      let screens = self.currentScreens
      for candidate in self.navigationWindows.values {
        self.applyPlacementRule(
          pid: candidate.key.pid, window: candidate.window, screens: screens)
      }
    }
  }

  /// Prepare window geometry when the running-app set changes. Selection on a
  /// `window focus` keypress only reads this in-memory catalog; AX discovery
  /// runs on a separate queue so a slow app cannot hold up a focus action.
  func refreshNavigationCatalog(
    statusBarReservesSpace: Bool, statusBarMonitor: Config.StatusBar.Monitor
  ) {
    let pids = NSWorkspace.shared.runningApplications
      .filter { $0.activationPolicy == .regular && !$0.isTerminated }
      .map(\.processIdentifier)
      .filter { $0 != ProcessInfo.processInfo.processIdentifier }
    let screens = screenLayoutsProvider(statusBarReservesSpace, statusBarMonitor)
    let activePIDs = Set(pids)
    queue.async { [weak self] in
      guard let self, !screens.isEmpty else { return }
      self.currentScreens = screens
      self.navigationWindows = self.navigationWindows.filter { activePIDs.contains($0.key.pid) }
    }
    navigationBuildQueue.async { [weak self] in
      guard let self else { return }
      for pid in pids {
        guard let snapshot = self.loadNavigationWindows(pid: pid, screens: screens) else {
          continue
        }
        self.queue.async { [weak self] in
          self?.installNavigationWindows(snapshot, pid: pid, screens: screens)
        }
      }
    }
  }

  func focusWindow(_ direction: WindowFocusDirection, targetPID: pid_t) {
    queue.async { [weak self] in
      guard let self, let source = self.focusedWindowKey, source.pid == targetPID else { return }
      let candidates = self.sortedNavigationCandidates()
      guard let selected = WindowFocusPlanner.nearest(direction, from: source, in: candidates)
      else { return }
      self.raiseNavigationWindow(selected)
    }
  }

  /// `window focus --direction=next|previous|behind`. `zOrder` is the
  /// on-screen window list as read on the main thread by the caller
  /// (`WindowSnapshot.windowList` must not run on this queue).
  func focusWindow(cycle: WindowFocusCycle, targetPID: pid_t, zOrder: [WindowFocusZEntry]) {
    queue.async { [weak self] in
      guard let self, let source = self.focusedWindowKey, source.pid == targetPID else { return }
      let candidates = self.sortedNavigationCandidates()
      let ordered = WindowFocusPlanner.zOrdered(candidates, zOrder: zOrder) { $0.pid }
      let frames = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0.frame) })
      guard
        let selected = WindowFocusPlanner.cycle(
          cycle, from: source, ordered: ordered, frames: frames)
      else { return }
      self.raiseNavigationWindow(selected)
    }
  }

  /// `mouse screens --focus`: the frontmost cataloged window on the display
  /// named `identity`. `zOrder` is read on the main thread by the caller.
  func focusFrontmostWindow(
    onScreen identity: String, screens: [WindowScreenLayout], zOrder: [WindowFocusZEntry]
  ) {
    queue.async { [weak self] in
      guard let self else { return }
      let candidates = self.sortedNavigationCandidates()
      let ordered = WindowFocusPlanner.zOrdered(candidates, zOrder: zOrder) { $0.pid }
      let frames = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0.frame) })
      guard
        let selected = WindowFocusPlanner.frontmost(
          onScreen: identity, screens: screens, ordered: ordered, frames: frames)
      else {
        FlashLog.debug("[screens] focus no_window display=\(identity)")
        return
      }
      self.raiseNavigationWindow(selected)
    }
  }

  /// `window next` / `window previous`: the focused app's cataloged windows
  /// in stacking order, kept for the run (see `WindowFocusPlanner.appCycle`).
  func focusAppWindow(_ cycle: WindowAppCycle, targetPID: pid_t, zOrder: [WindowFocusZEntry]) {
    queue.async { [weak self] in
      guard let self, let source = self.focusedWindowKey, source.pid == targetPID else { return }
      let candidates = self.sortedNavigationCandidates().filter { $0.id.pid == targetPID }
      let ordered = WindowFocusPlanner.zOrdered(candidates, zOrder: zOrder) { $0.pid }
      guard
        let run = WindowFocusPlanner.appCycle(
          cycle, focused: source, ordered: ordered, run: self.appCycleRun)
      else { return }
      self.appCycleRun = run
      self.raiseNavigationWindow(run.selected)
    }
  }

  /// `window switch`'s choice, on the AX queue: `window` comes forward,
  /// unminimized, as its app's main window. `completion` runs on main with
  /// false when the element no longer is a window of `pid` (it closed):
  /// nothing is focused then, never another of the app's windows.
  func focusSwitcherWindow(
    pid: pid_t, window: AXUIElement, completion: @escaping (Bool) -> Void
  ) {
    queue.async {
      let raised = WindowMover.raiseSwitcherWindow(window, pid: pid)
      DispatchQueue.main.async { completion(raised) }
    }
  }

  private func sortedNavigationCandidates() -> [WindowFocusCandidate<WindowKey>] {
    navigationWindows.values.filter { !(tiling?.isParked($0.key) ?? false) }.sorted {
      if $0.key.pid != $1.key.pid { return $0.key.pid < $1.key.pid }
      if $0.frame.minX != $1.frame.minX { return $0.frame.minX < $1.frame.minX }
      return $0.frame.minY < $1.frame.minY
    }.map {
      WindowFocusCandidate(id: $0.key, frame: $0.frame)
    }
  }

  private func raiseNavigationWindow(_ selected: WindowKey) {
    guard let target = navigationWindows[selected] else { return }
    _ = AXUIElementPerformAction(target.window, kAXRaiseAction as CFString)
    _ = AXUIElementSetAttributeValue(
      target.window, kAXMainAttribute as CFString, kCFBooleanTrue)
    _ = AXUIElementSetAttributeValue(
      target.window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    DispatchQueue.main.async {
      guard let app = NSRunningApplication(processIdentifier: selected.pid) else { return }
      RunningApplicationActivation.activate(app, restoringMinimizedWindows: false)
    }
  }

  private func scheduleNavigationRefresh(pid: pid_t, screens: [WindowScreenLayout]) {
    navigationBuildQueue.async { [weak self] in
      guard let self, let snapshot = self.loadNavigationWindows(pid: pid, screens: screens)
      else { return }
      self.queue.async { [weak self] in
        self?.installNavigationWindows(snapshot, pid: pid, screens: screens)
      }
    }
  }

  private func loadNavigationWindows(
    pid: pid_t, screens: [WindowScreenLayout]
  ) -> [NavigationWindow]? {
    guard let primaryHeight = WindowMover.primaryHeight(in: screens) else { return nil }
    let axApp = AXApp.make(pid: pid)
    AXUIElementSetMessagingTimeout(axApp, 1)
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &raw) == .success,
      let windows = raw as? [AXUIElement]
    else { return nil }
    var snapshot: [NavigationWindow] = []
    for window in windows {
      AXUIElementSetMessagingTimeout(window, 1)
      guard
        let geometry = WindowMover.readWindowGeometry(window: window, primaryHeight: primaryHeight),
        !geometry.minimized
      else { continue }
      let frame = geometry.frame
      guard frame.width > 0, frame.height > 0,
        screens.contains(where: { $0.frame.intersects(frame) })
      else { continue }
      let key = WindowKey(pid: pid, window: window)
      snapshot.append(
        NavigationWindow(key: key, window: window, frame: frame, subrole: geometry.subrole))
    }
    return snapshot
  }

  private func installNavigationWindows(
    _ snapshot: [NavigationWindow], pid: pid_t, screens: [WindowScreenLayout]
  ) {
    guard NSRunningApplication(processIdentifier: pid)?.isTerminated == false else { return }
    let previous = navigationWindows.filter { $0.key.pid == pid }
    navigationWindows = navigationWindows.filter { $0.key.pid != pid }
    for candidate in snapshot {
      let fresh =
        previous[candidate.key].flatMap {
          $0.updatedAt.uptimeNanoseconds > candidate.updatedAt.uptimeNanoseconds ? $0 : nil
        } ?? candidate
      navigationWindows[candidate.key] = fresh
      applyPlacementRule(pid: pid, window: candidate.window, screens: screens)
      adoptCatalogedLayout(fresh, pid: pid, screens: screens)
    }
    adoptForTiling(snapshot)
  }

  /// A cataloged window nothing tracks yet but that sits in a slot (placed
  /// before Flash started, by another tool, or while it was not looking) is
  /// adopted, so a display change keeps it there too. Only untracked windows,
  /// and never during a display change or right after Flash moved the window:
  /// a catalog frame read before either must not stand for the user's choice.
  private func adoptCatalogedLayout(
    _ candidate: NavigationWindow, pid: pid_t, screens: [WindowScreenLayout]
  ) {
    let key = candidate.key
    let now = DispatchTime.now()
    guard tiling == nil, tracked[key] == nil, !sessionSuspended, currentScreens == screens,
      now >= screenChangeActiveUntil,
      now >= (selfAuthoredChangesUntil[key] ?? DispatchTime(uptimeNanoseconds: 0)),
      let intent = WindowLayoutIntent.observed(
        frame: candidate.frame, screens: screens, existing: nil, declared: declaredLayouts)
    else { return }
    tracked[key] = TrackedLayout(pid: pid, window: candidate.window, intent: intent)
  }

  private func isMinimized(_ window: AXUIElement) -> Bool {
    var raw: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &raw)
        == .success
    else { return false }
    return raw as? Bool == true
  }

  func observedWindowEvent(
    pid: pid_t, window: AXUIElement?, notification: String,
    statusBarReservesSpace: Bool, statusBarMonitor: Config.StatusBar.Monitor
  ) {
    let screens = screenLayoutsProvider(statusBarReservesSpace, statusBarMonitor)
    queue.async { [weak self] in
      guard let self, !screens.isEmpty else { return }
      if notification == kAXUIElementDestroyedNotification as String, let window {
        let key = WindowKey(pid: pid, window: window)
        self.navigationWindows.removeValue(forKey: key)
        self.ruleChecks.forget(key)
        self.tiling?.forget(key)
      }
      // A minimized window leaves its tile; restored, the catalog brings it
      // back to the focused workspace.
      if notification == kAXWindowMiniaturizedNotification as String, let window {
        self.tiling?.forget(WindowKey(pid: pid, window: window))
      }
      if notification == kAXWindowCreatedNotification as String
        || notification == kAXUIElementDestroyedNotification as String
        || notification == kAXWindowMiniaturizedNotification as String
        || notification == kAXWindowDeminiaturizedNotification as String
      {
        self.scheduleNavigationRefresh(pid: pid, screens: screens)
      }
      // A new window is checked against the rules once; a title change
      // later never re-checks it (`PlacementRuleChecks`).
      if notification == kAXWindowCreatedNotification as String, let window {
        self.applyPlacementRule(pid: pid, window: window, screens: screens)
      }
    }
  }

  private func applyPlacementRule(
    pid: pid_t, window: AXUIElement, screens: [WindowScreenLayout]
  ) {
    let key = WindowKey(pid: pid, window: window)
    guard tiling == nil, !placementRules.isEmpty, !sessionSuspended, !screens.isEmpty,
      let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    else { return }
    guard
      let rule = ruleChecks.rule(
        for: key, in: placementRules, bundleID: bundleID,
        title: {
          var rawTitle: CFTypeRef?
          return AXUIElementCopyAttributeValue(
            window, kAXTitleAttribute as CFString, &rawTitle) == .success
            ? rawTitle as? String : nil
        })
    else { return }
    guard
      let result = WindowMover.move(
        rule.move, targetPID: pid, screens: screens, window: window,
        existingLayout: { [weak self] window in
          self?.tracked[WindowKey(pid: pid, window: window)]?.intent.layout
        })
    else { return }
    ruleChecks.applied(key)
    if let cataloged = navigationWindows[key],
      let primaryHeight = WindowMover.primaryHeight(in: screens),
      let frame = WindowMover.readWindowFrameInNSCoords(
        window: window, primaryHeight: primaryHeight)
    {
      navigationWindows[key] = NavigationWindow(
        key: key, window: window, frame: frame, subrole: cataloged.subrole)
    }
    if let layout = result.layout {
      tracked[key] = TrackedLayout(
        pid: pid, window: window,
        intent: WindowLayoutIntent(layout: layout, placedOn: result.screen))
      selfAuthoredChangesUntil[key] = .now() + .milliseconds(Self.authoredChangeGraceMs)
    }
  }

  /// The session stopped or resumed being interactive (lock, sleep, screens
  /// asleep). Resuming restores every window whose layout did not land while
  /// it was away, re-reading the displays over the usual recovery passes.
  func setSessionSuspended(
    _ suspended: Bool,
    statusBarReservesSpace: Bool,
    statusBarMonitor: Config.StatusBar.Monitor,
    beforeRecoveryPass: (() -> Void)? = nil,
    afterRecoveryPass: (([WindowScreenLayout]) -> Void)? = nil
  ) {
    queue.async { [weak self] in
      guard let self, self.sessionSuspended != suspended else { return }
      self.sessionSuspended = suspended
      let displaysChanged =
        self.suspendedTopologyBaseline.map { $0 != self.currentScreens } ?? false
      guard !suspended, !self.pendingRestoreKeys.isEmpty || displaysChanged else {
        if !suspended { self.suspendedTopologyBaseline = nil }
        return
      }
      FlashLog.debug(
        "[placement] session_resumed pending=\(self.pendingRestoreKeys.count) "
          + "displays_changed=\(displaysChanged)")
      DispatchQueue.main.async { [weak self] in
        self?.screenParametersDidChange(
          statusBarReservesSpace: statusBarReservesSpace,
          statusBarMonitor: statusBarMonitor,
          beforeRecoveryPass: beforeRecoveryPass,
          afterRecoveryPass: afterRecoveryPass)
      }
    }
  }

  /// Reapply semantic layouts after any display topology or usable-frame
  /// change. Repeated bounded passes cover apps that perform their own delayed
  /// relocation after AppKit's screen notification; a newer notification
  /// cancels the older recovery generation. `beforeRecoveryPass` runs on main
  /// ahead of each pass's geometry snapshot.
  func screenParametersDidChange(
    statusBarReservesSpace: Bool,
    statusBarMonitor: Config.StatusBar.Monitor,
    forceRecovery: Bool = true,
    beforeRecoveryPass: (() -> Void)? = nil,
    afterRecoveryPass: (([WindowScreenLayout]) -> Void)? = nil
  ) {
    let provider = screenLayoutsProvider
    scheduleScreenRecovery(
      initialScreens: provider(statusBarReservesSpace, statusBarMonitor),
      forceRecovery: forceRecovery,
      settledScreens: {
        beforeRecoveryPass?()
        return provider(statusBarReservesSpace, statusBarMonitor)
      },
      afterRecoveryPass: afterRecoveryPass)
  }

  /// Value-only entry point so display handoff scheduling can be exercised
  /// without asking AppKit for the host's real screen topology.
  func screenParametersDidChange(
    screens: [WindowScreenLayout],
    afterRecoveryPass: (([WindowScreenLayout]) -> Void)? = nil
  ) {
    scheduleScreenRecovery(
      initialScreens: screens,
      forceRecovery: false,
      settledScreens: { screens },
      afterRecoveryPass: afterRecoveryPass)
  }

  private func scheduleScreenRecovery(
    initialScreens: [WindowScreenLayout],
    forceRecovery: Bool,
    settledScreens: @escaping () -> [WindowScreenLayout],
    afterRecoveryPass: (([WindowScreenLayout]) -> Void)?
  ) {
    queue.async { [weak self] in
      guard let self else { return }
      // While suspended, keep the displays from before the first change;
      // the first pass after resuming measures the change from them.
      if self.sessionSuspended, self.suspendedTopologyBaseline == nil,
        !self.currentScreens.isEmpty
      {
        self.suspendedTopologyBaseline = self.currentScreens
      }
      let previousScreens =
        self.sessionSuspended
        ? self.currentScreens : self.suspendedTopologyBaseline ?? self.currentScreens
      if !self.sessionSuspended { self.suspendedTopologyBaseline = nil }
      if !initialScreens.isEmpty { self.currentScreens = initialScreens }
      guard !previousScreens.isEmpty, !initialScreens.isEmpty,
        forceRecovery || previousScreens != initialScreens
      else { return }

      FlashLog.debug(
        "[placement] screen_change screens=\(initialScreens.count) "
          + "tracked=\(self.tracked.count) "
          + "usable=\(initialScreens.map { NSStringFromRect($0.usableFrame) }.joined(separator: " "))"
      )
      let now = DispatchTime.now()
      let continuingChange = now < self.screenChangeActiveUntil
      if !continuingChange {
        self.screenChangeKeys = Set(self.tracked.keys)
        self.screenChangeBaseline = previousScreens
        self.screenChangeTopologyChanged = previousScreens != initialScreens
      } else {
        self.screenChangeKeys.formUnion(self.tracked.keys)
        if previousScreens != initialScreens { self.screenChangeTopologyChanged = true }
      }
      self.screenChangeActiveUntil =
        now + .milliseconds((self.screenRecoveryDelaysMs.last ?? 0) + Self.authoredChangeGraceMs)
      self.screenChangeGeneration &+= 1
      let generation = self.screenChangeGeneration
      let lastDelayMs = self.screenRecoveryDelaysMs.last

      for delayMs in self.screenRecoveryDelaysMs {
        // AppKit may deliver the notification before NSScreen.main and
        // visibleFrame settle. Re-snapshot on main for every bounded pass
        // instead of replaying the notification's transitional geometry.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
          let screens = settledScreens()
          self?.queue.async { [weak self] in
            guard let self, self.screenChangeGeneration == generation else { return }
            if !screens.isEmpty {
              self.currentScreens = screens
              self.tiling?.setScreens(screens)
              self.restoreTrackedLayouts(self.screenChangeKeys, using: screens)
              if self.screenChangeTopologyChanged {
                self.fitWindowsLeftOffTheDisplays(
                  previous: self.screenChangeBaseline, current: screens)
              }
              if let afterRecoveryPass {
                DispatchQueue.main.async {
                  afterRecoveryPass(screens)
                }
              }
            }
            if delayMs == lastDelayMs {
              self.screenChangeKeys.removeAll()
            }
          }
        }
      }
    }
  }

  /// Track native/dragged named-slot changes too, retain an explicitly applied
  /// proportional intent while its frame still matches, and forget Flash-owned
  /// layout as soon as the user moves the window to an arbitrary frame. The AX
  /// observer supplies the exact focused-window element, so multiple windows
  /// belonging to the same process remain independent.
  func observedWindowFrameChange(
    pid: pid_t,
    window: AXUIElement,
    frame: CGRect,
    notification: String,
    statusBarReservesSpace: Bool,
    statusBarMonitor: Config.StatusBar.Monitor
  ) {
    let screens = screenLayoutsProvider(statusBarReservesSpace, statusBarMonitor)
    queue.async { [weak self] in
      guard let self else { return }
      let key = WindowKey(pid: pid, window: window)
      if notification == kAXUIElementDestroyedNotification as String {
        self.tracked.removeValue(forKey: key)
        self.selfAuthoredChangesUntil.removeValue(forKey: key)
        self.pendingRestoreKeys.remove(key)
        self.navigationWindows.removeValue(forKey: key)
        self.ruleChecks.forget(key)
        return
      }
      if let cataloged = self.navigationWindows[key] {
        self.navigationWindows[key] = NavigationWindow(
          key: key, window: window, frame: frame, subrole: cataloged.subrole)
      }
      // AppKit can publish the new NSScreen topology before delivering its
      // screen-parameters notification. Do not mistake macOS's interim window
      // relocation for a user-authored free-form resize and erase the slot we
      // are about to restore.
      if self.currentScreens != screens {
        return
      }
      // Nobody moves windows on a locked screen: frames changing then are
      // macOS relocating them, and a window still waiting for its layout must
      // not have it erased by the displaced frame it is waiting to leave.
      if self.sessionSuspended || self.pendingRestoreKeys.contains(key) { return }
      let now = DispatchTime.now()
      if now < self.screenChangeActiveUntil
        || now < (self.selfAuthoredChangesUntil[key] ?? DispatchTime(uptimeNanoseconds: 0))
      {
        return
      }
      self.selfAuthoredChangesUntil.removeValue(forKey: key)
      if self.tiling?.manages(key) == true {
        self.scheduleTilingSettle(
          key, resized: notification == kAXWindowResizedNotification as String)
        return
      }
      self.recordObservedLayout(
        key: key, pid: pid, window: window, frame: frame, screens: screens)
    }
  }

  /// Classify the focused window when Flash first observes it, not only after
  /// it moves. A window that was already tiled/maximized before Flash launched
  /// must still survive the first display handoff.
  func observedFocusedWindow(
    pid: pid_t,
    window: AXUIElement,
    statusBarReservesSpace: Bool,
    statusBarMonitor: Config.StatusBar.Monitor
  ) {
    let screens = screenLayoutsProvider(statusBarReservesSpace, statusBarMonitor)
    queue.async { [weak self] in
      guard let self, let primaryHeight = WindowMover.primaryHeight(in: screens) else { return }
      let key = WindowKey(pid: pid, window: window)
      self.focusedWindowKey = key
      self.appCycleRun = self.appCycleRun?.observing(key)
      self.tiling?.focus(key)
      if self.currentScreens.isEmpty { self.currentScreens = screens }
      guard self.currentScreens == screens else { return }
      self.scheduleNavigationRefresh(pid: pid, screens: screens)
      // Nil for no user window too: clicking the desktop focuses Finder's
      // full-screen `AXScrollArea`, which must never be tracked or placed.
      let geometry = WindowMover.readWindowGeometry(window: window, primaryHeight: primaryHeight)
      let frame = geometry?.frame
      if let geometry {
        let cataloged = NavigationWindow(
          key: key, window: window, frame: geometry.frame, subrole: geometry.subrole)
        self.navigationWindows[key] = cataloged
        // A new window tiles when it is focused, before the catalog refresh.
        if !geometry.minimized, screens.contains(where: { $0.frame.intersects(geometry.frame) }) {
          self.adoptForTiling([cataloged])
        }
      }
      if self.pendingRestoreKeys.contains(key) {
        // Its layout never landed (the frame was unreadable then); the user
        // is looking at it now, so put it right.
        self.restoreTrackedLayouts([key], using: screens)
        return
      }
      let now = DispatchTime.now()
      guard now >= self.screenChangeActiveUntil,
        now >= (self.selfAuthoredChangesUntil[key] ?? DispatchTime(uptimeNanoseconds: 0)),
        let frame
      else { return }
      self.selfAuthoredChangesUntil.removeValue(forKey: key)
      self.recordObservedLayout(
        key: key, pid: pid, window: window, frame: frame, screens: screens)
      self.applyPlacementRule(pid: pid, window: window, screens: screens)
    }
  }

  /// `home`: the departed display a recovered, untracked window belongs to.
  private func recordObservedLayout(
    key: WindowKey,
    pid: pid_t,
    window: AXUIElement,
    frame: CGRect,
    screens: [WindowScreenLayout],
    home: String? = nil
  ) {
    guard tiling?.manages(key) != true else { return }
    guard
      let intent = WindowLayoutIntent.observed(
        frame: frame, screens: screens, existing: tracked[key]?.intent,
        declared: declaredLayouts, home: home)
    else {
      tracked.removeValue(forKey: key)
      return
    }
    tracked[key] = TrackedLayout(pid: pid, window: window, intent: intent)
  }

  private enum RestoreOutcome {
    case restored, alreadyCorrect, refused, unreadable
    /// Minimized: no frame is written to a window nobody sees; it is put in
    /// its slot when it is focused again.
    case minimized
  }

  private func restoreTrackedLayouts(_ keys: Set<WindowKey>, using screens: [WindowScreenLayout]) {
    guard !keys.isEmpty,
      let primaryHeight = WindowMover.primaryHeight(in: screens)
    else { return }
    guard !sessionSuspended else {
      pendingRestoreKeys.formUnion(keys.filter { tracked[$0] != nil })
      FlashLog.debug(
        "[placement] restore_deferred reason=session_suspended "
          + "pending=\(pendingRestoreKeys.count)")
      return
    }
    var counts: [RestoreOutcome: Int] = [:]
    var dropped = 0
    for key in keys {
      guard var layout = tracked[key] else {
        pendingRestoreKeys.remove(key)
        dropped += 1
        continue
      }
      guard NSRunningApplication(processIdentifier: layout.pid)?.isTerminated == false else {
        tracked.removeValue(forKey: key)
        selfAuthoredChangesUntil.removeValue(forKey: key)
        pendingRestoreKeys.remove(key)
        dropped += 1
        continue
      }
      let bundleIdentifier =
        NSRunningApplication(processIdentifier: layout.pid)?.bundleIdentifier
      let axApp = AXApp.make(pid: layout.pid)
      let outcome = GeckoAccessibility.withWindowManagement(
        pid: layout.pid,
        bundleIdentifier: bundleIdentifier,
        app: axApp
      ) { axApp, prepareGeometry -> RestoreOutcome in
        if isMinimized(layout.window) { return .minimized }
        guard
          let current = WindowMover.readWindowFrameInNSCoords(
            window: layout.window,
            primaryHeight: primaryHeight),
          let plan = layout.intent.recoveryPlan(currentFrame: current, screens: screens)
        else { return .unreadable }
        layout.intent.recovered(on: plan.screen)
        guard !WindowMover.framesMatchPlacement(current, plan.frame) else {
          return .alreadyCorrect
        }
        let startedAt = DispatchTime.now()
        prepareGeometry()
        let applied = WindowMover.apply(
          rect: plan.frame,
          toWindow: layout.window,
          axApp: axApp,
          primaryHeight: primaryHeight,
          bundleIdentifier: bundleIdentifier,
          from: current,
          within: plan.screen.usableFrame)
        let elapsedMs = WindowMover.elapsedMs(since: startedAt)
        if elapsedMs >= 100 {
          FlashLog.warn(
            "[placement] slow restore pid=\(layout.pid) "
              + "layout=\(WindowMover.description(of: layout.intent.layout)) "
              + "elapsed_ms=\(Int(elapsedMs.rounded()))")
        }
        switch applied.outcome {
        case .converged: return .restored
        case .refused: return .refused
        case .unreadable: return .unreadable
        }
      }
      counts[outcome, default: 0] += 1
      // An unreadable window keeps waiting (a locked or waking session), and
      // a minimized one until it is focused again; one that took its frame,
      // or whose app refused it, is done.
      if outcome == .unreadable || outcome == .minimized {
        pendingRestoreKeys.insert(key)
      } else {
        pendingRestoreKeys.remove(key)
      }
      tracked[key] = layout
      selfAuthoredChangesUntil[key] =
        .now() + .milliseconds(Self.authoredChangeGraceMs)
    }
    // Logged every pass, not only when something moved: a pass that restores
    // nothing because the windows were already dropped from tracking looks
    // identical to a pass that had nothing to do, and telling those apart is
    // the whole question when a restore does not stick.
    FlashLog.debug(
      "[placement] restore_pass considered=\(keys.count) "
        + "restored=\(counts[.restored] ?? 0) already_correct=\(counts[.alreadyCorrect] ?? 0) "
        + "refused=\(counts[.refused] ?? 0) unreadable=\(counts[.unreadable] ?? 0) "
        + "minimized=\(counts[.minimized] ?? 0) "
        + "untracked=\(dropped) pending=\(pendingRestoreKeys.count)")
  }

  /// macOS moves background windows onto a remaining display and leaves the
  /// frontmost one at the old size. Anything already tracked was restored
  /// above. This pass scales the rest onto a connected display.
  private func fitWindowsLeftOffTheDisplays(
    previous: [WindowScreenLayout], current: [WindowScreenLayout]
  ) {
    guard !sessionSuspended,
      let primaryHeight = WindowMover.primaryHeight(in: current)
    else { return }
    let flashPID = ProcessInfo.processInfo.processIdentifier
    let pids = recoveryApplications().compactMap { app -> pid_t? in
      guard app.activationPolicy == .regular, !app.isTerminated,
        app.processIdentifier != flashPID
      else { return nil }
      return app.processIdentifier
    }
    var fitted = 0
    for pid in pids {
      guard let windows = loadRecoveryWindows(pid: pid, primaryHeight: primaryHeight) else {
        continue
      }
      let bundleIdentifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
      let axApp = AXApp.make(pid: pid)
      for candidate in windows {
        let key = candidate.key
        if tracked[key] != nil || tiling?.manages(key) == true { continue }
        guard
          let frame = WindowMover.relocatedFrame(
            candidate.frame, from: previous, to: current)
        else { continue }
        let outcome = GeckoAccessibility.withWindowManagement(
          pid: pid,
          bundleIdentifier: bundleIdentifier,
          app: axApp
        ) { axApp, prepareGeometry -> RestoreOutcome in
          prepareGeometry()
          switch WindowMover.apply(
            rect: frame,
            toWindow: candidate.window,
            axApp: axApp,
            primaryHeight: primaryHeight,
            bundleIdentifier: bundleIdentifier,
            from: candidate.frame,
            within: WindowMover.screenContaining(frame: frame, screens: current)?.usableFrame
              ?? frame
          ).outcome {
          case .converged: return .restored
          case .refused: return .refused
          case .unreadable: return .unreadable
          }
        }
        if outcome == .restored {
          fitted += 1
          selfAuthoredChangesUntil[key] = .now() + .milliseconds(Self.authoredChangeGraceMs)
          // A slot the fit lands in belongs to the display that left: the
          // window goes back there when it returns.
          let departed = WindowMover.screenOwning(frame: candidate.frame, screens: previous)
            .flatMap { screen in
              current.contains { $0.identity == screen.identity } ? nil : screen.identity
            }
          recordObservedLayout(
            key: key, pid: pid, window: candidate.window, frame: frame, screens: current,
            home: departed)
        }
      }
    }
    if fitted > 0 {
      FlashLog.debug("[placement] fit_stranded count=\(fitted)")
    }
  }

  private func loadRecoveryWindows(
    pid: pid_t, primaryHeight: CGFloat
  ) -> [NavigationWindow]? {
    let axApp = AXApp.make(pid: pid)
    AXUIElementSetMessagingTimeout(axApp, 1)
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &raw) == .success,
      let windows = raw as? [AXUIElement]
    else { return nil }
    var snapshot: [NavigationWindow] = []
    for window in windows {
      AXUIElementSetMessagingTimeout(window, 1)
      // Windows of every subrole, a palette left behind included, but never
      // Finder's desktop, which Finder lists among its windows: one read.
      guard
        let geometry = WindowMover.readWindowGeometry(
          window: window, primaryHeight: primaryHeight, subroles: nil),
        !geometry.minimized, geometry.frame.width > 1, geometry.frame.height > 1
      else { continue }
      let frame = geometry.frame
      snapshot.append(
        NavigationWindow(key: WindowKey(pid: pid, window: window), window: window, frame: frame))
    }
    return snapshot
  }

  // MARK: Tiling

  fileprivate var tilingEngine: TilingEngine<WindowLayoutManager>? { tiling }

  fileprivate func screenLayouts(
    _ statusBarReservesSpace: Bool, _ statusBarMonitor: Config.StatusBar.Monitor
  ) -> [WindowScreenLayout] {
    screenLayoutsProvider(statusBarReservesSpace, statusBarMonitor)
  }

  fileprivate func applyTilingSettings(_ settings: TilingSettings, screens: [WindowScreenLayout]) {
    if !settings.persist {
      PollScheduler.shared.unregister("core:tiling_save")
      tilingStore.remove()
    }
    guard settings.enabled else {
      guard let engine = tiling else { return }
      if settings.persist && engine.settings.persist { tilingStore.save(engine.snapshot()) }
      PollScheduler.shared.unregister("core:tiling_save")
      engine.releaseAll()
      tiling = nil
      DispatchQueue.main.async { [weak self] in self?.tilingStatusDidChange?(nil) }
      FlashLog.info("[tiling] stopped")
      return
    }
    if let engine = tiling {
      engine.update(settings)
      return
    }
    let engine = TilingEngine(driver: self, settings: settings)
    if settings.persist {
      if let saved = tilingStore.load() { engine.restore(saved) }
    } else {
      tilingStore.remove()
    }
    engine.layoutDidChange = { [weak self, weak engine] in
      guard let self, let engine, engine.settings.persist else { return }
      // Only while layout mutations await a save; coalesce a catalog batch.
      PollScheduler.shared.scheduleOnce(
        "core:tiling_save", afterMs: 150, priority: .low, on: self.queue
      ) { [weak self, weak engine] in
        guard let self, let engine, self.tiling === engine, engine.settings.persist else { return }
        self.tilingStore.save(engine.snapshot())
      }
    }
    engine.statusDidChange = { [weak self] status in
      DispatchQueue.main.async { self?.tilingStatusDidChange?(status) }
    }
    tiling = engine
    let start = screens.isEmpty ? currentScreens : screens
    if !start.isEmpty { currentScreens = start }
    engine.setScreens(currentScreens)
    adoptForTiling(Array(navigationWindows.values))
    if let focused = focusedWindowKey { engine.focus(focused) }
    FlashLog.info("[tiling] started", fields: ["windows": String(navigationWindows.count)])
  }

  /// Cataloged windows tiling does not manage yet; a window tiling takes
  /// leaves layout tracking.
  private func adoptForTiling(_ windows: [NavigationWindow]) {
    guard let tiling else { return }
    let candidates = windows.filter { !tiling.manages($0.key) }.map { window in
      TilingEngine<WindowLayoutManager>.Candidate(
        key: window.key, pid: window.key.pid,
        bundleID: NSRunningApplication(processIdentifier: window.key.pid)?.bundleIdentifier,
        frame: window.frame, subrole: window.subrole)
    }
    guard !candidates.isEmpty else { return }
    for candidate in candidates { tracked.removeValue(forKey: candidate.key) }
    tiling.adopt(candidates)
    // Focus reported before the window joined: tile commands act on it now.
    if let focusedWindowKey, candidates.contains(where: { $0.key == focusedWindowKey }) {
      tiling.focus(focusedWindowKey)
    }
  }

  /// A tiled window moved or resized by hand: settle once the mouse button
  /// is up, so a drag is judged where it ends. `core:tiling_settle`,
  /// priority `high`, re-armed by every move while a drag lasts, armed only
  /// then. A resize notification anywhere in the drag makes it a resize.
  private func scheduleTilingSettle(_ key: WindowKey, resized: Bool) {
    if tilingDragKey != key { tilingDragResized = false }
    tilingDragKey = key
    tilingDragResized = tilingDragResized || resized
    PollScheduler.shared.scheduleOnce(
      "core:tiling_settle", afterMs: 200, priority: .high, on: queue
    ) { [weak self] in
      self?.settleTilingDrag()
    }
  }

  /// The drag ended: its frame read from the window that fired, and for a
  /// move the pointer, read once, so the drop is judged where the hand let
  /// go rather than where the window's frame happens to be.
  private func settleTilingDrag() {
    guard let key = tilingDragKey, let tiling else { return }
    if CGEventSource.buttonState(.hidSystemState, button: .left) {
      scheduleTilingSettle(key, resized: false)
      return
    }
    let resized = tilingDragResized
    tilingDragKey = nil
    tilingDragResized = false
    guard let primaryHeight = WindowMover.primaryHeight(in: currentScreens),
      let frame = WindowMover.readWindowFrameInNSCoords(
        window: key.window, primaryHeight: primaryHeight)
    else { return }
    if resized {
      tiling.userResized(key, to: frame)
      return
    }
    let pointer = CGEvent(source: nil).map {
      CGPoint(x: $0.location.x, y: primaryHeight - $0.location.y)
    }
    tiling.userMoved(key, to: frame, at: pointer)
  }

  fileprivate var currentScreensForTiling: [WindowScreenLayout] { currentScreens }

  /// A tiled window's frame through the window mover, marked as Flash's own
  /// so its echo is not read as the user's.
  fileprivate func applyTiledFrame(_ frame: CGRect, to key: WindowKey, within bounds: CGRect) {
    guard let primaryHeight = WindowMover.primaryHeight(in: currentScreens) else { return }
    let current =
      WindowMover.readWindowFrameInNSCoords(window: key.window, primaryHeight: primaryHeight)
      ?? frame
    let bundleIdentifier = NSRunningApplication(processIdentifier: key.pid)?.bundleIdentifier
    selfAuthoredChangesUntil[key] = .now() + .milliseconds(Self.authoredChangeGraceMs)
    tracked.removeValue(forKey: key)
    _ = GeckoAccessibility.withWindowManagement(
      pid: key.pid, bundleIdentifier: bundleIdentifier, app: AXApp.make(pid: key.pid)
    ) { axApp, prepareGeometry -> WindowMover.Placement in
      prepareGeometry()
      return WindowMover.apply(
        rect: frame, toWindow: key.window, axApp: axApp, primaryHeight: primaryHeight,
        bundleIdentifier: bundleIdentifier, from: current, within: bounds)
    }
    if let cataloged = navigationWindows[key] {
      navigationWindows[key] = NavigationWindow(
        key: key, window: key.window, frame: frame, subrole: cataloged.subrole)
    }
  }

  /// Park a window of a hidden workspace: only its position, so its top-left
  /// corner sits at `corner` and its size is kept for its return.
  fileprivate func parkTiledWindow(_ key: WindowKey, topLeft: CGPoint) {
    guard let primaryHeight = WindowMover.primaryHeight(in: currentScreens) else { return }
    var point = ScreenPoint<NSSpace>(topLeft).toAX(primaryHeight: primaryHeight).cgPoint
    guard let value = AXValueCreate(.cgPoint, &point) else { return }
    selfAuthoredChangesUntil[key] = .now() + .milliseconds(Self.authoredChangeGraceMs)
    AXUIElementSetMessagingTimeout(key.window, AXApp.defaultMessagingTimeout)
    let status = AXUIElementSetAttributeValue(
      key.window, kAXPositionAttribute as CFString, value)
    if status != .success {
      FlashLog.debug(
        "[tiling] park_failed", fields: ["pid": String(key.pid), "status": "\(status.rawValue)"])
    }
  }

  func appDidTerminate(pid: pid_t) {
    queue.async { [weak self] in
      guard let self else { return }
      let keys = self.tracked.keys.filter { $0.pid == pid }
      for key in keys {
        self.tracked.removeValue(forKey: key)
        self.selfAuthoredChangesUntil.removeValue(forKey: key)
        self.screenChangeKeys.remove(key)
        self.pendingRestoreKeys.remove(key)
      }
      self.minimizedByFlash.removeAll { $0.pid == pid }
      self.navigationWindows = self.navigationWindows.filter { $0.key.pid != pid }
      self.ruleChecks.forget { $0.pid == pid }
      self.tiling?.forget(pid: pid)
      if self.focusedWindowKey?.pid == pid { self.focusedWindowKey = nil }
    }
  }
}

/// Implements the `window move` named/proportional layout and screen-selection
/// options against the focused application's focused window via Accessibility. When the
/// persistent Flash status bar is active, every target rect is computed
/// from the screen frame after reserving the top status band, even if
/// macOS temporarily reports a full-height `visibleFrame`.
///
/// Coordinate spaces:
///   - `NSScreen.frame` / `NSScreen.visibleFrame` use the primary
///     screen's bottom-left as `(0, 0)` with Y growing upward.
///   - `kAXPositionAttribute` uses the primary screen's TOP-LEFT as
///     `(0, 0)` with Y growing downward.
/// All math is done in NSScreen space; conversion to AX coordinates
/// happens once at the call to `AXValueCreate`.
extension WindowLayoutManager {
  /// `[tiling]` after a configuration load: start tiling the cataloged
  /// windows, update its settings, or stop and show every parked window.
  func configureTiling(
    _ settings: TilingSettings, statusBarReservesSpace: Bool,
    statusBarMonitor: Config.StatusBar.Monitor
  ) {
    let screens = screenLayouts(statusBarReservesSpace, statusBarMonitor)
    queue.async { [weak self] in self?.applyTilingSettings(settings, screens: screens) }
  }

  /// `tile …`; `completion` runs on main.
  func performTiling(_ command: TilingCommand, completion: @escaping (TilingOutcome) -> Void) {
    queue.async { [weak self] in
      let outcome = self?.tilingEngine?.perform(command) ?? .disabled
      DispatchQueue.main.async { completion(outcome) }
    }
  }

  /// `workspace …`; `completion` runs on main.
  func performWorkspace(
    _ command: WorkspaceCommand, completion: @escaping (TilingOutcome) -> Void
  ) {
    queue.async { [weak self] in
      let outcome = self?.tilingEngine?.perform(command) ?? .disabled
      DispatchQueue.main.async { completion(outcome) }
    }
  }

  /// Quit: every parked window back on screen, waited for at most `timeout`
  /// (a hung app must not hold the quit).
  func releaseTiling(timeout: TimeInterval = 2) {
    let done = DispatchSemaphore(value: 0)
    queue.async { [weak self] in
      if let self, let engine = self.tilingEngine {
        if engine.settings.persist { self.tilingStore.save(engine.snapshot()) }
        engine.releaseAll()
      }
      done.signal()
    }
    _ = done.wait(timeout: .now() + timeout)
  }
}

enum WindowMover {

  struct MoveResult {
    let window: AXUIElement
    let layout: WindowLayout?
    /// The display the window was placed on.
    let screen: WindowScreenLayout
  }

  struct FramePlan {
    let frame: CGRect
    let layout: WindowLayout?
  }

  struct LayoutRecoveryPlan {
    let screen: WindowScreenLayout
    let frame: CGRect
  }

  /// Snapshot AppKit-owned screen state on the main thread before any AX work
  /// moves to the background queue. `NSScreen` is an AppKit object; the plain
  /// value layouts below are safe to carry onto `WindowLayoutManager.queue`.
  static func screenLayouts(
    statusBarReservesSpace: Bool,
    statusBarMonitor: Config.StatusBar.Monitor
  ) -> [WindowScreenLayout] {
    screenLayouts(
      // NSScreenNumber is present for physical displays. Keep a deterministic
      // fallback for virtual/test screens rather than dropping the layout.
      screens: NSScreen.screens.enumerated().map { index, screen in
        (
          id: screen.displayID ?? CGDirectDisplayID(index + 1), frame: screen.frame,
          visibleFrame: screen.visibleFrame
        )
      },
      snapshot: OverlayPanel.currentScreenSnapshot(),
      statusBarReservesSpace: statusBarReservesSpace, statusBarMonitor: statusBarMonitor,
      identities: Dictionary(
        NSScreen.screens.compactMap { screen in
          screen.displayID.flatMap { id in displayIdentity(id).map { (id, $0) } }
        }, uniquingKeysWith: { first, _ in first }))
  }

  /// Each display's slots: its live visible frame, less the status bar band
  /// on displays showing the bar. The band is the snapshot's
  /// `statusBarHeight`, the very value the bar is painted with, so a slot's
  /// top edge is the bar's bottom edge even when the live visible frame has
  /// moved since the snapshot.
  /// `identities`: each display's UUID by id (`displayIdentity`).
  static func screenLayouts(
    screens: [(id: CGDirectDisplayID, frame: CGRect, visibleFrame: CGRect)],
    snapshot: OverlayPanel.ScreenSnapshot,
    statusBarReservesSpace: Bool,
    statusBarMonitor: Config.StatusBar.Monitor,
    identities: [CGDirectDisplayID: String] = [:]
  ) -> [WindowScreenLayout] {
    let mainFrame = (screens.first { $0.frame.origin == .zero } ?? screens.first)?.frame
    return screens.map { screen in
      let reserves = shouldReserveStatusBarSpace(
        statusBarVisible: statusBarReservesSpace, monitor: statusBarMonitor,
        isMainScreen: screen.frame == mainFrame)
      return WindowScreenLayout(
        id: screen.id,
        frame: screen.frame,
        usableFrame: usableFrame(
          screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
          statusBarHeight: reserves ? snapshot.statusBarHeight(forScreenFrame: screen.frame) : nil),
        identity: identities[screen.id])
    }
  }

  /// The display's UUID (`CGDisplayCreateUUIDFromDisplayID`, about 10 µs), or
  /// nil for a display macOS gives none.
  static func displayIdentity(_ id: CGDirectDisplayID) -> String? {
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
    return CFUUIDCreateString(nil, uuid) as String?
  }

  static func shouldReserveStatusBarSpace(
    statusBarVisible: Bool,
    monitor: Config.StatusBar.Monitor,
    isMainScreen: Bool
  ) -> Bool {
    statusBarVisible && (monitor == .all || isMainScreen)
  }

  static func primaryHeight(in screens: [WindowScreenLayout]) -> CGFloat? {
    screens.first(where: { $0.frame.origin == .zero })?.frame.height
      ?? screens.first?.frame.height
  }

  static func move(
    _ params: MoveWindowParams,
    targetPID: pid_t,
    screens: [WindowScreenLayout],
    window: AXUIElement? = nil,
    existingLayout: (AXUIElement) -> WindowLayout?
  ) -> MoveResult? {
    let startedAt = DispatchTime.now()
    let axApp = AXApp.make(pid: targetPID)
    let bundleIdentifier =
      NSRunningApplication(processIdentifier: targetPID)?.bundleIdentifier
    return GeckoAccessibility.withWindowManagement(
      pid: targetPID,
      bundleIdentifier: bundleIdentifier,
      app: axApp
    ) { axApp, prepareGeometry in
      move(
        params,
        targetPID: targetPID,
        screens: screens,
        startedAt: startedAt,
        axApp: axApp,
        bundleIdentifier: bundleIdentifier,
        prepareGeometry: prepareGeometry,
        window: window,
        existingLayout: existingLayout)
    }
  }

  @discardableResult
  static func setWindowState(
    _ action: WindowStateAction, targetPID: pid_t, restoreWindow: AXUIElement? = nil
  ) -> AXUIElement? {
    let axApp = AXApp.make(pid: targetPID)
    let window: AXUIElement?
    switch action {
    case .restore:
      if let restoreWindow {
        window = restoreWindow
      } else {
        var rawWindows: CFTypeRef?
        guard
          AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &rawWindows)
            == .success, let windows = rawWindows as? [AXUIElement]
        else { return nil }
        window = windows.first { readBoolean($0, attribute: kAXMinimizedAttribute) == true }
      }
    case .minimize, .fullscreen:
      window = resolveWindow(axApp)?.window
    }
    guard let window else {
      FlashLog.warn("[window] no target window for pid \(targetPID)")
      return nil
    }
    AXUIElementSetMessagingTimeout(window, AXApp.defaultMessagingTimeout)

    let attribute: String
    let desired: Bool
    switch action {
    case .minimize:
      attribute = kAXMinimizedAttribute
      desired = true
      if readBoolean(window, attribute: attribute) == true { return nil }
    case .restore:
      attribute = kAXMinimizedAttribute
      desired = false
      guard readBoolean(window, attribute: attribute) == true else { return nil }
    case .fullscreen(let state):
      attribute = "AXFullScreen"
      guard let current = readBoolean(window, attribute: attribute) else {
        FlashLog.warn("[window] full screen unsupported for pid \(targetPID)")
        return nil
      }
      switch state {
      case .on: desired = true
      case .off: desired = false
      case .toggle: desired = !current
      }
      if desired == current { return window }
    }
    guard
      AXUIElementSetAttributeValue(
        window, attribute as CFString,
        desired ? kCFBooleanTrue : kCFBooleanFalse) == .success
    else {
      FlashLog.warn("[window] cannot set \(attribute) for pid \(targetPID)")
      return nil
    }
    if case .restore = action {
      _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
      DispatchQueue.main.async {
        guard let app = NSRunningApplication(processIdentifier: targetPID) else { return }
        RunningApplicationActivation.activate(app, restoringMinimizedWindows: false)
      }
    }
    return window
  }

  /// Validate `window` as a live window of `pid`, unminimize it and raise it
  /// as its app's main and focused window. False, touching nothing, when
  /// the element is gone or is no window of `pid`.
  static func raiseSwitcherWindow(_ window: AXUIElement, pid: pid_t) -> Bool {
    var owner: pid_t = 0
    guard AXUIElementGetPid(window, &owner) == .success, owner == pid else { return false }
    AXUIElementSetMessagingTimeout(window, 1)
    var role: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role) == .success,
      role as? String == kAXWindowRole as String
    else { return false }
    if readBoolean(window, attribute: kAXMinimizedAttribute) == true {
      guard
        AXUIElementSetAttributeValue(
          window, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success
      else { return false }
    }
    _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    _ = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    return true
  }

  private static func readBoolean(_ window: AXUIElement, attribute: String) -> Bool? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, attribute as CFString, &raw) == .success else {
      return nil
    }
    return raw as? Bool
  }

  private static func move(
    _ params: MoveWindowParams,
    targetPID: pid_t,
    screens: [WindowScreenLayout],
    startedAt: DispatchTime,
    axApp: AXUIElement,
    bundleIdentifier: String?,
    prepareGeometry: () -> Void,
    window explicitWindow: AXUIElement?,
    existingLayout: (AXUIElement) -> WindowLayout?
  ) -> MoveResult? {

    // Resolve the window to move. Three fallbacks because Flash holds
    // key focus during normal-mode capture, so AX answers vary by app:
    //   1. `kAXFocusedWindow`  — only populated when the target app is
    //                            the focused process (i.e. Cocoa apps
    //                            with retained focus state). Often nil.
    //   2. `kAXMainWindow`     — the app's frontmost window regardless
    //                            of who owns the keyboard. Cocoa apps
    //                            track this; some non-Cocoa apps (e.g.
    //                            Alacritty) leave it unset.
    //   3. `kAXWindows[0]`     — the first entry in the app's window
    //                            list, ordered front-to-back by AX.
    //                            Works for Alacritty et al. that only
    //                            expose the list.
    let resolveStartedAt = DispatchTime.now()
    guard
      let resolution = explicitWindow.map({ (window: $0, source: "observed") })
        ?? resolveWindow(axApp)
    else {
      FlashLog.warn(
        "[window] no AX window for pid \(targetPID)")
      return nil
    }
    let window = resolution.window
    let resolveMs = elapsedMs(since: resolveStartedAt)
    // The window element does not inherit the app element's timeout.
    AXUIElementSetMessagingTimeout(window, AXApp.defaultMessagingTimeout)

    guard let primaryHeight = primaryHeight(in: screens) else { return nil }
    let frameStartedAt = DispatchTime.now()
    guard
      let currentFrame = readWindowFrameInNSCoords(
        window: window, primaryHeight: primaryHeight)
    else { return nil }
    let frameMs = elapsedMs(since: frameStartedAt)
    let currentIndex = screenIndex(forFrame: currentFrame, screens: screens)
    let targetIndex = relativeScreenIndex(
      from: currentIndex, offset: params.screen, screens: screens)
    let currentScreen = screens[currentIndex]
    let targetScreen = screens[targetIndex]
    guard
      let plan = framePlan(
        currentFrame: currentFrame,
        from: currentScreen,
        to: targetScreen,
        currentLayout: existingLayout(window),
        requestedLayout: params.layout,
        screenChanged: targetIndex != currentIndex)
    else { return nil }
    let rect = plan.frame
    prepareGeometry()
    let applyStartedAt = DispatchTime.now()
    let placement = apply(
      rect: rect,
      toWindow: window,
      axApp: axApp,
      primaryHeight: primaryHeight,
      bundleIdentifier: bundleIdentifier,
      from: currentFrame,
      within: targetScreen.usableFrame)
    let applyMs = elapsedMs(since: applyStartedAt)
    let totalMs = elapsedMs(since: startedAt)
    let writes =
      placement.writes.isEmpty
      ? "none" : placement.writes.map(\.rawValue).joined(separator: ",")
    let timing =
      "pid=\(targetPID) bundle=\(bundleIdentifier ?? "-") source=\(resolution.source) "
      + "writes=\(writes) "
      + "corrections=\(placement.corrections) outcome=\(placement.outcome) "
      + "resolve_ms=\(String(format: "%.2f", resolveMs)) "
      + "frame_ms=\(String(format: "%.2f", frameMs)) "
      + "apply_ms=\(String(format: "%.2f", applyMs)) "
      + "total_ms=\(String(format: "%.2f", totalMs))"
    FlashLog.debug("[window] placed \(timing)")
    if totalMs >= 100 {
      FlashLog.warn(
        "[window] slow \(timing) "
          + "layout=\(plan.layout.map { description(of: $0) } ?? "arbitrary")")
    }
    return MoveResult(
      window: window,
      layout: plan.layout,
      screen: targetScreen)
  }

  /// Plan a move entirely in NSScreen coordinates. A requested layout wins;
  /// otherwise a screen-only move carries a still-matching tracked intent or
  /// recognized named slot onto the destination. Truly free-form frames are
  /// remapped proportionally without becoming managed layouts.
  static func framePlan(
    currentFrame: CGRect,
    from source: WindowScreenLayout,
    to destination: WindowScreenLayout,
    currentLayout: WindowLayout?,
    requestedLayout: WindowLayout?,
    screenChanged: Bool
  ) -> FramePlan? {
    if let requestedLayout {
      return FramePlan(
        frame: rectFor(layout: requestedLayout, in: destination.usableFrame),
        layout: requestedLayout)
    }
    guard screenChanged else { return nil }
    if let currentLayout,
      framesApproximatelyEqual(
        currentFrame,
        rectFor(layout: currentLayout, in: source.usableFrame))
    {
      return FramePlan(
        frame: rectFor(layout: currentLayout, in: destination.usableFrame),
        layout: currentLayout)
    }
    let sourcePosition = position(matching: currentFrame, in: source.usableFrame)
    if let sourcePosition {
      return FramePlan(
        frame: rectFor(position: sourcePosition, in: destination.usableFrame),
        layout: .position(sourcePosition))
    }
    return FramePlan(
      frame: remap(
        frame: currentFrame,
        from: source.usableFrame,
        to: destination.usableFrame),
      layout: nil)
  }

  /// Where a window should sit after a display is unplugged, when its frame
  /// no longer fits a connected screen. Nil when the window already fits, or
  /// when the move would not change it. A window that filled the departed
  /// display fills the display it lands on; one that merely overflows is
  /// pulled inside that display.
  static func relocatedFrame(
    _ frame: CGRect,
    from previous: [WindowScreenLayout],
    to current: [WindowScreenLayout]
  ) -> CGRect? {
    // A frame inside the connected displays, one or several (a window the
    // user stretched across two of them), was not left behind by any change.
    guard frame.width > 1, frame.height > 1, !current.isEmpty,
      !frameFits(frame, on: current), !frameIsCovered(frame, by: current)
    else { return nil }
    let onCurrent = screenOwning(frame: frame, screens: current)
    let source = screenOwning(frame: frame, screens: previous)
    // Misses every display we have seen: the user parked it off-screen.
    guard source != nil || onCurrent != nil else { return nil }
    let destination = onCurrent ?? current[0]
    let placed: CGRect
    if let source,
      !framesApproximatelyEqual(source.usableFrame, destination.usableFrame, tolerance: 1)
    {
      placed = fitted(
        remap(frame: frame, from: source.usableFrame, to: destination.usableFrame),
        within: destination.usableFrame)
    } else {
      placed = fitted(frame, within: destination.usableFrame)
    }
    guard !framesMatchPlacement(placed, frame) else { return nil }
    return placed
  }

  /// True when the connected displays together cover `frame`, less a few
  /// points of AX rounding along its edges. Displays never overlap, so their
  /// intersections with it add up to the area they cover.
  static func frameIsCovered(
    _ frame: CGRect, by screens: [WindowScreenLayout], tolerance: CGFloat = 8
  ) -> Bool {
    let inner = frame.insetBy(
      dx: min(tolerance, frame.width / 2 - 0.5), dy: min(tolerance, frame.height / 2 - 0.5))
    let covered = screens.reduce(CGFloat(0)) { sum, screen in
      sum + intersectionArea(inner, screen.frame)
    }
    return covered >= inner.width * inner.height - 0.5
  }

  /// True when `frame` lies inside some connected display, plus a few points
  /// so AX rounding is not treated as an orphan.
  static func frameFits(
    _ frame: CGRect, on screens: [WindowScreenLayout], tolerance: CGFloat = 8
  ) -> Bool {
    screens.contains { screen in
      screen.frame.insetBy(dx: -tolerance, dy: -tolerance).contains(frame)
    }
  }

  /// The display that contains the frame's centre, or the one it overlaps
  /// most. Nil when the frame misses every display: an intentionally
  /// off-screen window, not one a departed display left behind.
  static func screenOwning(
    frame: CGRect, screens: [WindowScreenLayout]
  ) -> WindowScreenLayout? {
    let centre = CGPoint(x: frame.midX, y: frame.midY)
    if let hit = screens.first(where: { $0.frame.contains(centre) }) { return hit }
    guard
      let best = screens.max(by: {
        intersectionArea(frame, $0.frame) < intersectionArea(frame, $1.frame)
      }), intersectionArea(frame, best.frame) > 0
    else { return nil }
    return best
  }

  /// Shrink and slide `frame` until it lies inside `usable`.
  static func fitted(_ frame: CGRect, within usable: CGRect) -> CGRect {
    guard usable.width > 1, usable.height > 1 else { return frame }
    var result = frame
    result.size.width = min(result.width, usable.width)
    result.size.height = min(result.height, usable.height)
    if result.minX < usable.minX { result.origin.x = usable.minX }
    if result.minY < usable.minY { result.origin.y = usable.minY }
    if result.maxX > usable.maxX { result.origin.x = usable.maxX - result.width }
    if result.maxY > usable.maxY { result.origin.y = usable.maxY - result.height }
    return result
  }

  static func description(of layout: WindowLayout) -> String {
    switch layout {
    case .position(let position):
      return "position=\(position.rawValue)"
    case .proportional(let frame):
      return "x=\(frame.xPercent)% y=\(frame.yPercent)% "
        + "width=\(frame.widthPercent)% height=\(frame.heightPercent)%"
    }
  }

  /// Proportionally remap `frame` from one visible frame into
  /// another. Both rects are NSScreen Y-up coordinates.
  static func remap(
    frame: CGRect, from src: CGRect, to dst: CGRect
  ) -> CGRect {
    guard src.width > 0, src.height > 0 else { return frame }
    let relX = (frame.minX - src.minX) / src.width
    let relY = (frame.minY - src.minY) / src.height
    let relW = frame.width / src.width
    let relH = frame.height / src.height
    return CGRect(
      x: dst.minX + relX * dst.width,
      y: dst.minY + relY * dst.height,
      width: relW * dst.width,
      height: relH * dst.height)
  }

  /// Index of the screen that owns the frame's centre, or `0` when
  /// no screen claims the centre (e.g. an off-screen window after a
  /// monitor was unplugged).
  /// The display `offset` steps from `screens[index]`, walking them as they
  /// are arranged: left to right, then top to bottom, wrapping. An index into
  /// `screens`, whose order (`NSScreen.screens`) only promises the primary
  /// first.
  static func relativeScreenIndex(
    from index: Int, offset: Int, screens: [WindowScreenLayout]
  ) -> Int {
    guard !screens.isEmpty, offset != 0 else { return index }
    let arranged = screens.indices.sorted { lhs, rhs in
      let a = screens[lhs].frame
      let b = screens[rhs].frame
      if a.minX != b.minX { return a.minX < b.minX }
      return a.maxY > b.maxY
    }
    guard let position = arranged.firstIndex(of: index) else { return index }
    let count = arranged.count
    // Swift's `%` keeps the sign of a negative left side: wrap through `+ count`.
    return arranged[((position + offset) % count + count) % count]
  }

  static func screenIndex(
    forFrame frame: CGRect, screens: [WindowScreenLayout]
  ) -> Int {
    let centre = CGPoint(x: frame.midX, y: frame.midY)
    for (i, s) in screens.enumerated() where s.frame.contains(centre) {
      return i
    }
    // A partly off-screen window can have its centre outside every display.
    // Pick the display with the greatest overlap before falling back to the
    // primary for a fully orphaned frame after unplugging a monitor.
    if let best = screens.enumerated().max(by: {
      intersectionArea(frame, $0.element.frame) < intersectionArea(frame, $1.element.frame)
    }), intersectionArea(frame, best.element.frame) > 0 {
      return best.offset
    }
    return 0
  }

  static func screenContaining(
    frame: CGRect, screens: [WindowScreenLayout]
  ) -> WindowScreenLayout? {
    guard !screens.isEmpty else { return nil }
    return screens[screenIndex(forFrame: frame, screens: screens)]
  }

  private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
    let intersection = lhs.intersection(rhs)
    guard !intersection.isNull else { return 0 }
    return intersection.width * intersection.height
  }

  /// The visible frame, less `statusBarHeight` points along the screen's top
  /// when the display shows the bar (nil when it does not).
  static func usableFrame(
    screenFrame: CGRect, visibleFrame: CGRect, statusBarHeight: CGFloat?
  ) -> CGRect {
    guard let statusBarHeight else { return visibleFrame }
    let maxY = screenFrame.maxY - statusBarHeight
    return CGRect(
      x: visibleFrame.minX,
      y: visibleFrame.minY,
      width: visibleFrame.width,
      height: max(0, maxY - visibleFrame.minY))
  }

  /// Resolve focused/main/frontmost in one AX IPC. Flash's overlay may own key
  /// focus while a normal-mode mapping fires, so the target application's
  /// focused attribute is legitimately absent; requesting all fallbacks as one
  /// batch avoids serially waiting on three app round trips in that case.
  private static func resolveWindow(
    _ axApp: AXUIElement
  ) -> (window: AXUIElement, source: String)? {
    let names = [
      kAXFocusedWindowAttribute as String,
      kAXMainWindowAttribute as String,
      kAXWindowsAttribute as String,
    ]
    var raw: CFArray?
    let startedAt = DispatchTime.now()
    let status = AXUIElementCopyMultipleAttributeValues(
      axApp, names as CFArray, AXCopyMultipleAttributeOptions(), &raw)
    if status == .success, let values = raw as? [Any], values.count == names.count {
      if let window = windowElement(values[0]) { return (window, "focused") }
      if let window = windowElement(values[1]) { return (window, "main") }
      if let windows = values[2] as? [AXUIElement], let window = windows.first {
        return (window, "windows")
      }
    }
    guard
      windowLookupFallbacksMayAnswer(
        afterBatch: status, elapsedMs: elapsedMs(since: startedAt),
        timeoutMs: Double(AXApp.defaultMessagingTimeout) * 1_000)
    else {
      var pid: pid_t = 0
      AXUIElementGetPid(axApp, &pid)
      FlashLog.warn("[placement] window lookup abandoned pid=\(pid) reason=ax_timeout")
      return nil
    }

    // Rare wholesale batch failure: keep the compatibility fallbacks lazy so
    // a successful focused/main lookup stops before the more expensive window
    // list read.
    if let window = copyWindowAttribute(axApp, kAXFocusedWindowAttribute) {
      return (window, "focused_fallback")
    }
    if let window = copyWindowAttribute(axApp, kAXMainWindowAttribute) {
      return (window, "main_fallback")
    }
    var windowsRaw: CFTypeRef?
    if AXUIElementCopyAttributeValue(
      axApp, kAXWindowsAttribute as CFString, &windowsRaw) == .success,
      let windows = windowsRaw as? [AXUIElement], let window = windows.first
    {
      return (window, "windows_fallback")
    }
    return nil
  }

  private static func copyWindowAttribute(
    _ axApp: AXUIElement, _ attribute: String
  ) -> AXUIElement? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, attribute as CFString, &raw) == .success,
      let raw
    else { return nil }
    return windowElement(raw)
  }

  private static func windowElement(_ value: Any) -> AXUIElement? {
    guard CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
  }

  /// Read the AX position + size and convert to NSScreen coordinates
  /// (bottom-left origin, Y-up).
  static func readWindowFrameInNSCoords(
    window: AXUIElement, primaryHeight: CGFloat
  ) -> CGRect? {
    let names = [kAXPositionAttribute as String, kAXSizeAttribute as String]
    var raw: CFArray?
    guard
      AXUIElementCopyMultipleAttributeValues(
        window, names as CFArray, AXCopyMultipleAttributeOptions(), &raw) == .success,
      let values = raw as? [Any], values.count == names.count,
      CFGetTypeID(values[0] as CFTypeRef) == AXValueGetTypeID(),
      CFGetTypeID(values[1] as CFTypeRef) == AXValueGetTypeID()
    else { return nil }

    var pos = CGPoint.zero
    var size = CGSize.zero
    let posValue = values[0] as! AXValue
    let sizeValue = values[1] as! AXValue
    guard AXValueGetType(posValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize else {
      return nil
    }
    AXValueGetValue(posValue, .cgPoint, &pos)
    AXValueGetValue(sizeValue, .cgSize, &size)

    return nsRectFromAX(position: pos, size: size, primaryHeight: primaryHeight)
  }

  /// Subroles of a window a person works in. Palettes, floating panels and
  /// system dialogs are left out; a window reporting no subrole is kept.
  static let userWindowSubroles: Set<String> = [kAXStandardWindowSubrole, kAXDialogSubrole]

  /// A user window's frame and whether it is minimized, in one batched read:
  /// the catalog walk reads every window of an app this way. Nil for an
  /// element that is no user window: Finder lists the desktop among its
  /// windows, a full-screen `AXScrollArea`.
  /// `subroles` nil keeps every window subrole (palettes, panels).
  static func readWindowGeometry(
    window: AXUIElement, primaryHeight: CGFloat,
    subroles: Set<String>? = userWindowSubroles
  ) -> (frame: CGRect, minimized: Bool, subrole: String?)? {
    let names = [
      kAXPositionAttribute as String, kAXSizeAttribute as String, kAXMinimizedAttribute as String,
      kAXRoleAttribute as String, kAXSubroleAttribute as String,
    ]
    var raw: CFArray?
    guard
      AXUIElementCopyMultipleAttributeValues(
        window, names as CFArray, AXCopyMultipleAttributeOptions(), &raw) == .success,
      let values = raw as? [Any]
    else { return nil }
    return parseWindowGeometry(values, primaryHeight: primaryHeight, subroles: subroles)
  }

  /// The role must be a window with a user subrole (or none); position and
  /// size must both read; a minimized flag that did not (an error value in
  /// its slot) counts as not minimized.
  static func parseWindowGeometry(
    _ values: [Any], primaryHeight: CGFloat, subroles: Set<String>? = userWindowSubroles
  ) -> (frame: CGRect, minimized: Bool, subrole: String?)? {
    guard values.count == 5, values[3] as? String == kAXWindowRole as String,
      subroles.map({ allowed in (values[4] as? String).map(allowed.contains) ?? true }) ?? true,
      CFGetTypeID(values[0] as CFTypeRef) == AXValueGetTypeID(),
      CFGetTypeID(values[1] as CFTypeRef) == AXValueGetTypeID()
    else { return nil }
    let posValue = values[0] as! AXValue
    let sizeValue = values[1] as! AXValue
    guard AXValueGetType(posValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize else {
      return nil
    }
    var pos = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(posValue, .cgPoint, &pos)
    AXValueGetValue(sizeValue, .cgSize, &size)
    let minimized =
      CFGetTypeID(values[2] as CFTypeRef) == CFBooleanGetTypeID()
      && CFBooleanGetValue((values[2] as! CFBoolean))
    return (
      nsRectFromAX(position: pos, size: size, primaryHeight: primaryHeight), minimized,
      values[4] as? String
    )
  }

  /// AX y is from the primary screen's top-left, Y-down. Convert to NSScreen
  /// y (from the primary's bottom-left, Y-up). The active-window border's
  /// fast path reads geometry this way, so it has to land in the same space
  /// as the WindowServer scan it replaced.
  static func nsRectFromAX(
    position: CGPoint, size: CGSize, primaryHeight: CGFloat
  ) -> CGRect {
    ScreenRect<AXSpace>(CGRect(origin: position, size: size)).toNS(primaryHeight: primaryHeight)
      .cgRect
  }

  /// Map a `WindowPosition` onto a slot of the supplied usable frame
  /// (in NSScreen / Y-up coordinates).
  static func rectFor(
    position: WindowPosition, in vf: CGRect
  ) -> CGRect {
    pointAligned(fractionalRect(for: position, in: vf))
  }

  /// A slot's edges on whole points. Each edge rounds on its own and the size
  /// follows from the rounded edges, so neighbouring slots (the two halves of
  /// an odd-width display) share an edge instead of leaving a gap or
  /// overlapping, and the frame an app reports back matches it exactly.
  static func pointAligned(_ rect: CGRect) -> CGRect {
    let minX = rect.minX.rounded()
    let minY = rect.minY.rounded()
    return CGRect(
      x: minX, y: minY,
      width: rect.maxX.rounded() - minX, height: rect.maxY.rounded() - minY)
  }

  private static func fractionalRect(
    for position: WindowPosition, in vf: CGRect
  ) -> CGRect {
    let halfW = vf.width / 2
    let halfH = vf.height / 2
    switch position {
    case .maximized:
      return vf
    case .leftHalf:
      return CGRect(x: vf.minX, y: vf.minY, width: halfW, height: vf.height)
    case .rightHalf:
      return CGRect(x: vf.midX, y: vf.minY, width: halfW, height: vf.height)
    case .topHalf:
      // NSScreen Y is up, so "top" is the upper half (y >= midY).
      return CGRect(x: vf.minX, y: vf.midY, width: vf.width, height: halfH)
    case .bottomHalf:
      return CGRect(x: vf.minX, y: vf.minY, width: vf.width, height: halfH)
    case .topLeft:
      return CGRect(x: vf.minX, y: vf.midY, width: halfW, height: halfH)
    case .topRight:
      return CGRect(x: vf.midX, y: vf.midY, width: halfW, height: halfH)
    case .bottomLeft:
      return CGRect(x: vf.minX, y: vf.minY, width: halfW, height: halfH)
    case .bottomRight:
      return CGRect(x: vf.midX, y: vf.minY, width: halfW, height: halfH)
    case .centered:
      // 70 × 80 of the visible frame, centred. Matches the
      // Hammerspoon `wm.centered()` shape users migrate from.
      let w = vf.width * 0.7
      let h = vf.height * 0.8
      return CGRect(
        x: vf.minX + (vf.width - w) / 2,
        y: vf.minY + (vf.height - h) / 2,
        width: w, height: h)
    }
  }

  /// Map a semantic layout onto the supplied usable frame. Proportional `x`
  /// and `y` are measured from the user's top-left perspective even though the
  /// returned CGRect uses NSScreen's bottom-left, Y-up coordinate space.
  static func rectFor(layout: WindowLayout, in usableFrame: CGRect) -> CGRect {
    switch layout {
    case .position(let position):
      return rectFor(position: position, in: usableFrame)
    case .proportional(let frame):
      let width = usableFrame.width * CGFloat(frame.widthPercent / 100)
      let height = usableFrame.height * CGFloat(frame.heightPercent / 100)
      return pointAligned(
        CGRect(
          x: usableFrame.minX + usableFrame.width * CGFloat(frame.xPercent / 100),
          y: usableFrame.maxY
            - usableFrame.height * CGFloat(frame.yPercent / 100)
            - height,
          width: width,
          height: height))
    }
  }

  /// Recover the semantic slot represented by an observed window frame. The
  /// small tolerance absorbs AX/AppKit rounding on odd-sized displays without
  /// treating an intentional free-form resize as a tiled layout.
  static func position(
    matching frame: CGRect,
    in usableFrame: CGRect,
    tolerance: CGFloat = 2
  ) -> WindowPosition? {
    WindowPosition.allCases.first {
      framesApproximatelyEqual(
        frame, rectFor(position: $0, in: usableFrame), tolerance: tolerance)
    }
  }

  /// The layout `frame` sits in: the window's own tracked layout first, then
  /// a named slot, then a proportional layout the config's mappings declare —
  /// so a window placed by such a mapping is recognized after Flash restarts.
  static func semanticLayout(
    matching frame: CGRect,
    in usableFrame: CGRect,
    existing: WindowLayout?,
    declared: [WindowLayout] = []
  ) -> WindowLayout? {
    if let existing,
      framesApproximatelyEqual(frame, rectFor(layout: existing, in: usableFrame))
    {
      return existing
    }
    if let position = position(matching: frame, in: usableFrame) {
      return .position(position)
    }
    return declared.first {
      framesApproximatelyEqual(frame, rectFor(layout: $0, in: usableFrame))
    }
  }

  static func framesApproximatelyEqual(
    _ lhs: CGRect,
    _ rhs: CGRect,
    tolerance: CGFloat = 2
  ) -> Bool {
    abs(lhs.minX - rhs.minX) <= tolerance
      && abs(lhs.minY - rhs.minY) <= tolerance
      && abs(lhs.width - rhs.width) <= tolerance
      && abs(lhs.height - rhs.height) <= tolerance
  }

  /// Whether a window sits where a placement put it. Slot recognition above
  /// forgives a couple of points; placement cannot, or a window left a point
  /// off its slot stays there until the next manual move closes the gap.
  /// Anything under a point is the app rounding a fractional target.
  static func framesMatchPlacement(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    abs(lhs.minX - rhs.minX) < 1
      && abs(lhs.minY - rhs.minY) < 1
      && abs(lhs.width - rhs.width) < 1
      && abs(lhs.height - rhs.height) < 1
  }

  /// The most correction rounds `apply` makes after its planned writes. One
  /// is enough to defeat the async grow-clamp race described below; the extra
  /// margin lets grid-snapping apps settle without looping.
  private static let applyCorrectionAttempts = 2

  /// Wall-clock ceiling on those corrections. Every AX write and read-back is
  /// a blocking round trip into the target app on the serial layout queue,
  /// which also serves `window focus`, so a pathologically slow app must give
  /// up its turn. The post-restore check below is outside the budget: it is
  /// the one that decides whether the move stuck at all.
  private static let applyCorrectionBudgetMs = 120

  /// How a placement ended: the window took the rect, its app kept it
  /// elsewhere, or its frame could not be read back (the session is locked,
  /// or the app is not answering Accessibility).
  enum ApplyOutcome: Equatable {
    case converged, refused, unreadable
  }

  /// A placement's outcome and the Accessibility writes it took, for the
  /// move log.
  struct Placement: Equatable {
    let outcome: ApplyOutcome
    let writes: [WindowFrameWrite]
    let corrections: Int
  }

  /// The writes that take a window from `current` to `target`, both in
  /// NSScreen coordinates; `bounds` is the destination display's usable
  /// frame. Accessibility moves the top-left corner and resizes about it, one
  /// attribute per round trip, and every write that changes the frame makes
  /// the app lay the window out again, so a placement writes only what
  /// differs:
  ///
  ///   - nothing for a window already in place (within a point, as
  ///     `framesMatchPlacement` accepts it);
  ///   - the position alone when only the corner moves (half to half), and
  ///     the size alone when only the size changes (maximized to left half);
  ///   - both, ordered so the frame in between stays on the display: shrink
  ///     then move, or move then grow. Growing at the old corner would push
  ///     the window off the display, where the app clamps it — the "maximize
  ///     fills ~85% of the width" race the corrections exist for.
  ///   - A window not on the destination's usable frame (another display, or
  ///     hanging off this one) gets the size → position → size burst
  ///     Hammerspoon, AeroSpace and yabai use: its first size write can be
  ///     clamped to the display it is leaving, the position frees it, and
  ///     the second size write applies it.
  static func frameWrites(
    from current: CGRect, to target: CGRect, within bounds: CGRect
  ) -> [WindowFrameWrite] {
    guard !framesMatchPlacement(current, target) else { return [] }
    let moves = abs(current.minX - target.minX) >= 1 || abs(current.maxY - target.maxY) >= 1
    let resizes =
      abs(current.width - target.width) >= 1 || abs(current.height - target.height) >= 1
    // Under a point on each edge but not within `framesMatchPlacement`:
    // rewrite both, as if both moved.
    switch (moves, resizes) {
    case (true, false): return [.position]
    case (false, true): return [.size]
    default: break
    }
    guard bounds.insetBy(dx: -1, dy: -1).contains(current) else {
      return [.size, .position, .size]
    }
    let resizedInPlace = CGRect(
      x: current.minX, y: current.maxY - target.height,
      width: target.width, height: target.height)
    let movedFirst = CGRect(
      x: target.minX, y: target.maxY - current.height,
      width: current.width, height: current.height)
    return overflow(of: resizedInPlace, beyond: bounds) <= overflow(of: movedFirst, beyond: bounds)
      ? [.size, .position] : [.position, .size]
  }

  /// How far `rect` reaches past `bounds`, summed over its four edges.
  private static func overflow(of rect: CGRect, beyond bounds: CGRect) -> CGFloat {
    max(0, bounds.minX - rect.minX) + max(0, rect.maxX - bounds.maxX)
      + max(0, bounds.minY - rect.minY) + max(0, rect.maxY - bounds.maxY)
  }

  /// Place `window` at `nsRect`. `current` is its frame as just read, and
  /// `bounds` the usable frame of the display it is going to.
  @discardableResult
  static func apply(
    rect nsRect: CGRect,
    toWindow window: AXUIElement,
    axApp: AXUIElement,
    primaryHeight: CGFloat,
    bundleIdentifier: String?,
    from current: CGRect,
    within bounds: CGRect
  ) -> Placement {
    var pid: pid_t = 0
    AXUIElementGetPid(axApp, &pid)
    // A window element does not inherit its app element's messaging timeout.
    AXUIElementSetMessagingTimeout(window, AXApp.defaultMessagingTimeout)
    return apply(
      rect: nsRect, from: current, within: bounds,
      engine: AppTraits.of(bundleIdentifier: bundleIdentifier, pid: pid).engine,
      driver: .live(window: window, app: axApp, primaryHeight: primaryHeight),
      bundleIdentifier: bundleIdentifier)
  }

  /// Push the rect into the window through `driver`:
  ///
  ///   1. A window already in place takes no call at all.
  ///   2. Some apps (notably Cocoa apps with default behaviour) animate frame
  ///      changes by ~250ms whenever `AXEnhancedUserInterface` is true, and
  ///      Flash itself turns it on for Chromium and Flutter apps to wake
  ///      their tree. Toggling it off before the writes and back on after
  ///      collapses the animation to a single repaint, as Rectangle,
  ///      AeroSpace, Hammerspoon, Amethyst and yabai do. Its settability is
  ///      asked only when it is on, and Gecko apps are never asked: their
  ///      mode belongs to `GeckoAccessibility`, which switched it off before
  ///      `apply` ran.
  ///   3. The writes `frameWrites` plans.
  ///   4. Many apps apply frame writes asynchronously: when a position move
  ///      has not landed by the time the following size write is processed,
  ///      the app clamps the grow against the window's old position and it
  ///      settles narrower than requested. After the writes, read the frame
  ///      back (a synchronous AX round trip that flushes the app's pending
  ///      writes) and, if it missed the target, write again what still
  ///      differs. Bounded so a window that genuinely can't reach the rect
  ///      (grid-snapping terminals, min-size dialogs) stops instead of
  ///      looping. Every round is verified, including the last, so a window
  ///      still short when the attempts run out is logged, not left silently.
  static func apply(
    rect nsRect: CGRect,
    from current: CGRect,
    within bounds: CGRect,
    engine: AppTraits.Engine?,
    driver: WindowGeometryDriver,
    bundleIdentifier: String?
  ) -> Placement {
    let planned = frameWrites(from: current, to: nsRect, within: bounds)
    guard !planned.isEmpty else {
      return Placement(outcome: .converged, writes: [], corrections: 0)
    }
    let previousEnhanced = engine == .gecko ? nil : driver.enhancedUserInterface()
    let temporarilyDisableEnhancedUserInterface = shouldTemporarilyDisableEnhancedUserInterface(
      currentValue: previousEnhanced,
      isSettable: previousEnhanced == true && driver.enhancedUserInterfaceIsSettable(),
      engine: engine)
    if temporarilyDisableEnhancedUserInterface {
      driver.setEnhancedUserInterface(false)
    }
    // Restored explicitly below so the frame can be verified with enhanced UI
    // back on; this only catches the early-exit paths.
    var enhancedUserInterfaceRestored = false
    defer {
      if temporarilyDisableEnhancedUserInterface, !enhancedUserInterfaceRestored {
        driver.setEnhancedUserInterface(true)
      }
    }

    var writes: [WindowFrameWrite] = []
    func perform(_ plan: [WindowFrameWrite]) {
      for write in plan {
        driver.write(write, nsRect)
        writes.append(write)
      }
    }
    /// What is still off after a read-back; both when it was unreadable.
    func corrections(after actual: CGRect?) -> [WindowFrameWrite] {
      guard let actual else { return [.position, .size] }
      return frameWrites(from: actual, to: nsRect, within: bounds)
    }

    perform(planned)
    var actual = driver.frame()
    var converged = actual.map { framesMatchPlacement($0, nsRect) } ?? false
    let budget = DispatchTime.now() + .milliseconds(Self.applyCorrectionBudgetMs)
    var attempt = 0
    while !converged, attempt < Self.applyCorrectionAttempts, DispatchTime.now() < budget {
      attempt += 1
      perform(corrections(after: actual))
      actual = driver.frame()
      converged = actual.map { framesMatchPlacement($0, nsRect) } ?? false
    }

    if temporarilyDisableEnhancedUserInterface {
      driver.setEnhancedUserInterface(true)
      enhancedUserInterfaceRestored = true
      // Turning enhanced UI back on makes some apps re-run their own layout,
      // which can undo part of the move. That happens after every check above,
      // so the window settled short and nothing noticed. Look once more with
      // it on, and if the app took the frame back, put it right.
      actual = driver.frame()
      if actual.map({ framesMatchPlacement($0, nsRect) }) != true {
        driver.setEnhancedUserInterface(false)
        perform(corrections(after: actual))
        driver.setEnhancedUserInterface(true)
        actual = driver.frame()
      }
      converged = actual.map { framesMatchPlacement($0, nsRect) } ?? false
    }

    if !converged {
      // The window genuinely would not take the rect (min-size dialogs,
      // grid-snapping terminals, an app fighting back). Record it: this used
      // to fail silently, which is why it looked intermittent.
      FlashLog.warn(
        "[window] unconverged bundle=\(bundleIdentifier ?? "unknown") "
          + "target=\(NSStringFromRect(nsRect)) "
          + "actual=\(actual.map(NSStringFromRect) ?? "unreadable") "
          + "corrections=\(attempt)")
    }
    return Placement(
      outcome: converged ? .converged : actual == nil ? .unreadable : .refused,
      writes: writes, corrections: attempt)
  }

  static func shouldTemporarilyDisableEnhancedUserInterface(
    currentValue: Bool?,
    isSettable: Bool,
    engine: AppTraits.Engine?
  ) -> Bool {
    // Gecko's own enhanced-UI state is owned by `GeckoAccessibility`.
    return currentValue == true
      && isSettable
      && engine != .gecko
  }

  /// Whether `resolveWindow`'s one-attribute fallbacks can still answer
  /// after its batched lookup failed. A batch that failed only once it had
  /// waited out the messaging timeout means the app is not answering: each
  /// fallback would wait out the same timeout on the serial layout queue,
  /// four timeouts where one already told.
  static func windowLookupFallbacksMayAnswer(
    afterBatch status: AXError, elapsedMs: Double, timeoutMs: Double
  ) -> Bool {
    !(status == .cannotComplete && elapsedMs >= timeoutMs * 0.9)
  }

  static func elapsedMs(since start: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
  }
}

/// One Accessibility write of a window placement.
enum WindowFrameWrite: String, Equatable {
  /// `kAXSizeAttribute`; the app keeps the window's top-left corner.
  case size
  /// `kAXPositionAttribute`, the top-left corner; the app keeps the size.
  case position
}

/// The Accessibility calls one window placement makes, in NSScreen
/// coordinates: the window's frame and its app's `AXEnhancedUserInterface`.
/// Faked in tests.
struct WindowGeometryDriver {
  /// The window's frame; nil when it cannot be read.
  var frame: () -> CGRect?
  /// Write one component of `rect`.
  var write: (WindowFrameWrite, CGRect) -> Void
  /// The app's `AXEnhancedUserInterface`; nil when it has none.
  var enhancedUserInterface: () -> Bool?
  var enhancedUserInterfaceIsSettable: () -> Bool
  var setEnhancedUserInterface: (Bool) -> Void

  static func live(
    window: AXUIElement, app: AXUIElement, primaryHeight: CGFloat
  ) -> WindowGeometryDriver {
    WindowGeometryDriver(
      frame: {
        WindowMover.readWindowFrameInNSCoords(window: window, primaryHeight: primaryHeight)
      },
      write: { write, rect in
        switch write {
        case .size:
          var size = rect.size
          if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
          }
        case .position:
          var position = ScreenRect<NSSpace>(rect).toAX(primaryHeight: primaryHeight).origin.cgPoint
          if let value = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
          }
        }
      },
      enhancedUserInterface: {
        var value: CFTypeRef?
        guard
          AXUIElementCopyAttributeValue(app, "AXEnhancedUserInterface" as CFString, &value)
            == .success,
          let value, CFGetTypeID(value) == CFBooleanGetTypeID()
        else { return nil }
        return CFBooleanGetValue((value as! CFBoolean))
      },
      enhancedUserInterfaceIsSettable: {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(
          app, "AXEnhancedUserInterface" as CFString, &settable) == .success
          && settable.boolValue
      },
      setEnhancedUserInterface: { enabled in
        AXUIElementSetAttributeValue(
          app, "AXEnhancedUserInterface" as CFString,
          enabled ? kCFBooleanTrue : kCFBooleanFalse)
      })
  }
}

extension WindowLayoutManager: TilingWindowDriver {
  typealias Key = WindowKey

  func tilingWindowNumber(of key: WindowKey) -> UInt32? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(key.window, "AXWindowNumber" as CFString, &raw) == .success,
      let number = raw as? NSNumber,
      number.uint64Value > 0, number.uint64Value <= UInt32.max
    else { return nil }
    return number.uint32Value
  }

  func tilingTitle(of key: WindowKey) -> String? {
    var raw: CFTypeRef?
    return AXUIElementCopyAttributeValue(key.window, kAXTitleAttribute as CFString, &raw)
      == .success ? raw as? String : nil
  }

  func tilingFrame(of key: WindowKey) -> CGRect? {
    guard let primaryHeight = WindowMover.primaryHeight(in: currentScreensForTiling) else {
      return nil
    }
    return WindowMover.readWindowFrameInNSCoords(window: key.window, primaryHeight: primaryHeight)
  }

  func tilingApply(_ frame: CGRect, to key: WindowKey, within bounds: CGRect) {
    applyTiledFrame(frame, to: key, within: bounds)
  }

  func tilingPark(_ key: WindowKey, topLeft: CGPoint) {
    parkTiledWindow(key, topLeft: topLeft)
  }

  func tilingRaise(_ key: WindowKey) {
    _ = AXUIElementPerformAction(key.window, kAXRaiseAction as CFString)
    _ = AXUIElementSetAttributeValue(key.window, kAXMainAttribute as CFString, kCFBooleanTrue)
    _ = AXUIElementSetAttributeValue(key.window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    let pid = key.pid
    DispatchQueue.main.async {
      guard let app = NSRunningApplication(processIdentifier: pid) else { return }
      RunningApplicationActivation.activate(app, restoringMinimizedWindows: false)
    }
  }
}
