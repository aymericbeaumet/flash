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
    guard ms >= Self.stallThresholdMs else { return }
    let activity = MainThreadActivity.recent()
    FlashLog.warn(
      String(format: "[watchdog] main_busy ms=%.0f", ms),
      fields: ["last_activity_ms_ago": activity])
  }
}
