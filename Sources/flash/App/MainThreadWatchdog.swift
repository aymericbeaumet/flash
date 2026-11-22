import Foundation

/// The most recent coarse units of work the main thread started, so a stall
/// report can say what main was doing. The keyboard capture tap, every AX
/// observer source and all mode logic share the main run loop — when it
/// stalls, keystrokes stall system-wide (and past the OS time budget the
/// session tap gets disabled outright). `MainRunLoopStallObserver` measures
/// each stall with no timer; this ring names it.
enum MainThreadActivity {
  static let ringSize = 8

  private struct Activity {
    var label: StaticString
    var at: DispatchTime
  }

  private static let lock = NSLock()
  private static var activities: [Activity] = []
  private static var cursor = 0

  /// Record that main is about to run `label`. Call at the top of every
  /// coarse main-thread unit of work (mode transition, config reload,
  /// activation, commit, key routing). `StaticString` keeps the call free of
  /// allocation; the lock is uncontended in practice.
  static func note(_ label: StaticString) {
    let entry = Activity(label: label, at: .now())
    lock.lock()
    if activities.count < ringSize {
      activities.append(entry)
    } else {
      activities[cursor] = entry
    }
    cursor = (cursor + 1) % ringSize
    lock.unlock()
  }

  /// Most recent labels first, each with its age relative to `now` in ms.
  static func recent(now: DispatchTime = .now()) -> String {
    lock.lock()
    let snapshot = activities
    let cursor = self.cursor
    lock.unlock()
    guard !snapshot.isEmpty else { return "" }
    let ordered: [Activity]
    if snapshot.count < ringSize {
      ordered = snapshot.reversed()
    } else {
      ordered = (snapshot[cursor...] + snapshot[..<cursor]).reversed()
    }
    return ordered.map { activity in
      let ageMs = Double(now.uptimeNanoseconds &- activity.at.uptimeNanoseconds) / 1_000_000
      return "\(activity.label)(\(Int(ageMs.rounded())))"
    }.joined(separator: ",")
  }
}

/// Always-on stall detection at no idle cost. The main run loop reports when
/// it wakes and when it is about to sleep again; the time between is one busy
/// stretch — however many sources it served — and a stretch past the
/// threshold is a stall the keyboard tap sat behind. It needs no timer, so it
/// runs at every log level; it reports once main is free again, with the
/// activity labels that led up to it.
final class MainRunLoopStallObserver {
  static let stallThresholdMs = 250.0
  /// A busy stretch a keystroke can feel (three frames) but the tap
  /// survives: logged at info, so `bench:log-summary` shows what main
  /// spends its hitches on.
  static let hitchThresholdMs = 50.0

  private var observer: CFRunLoopObserver?
  private var busySince: UInt64?

  func start() {
    guard observer == nil else { return }
    let activities =
      CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
    let observer = CFRunLoopObserverCreateWithHandler(
      kCFAllocatorDefault, activities, true, CFIndex.max
    ) { [weak self] _, activity in
      self?.observe(activity, now: DispatchTime.now().uptimeNanoseconds)
    }
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    self.observer = observer
  }

  private func observe(_ activity: CFRunLoopActivity, now: UInt64) {
    if activity == .afterWaiting {
      busySince = now
      return
    }
    guard let started = busySince else { return }
    busySince = nil
    let ms = Double(now &- started) / 1_000_000
    switch Self.severity(ms: ms) {
    case nil:
      return
    case .hitch:
      FlashLog.info(
        String(format: "[watchdog] main_hitch ms=%.0f", ms),
        fields: ["last_activity_ms_ago": MainThreadActivity.recent()])
    case .stall:
      FlashLog.warn(
        String(format: "[watchdog] main_busy ms=%.0f", ms),
        fields: ["last_activity_ms_ago": MainThreadActivity.recent()])
    }
  }

  enum Severity: Equatable {
    case hitch
    case stall
  }

  /// How a busy stretch of `ms` is reported: nothing under a hitch.
  static func severity(ms: Double) -> Severity? {
    if ms >= stallThresholdMs { return .stall }
    if ms >= hitchThresholdMs { return .hitch }
    return nil
  }
}

/// Flash answers the keyboard: a key must be handled at once, not after App
/// Nap throttled the resident for looking idle (an agent app with no visible
/// window is a candidate). One activity, held for the life of the process,
/// keeps App Nap off while still letting the Mac and its displays sleep, and
/// leaves timer coalescing alone: `.latencyCritical` would defeat the slack
/// `PollScheduler` registrations declare.
enum ResidentActivity {
  static let options: ProcessInfo.ActivityOptions = [.userInitiatedAllowingIdleSystemSleep]

  static func begin() -> NSObjectProtocol {
    ProcessInfo.processInfo.beginActivity(
      options: options, reason: "Flash answers keyboard input as it arrives")
  }
}
