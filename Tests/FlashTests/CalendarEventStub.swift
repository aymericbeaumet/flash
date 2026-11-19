import Foundation

@testable import flash

/// The host's calendar for the tests: the events a test gave it and the
/// access it says macOS grants. It records every call and on which thread,
/// asks macOS nothing and reads no calendar of the Mac's.
final class CalendarEventStub: CalendarEventProviding {
  private let lock = NSLock()
  private var currentAccess: GrantAccess
  private let grants: Bool
  private var listing: HostCalendarListing
  private var askCount = 0
  private var readCount = 0
  private var mainCalls = false
  private var changeHandler: (@Sendable () -> Void)?
  private var readCalendars: [[String]] = []
  private var readRanges: [ClosedRange<Date>] = []
  private var pendingAnswers: [(Bool) -> Void] = []
  private let holdsAnswer: Bool

  /// `grants`: what the user answers the prompt. `holdsAnswer`: the prompt
  /// stays open until `answer()`.
  init(
    access: GrantAccess, grants: Bool = true, events: [HostCalendarEvent] = [],
    holdsAnswer: Bool = false
  ) {
    currentAccess = access
    self.grants = grants
    listing = .events(events)
    self.holdsAnswer = holdsAnswer
  }

  /// 2027-01-15 08:00:00 UTC, the instant the conformance corpus reads at.
  static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

  /// The calendar the conformance corpus describes: a stand-up at 08:12 in
  /// `Work`, with a URL, a room and a Zoom link in its notes, and a lunch at
  /// 10:00 in `Home`.
  static func corpus() -> CalendarEventStub {
    CalendarEventStub(
      access: .granted,
      events: [
        HostCalendarEvent(
          id: "E2@1800007200", title: "Lunch", start: t0.addingTimeInterval(7_200),
          end: t0.addingTimeInterval(10_800), calendar: "Home"),
        HostCalendarEvent(
          id: "E1@1800000720", title: "Standup", start: t0.addingTimeInterval(720),
          end: t0.addingTimeInterval(2_520), calendar: "Work",
          url: "https://example.com/standup", location: "Room 4",
          notes: "Agenda: demos.\nJoin Zoom Meeting (https://zoom.us/j/123?pwd=abc)."),
      ])
  }

  var asks: Int { locked { askCount } }
  var reads: Int { locked { readCount } }
  var calledOnMain: Bool { locked { mainCalls } }
  var observing: Bool { locked { changeHandler != nil } }
  var calendars: [[String]] { locked { readCalendars } }
  var ranges: [ClosedRange<Date>] { locked { readRanges } }
  var events: HostCalendarListing {
    get { locked { listing } }
    set { locked { listing = newValue } }
  }

  func access() -> GrantAccess {
    locked {
      mainCalls = mainCalls || Thread.isMainThread
      return currentAccess
    }
  }

  func requestAccess(_ done: @escaping (Bool) -> Void) {
    let answerNow = locked { () -> Bool in
      askCount += 1
      if holdsAnswer { pendingAnswers.append(done) }
      return !holdsAnswer
    }
    if answerNow { settle([done]) }
  }

  /// The user answers the open prompt.
  func answer() {
    settle(
      locked {
        defer { pendingAnswers = [] }
        return pendingAnswers
      })
  }

  private func settle(_ waiting: [(Bool) -> Void]) {
    let granted = locked { () -> Bool in
      currentAccess = grants ? .granted : .denied
      return grants
    }
    for done in waiting { DispatchQueue.global().async { done(granted) } }
  }

  /// As EventKit does: the events of the calendars named, or of all.
  func events(from start: Date, to end: Date, calendars: [String]) -> HostCalendarListing {
    locked {
      readCount += 1
      mainCalls = mainCalls || Thread.isMainThread
      readCalendars.append(calendars)
      readRanges.append(start...end)
      guard case .events(let events) = listing, !calendars.isEmpty else { return listing }
      return .events(events.filter { calendars.contains($0.calendar) })
    }
  }

  func observeChanges(_ onChange: @escaping @Sendable () -> Void) {
    locked { changeHandler = onChange }
  }
  func stopObservingChanges() { locked { changeHandler = nil } }
  /// The calendar database changed.
  func change() { locked { changeHandler }?() }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}
