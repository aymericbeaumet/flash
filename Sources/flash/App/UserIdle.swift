import AppKit

/// How long nobody touched the keyboard, mouse or trackpad, and what to
/// announce about it: `core:user.idle` once per away episode at each
/// threshold the idle time passes, and `core:user.active` once input comes
/// back after any of them. Pure: the resident feeds it the session's idle
/// time on the shared clock and emits what it returns.
struct IdleWatch: Equatable {
  /// The idle time a subscriber that names none waits for.
  static let defaultSeconds = 300
  /// How often a user announced idle is checked for having come back. No
  /// event tap sees the pointer, so this read is the only witness, and it
  /// runs only while an episode is announced.
  static let returnProbeSeconds: Double = 2
  /// Accepted `[monitors.<name>] idle` values.
  static let secondsRange = 1...86_400

  enum Announcement: Equatable {
    /// The idle time reached `seconds`, one of the thresholds.
    case idle(seconds: Int)
    /// Input came back after an announced episode of `idleSeconds`.
    case active(idleSeconds: Int)
  }

  struct Step: Equatable {
    var announcements: [Announcement]
    /// Seconds until the next sample; nil while no threshold is watched.
    var nextSampleIn: Double?
  }

  private(set) var thresholds: [Int] = []
  /// Thresholds announced in the current episode.
  private(set) var announced: Set<Int> = []
  private var lastIdleSeconds: Double = 0

  /// One sample of the idle time, against the thresholds wanted now.
  mutating func sample(idleSeconds: Double, thresholds wanted: [Int]) -> Step {
    thresholds = Array(Set(wanted.filter { $0 > 0 })).sorted()
    var announcements: [Announcement] = []
    // The idle time only grows until input resets it.
    if idleSeconds < lastIdleSeconds {
      if !announced.isEmpty {
        announcements.append(.active(idleSeconds: Int(lastIdleSeconds.rounded())))
      }
      announced.removeAll()
    }
    lastIdleSeconds = idleSeconds
    announced.formIntersection(thresholds)
    for threshold in thresholds
    where Double(threshold) <= idleSeconds && !announced.contains(threshold) {
      announced.insert(threshold)
      announcements.append(.idle(seconds: threshold))
    }
    guard !thresholds.isEmpty else { return Step(announcements: announcements, nextSampleIn: nil) }
    var next = Double.infinity
    if let pending = thresholds.first(where: { !announced.contains($0) }) {
      next = Double(pending) - idleSeconds
    }
    if !announced.isEmpty { next = min(next, Self.returnProbeSeconds) }
    return Step(announcements: announcements, nextSampleIn: max(next, 0.05))
  }
}

/// Seconds since the last keyboard, mouse, trackpad or scroll input in the
/// session. Reads only that time, never what the input was.
enum UserInput {
  static let eventTypes: [CGEventType] = [
    .keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel, .flagsChanged,
  ]

  static func secondsSinceLastInput() -> Double {
    eventTypes.map {
      CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
    }.min() ?? 0
  }
}

/// `core:user.idle` and `core:user.active`, observed only while a plugin or
/// an event monitor listens to either (`HostEventSources`). Main thread only.
final class UserIdleMonitor: HostEventSource {
  private var watch = IdleWatch()
  /// `.low`: an away announcement a few seconds late changes nothing, and
  /// its slack lets the wake-up coalesce with the clock's others.
  private let deadline: PollDeadline
  private let thresholds: () -> [Int]
  private let readIdleSeconds: () -> Double
  private let announce: (IdleWatch.Announcement) -> Void

  init(
    thresholds: @escaping () -> [Int],
    readIdleSeconds: @escaping () -> Double = UserInput.secondsSinceLastInput,
    deadline: PollDeadline = PollDeadline("core:user-idle", priority: .low, on: .main),
    announce: @escaping (IdleWatch.Announcement) -> Void
  ) {
    self.thresholds = thresholds
    self.readIdleSeconds = readIdleSeconds
    self.deadline = deadline
    self.announce = announce
  }

  func start() { sample() }

  func stop() {
    deadline.cancel()
    watch = IdleWatch()
  }

  /// The thresholds changed (a configuration reload): sample now, so a
  /// lower one is not waited for at the old deadline.
  func refresh() {
    deadline.cancel()
    sample()
  }

  private func sample() {
    let step = watch.sample(idleSeconds: readIdleSeconds(), thresholds: thresholds())
    for announcement in step.announcements { announce(announcement) }
    guard let next = step.nextSampleIn else { return }
    deadline.arm(after: next) { [weak self] in self?.sample() }
  }
}
