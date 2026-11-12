import AppKit
import ApplicationServices
import FlashCore

/// The macOS side of `SystemSurfaceController`, on its queue: the Dock's
/// private request entry point, one AX observer on the Dock for its view
/// reports, and the Accessibility reads and presses of the panels.
///
/// - The Dock takes `CoreDockSendNotification`, resolved at run time; this is
///   the one place Flash calls it. A macOS without it fails the commands.
/// - The Dock posts `AXExposeShowAllWindows`, `AXExposeShowFrontWindows`,
///   `AXExposeShowDesktop` and `AXExposeExit` on its application element as
///   its views open and close, however they were opened.
/// - Notification Center and Control Center are pressed through Control
///   Center's own menu-bar items (`AXExtrasMenuBar`, by `AXIdentifier`); each
///   panel is open while its process (`com.apple.notificationcenterui`,
///   `com.apple.controlcenter`) shows an `AXSystemDialog` window.
/// - The Apps view of macOS 26 is Spotlight's panel: open while Spotlight
///   shows an `AXSystemDialog` window, which its search panel is too, so an
///   open Spotlight search counts as the Apps view.
final class LiveSystemSurfaces: SystemSurfaceBackend {
  static let dockBundleIdentifier = "com.apple.dock"
  static let controlCenterBundleIdentifier = "com.apple.controlcenter"
  static let spotlightBundleIdentifier = "com.apple.Spotlight"
  static let clockMenuExtra = "com.apple.menuextra.clock"
  static let controlCenterMenuExtra = "com.apple.menuextra.controlcenter"
  static let panelSubrole = "AXSystemDialog"
  /// The menu bar's status items as Control Center exposes them.
  static let extrasMenuBarAttribute = "AXExtrasMenuBar"
  /// Delays before re-registering what a Dock that is still launching
  /// refused (`kAXErrorCannotComplete`), as `AppMonitor` does for apps.
  static let registrationRetryDelaysMs = [60, 150, 400, 1_000, 3_000]

  private typealias DockSend = @convention(c) (CFString, Int32) -> Void
  /// The private `CoreDockSendNotification`; nil on a macOS without it.
  private static let dockSend: DockSend? = dlsym(
    UnsafeMutableRawPointer(bitPattern: -2), "CoreDockSendNotification"
  ).map { unsafeBitCast($0, to: DockSend.self) }

  var dockReports: ((pid_t, String) -> Void)? {
    get { Self.sink.deliver }
    set { Self.sink.deliver = newValue }
  }

  private let queue: DispatchQueue
  private let pollScheduler: PollScheduler
  /// Queue-confined.
  private var observation: DockObservation?
  private var registrationAttempt = 0

  init(queue: DispatchQueue, pollScheduler: PollScheduler = .shared) {
    self.queue = queue
    self.pollScheduler = pollScheduler
  }

  var nowMs: UInt64 { DispatchTime.now().uptimeNanoseconds / 1_000_000 }

  func after(_ ms: Int, _ body: @escaping () -> Void) {
    // A timeout bounding one wait for a Dock report, not a clock.
    queue.asyncAfter(deadline: .now() + .milliseconds(ms), execute: body)
  }

  func recheck(after ms: Int, _ body: @escaping () -> Void) {
    // Armed only while a panel press waits for its panel; `.high`: the user
    // just asked for it and the next request waits on it.
    pollScheduler.scheduleOnce(
      "core:surface_confirm", afterMs: ms, priority: .high, on: queue, handler: body)
  }

  func postDockNotification(for surface: SystemSurface) -> Bool {
    guard let name = surface.dockNotification, let send = Self.dockSend else { return false }
    send(name as CFString, 0)
    return true
  }

  func readShown(_ surface: SystemSurface) -> Bool? {
    switch surface {
    case .notificationCenter:
      return Self.showsPanel(bundleIdentifier: NotificationCenterSurface.bundleIdentifier)
    case .controlCenter:
      return Self.showsPanel(bundleIdentifier: Self.controlCenterBundleIdentifier)
    case .launchpad:
      // Before macOS 26 the Dock draws Launchpad and reports nothing about it.
      guard
        ProcessInfo.processInfo.isOperatingSystemAtLeast(
          OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
      else { return nil }
      return Self.showsPanel(bundleIdentifier: Self.spotlightBundleIdentifier)
    case .desktop, .missionControl, .appWindows:
      return nil
    }
  }

  func press(_ surface: SystemSurface) -> String? {
    let identifier: String
    switch surface {
    case .notificationCenter: identifier = Self.clockMenuExtra
    case .controlCenter: identifier = Self.controlCenterMenuExtra
    case .desktop, .missionControl, .appWindows, .launchpad:
      return "\(surface.title) has no menu-bar item"
    }
    guard let pid = Self.runningPID(Self.controlCenterBundleIdentifier) else {
      return "Control Center is not running"
    }
    let app = AXApp.make(pid: pid)
    guard let bar = Self.element(app, Self.extrasMenuBarAttribute),
      let items = Self.elements(bar, kAXChildrenAttribute)
    else { return "could not read the menu bar's status items" }
    guard
      let item = items.first(where: {
        Self.string($0, "AXIdentifier") == identifier
      })
    else { return "found no \(surface.title) item in the menu bar" }
    let status = AXUIElementPerformAction(item, kAXPressAction as CFString)
    guard status == .success else {
      return "pressing the \(surface.title) menu-bar item failed (AX error \(status.rawValue))"
    }
    return nil
  }

  func observeDock() -> pid_t? {
    let pid = Self.runningPID(Self.dockBundleIdentifier)
    if let observation, observation.pid == pid { return pid }
    observation?.stop()
    observation = nil
    guard let pid, PermissionCheck.isAccessibilityTrusted,
      let next = DockObservation(pid: pid)
    else { return nil }
    let refused = next.register(Array(DockViewTracker.reports.keys))
    guard let refused else {
      next.stop()
      FlashLog.warn("[surfaces] dock_observer_failed pid=\(pid)")
      return nil
    }
    observation = next
    registrationAttempt = 0
    retry(refused, on: next)
    FlashLog.debug("[surfaces] dock_observed pid=\(pid)")
    return pid
  }

  /// Register what a launching Dock refused on a bounded ladder. `.normal`:
  /// until a retry lands the Dock's reports go unseen, but nobody is waiting
  /// on the instant. Armed only while a Dock refused a registration.
  private func retry(_ refused: [String], on observation: DockObservation) {
    guard !refused.isEmpty else { return }
    guard registrationAttempt < Self.registrationRetryDelaysMs.count else {
      FlashLog.warn("[surfaces] dock_observer_gave_up refused=\(refused.count)")
      return
    }
    let delay = Self.registrationRetryDelaysMs[registrationAttempt]
    registrationAttempt += 1
    pollScheduler.scheduleOnce(
      "core:dock_observer_retry", afterMs: delay, priority: .normal, on: queue
    ) { [weak self, weak observation] in
      guard let self, let observation, self.observation === observation else { return }
      self.retry(observation.register(refused) ?? [], on: observation)
    }
  }

  // MARK: Accessibility

  static func runningPID(_ bundleIdentifier: String) -> pid_t? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
      .first { !$0.isTerminated }?.processIdentifier
  }

  /// Whether the process of `bundleIdentifier` shows a system-dialog
  /// window, the shape of an open panel; false when it is not running, nil
  /// when its windows cannot be read.
  static func showsPanel(bundleIdentifier: String) -> Bool? {
    guard let pid = runningPID(bundleIdentifier) else { return false }
    guard let windows = elements(AXApp.make(pid: pid), kAXWindowsAttribute) else { return nil }
    return windows.contains { string($0, kAXSubroleAttribute) == panelSubrole }
  }

  private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else {
      return nil
    }
    return raw
  }

  private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    guard let raw = value(element, attribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else {
      return nil
    }
    return (raw as! AXUIElement)
  }

  private static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
    value(element, attribute) as? [AXUIElement]
  }

  private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
    value(element, attribute) as? String
  }

  // MARK: The Dock's reports

  /// Where every Dock observer's callback goes. It lives as long as the
  /// process, so a callback already on its way when an observer is torn
  /// down never meets a freed refcon; the pid it carries tells the
  /// controller which Dock reported.
  private final class Sink {
    private let lock = NSLock()
    private var handler: ((pid_t, String) -> Void)?

    var deliver: ((pid_t, String) -> Void)? {
      get {
        lock.lock()
        defer { lock.unlock() }
        return handler
      }
      set {
        lock.lock()
        handler = newValue
        lock.unlock()
      }
    }
  }

  private static let sink = Sink()

  /// Runs on `AXObserverThread`.
  private static let callback: AXObserverCallback = { _, element, notification, _ in
    var pid: pid_t = 0
    guard AXUIElementGetPid(element, &pid) == .success else { return }
    sink.deliver?(pid, notification as String)
  }

  /// One AX observer on one Dock process.
  private final class DockObservation {
    let pid: pid_t
    private let observer: AXObserver
    private let element: AXUIElement
    private var registered: [String] = []

    init?(pid: pid_t) {
      var observer: AXObserver?
      guard AXObserverCreate(pid, LiveSystemSurfaces.callback, &observer) == .success,
        let observer
      else { return nil }
      self.pid = pid
      self.observer = observer
      element = AXApp.make(pid: pid)
      AXObserverThread.shared.add(AXObserverGetRunLoopSource(observer))
    }

    /// Register `names`: those refused because the Dock is not ready yet, or
    /// nil when any was refused for another reason.
    func register(_ names: [String]) -> [String]? {
      var refused: [String] = []
      for name in names {
        switch AXObserverAddNotification(observer, element, name as CFString, nil) {
        case .success, .notificationAlreadyRegistered: registered.append(name)
        case .cannotComplete: refused.append(name)
        default: return nil
        }
      }
      return refused
    }

    func stop() {
      AXObserverThread.shared.remove(AXObserverGetRunLoopSource(observer))
      for name in registered {
        _ = AXObserverRemoveNotification(observer, element, name as CFString)
      }
      registered = []
    }
  }
}
