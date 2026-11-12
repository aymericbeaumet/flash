import FlashCore
import Foundation

/// A macOS surface over or beside the windows: the Dock's Show Desktop,
/// Mission Control, App Exposé and Launchpad (the Apps view since macOS 26),
/// and the Notification Center and Control Center panels. The raw value is
/// the command's topic (`flash missioncontrol show`).
///
/// The topics are Apple's names run together. App Exposé is `appwindows`,
/// after the macOS shortcut that opens it ("Application windows"), and the
/// Apps view keeps `launchpad`, the name of the Dock request that still
/// opens it and of the gesture, clear of the `app` topic.
enum SystemSurface: String, CaseIterable, Hashable {
  case desktop
  case missionControl = "missioncontrol"
  case appWindows = "appwindows"
  case launchpad
  case notificationCenter = "notificationcenter"
  case controlCenter = "controlcenter"

  /// What macOS calls it, in failures.
  var title: String {
    switch self {
    case .desktop: return "Show Desktop"
    case .missionControl: return "Mission Control"
    case .appWindows: return "App Exposé"
    case .launchpad: return "the Apps view"
    case .notificationCenter: return "Notification Center"
    case .controlCenter: return "Control Center"
    }
  }

  /// The Dock view this surface is: the Dock reports entering and leaving
  /// it. Nil for the surfaces other processes draw.
  var dockView: DockView? {
    switch self {
    case .desktop: return .desktop
    case .missionControl: return .missionControl
    case .appWindows: return .appWindows
    case .launchpad, .notificationCenter, .controlCenter: return nil
    }
  }

  /// The surface a Dock view belongs to.
  init?(dockView: DockView) {
    switch dockView {
    case .none: return nil
    case .desktop: self = .desktop
    case .missionControl: self = .missionControl
    case .appWindows: self = .appWindows
    }
  }

  /// The request that toggles this surface in the Dock (the private
  /// `CoreDockSendNotification`). Launchpad's opens the Apps view on
  /// macOS 26, which Spotlight draws. Nil for the Control Center panels,
  /// which are pressed through their menu-bar items.
  var dockNotification: String? {
    switch self {
    case .desktop: return "com.apple.showdesktop.awake"
    case .missionControl: return "com.apple.expose.awake"
    case .appWindows: return "com.apple.expose.front.awake"
    case .launchpad: return "com.apple.launchpad.toggle"
    case .notificationCenter, .controlCenter: return nil
    }
  }
}

/// `show` and `hide` leave a surface that already is as asked alone;
/// `toggle` is whichever of the two it is not.
enum SurfaceVisibility: String, CaseIterable, Hashable {
  case show, hide, toggle
}

/// `flash <surface> show|hide|toggle`.
struct SystemSurfaceCommand: Hashable {
  let surface: SystemSurface
  let visibility: SurfaceVisibility

  init(_ surface: SystemSurface, _ visibility: SurfaceVisibility) {
    self.surface = surface
    self.visibility = visibility
  }

  var name: CommandName { CommandName(surface.rawValue, visibility.rawValue) }

  /// The command table's one line.
  var summary: String {
    switch (surface, visibility) {
    case (.desktop, .show): return "Show the desktop, moving every window aside"
    case (.desktop, .hide): return "Bring the windows back over the desktop"
    case (.desktop, .toggle): return "Show the desktop, or bring the windows back"
    case (.appWindows, .show): return "Show the focused app's windows (App Exposé)"
    case (.appWindows, .hide): return "Close App Exposé"
    case (.appWindows, .toggle): return "Show the focused app's windows, or close App Exposé"
    case (.launchpad, .show): return "Open the Apps view (Launchpad before macOS 26)"
    case (.launchpad, .hide): return "Close the Apps view (Launchpad before macOS 26)"
    case (.launchpad, .toggle): return "Open or close the Apps view (Launchpad before macOS 26)"
    case (_, .show): return "Open \(surface.title)"
    case (_, .hide): return "Close \(surface.title)"
    case (_, .toggle): return "Open or close \(surface.title)"
    }
  }

  /// What it does, in the third person and without a full stop: the
  /// explanation's first clause, and the gestures'.
  var action: String {
    switch (surface, visibility) {
    case (.desktop, .show): return "Shows the desktop, moving every window aside"
    case (.desktop, .hide): return "Brings the windows back over the desktop"
    case (.desktop, .toggle): return "Shows the desktop, or brings the windows back"
    case (.appWindows, .show): return "Shows the focused app's windows (App Exposé)"
    case (.appWindows, .hide): return "Closes App Exposé"
    case (.appWindows, .toggle): return "Shows the focused app's windows, or closes App Exposé"
    case (_, .show): return "Opens \(surface.title)"
    case (_, .hide): return "Closes \(surface.title)"
    case (_, .toggle): return "Opens or closes \(surface.title)"
    }
  }

  /// The mapping explanation, as one sentence.
  var explanation: String {
    let shown = surface == .desktop || surface == .appWindows ? "showing" : "open"
    switch visibility {
    case .show: return "\(action); does nothing when it is already \(shown)."
    case .hide: return "\(action); does nothing when it is not \(shown)."
    case .toggle: return "\(action)."
    }
  }
}

/// The Dock's own views, as it reports them to Accessibility.
enum DockView: Equatable {
  case none, missionControl, appWindows, desktop
}

/// The Dock's view from its reports, for the Dock process `pid` Flash
/// observes (nil while it observes none). A Dock that let a request go
/// unconfirmed is silent until it reports again: its view is unknown. A pure
/// value.
struct DockViewTracker: Equatable {
  /// The notifications the Dock posts on its application element as a view
  /// opens and closes (observed on macOS 26).
  static let reports: [String: DockView] = [
    "AXExposeShowAllWindows": .missionControl,
    "AXExposeShowFrontWindows": .appWindows,
    "AXExposeShowDesktop": .desktop,
    "AXExposeExit": .none,
  ]

  private(set) var pid: pid_t?
  private(set) var view: DockView = .none
  private(set) var silent = false

  /// The view to plan from; nil when Flash cannot know it.
  var knownView: DockView? { pid == nil || silent ? nil : view }

  /// A report; true when it changed the view. Any report ends a silence.
  mutating func observe(_ notification: String) -> Bool {
    guard let next = Self.reports[notification] else { return false }
    let changed = silent || next != view
    silent = false
    view = next
    return changed
  }

  /// Observation started on Dock `pid`, or stopped: a Dock that just
  /// launched shows no view, and none can be seen without reports.
  mutating func reset(pid: pid_t?) {
    self.pid = pid
    view = .none
    silent = false
  }

  /// A request went unconfirmed: until the Dock reports again its view is
  /// unknown, so only `toggle` runs, blind.
  mutating func timedOut() {
    silent = true
    view = .none
  }
}

/// One thing a surface command does, in order.
enum SurfaceStep: Equatable {
  /// Send the surface's Dock request, then wait until the Dock reports
  /// `awaiting`.
  case dock(SystemSurface, awaiting: DockView)
  /// Send the surface's Dock request with no report to wait for: Launchpad,
  /// which another process draws, or any Dock surface while Flash sees no
  /// reports. `shows` is what it should do, when Flash can tell.
  case dockUnobserved(SystemSurface, shows: Bool?)
  /// Press the surface's menu-bar item.
  case press(SystemSurface, shows: Bool?)
}

enum SurfacePlan: Equatable {
  case steps([SurfaceStep])
  /// Nothing can run, for this reason.
  case refused(String)
}

/// What a run of commands for one surface amounts to: a burst of toggles
/// cancels in pairs, and a `show` or `hide` decides whatever came before it.
enum SurfaceEffect: Equatable {
  case unchanged, toggle, show, hide

  init(_ visibility: SurfaceVisibility) {
    switch visibility {
    case .show: self = .show
    case .hide: self = .hide
    case .toggle: self = .toggle
    }
  }

  /// This effect, then `next`.
  func then(_ next: SurfaceVisibility) -> SurfaceEffect {
    switch next {
    case .show: return .show
    case .hide: return .hide
    case .toggle:
      switch self {
      case .unchanged: return .toggle
      case .toggle: return .unchanged
      case .show: return .hide
      case .hide: return .show
      }
    }
  }

  /// The one command with this effect; nil when it changes nothing.
  var visibility: SurfaceVisibility? {
    switch self {
    case .unchanged: return nil
    case .toggle: return .toggle
    case .show: return .show
    case .hide: return .hide
    }
  }
}

/// What a surface command does from what Flash knows: the Dock's view
/// (nil without its reports) and, for the panels and Launchpad, whether
/// they are open (nil when that cannot be read).
enum SystemSurfacePlanner {
  static func plan(
    _ command: SystemSurfaceCommand, dockView: DockView?, shown: Bool?
  ) -> SurfacePlan {
    let surface = command.surface
    if let target = surface.dockView {
      guard let dockView else {
        return command.visibility == .toggle
          ? .steps([.dockUnobserved(surface, shows: nil)])
          : .refused(
            "\(command.name): Flash has no report of the Dock's view (it needs "
              + "Accessibility, a running Dock, and a Dock that reports); "
              + "\(surface.rawValue) toggle still works")
      }
      let showing = dockView == target
      guard let show = wanted(command.visibility, showing: showing) else { return .steps([]) }
      guard show else { return .steps([.dock(surface, awaiting: .none)]) }
      return .steps(leaving(dockView) + [.dock(surface, awaiting: target)])
    }
    guard let shown else {
      guard command.visibility == .toggle else {
        return .refused(
          "\(command.name): "
            + (surface == .launchpad
              ? "this macOS does not report whether Launchpad is open"
              : "could not read whether \(surface.title) is open")
            + "; \(surface.rawValue) toggle still works")
      }
      return .steps(
        surface == .launchpad ? leaving(dockView) + [step(surface, nil)] : [step(surface, nil)])
    }
    guard let show = wanted(command.visibility, showing: shown) else { return .steps([]) }
    if surface == .launchpad, show {
      return .steps(leaving(dockView) + [step(surface, true)])
    }
    return .steps([step(surface, show)])
  }

  /// True to show, false to hide, nil when the surface already is as asked.
  private static func wanted(_ visibility: SurfaceVisibility, showing: Bool) -> Bool? {
    let show: Bool
    switch visibility {
    case .show: show = true
    case .hide: show = false
    case .toggle: show = !showing
    }
    return show == showing ? nil : show
  }

  /// A Dock request made from any Dock view returns to the windows instead
  /// of switching views, so another view is left first: its own request,
  /// then the Dock's report that it is gone.
  private static func leaving(_ dockView: DockView?) -> [SurfaceStep] {
    guard let dockView, let current = SystemSurface(dockView: dockView) else { return [] }
    return [.dock(current, awaiting: .none)]
  }

  private static func step(_ surface: SystemSurface, _ shows: Bool?) -> SurfaceStep {
    surface.dockNotification == nil
      ? .press(surface, shows: shows) : .dockUnobserved(surface, shows: shows)
  }
}

/// What the controller asks of macOS, behind a seam so the sequencing is
/// tested without opening anything on screen. Every call but `dockReports`
/// runs on the controller's queue.
protocol SystemSurfaceBackend: AnyObject {
  /// Where the observed Dock's notifications go, from any thread.
  var dockReports: ((pid_t, String) -> Void)? { get set }
  /// Ask the Dock to toggle `surface`; false when this macOS does not
  /// accept the request.
  func postDockNotification(for surface: SystemSurface) -> Bool
  /// Whether `surface` — Launchpad, Notification Center, Control Center —
  /// is on screen; nil when Flash cannot tell.
  func readShown(_ surface: SystemSurface) -> Bool?
  /// Press `surface`'s menu-bar item: nil, or why it could not.
  func press(_ surface: SystemSurface) -> String?
  /// The Dock process whose reports reach `dockReports`, registering on the
  /// one running now when it is not that one (a relaunch); nil while none is
  /// observed.
  func observeDock() -> pid_t?
  /// Run `body` on the controller's queue `ms` from now: the timeout
  /// bounding one wait for a Dock report.
  func after(_ ms: Int, _ body: @escaping () -> Void)
  /// Run `body` on the controller's queue `ms` from now, replacing a check
  /// still pending: one step of the ladder that confirms a panel press.
  func recheck(after ms: Int, _ body: @escaping () -> Void)
  /// Monotonic milliseconds.
  var nowMs: UInt64 { get }
}

/// Owns every system surface command and the trackpad gestures and keys
/// that open the same surfaces. Requests run one at a time on one serial
/// queue, never main: each plans from what Flash knows when its turn comes —
/// the Dock's view from the Dock's own Accessibility reports, a panel's from
/// one AX read of its process — so `show` and `hide` are idempotent and a
/// burst of toggles alternates. A Dock request waits for the report that
/// confirms it, bounded by `dockReportTimeoutMs`, before the next request
/// plans. A panel press waits the same way for the panel's process to show
/// or close it (`panelConfirmDelaysMs`), and requests for that panel queued
/// meanwhile fold into their net effect, so a burst of toggles ends as its
/// count says with as few presses as the panel can follow. A press the
/// panel never confirmed is trusted over a read for `panelSettleMs`.
final class SystemSurfaceController {
  /// How long a Dock request may go unconfirmed before its command fails.
  static let dockReportTimeoutMs = 1_500
  /// How long a press or Launchpad request stands in for a read of the
  /// panel it opened or closed.
  static let panelSettleMs = 1_000
  /// Reads that confirm a panel press, about 0.9 s in all: the panel's
  /// window appears as it starts sliding in and goes once it slid out.
  static let panelConfirmDelaysMs = [60, 120, 240, 480]

  private struct Request {
    let command: SystemSurfaceCommand
    let completion: (String?) -> Void
  }

  private struct Running {
    let request: Request
    var steps: ArraySlice<SurfaceStep>
    /// The Dock view being waited for, and the wait's timeout token.
    var awaiting: (view: DockView, surface: SystemSurface, token: UInt64)?
    /// The panel press being confirmed: the state it should reach, and the
    /// ladder step and token of the next read.
    var confirming: (surface: SystemSurface, shows: Bool, step: Int, token: UInt64)?
  }

  private struct Expectation {
    let shown: Bool
    let untilMs: UInt64
  }

  private let queue: DispatchQueue
  private let completionQueue: DispatchQueue
  private let backend: SystemSurfaceBackend
  /// Gets the Dock's view on the completion queue each time it changes (nil
  /// while Flash cannot know it): what `f` labels while Mission Control or
  /// App Exposé is up, and what NORMAL lets through to the Dock.
  private let dockViewChanged: ((DockView?) -> Void)?
  // Queue-confined.
  private var tracker = DockViewTracker()
  /// The view last published; `.none` (outer) before the first.
  private var publishedView: DockView??
  private var expectations: [SystemSurface: Expectation] = [:]
  private var waiting: [Request] = []
  private var running: Running?
  private var waitSerial: UInt64 = 0

  init(
    queue: DispatchQueue = DispatchQueue(label: "flash.system_surfaces", qos: .userInitiated),
    completionQueue: DispatchQueue = .main,
    backend: SystemSurfaceBackend? = nil,
    dockViewChanged: ((DockView?) -> Void)? = nil
  ) {
    self.queue = queue
    self.completionQueue = completionQueue
    self.dockViewChanged = dockViewChanged
    self.backend = backend ?? LiveSystemSurfaces(queue: queue)
    self.backend.dockReports = { [weak self] pid, notification in
      self?.queue.async { self?.dockReported(pid: pid, notification: notification) }
    }
  }

  /// Observe the Dock now, so a view the user opens before the first
  /// command is already known when it runs.
  func start() {
    queue.async { [self] in refreshDockObservation() }
  }

  /// An app launched: a relaunched Dock is observed again at once.
  func applicationLaunched(bundleIdentifier: String?) {
    guard bundleIdentifier == LiveSystemSurfaces.dockBundleIdentifier else { return }
    start()
  }

  /// `flash <surface> show|hide|toggle`; `completion` gets nil once done,
  /// or why it could not be, on the completion queue.
  func perform(_ command: SystemSurfaceCommand, completion: @escaping (String?) -> Void) {
    queue.async { [self] in
      waiting.append(Request(command: command, completion: completion))
      runNextIfIdle()
    }
  }

  // MARK: Queue

  private func refreshDockObservation() {
    let pid = backend.observeDock()
    if pid != tracker.pid { tracker.reset(pid: pid) }
    publishView()
  }

  /// Hand the Dock's view to `dockViewChanged` when it changed.
  private func publishView() {
    let view = tracker.knownView
    guard let dockViewChanged, publishedView != .some(view) else { return }
    publishedView = .some(view)
    completionQueue.async { dockViewChanged(view) }
  }

  /// A report from Dock `pid`. One from a Dock Flash has not caught up
  /// with (it began observing after a relaunch) first takes up that Dock;
  /// one from a Dock that is gone is dropped.
  private func dockReported(pid: pid_t, notification: String) {
    if pid != tracker.pid { refreshDockObservation() }
    guard pid == tracker.pid, tracker.observe(notification) else { return }
    FlashLog.debug("[surfaces] dock_view=\(tracker.view)")
    publishView()
    guard var run = running, let awaiting = run.awaiting, awaiting.view == tracker.view else {
      return
    }
    run.awaiting = nil
    running = run
    advance()
    runNextIfIdle()
  }

  private func runNextIfIdle() {
    while running == nil, !waiting.isEmpty {
      guard let request = foldedPanelRequest(waiting.removeFirst()) else { continue }
      refreshDockObservation()
      let surface = request.command.surface
      let shown = surface.dockView == nil ? currentShown(surface) : nil
      switch SystemSurfacePlanner.plan(
        request.command, dockView: tracker.knownView, shown: shown)
      {
      case .refused(let reason):
        finish(request, reason)
      case .steps(let steps):
        running = Running(request: request, steps: steps[...], awaiting: nil)
        advance()
      }
    }
  }

  /// `first` and the requests for the same menu-bar panel queued right
  /// after it, as one request of their net effect that completes them all;
  /// nil when they cancel out, already completed. Dock views keep running
  /// in turn: each waits for the Dock's report.
  private func foldedPanelRequest(_ first: Request) -> Request? {
    let surface = first.command.surface
    guard surface.dockView == nil, surface != .launchpad,
      waiting.first?.command.surface == surface
    else { return first }
    var effect = SurfaceEffect(first.command.visibility)
    var completions = [first.completion]
    while let next = waiting.first, next.command.surface == surface {
      waiting.removeFirst()
      effect = effect.then(next.command.visibility)
      completions.append(next.completion)
    }
    FlashLog.debug("[surfaces] \(surface.rawValue) folded=\(completions.count) effect=\(effect)")
    let complete: (String?) -> Void = { failure in
      for completion in completions { completion(failure) }
    }
    guard let visibility = effect.visibility else {
      // The burst cancels out: nothing to press.
      finish(Request(command: first.command, completion: complete), nil)
      return nil
    }
    return Request(command: SystemSurfaceCommand(surface, visibility), completion: complete)
  }

  /// A panel's state: what Flash just made it do while that settles, else a
  /// read.
  private func currentShown(_ surface: SystemSurface) -> Bool? {
    if let expected = expectations[surface] {
      if backend.nowMs < expected.untilMs { return expected.shown }
      expectations[surface] = nil
    }
    return backend.readShown(surface)
  }

  /// Run the current request's steps until one waits for a Dock report
  /// (`running` keeps it), or it ends (`running` is cleared).
  private func advance() {
    while var run = running {
      guard let step = run.steps.popFirst() else {
        return end(run.request, nil)
      }
      running = run
      switch step {
      case .dock(let surface, let view):
        guard backend.postDockNotification(for: surface) else {
          return end(run.request, Self.dockUnavailable)
        }
        waitSerial &+= 1
        let token = waitSerial
        run.awaiting = (view, surface, token)
        running = run
        backend.after(Self.dockReportTimeoutMs) { [weak self] in self?.timedOut(token) }
        return
      case .dockUnobserved(let surface, let shows):
        guard backend.postDockNotification(for: surface) else {
          return end(run.request, Self.dockUnavailable)
        }
        expect(surface, shows)
      case .press(let surface, let shows):
        if let failure = backend.press(surface) {
          return end(run.request, "\(run.request.command.name): \(failure)")
        }
        expect(surface, shows)
        guard let shows else { continue }
        // Wait for the panel to reach it before anything else plans.
        waitSerial &+= 1
        run.confirming = (surface, shows, 0, waitSerial)
        running = run
        scheduleConfirmation(token: waitSerial, step: 0)
        return
      }
    }
  }

  private func scheduleConfirmation(token: UInt64, step: Int) {
    backend.recheck(after: Self.panelConfirmDelaysMs[step]) { [weak self] in
      self?.confirm(token)
    }
  }

  /// One read of the panel being pressed: as asked, it is confirmed and the
  /// read is trusted again; not yet, the next step of the ladder; past the
  /// last, the press stands in for the read until it settles.
  private func confirm(_ token: UInt64) {
    guard var run = running, let confirming = run.confirming, confirming.token == token else {
      return
    }
    let shown = backend.readShown(confirming.surface)
    if shown == confirming.shows {
      expectations[confirming.surface] = nil
    } else if confirming.step + 1 < Self.panelConfirmDelaysMs.count {
      run.confirming = (
        confirming.surface, confirming.shows, confirming.step + 1, confirming.token
      )
      running = run
      return scheduleConfirmation(token: token, step: confirming.step + 1)
    } else {
      FlashLog.warn(
        "[surfaces] \(run.request.command.name): \(confirming.surface.title) did not "
          + "\(confirming.shows ? "open" : "close") yet; trusting the press")
    }
    run.confirming = nil
    running = run
    advance()
    runNextIfIdle()
  }

  private func expect(_ surface: SystemSurface, _ shows: Bool?) {
    expectations[surface] = shows.map {
      Expectation(shown: $0, untilMs: backend.nowMs + UInt64(Self.panelSettleMs))
    }
  }

  /// The Dock left a request unconfirmed. A `toggle` whose last request went
  /// out ran as asked, as it does without reports; anything else fails, since
  /// the state it asked for is unknown. Either way the Dock is silent until
  /// it reports again.
  private func timedOut(_ token: UInt64) {
    guard let run = running, let awaiting = run.awaiting, awaiting.token == token else { return }
    tracker.timedOut()
    publishView()
    let change = awaiting.view == .none ? "closing" : "opening"
    let failure =
      "\(run.request.command.name): the Dock did not report \(awaiting.surface.title) \(change)"
    if run.request.command.visibility == .toggle, run.steps.isEmpty {
      FlashLog.warn("[surfaces] \(failure); toggling blind until it reports")
      end(run.request, nil)
    } else {
      end(run.request, failure)
    }
    runNextIfIdle()
  }

  private func end(_ request: Request, _ failure: String?) {
    running = nil
    finish(request, failure)
  }

  private func finish(_ request: Request, _ failure: String?) {
    if let failure {
      FlashLog.warn("[surfaces] \(failure)", source: "core:Command")
    } else {
      FlashLog.debug("[surfaces] \(request.command.name) done")
    }
    completionQueue.async { request.completion(failure) }
  }

  private static let dockUnavailable =
    "this macOS does not accept Dock requests (CoreDockSendNotification is missing)"
}
