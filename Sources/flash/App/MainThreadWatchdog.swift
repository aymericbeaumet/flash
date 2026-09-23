import Foundation

/// Detects main-thread starvation. The keyboard capture tap, every AX
/// observer source, and all mode logic share the main run loop — when it
/// stalls, keystrokes stall system-wide (and past the OS time budget the
/// session tap gets disabled outright). Stalls were previously invisible:
/// Flash's logging is event-driven, so a blocked main thread simply logs
/// nothing and the episode leaves no trace to diagnose after the fact.
///
/// A background timer pings main every `pingIntervalMs`; the pong measures
/// the round-trip. Anything over `stallThresholdMs` is logged with its
/// duration and the most recent main-thread activity labels, turning "the
/// keyboard felt dead for a moment" into a grep-able line that also says what
/// main was doing right before. `DispatchTime` is uptime-based (does not
/// advance during system sleep), so sleep/wake cannot fake a stall.
final class MainThreadWatchdog {
  static let pingIntervalMs = 250
  static let stallThresholdMs = 300.0
  static let activityRingSize = 8

  private let queue = DispatchQueue(label: "flash.main_thread_watchdog", qos: .userInitiated)
  private var registered = false
  private var awaitingPong = false
  private var pingSentAt = DispatchTime.now()

  // MARK: - Activity ring

  private struct Activity {
    var label: StaticString
    var at: DispatchTime
  }

  private static let activityLock = NSLock()
  private static var activities: [Activity] = []
  private static var activityCursor = 0

  /// Record that main is about to run `label`. Call at the top of every
  /// coarse main-thread unit of work (mode transition, config reload,
  /// activation, commit, key routing). `StaticString` keeps the call free of
  /// allocation; the lock is uncontended in practice.
  static func note(_ label: StaticString) {
    let entry = Activity(label: label, at: .now())
    activityLock.lock()
    if activities.count < activityRingSize {
      activities.append(entry)
    } else {
      activities[activityCursor] = entry
    }
    activityCursor = (activityCursor + 1) % activityRingSize
    activityLock.unlock()
  }

  /// Most recent labels first, each with its age relative to `now` in ms.
  static func recentActivity(now: DispatchTime = .now()) -> String {
    activityLock.lock()
    let snapshot = activities
    let cursor = activityCursor
    activityLock.unlock()
    guard !snapshot.isEmpty else { return "" }
    let ordered: [Activity]
    if snapshot.count < activityRingSize {
      ordered = snapshot.reversed()
    } else {
      ordered = (snapshot[cursor...] + snapshot[..<cursor]).reversed()
    }
    return ordered.map { activity in
      let ageMs = Double(now.uptimeNanoseconds &- activity.at.uptimeNanoseconds) / 1_000_000
      return "\(activity.label)(\(Int(ageMs.rounded())))"
    }.joined(separator: ",")
  }

  // MARK: - Ping

  /// The watchdog pings main four times a second, so it earns its keep only
  /// while someone can read the result. `[debug] log_level` decides.
  func setEnabled(_ enabled: Bool) {
    if enabled {
      start()
    } else {
      guard registered else { return }
      registered = false
      PollScheduler.shared.unregister(Self.clientID)
    }
  }

  static let clientID = "core:main_thread_watchdog"

  func start() {
    guard !registered else { return }
    registered = true
    // A stall measurement is only meaningful if the ping itself is punctual.
    PollScheduler.shared.register(
      Self.clientID, everyMs: Self.pingIntervalMs, priority: .system, on: queue
    ) { [weak self] in self?.ping() }
  }

  private func ping() {
    // Main hasn't answered the previous ping — it's mid-stall. Let that
    // ping's pong measure the full blockage instead of stacking pings, so
    // one contiguous stall produces one line with its total duration.
    guard !awaitingPong else { return }
    awaitingPong = true
    pingSentAt = DispatchTime.now()
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let pongAt = DispatchTime.now()
      let activity = MainThreadWatchdog.recentActivity(now: pongAt)
      self.queue.async {
        let ms =
          Double(pongAt.uptimeNanoseconds - self.pingSentAt.uptimeNanoseconds)
          / 1_000_000
        self.awaitingPong = false
        if ms >= Self.stallThresholdMs {
          FlashLog.warn(
            String(format: "[watchdog] main_thread_stall ms=%.0f", ms),
            fields: ["last_activity_ms_ago": activity])
        }
      }
    }
  }
}

/// Always-on stall detection at no idle cost. The main run loop reports when
/// it wakes and when it is about to sleep again; the time between is one busy
/// stretch — however many sources it served — and a stretch past the
/// threshold is a stall the keyboard tap sat behind. Unlike the ping
/// watchdog it needs no timer, so it runs at every log level; it reports once
/// main is free again, with the activity labels that led up to it.
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
    let activity = MainThreadWatchdog.recentActivity()
    FlashLog.warn(
      String(format: "[watchdog] main_busy ms=%.0f", ms),
      fields: ["last_activity_ms_ago": activity])
  }
}
