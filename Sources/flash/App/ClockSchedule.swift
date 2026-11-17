import Foundation

/// A time of day to the minute, as a monitor's `at` names it and
/// `core:clock.minute` announces it: `"09:55"`, 24-hour.
struct ClockTime: Hashable, Comparable, CustomStringConvertible {
  let hour: Int
  let minute: Int

  init?(hour: Int, minute: Int) {
    guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
    self.hour = hour
    self.minute = minute
  }

  /// `HH:MM` exactly: two digits each, so `9:55` and `09:55:00` are typos,
  /// not times.
  init?(_ text: String) {
    let parts = text.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2,
      parts.allSatisfy({ $0.count == 2 && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
      let hour = Int(parts[0]), let minute = Int(parts[1])
    else { return nil }
    self.init(hour: hour, minute: minute)
  }

  var description: String { String(format: "%02d:%02d", hour, minute) }

  static func < (lhs: ClockTime, rhs: ClockTime) -> Bool {
    (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute)
  }
}

/// A day of the week as a monitor's `days` names it, in the calendar's
/// order (Sunday is 1).
enum Weekday: String, CaseIterable {
  case sun, mon, tue, wed, thu, fri, sat

  init?(calendarWeekday: Int) {
    guard Self.allCases.indices.contains(calendarWeekday - 1) else { return nil }
    self = Self.allCases[calendarWeekday - 1]
  }
}

/// What `core:clock.minute` announces, and when the clock is read next.
/// Pure: the resident feeds it the wall clock on the shared poll clock and
/// emits what it returns.
///
/// A minute is due when its first second has passed since the last read.
/// A plugin listener hears every minute; an event monitor only its `at`
/// times. A time the Mac slept or sat locked through is announced once on
/// the next read the same day, with how late it is, and only the latest of
/// the every-minute ones is: a wake never replays a night of minutes.
struct ClockWatch {
  struct Wants: Equatable {
    /// A plugin listens: every minute is news.
    var everyMinute = false
    /// The times event monitors fire at.
    var times: Set<ClockTime> = []

    var isEmpty: Bool { !everyMinute && times.isEmpty }
  }

  struct Announcement: Equatable {
    /// The minute's first second.
    var minute: Date
    var time: ClockTime
    var weekday: Weekday
    /// `YYYY-MM-DD`, in the current time zone.
    var date: String
    /// Whole seconds between the minute and the read that announced it.
    var lateSeconds: Int

    var payload: [String: Any] {
      [
        "time": time.description, "weekday": weekday.rawValue, "date": date,
        "late_seconds": lateSeconds,
      ]
    }
  }

  struct Step: Equatable {
    var announcements: [Announcement]
    /// The next due minute, or nil when nothing listens.
    var next: Date?
  }

  private(set) var wants = Wants()
  /// The latest read: minutes up to it are announced. Never moves back,
  /// so a clock stepped back a second cannot announce a minute twice.
  private(set) var lastRead: Date?

  /// Read the clock at `now`: announce what fell due since the last read,
  /// for the times wanted when it fell due, then watch `wanted` from here.
  mutating func read(now: Date, calendar: Calendar, wanted: Wants? = nil) -> Step {
    var announcements: [Announcement] = []
    if let lastRead, lastRead < now {
      let dayStart = calendar.startOfDay(for: now)
      // Only today's: a monitor at 17:00 does not run when Monday's wake
      // finds Friday evening missed.
      let lower = max(lastRead, dayStart.addingTimeInterval(-0.001))
      var due: Set<Date> = []
      for time in wants.times {
        if let minute = calendar.date(
          bySettingHour: time.hour, minute: time.minute, second: 0, of: now),
          minute > lower, minute <= now
        {
          due.insert(minute)
        }
      }
      if wants.everyMinute, let minute = calendar.dateInterval(of: .minute, for: now)?.start,
        minute > lower
      {
        due.insert(minute)
      }
      announcements = due.sorted().compactMap {
        Self.announcement(minute: $0, now: now, calendar: calendar)
      }
    }
    lastRead = max(lastRead ?? now, now)
    if let wanted { wants = wanted }
    return Step(announcements: announcements, next: next(after: now, calendar: calendar))
  }

  private func next(after now: Date, calendar: Calendar) -> Date? {
    var candidates: [Date] = []
    if wants.everyMinute, let minute = calendar.dateInterval(of: .minute, for: now) {
      candidates.append(minute.end)
    }
    for time in wants.times {
      if let date = calendar.nextDate(
        after: now, matching: DateComponents(hour: time.hour, minute: time.minute, second: 0),
        matchingPolicy: .nextTime)
      {
        candidates.append(date)
      }
    }
    return candidates.min()
  }

  private static func announcement(minute: Date, now: Date, calendar: Calendar) -> Announcement? {
    let parts = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .weekday], from: minute)
    guard let year = parts.year, let month = parts.month, let day = parts.day,
      let time = ClockTime(hour: parts.hour ?? -1, minute: parts.minute ?? -1),
      let weekday = Weekday(calendarWeekday: parts.weekday ?? 0)
    else { return nil }
    return Announcement(
      minute: minute, time: time, weekday: weekday,
      date: String(format: "%04d-%02d-%02d", year, month, day),
      lateSeconds: max(0, Int(now.timeIntervalSince(minute))))
  }
}

/// `core:clock.minute`, read only while a plugin or an event monitor listens
/// (`HostEventSources`): once at each due minute on the shared clock, and
/// again when the system clock or time zone changes. Main thread only.
final class ClockMinuteMonitor: HostEventSource {
  private var watch = ClockWatch()
  /// `.normal`: a run a moment past its minute changes nothing, but a
  /// reminder should not wait out the low priority's second of slack.
  private let deadline: PollDeadline
  private let wants: () -> ClockWatch.Wants
  private let now: () -> Date
  private let calendar: () -> Calendar
  private let announce: (ClockWatch.Announcement) -> Void
  private var observers: [NSObjectProtocol] = []

  init(
    wants: @escaping () -> ClockWatch.Wants,
    now: @escaping () -> Date = Date.init,
    calendar: @escaping () -> Calendar = ClockMinuteMonitor.currentCalendar,
    deadline: PollDeadline = PollDeadline("core:clock-minute", priority: .normal, on: .main),
    announce: @escaping (ClockWatch.Announcement) -> Void
  ) {
    self.wants = wants
    self.now = now
    self.calendar = calendar
    self.deadline = deadline
    self.announce = announce
  }

  /// Gregorian in the time zone as it stands, so a change of zone is read.
  static func currentCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .autoupdatingCurrent
    return calendar
  }

  func start() {
    guard observers.isEmpty else { return }
    // A set clock or a new zone moves every due minute: read and re-arm.
    observers = [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange].map {
      NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) {
        [weak self] _ in self?.read()
      }
    }
    read(wanted: wants())
  }

  func stop() {
    observers.forEach(NotificationCenter.default.removeObserver)
    observers = []
    deadline.cancel()
    watch = ClockWatch()
  }

  /// The listeners changed: announce what fell due for the old ones, then
  /// watch for the new, so a time added just after it passed does not fire.
  func refresh() { read(wanted: wants()) }

  private func read(wanted: ClockWatch.Wants? = nil) {
    let step = watch.read(now: now(), calendar: calendar(), wanted: wanted)
    for announcement in step.announcements { announce(announcement) }
    guard let next = step.next else { return deadline.cancel() }
    // Past the minute's first second, not on it, so the read finds it due.
    deadline.arm(after: next.timeIntervalSince(now()) + 0.05) { [weak self] in self?.read() }
  }
}
