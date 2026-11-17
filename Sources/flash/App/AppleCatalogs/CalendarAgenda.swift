import Foundation

/// `[calendar]`: which events the next-meeting values and the `calendar`
/// commands count, and how far ahead they look.
struct CalendarSettings: Equatable {
  /// Calendars to read, by the title Calendar shows; empty reads every
  /// event calendar.
  var calendars: [String] = []
  /// Count all-day events.
  var allDay = false
  /// Count events the user declined.
  var declined = false
  /// How far ahead, in hours, the next event may start.
  var lookaheadHours = 24

  static let lookaheadHoursRange = 1...168

  var lookahead: TimeInterval { TimeInterval(lookaheadHours) * 3_600 }

  /// Whether `event` counts. A cancelled event never does.
  func admits(_ event: CalendarEvent) -> Bool {
    !event.canceled && (allDay || !event.isAllDay) && (declined || !event.declined)
  }
}

/// One occurrence of an event, as the calendar reader saw it.
struct CalendarEvent: Equatable {
  /// The event's identifier and this occurrence's start: a repeating
  /// event's occurrences share the identifier.
  var id: String
  var title: String
  var start: Date
  var end: Date
  var isAllDay = false
  /// The title of the calendar it belongs to.
  var calendar = ""
  /// The user is an attendee who declined it.
  var declined = false
  var canceled = false
  /// The meeting link found in its URL, location or notes.
  var link: MeetingLink?

  /// The title on one line, untitled events named as Calendar names them.
  var displayTitle: String {
    let words = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return words.isEmpty ? "New Event" : words
  }
}

/// The events of one read, in start order, and how far ahead of now an event
/// may start to be next. A read covers twice the look-ahead, and is read
/// again once one look-ahead has passed, so the values never miss an event
/// that entered the look-ahead since.
struct CalendarAgenda: Equatable {
  var events: [CalendarEvent]
  var lookahead: TimeInterval

  init(events: [CalendarEvent], lookahead: TimeInterval) {
    self.events = events.sorted {
      ($0.start, $0.end, $0.id) < ($1.start, $1.end, $1.id)
    }
    self.lookahead = lookahead
  }
}

/// `#{flash.calendar.next…}`: the next event, as text a status format shows.
enum CalendarStatusValue: String, CaseIterable {
  /// `Standup in 12m`, `Standup now`.
  case next = "flash.calendar.next"
  case title = "flash.calendar.next_title"
  /// `in 12m`, `in 1h 5m`, `now`.
  case until = "flash.calendar.next_in"
  /// Whole minutes until it starts, rounded up; `0` once it began.
  case minutes = "flash.calendar.next_minutes"
  /// `09:30`, local time.
  case start = "flash.calendar.next_start"
  case end = "flash.calendar.next_end"
  /// `1` once it began, empty before.
  case ongoing = "flash.calendar.next_ongoing"
  /// The meeting link as the event writes it; empty without one.
  case link = "flash.calendar.next_link"

  /// Whether a status format reading `name` reads the calendar.
  static func isCalendarValue(_ name: String) -> Bool {
    CalendarStatusValue(rawValue: name) != nil
  }
}

/// What `calendar join` opens.
enum CalendarJoinTarget: Equatable {
  case join(CalendarEvent, MeetingLink)
  /// The event it would join has no link.
  case noLink(CalendarEvent)
  case noEvent
}

/// Which event is next, what the values say about it, and when they next
/// change. Pure, so the rules are tested without a calendar.
enum CalendarNext {
  /// An event that began stays next for its first ten minutes, long enough
  /// to join it late; then the next one to start takes over.
  static let grace: TimeInterval = 600

  /// The event the values show at `now`: the latest to begin of those that
  /// began within `grace` and have not ended, else the first to begin within
  /// the look-ahead. At equal starts one with a meeting link comes first.
  static func shown(_ agenda: CalendarAgenda, at now: Date) -> CalendarEvent? {
    let begun = agenda.events.filter {
      $0.start <= now && now < $0.end && now < $0.start.addingTimeInterval(grace)
    }
    if let event = begun.min(by: { precedes($0, $1, latestFirst: true) }) { return event }
    let horizon = now.addingTimeInterval(agenda.lookahead)
    return agenda.events.filter { $0.start > now && $0.start <= horizon }
      .min(by: { precedes($0, $1, latestFirst: false) })
  }

  private static func precedes(
    _ lhs: CalendarEvent, _ rhs: CalendarEvent, latestFirst: Bool
  ) -> Bool {
    if lhs.start != rhs.start { return latestFirst ? lhs.start > rhs.start : lhs.start < rhs.start }
    if (lhs.link != nil) != (rhs.link != nil) { return lhs.link != nil }
    return (lhs.end, lhs.title, lhs.id) < (rhs.end, rhs.title, rhs.id)
  }

  /// Every `#{flash.calendar.next…}` value at `now`; empty when no event is
  /// next, so each value is unknown.
  static func values(
    _ agenda: CalendarAgenda, at now: Date, timeZone: TimeZone = .current
  ) -> [String: String] {
    guard let event = shown(agenda, at: now) else { return [:] }
    let ongoing = event.start <= now
    let minutes = ongoing ? 0 : minutesUntil(event.start, from: now)
    let until = ongoing ? "now" : "in " + duration(minutes: minutes)
    // `#` doubled: a title is text, never a style or a link.
    let title = event.displayTitle.replacingOccurrences(of: "#", with: "##")
    let values: [CalendarStatusValue: String] = [
      .next: "\(title) \(until)",
      .title: title,
      .until: until,
      .minutes: String(minutes),
      .start: clock(event.start, timeZone: timeZone),
      .end: clock(event.end, timeZone: timeZone),
      .ongoing: ongoing ? "1" : "",
      .link: event.link?.url.absoluteString ?? "",
    ]
    return Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
  }

  /// The first instant after `now` at which a value may change: the next
  /// minute of the countdown, or an event starting, ending, leaving its
  /// grace or entering the look-ahead. Nil when nothing will.
  static func nextChange(_ agenda: CalendarAgenda, after now: Date) -> Date? {
    var instants: [Date] = []
    for event in agenda.events {
      instants += [
        event.start.addingTimeInterval(-agenda.lookahead), event.start,
        event.start.addingTimeInterval(grace), event.end,
      ]
    }
    if let event = shown(agenda, at: now), event.start > now {
      // The countdown shows `ceil(remaining / 60)`: it drops a minute each
      // time the remaining time reaches a whole minute.
      let remaining = Double(minutesUntil(event.start, from: now) - 1) * 60
      instants.append(event.start.addingTimeInterval(-remaining))
    }
    return instants.filter { $0 > now }.min()
  }

  /// What `calendar join` opens at `now`: the shown event's link once it
  /// began or begins within `grace`; else that of the latest event in
  /// progress that has one, for rejoining a meeting; else the shown event's,
  /// however far ahead.
  static func joinTarget(_ agenda: CalendarAgenda, at now: Date) -> CalendarJoinTarget {
    let shown = shown(agenda, at: now)
    if let shown, let link = shown.link, shown.start <= now.addingTimeInterval(grace) {
      return .join(shown, link)
    }
    let inProgress = agenda.events.filter { $0.start <= now && now < $0.end }
    if let event = inProgress.filter({ $0.link != nil })
      .min(by: { precedes($0, $1, latestFirst: true) }), let link = event.link
    {
      return .join(event, link)
    }
    if let shown {
      return shown.link.map { .join(shown, $0) } ?? .noLink(shown)
    }
    if let event = inProgress.min(by: { precedes($0, $1, latestFirst: true) }) {
      return .noLink(event)
    }
    return .noEvent
  }

  /// `calendar next`: the shown event's title, and when it is, its times and
  /// its meeting service on one line (`in 12m · 09:30–10:00 · Zoom`).
  static func summary(
    _ agenda: CalendarAgenda, at now: Date, timeZone: TimeZone = .current
  ) -> (title: String, detail: String)? {
    guard let event = shown(agenda, at: now) else { return nil }
    let until =
      event.start <= now ? "now" : "in " + duration(minutes: minutesUntil(event.start, from: now))
    var parts = [
      until,
      "\(clock(event.start, timeZone: timeZone))–\(clock(event.end, timeZone: timeZone))",
    ]
    if let link = event.link { parts.append(link.service) }
    return (event.displayTitle, parts.joined(separator: " · "))
  }

  /// Whole minutes from `now` until `date`, rounded up: `1` in the last
  /// minute before it.
  static func minutesUntil(_ date: Date, from now: Date) -> Int {
    max(1, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
  }

  /// `12m`, `1h 5m`, `2h`, `1d 3h`.
  static func duration(minutes: Int) -> String {
    let hours = minutes / 60
    if hours == 0 { return "\(minutes)m" }
    if hours >= 24 {
      let days = hours / 24
      return hours % 24 == 0 ? "\(days)d" : "\(days)d \(hours % 24)h"
    }
    return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m"
  }

  /// `HH:mm` in `timeZone`, from the zone's offset at that instant: no
  /// formatter, so the controller and the calendar queue can both call it.
  static func clock(_ date: Date, timeZone: TimeZone) -> String {
    let local = Int(date.timeIntervalSince1970.rounded(.down)) + timeZone.secondsFromGMT(for: date)
    let seconds = ((local % 86_400) + 86_400) % 86_400
    let hour = seconds / 3_600
    let minute = seconds % 3_600 / 60
    return (hour < 10 ? "0" : "") + "\(hour):" + (minute < 10 ? "0" : "") + "\(minute)"
  }

  /// Why there is nothing to show within `lookaheadHours`.
  static func noEventMessage(lookaheadHours: Int) -> String {
    "No event in the next \(lookaheadHours == 1 ? "hour" : "\(lookaheadHours) hours")"
  }
}
