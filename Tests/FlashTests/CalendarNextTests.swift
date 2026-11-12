import EventKit
import FlashCore
import XCTest

@testable import flash

/// The next-meeting values, `calendar join` and `calendar next`: which event
/// is next, what the values say and when they change, the meeting links found
/// in events, when the calendar is read and when macOS is asked. The reader
/// is a stub: no test touches the Mac's calendars or shows a prompt.
final class CalendarNextTests: XCTestCase {
  /// 2027-01-15 08:00:00 UTC.
  private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
  private static let utc = TimeZone(identifier: "UTC")!
  private static let zoom = MeetingLink(
    service: "Zoom", url: URL(string: "https://zoom.us/j/123")!,
    appURL: URL(string: "zoommtg://zoom.us/join?action=join&confno=123"))
  private static let meet = MeetingLink(
    service: "Google Meet", url: URL(string: "https://meet.google.com/abc-defg-hij")!)

  /// `minutes` after 08:00 UTC.
  private static func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

  private static func event(
    _ title: String, _ start: Double, _ end: Double, link: MeetingLink? = nil,
    allDay: Bool = false, declined: Bool = false, canceled: Bool = false
  ) -> CalendarEvent {
    CalendarEvent(
      id: "\(title)@\(start)", title: title, start: at(start), end: at(end), isAllDay: allDay,
      calendar: "Work", declined: declined, canceled: canceled, link: link)
  }

  private static func agenda(_ events: CalendarEvent..., hours: Int = 24) -> CalendarAgenda {
    CalendarAgenda(events: events, lookahead: TimeInterval(hours) * 3_600)
  }

  private func values(_ agenda: CalendarAgenda, at minutes: Double) -> [String: String] {
    CalendarNext.values(agenda, at: Self.at(minutes), timeZone: Self.utc)
  }

  // MARK: - Which event is next

  func testTheFirstEventToStartWithinTheLookAheadIsNext() {
    let agenda = Self.agenda(
      Self.event("Review", 120, 150), Self.event("Standup", 30, 45),
      Self.event("Later", 30 * 60, 30 * 60 + 30))
    XCTAssertEqual(CalendarNext.shown(agenda, at: Self.at(0))?.title, "Standup")
    XCTAssertEqual(CalendarNext.shown(agenda, at: Self.at(50))?.title, "Review")
    // Past the day's events, the next one is more than 24 hours away.
    XCTAssertNil(CalendarNext.shown(agenda, at: Self.at(151)))
    XCTAssertEqual(CalendarNext.shown(agenda, at: Self.at(6 * 60))?.title, "Later")
    XCTAssertNil(CalendarNext.shown(Self.agenda(), at: Self.at(0)))
  }

  /// MeetingBar's rule: a meeting that began stays next for ten minutes,
  /// long enough to join late, then the next one takes over.
  func testAnEventThatBeganStaysNextForItsFirstTenMinutes() {
    let agenda = Self.agenda(Self.event("Standup", 0, 60), Self.event("Review", 90, 120))
    XCTAssertEqual(CalendarNext.shown(agenda, at: Self.at(9.9))?.title, "Standup")
    XCTAssertEqual(CalendarNext.shown(agenda, at: Self.at(10))?.title, "Review")
    // A short meeting that ended is never next.
    let short = Self.agenda(Self.event("Ping", 0, 5))
    XCTAssertEqual(CalendarNext.shown(short, at: Self.at(4))?.title, "Ping")
    XCTAssertNil(CalendarNext.shown(short, at: Self.at(5)))
  }

  func testTheLatestToBeginWinsAndALinkBreaksATie() {
    let agenda = Self.agenda(Self.event("Focus", 0, 480), Self.event("Standup", 5, 20))
    XCTAssertEqual(CalendarNext.shown(agenda, at: Self.at(6))?.title, "Standup")
    let tie = Self.agenda(Self.event("Hold", 30, 60), Self.event("Call", 30, 60, link: Self.zoom))
    XCTAssertEqual(CalendarNext.shown(tie, at: Self.at(0))?.title, "Call")
    XCTAssertEqual(CalendarNext.shown(tie, at: Self.at(35))?.title, "Call")
  }

  func testSettingsDropCancelledAndByDefaultAllDayAndDeclinedEvents() {
    let normal = Self.event("Standup", 0, 15)
    let allDay = Self.event("Holiday", 0, 1_440, allDay: true)
    let declined = Self.event("Optional", 0, 30, declined: true)
    let canceled = Self.event("Gone", 0, 30, canceled: true)
    var settings = CalendarSettings()
    XCTAssertEqual(
      [normal, allDay, declined, canceled].filter(settings.admits).map(\.title), ["Standup"])
    settings.allDay = true
    settings.declined = true
    XCTAssertEqual(
      [normal, allDay, declined, canceled].filter(settings.admits).map(\.title),
      ["Standup", "Holiday", "Optional"])
    XCTAssertEqual(settings.lookahead, 86_400)
  }

  // MARK: - Values

  func testValuesCountDownInWholeMinutesRoundedUp() {
    let agenda = Self.agenda(Self.event("Standup", 12, 42, link: Self.meet))
    let values = values(agenda, at: 0.5)
    XCTAssertEqual(values["flash.calendar.next"], "Standup in 12m")
    XCTAssertEqual(values["flash.calendar.next_title"], "Standup")
    XCTAssertEqual(values["flash.calendar.next_in"], "in 12m")
    XCTAssertEqual(values["flash.calendar.next_minutes"], "12")
    XCTAssertEqual(values["flash.calendar.next_start"], "08:12")
    XCTAssertEqual(values["flash.calendar.next_end"], "08:42")
    XCTAssertEqual(values["flash.calendar.next_ongoing"], "")
    XCTAssertEqual(values["flash.calendar.next_link"], "https://meet.google.com/abc-defg-hij")
    XCTAssertEqual(Set(values.keys), Set(CalendarStatusValue.allCases.map(\.rawValue)))
    XCTAssertEqual(self.values(agenda, at: 11.5)["flash.calendar.next"], "Standup in 1m")
    XCTAssertEqual(self.values(agenda, at: 0)["flash.calendar.next_minutes"], "12")
  }

  func testAnEventInProgressIsNow() {
    let values = values(Self.agenda(Self.event("Standup", 0, 15)), at: 3)
    XCTAssertEqual(values["flash.calendar.next"], "Standup now")
    XCTAssertEqual(values["flash.calendar.next_in"], "now")
    XCTAssertEqual(values["flash.calendar.next_minutes"], "0")
    XCTAssertEqual(values["flash.calendar.next_ongoing"], "1")
    XCTAssertEqual(values["flash.calendar.next_link"], "")
  }

  func testNothingNextLeavesEveryValueUnknown() {
    XCTAssertEqual(values(Self.agenda(), at: 0), [:])
    XCTAssertEqual(values(Self.agenda(Self.event("Done", -60, -30)), at: 0), [:])
  }

  /// A title from someone else's invitation is text: never a style, a link or
  /// a click range, and always one line.
  func testATitleIsTextOnOneLine() {
    let agenda = Self.agenda(Self.event("#[range=user|x]1:1\n  #2", 5, 10))
    XCTAssertEqual(values(agenda, at: 0)["flash.calendar.next_title"], "##[range=user|x]1:1 ##2")
    let rendered = FlashStatusBarRenderer.segments(
      from: values(agenda, at: 0)["flash.calendar.next"] ?? "")
    XCTAssertEqual(rendered.map(\.text).joined(), "#[range=user|x]1:1 #2 in 5m")
    XCTAssertTrue(rendered.allSatisfy { $0.range == nil && $0.link == nil })
    XCTAssertEqual(Self.event("  ", 0, 1).displayTitle, "New Event")
  }

  func testDurationsAndClocks() {
    XCTAssertEqual(CalendarNext.duration(minutes: 1), "1m")
    XCTAssertEqual(CalendarNext.duration(minutes: 59), "59m")
    XCTAssertEqual(CalendarNext.duration(minutes: 60), "1h")
    XCTAssertEqual(CalendarNext.duration(minutes: 65), "1h 5m")
    XCTAssertEqual(CalendarNext.duration(minutes: 24 * 60), "1d")
    XCTAssertEqual(CalendarNext.duration(minutes: 27 * 60 + 30), "1d 3h")
    let paris = TimeZone(identifier: "Europe/Paris")!
    XCTAssertEqual(CalendarNext.clock(Self.t0, timeZone: Self.utc), "08:00")
    XCTAssertEqual(CalendarNext.clock(Self.t0, timeZone: paris), "09:00")
    // 2026-07-01 23:30 UTC is 01:30 the next day in Paris, in summer time.
    XCTAssertEqual(
      CalendarNext.clock(Date(timeIntervalSince1970: 1_782_948_600), timeZone: paris), "01:30")
    XCTAssertEqual(CalendarNext.noEventMessage(lookaheadHours: 24), "No event in the next 24 hours")
    XCTAssertEqual(CalendarNext.noEventMessage(lookaheadHours: 1), "No event in the next hour")
  }

  /// The templates docs/calendar.md shows.
  func testTheDocumentedTemplatesRender() {
    func render(_ template: String, _ values: [String: String]) -> [FlashStatusTextSegment] {
      FlashStatusBarTemplateEngine.render(
        template: .init(template: "#[align=right]" + template), context: FlashStatusBarContext(),
        dynamicValues: values
      ).rightDocument.filter { !$0.text.isEmpty }
    }
    let soon = values(Self.agenda(Self.event("Standup", 12, 42)), at: 0)
    let later = values(Self.agenda(Self.event("Review", 180, 210)), at: 0)
    let bar =
      "#{?flash.calendar.next,#[range=user|join]#[shrink]#{flash.calendar.next_title}#[noshrink]"
      + " #{flash.calendar.next_in}#[norange] · ,}X"
    XCTAssertEqual(render(bar, soon).map(\.text).joined(), "Standup in 12m · X")
    XCTAssertEqual(Set(render(bar, soon).compactMap(\.range)), ["join"])
    XCTAssertNil(render(bar, soon).last?.range)
    XCTAssertEqual(render(bar, [:]).map(\.text).joined(), "X")
    let gated =
      "#{?#{&&:#{flash.calendar.next},#{e|<=:#{flash.calendar.next_minutes},120}},"
      + "#{flash.calendar.next} · ,}X"
    XCTAssertEqual(render(gated, soon).map(\.text).joined(), "Standup in 12m · X")
    XCTAssertEqual(render(gated, later).map(\.text).joined(), "X")
    XCTAssertEqual(render(gated, [:]).map(\.text).joined(), "X")
  }

  // MARK: - When values change

  /// The values are read at the instant they change, never on a cadence: the
  /// countdown's next minute, then the start, the end of the grace, the end.
  func testTheNextChangeIsTheCountdownsNextMinuteOrAnEventBoundary() {
    let agenda = Self.agenda(Self.event("Standup", 12, 42))
    // 08:00:30: 11m30s left reads "12m" until 11m left, at 08:01:00.
    XCTAssertEqual(CalendarNext.nextChange(agenda, after: Self.at(0.5)), Self.at(1))
    XCTAssertEqual(CalendarNext.nextChange(agenda, after: Self.at(1)), Self.at(2))
    XCTAssertEqual(CalendarNext.nextChange(agenda, after: Self.at(11.2)), Self.at(12))
    XCTAssertEqual(CalendarNext.nextChange(agenda, after: Self.at(12)), Self.at(22))
    XCTAssertEqual(CalendarNext.nextChange(agenda, after: Self.at(22)), Self.at(42))
    XCTAssertNil(CalendarNext.nextChange(agenda, after: Self.at(42)))
    XCTAssertNil(CalendarNext.nextChange(Self.agenda(), after: Self.at(0)))
    // Nothing next: the next change is an event entering the look-ahead.
    let far = Self.agenda(Self.event("Later", 30 * 60, 31 * 60))
    XCTAssertEqual(CalendarNext.nextChange(far, after: Self.at(0)), Self.at(6 * 60))
    XCTAssertEqual(values(far, at: 6 * 60)["flash.calendar.next"], "Later in 1d")
  }

  // MARK: - Joining

  func testJoinOpensTheEventAboutToStartOrJustStarted() {
    let agenda = Self.agenda(
      Self.event("Standup", 0, 30, link: Self.zoom), Self.event("Review", 45, 60, link: Self.meet))
    XCTAssertEqual(
      CalendarNext.joinTarget(agenda, at: Self.at(-5)), .join(agenda.events[0], Self.zoom))
    XCTAssertEqual(
      CalendarNext.joinTarget(agenda, at: Self.at(5)), .join(agenda.events[0], Self.zoom))
    // Twenty minutes in, Review is next but forty minutes away: join rejoins
    // the meeting in progress.
    XCTAssertEqual(
      CalendarNext.joinTarget(agenda, at: Self.at(20)), .join(agenda.events[0], Self.zoom))
    // Ten minutes before Review, it is the one to join.
    XCTAssertEqual(
      CalendarNext.joinTarget(agenda, at: Self.at(35)), .join(agenda.events[1], Self.meet))
  }

  func testJoinFallsBackToTheNextEventsLinkAndSaysWhatIsMissing() {
    let later = Self.agenda(Self.event("Review", 120, 150, link: Self.meet))
    XCTAssertEqual(
      CalendarNext.joinTarget(later, at: Self.at(0)), .join(later.events[0], Self.meet))
    let lunch = Self.agenda(Self.event("Lunch", 30, 90))
    XCTAssertEqual(CalendarNext.joinTarget(lunch, at: Self.at(0)), .noLink(lunch.events[0]))
    XCTAssertEqual(CalendarNext.joinTarget(lunch, at: Self.at(60)), .noLink(lunch.events[0]))
    XCTAssertEqual(CalendarNext.joinTarget(Self.agenda(), at: Self.at(0)), .noEvent)
  }

  func testNextSummarizesTheShownEvent() {
    let agenda = Self.agenda(Self.event("Standup", 12, 42, link: Self.zoom))
    let summary = CalendarNext.summary(agenda, at: Self.at(0), timeZone: Self.utc)
    XCTAssertEqual(summary?.title, "Standup")
    XCTAssertEqual(summary?.detail, "in 12m · 08:12–08:42 · Zoom")
    XCTAssertEqual(
      CalendarNext.summary(agenda, at: Self.at(13), timeZone: Self.utc)?.detail,
      "now · 08:12–08:42 · Zoom")
    XCTAssertNil(CalendarNext.summary(Self.agenda(), at: Self.at(0)))
  }

  // MARK: - Meeting links

  private func link(url: String? = nil, location: String? = nil, notes: String? = nil)
    -> MeetingLink?
  {
    MeetingLinks.find(url: url.flatMap(URL.init(string:)), location: location, notes: notes)
  }

  func testEveryServiceIsFound() {
    let cases: [(String, String)] = [
      ("https://us02web.zoom.us/j/85748372?pwd=abc", "Zoom"),
      ("zoommtg://zoom.us/join?confno=1", "Zoom"),
      ("https://meet.google.com/abc-defg-hij", "Google Meet"),
      (
        "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0?context=%7b%7d",
        "Microsoft Teams"
      ),
      ("https://teams.live.com/meet/9387", "Microsoft Teams"),
      ("https://acme.webex.com/acme/j.php?MTID=m1", "Webex"),
      ("https://around.co/r/standup", "Around"),
      ("https://whereby.com/team-room", "Whereby"),
      ("https://facetime.apple.com/join#v=1&p=AbC&k=dEf", "FaceTime"),
      ("https://app.slack.com/huddle/T0123/C0456", "Slack huddle"),
      ("https://meet.jit.si/FlashStandup", "Jitsi Meet"),
      ("https://global.gotomeeting.com/join/123456789", "GoTo Meeting"),
      ("https://chime.aws/1234567890", "Amazon Chime"),
    ]
    for (url, service) in cases {
      let found = link(notes: "Join: \(url)\nThanks")
      XCTAssertEqual(found?.service, service, url)
      XCTAssertEqual(found?.url.absoluteString, url, url)
    }
  }

  func testTheJoinLinkIsTheFirstOneAndItsSentencePunctuationIsDropped() {
    let zoom = link(
      notes: """
        Find your local number: https://us02web.zoom.us/u/kdLx
        Join Zoom Meeting (https://us02web.zoom.us/j/857?pwd=x&amp;uname=a).
        Or https://meet.google.com/abc-defg-hij.
        """)
    XCTAssertEqual(zoom?.service, "Zoom")
    XCTAssertEqual(zoom?.url.absoluteString, "https://us02web.zoom.us/j/857?pwd=x&uname=a")
    XCTAssertEqual(
      link(notes: "<a href=\"https://meet.google.com/abc-defg-hij\">Join</a>")?.url.absoluteString,
      "https://meet.google.com/abc-defg-hij")
    // Webex's help pages are no meeting.
    XCTAssertNil(link(notes: "Help: https://help.webex.com/docs then https://www.webex.com/x"))
    XCTAssertNil(link(notes: "Agenda at https://example.com/agenda"))
  }

  func testTheURLThenTheLocationThenTheNotesAreRead() {
    let all = link(
      url: "https://meet.google.com/aaa-bbbb-ccc", location: "https://zoom.us/j/1",
      notes: "https://teams.live.com/meet/1")
    XCTAssertEqual(all?.service, "Google Meet")
    XCTAssertEqual(
      link(location: "Room 4 / https://zoom.us/j/1", notes: "https://teams.live.com/meet/1")?
        .service, "Zoom")
    // A URL or a location that is one web link is a meeting no service claims.
    XCTAssertEqual(
      link(url: "https://meet.acme.com/standup", notes: "https://zoom.us/j/1")?.service, "Zoom")
    let generic = link(url: "https://www.meet.acme.com/standup")
    XCTAssertEqual(generic?.service, "meet.acme.com")
    XCTAssertNil(generic?.appURL)
    XCTAssertEqual(link(location: "https://rooms.acme.com/4")?.service, "rooms.acme.com")
    XCTAssertNil(link(location: "Room 4, https://rooms.acme.com/4"))
    XCTAssertNil(link(url: "mailto:a@b.c", location: "Paris"))
    XCTAssertNil(link())
  }

  /// `calendar join` opens the meeting in its app when one handles it.
  func testZoomAndTeamsLinksHaveTheirAppsLinks() {
    XCTAssertEqual(
      link(notes: "https://acme.zoom.us/j/857?pwd=x1&uname=a")?.appURL?.absoluteString,
      "zoommtg://acme.zoom.us/join?action=join&confno=857&pwd=x1")
    XCTAssertEqual(
      link(notes: "https://zoom.us/j/857")?.appURL?.absoluteString,
      "zoommtg://zoom.us/join?action=join&confno=857")
    XCTAssertNil(link(notes: "https://zoom.us/my/alice")?.appURL)
    XCTAssertEqual(
      link(notes: "https://teams.microsoft.com/l/meetup-join/19%3am/0")?.appURL?.absoluteString,
      "msteams://teams.microsoft.com/l/meetup-join/19%3am/0")
    XCTAssertNil(link(notes: "https://meet.google.com/abc-defg-hij")?.appURL)
  }

  // MARK: - Reading the calendar

  private final class StubReader: CalendarEventReading {
    private let lock = NSLock()
    private var currentAccess: AppleCatalogAccess
    private let grants: Bool
    private var listing: CalendarEventListing
    private var askCount = 0
    private var readCount = 0
    private var accessReads = 0
    private var mainReads = false
    private var changeHandler: (() -> Void)?
    private var readCalendars: [[String]] = []
    private var readRanges: [ClosedRange<Date>] = []

    init(access: AppleCatalogAccess, grants: Bool = true, events: [CalendarEvent] = []) {
      currentAccess = access
      self.grants = grants
      listing = .events(events)
    }

    var asks: Int { locked { askCount } }
    var reads: Int { locked { readCount } }
    var accessChecks: Int { locked { accessReads } }
    var readOnMain: Bool { locked { mainReads } }
    var observing: Bool { locked { changeHandler != nil } }
    var calendars: [[String]] { locked { readCalendars } }
    var ranges: [ClosedRange<Date>] { locked { readRanges } }
    var events: CalendarEventListing {
      get { locked { listing } }
      set { locked { listing = newValue } }
    }

    func access() -> AppleCatalogAccess {
      locked {
        accessReads += 1
        mainReads = mainReads || Thread.isMainThread
        return currentAccess
      }
    }

    func requestAccess(_ done: @escaping (Bool) -> Void) {
      let granted = locked {
        askCount += 1
        currentAccess = grants ? .granted : .denied
        return grants
      }
      DispatchQueue.global().async { done(granted) }
    }

    func events(from start: Date, to end: Date, calendars: [String]) -> CalendarEventListing {
      locked {
        readCount += 1
        mainReads = mainReads || Thread.isMainThread
        readCalendars.append(calendars)
        readRanges.append(start...end)
        return listing
      }
    }

    func observeChanges(_ onChange: @escaping () -> Void) { locked { changeHandler = onChange } }
    func stopObservingChanges() { locked { changeHandler = nil } }
    func change() { locked { changeHandler }?() }

    private func locked<T>(_ body: () -> T) -> T {
      lock.lock()
      defer { lock.unlock() }
      return body()
    }
  }

  private final class Published {
    private let lock = NSLock()
    private var agendas: [CalendarAgenda?] = []
    func append(_ agenda: CalendarAgenda?) {
      lock.lock()
      agendas.append(agenda)
      lock.unlock()
    }
    var all: [CalendarAgenda?] {
      lock.lock()
      defer { lock.unlock() }
      return agendas
    }
  }

  private final class Opened {
    private let lock = NSLock()
    private var urls: [URL] = []
    func append(_ url: URL) {
      lock.lock()
      urls.append(url)
      lock.unlock()
    }
    var all: [URL] {
      lock.lock()
      defer { lock.unlock() }
      return urls
    }
  }

  private func owner(
    _ reader: StubReader, published: Published, opened: Opened = Opened(),
    appInstalled: Bool = true
  ) -> CalendarEvents {
    CalendarEvents(
      reader: reader, scheduler: PollScheduler(), now: { Self.at(0) },
      canOpen: { _ in appInstalled },
      open: { url, done in
        opened.append(url)
        done(nil)
      },
      publish: published.append)
  }

  private func waitUntil(
    _ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool
  ) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      guard Date() < deadline else { return XCTFail("timed out waiting for \(what)") }
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
  }

  private func perform(_ command: CalendarCommand, on events: CalendarEvents)
    -> CalendarCommandOutcome?
  {
    var outcome: CalendarCommandOutcome?
    let done = expectation(description: "calendar \(command)")
    events.perform(command) {
      outcome = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 10)
    return outcome
  }

  /// Configuring does not read: only a surface reading a value, or a
  /// command, does — so the default configuration never prompts.
  func testNothingIsReadUntilAValueIsShown() {
    let reader = StubReader(access: .undetermined)
    let published = Published()
    let events = owner(reader, published: published)
    events.configure(CalendarSettings(calendars: ["Work"]))
    events.drain()
    XCTAssertEqual(reader.accessChecks, 0)
    XCTAssertEqual(reader.asks, 0)
    XCTAssertTrue(published.all.isEmpty)
  }

  func testTheFirstShownValueAsksOnceThenReadsAndPublishes() {
    let reader = StubReader(
      access: .undetermined,
      events: [
        Self.event("Holiday", 0, 1_440, allDay: true), Self.event("Standup", 30, 45),
      ])
    let published = Published()
    let events = owner(reader, published: published)
    events.configure(CalendarSettings(calendars: ["Work"], lookaheadHours: 2))
    events.observe(true)
    waitUntil("the first read") { !published.all.isEmpty }
    XCTAssertEqual(reader.asks, 1)
    XCTAssertEqual(published.all.count, 1)
    XCTAssertEqual(published.all.first??.events.map(\.title), ["Standup"])
    XCTAssertEqual(published.all.first??.lookahead, 7_200)
    XCTAssertEqual(reader.calendars, [["Work"]])
    // Twice the look-ahead, so the values stay complete until the next read.
    XCTAssertEqual(reader.ranges, [Self.at(0)...Self.at(240)])
    XCTAssertTrue(reader.observing)
    XCTAssertFalse(reader.readOnMain)

    // A command reads again without asking; an unchanged read is not
    // published twice.
    XCTAssertEqual(
      perform(.next, on: events),
      .next(
        title: "Standup",
        detail:
          "in 30m · \(CalendarNext.clock(Self.at(30), timeZone: .current))–\(CalendarNext.clock(Self.at(45), timeZone: .current))"
      ))
    XCTAssertEqual(reader.asks, 1)
    XCTAssertEqual(reader.reads, 2)
    XCTAssertEqual(published.all.count, 1)

    events.observe(false)
    events.drain()
    XCTAssertFalse(reader.observing)
  }

  func testARefusedCalendarStaysEmptyAndQuiet() {
    let reader = StubReader(access: .undetermined, grants: false)
    let published = Published()
    let events = owner(reader, published: published)
    events.observe(true)
    waitUntil("the refusal") { !published.all.isEmpty }
    XCTAssertEqual(published.all.count, 1)
    XCTAssertNil(published.all.first ?? nil)
    XCTAssertEqual(reader.reads, 0)
    XCTAssertEqual(
      perform(.join, on: events),
      .failed(message: CalendarEvents.deniedMessage, log: "no Calendars access"))
    // Refused once, never asked again.
    XCTAssertEqual(reader.asks, 1)
  }

  func testADatabaseChangeIsReadOnceItSettles() {
    let reader = StubReader(access: .granted, events: [Self.event("Standup", 30, 45)])
    let published = Published()
    let events = owner(reader, published: published)
    events.observe(true)
    waitUntil("the first read") { published.all.count == 1 }
    reader.events = .events([Self.event("Standup", 30, 45), Self.event("Review", 60, 90)])
    reader.change()
    reader.change()
    waitUntil("the re-read") { published.all.count == 2 }
    XCTAssertEqual(published.all.last??.events.map(\.title), ["Standup", "Review"])
    XCTAssertEqual(reader.reads, 2, "a burst of changes is read once")
    // Not observed, a change reads nothing.
    events.observe(false)
    events.drain()
    reader.change()
    events.drain()
    XCTAssertEqual(reader.reads, 2)
  }

  func testJoinOpensTheMeetingInItsAppWhenOneHandlesIt() {
    let reader = StubReader(
      access: .granted, events: [Self.event("Standup", 2, 15, link: Self.zoom)])
    let opened = Opened()
    let events = owner(reader, published: Published(), opened: opened)
    XCTAssertEqual(
      perform(.join, on: events), .joined(title: "Standup", url: Self.zoom.appURL!))
    let web = owner(reader, published: Published(), opened: opened, appInstalled: false)
    XCTAssertEqual(perform(.join, on: web), .joined(title: "Standup", url: Self.zoom.url))
    XCTAssertEqual(opened.all, [Self.zoom.appURL!, Self.zoom.url])
  }

  func testCommandsSayWhyNothingOpened() {
    let reader = StubReader(access: .granted, events: [Self.event("Lunch", 30, 90)])
    let opened = Opened()
    let events = owner(reader, published: Published(), opened: opened)
    XCTAssertEqual(
      perform(.join, on: events),
      .failed(message: "Lunch has no meeting link", log: "no meeting link"))
    reader.events = .events([])
    XCTAssertEqual(
      perform(.join, on: events),
      .failed(message: "No event in the next 24 hours", log: "no event"))
    XCTAssertEqual(perform(.next, on: events), .noEvent("No event in the next 24 hours"))
    reader.events = .failed("boom")
    XCTAssertEqual(
      perform(.next, on: events),
      .failed(
        message: "Could not read your calendars: boom", log: "Could not read your calendars: boom"))
    XCTAssertTrue(opened.all.isEmpty)
  }

  func testEventKitAuthorizationReadsAsCatalogAccess() throws {
    XCTAssertEqual(EventKitAccess.access(.fullAccess), .granted)
    // macOS 13's `.authorized`, deprecated where the test bundle builds.
    let authorized = try XCTUnwrap(EKAuthorizationStatus(rawValue: 3))
    XCTAssertEqual(EventKitAccess.access(authorized), .granted)
    XCTAssertEqual(EventKitAccess.access(.notDetermined), .undetermined)
    XCTAssertEqual(EventKitAccess.access(.writeOnly), .denied)
    XCTAssertEqual(EventKitAccess.access(.denied), .denied)
    XCTAssertEqual(EventKitAccess.access(.restricted), .denied)
  }

  // MARK: - The status controller

  private final class Harness {
    let queue = DispatchQueue(label: "calendar.status.tests")
    var now: TimeInterval = 100
    /// 08:00:30 UTC.
    var wall = CalendarNextTests.at(0.5)
    var observed: [Bool] = []
    var alerts: [StatusAlert] = []
    /// The system time zone as the controller reads it.
    var zone = CalendarNextTests.utc
    var controller: FlashStatusBarController!

    init(_ template: String, monitors: [String: StatusMonitorSpec] = [:]) {
      controller = FlashStatusBarController(
        template: .init(template: template), refreshIntervalSeconds: 5,
        scheduler: PollScheduler(), queue: queue, clock: { [unowned self] in now },
        wallClock: { [unowned self] in wall },
        timeZone: { [unowned self] in zone },
        monitorAlertSink: { [weak self] in self?.alerts.append($0) },
        calendarObserver: { [unowned self] in observed.append($0) })
      if template.isEmpty { controller.setBar(enabled: false) }
      controller.updateMonitors(monitors)
      controller.start()
      drain()
    }

    func drain() { queue.sync {} }
    func advance(to minutes: Double) {
      queue.sync {
        now = 100 + (minutes - 0.5) * 60
        wall = CalendarNextTests.at(minutes)
        controller.tick()
      }
    }
    /// The bar's right lane as drawn.
    var bar: String {
      queue.sync { controller.lastPublishedModel?.rightDocument.map(\.text).joined() ?? "" }
    }
    var nextWakeup: TimeInterval? { queue.sync { controller.nextWakeup } }
    func settle() {
      drain()
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
  }

  /// The regression: the bar's clock read one zone and the next meeting's
  /// start another, and neither could follow a change the controller was
  /// told of. Both read the controller's zone, and a time-zone change
  /// re-renders them at once.
  func testATimeZoneChangeRerendersTheClockAndTheNextMeeting() throws {
    let harness = Harness("#[align=right]%H:%M #{flash.calendar.next_start}")
    defer { harness.controller.stop() }
    harness.controller.updateCalendarAgenda(Self.agenda(Self.event("Standup", 12, 42)))
    harness.drain()
    XCTAssertEqual(harness.bar, "08:00 08:12")
    harness.queue.sync { harness.zone = try! XCTUnwrap(TimeZone(identifier: "Asia/Tokyo")) }
    harness.controller.clockDidChange(reason: "time_zone")
    harness.drain()
    XCTAssertEqual(harness.bar, "17:00 17:12")
  }

  func testTheBarAsksForEventsOnlyWhileItShowsAValue() {
    let harness = Harness("#[align=right]#{flash.calendar.next}")
    defer { harness.controller.stop() }
    XCTAssertEqual(harness.observed, [true])
    harness.controller.updateCalendarAgenda(Self.agenda(Self.event("Standup", 12, 42)))
    harness.drain()
    XCTAssertEqual(harness.bar, "Standup in 12m")
    // The countdown wakes at its next minute, 30 s away, not on an interval.
    XCTAssertEqual(harness.nextWakeup, 130)
    harness.advance(to: 1)
    XCTAssertEqual(harness.bar, "Standup in 11m")
    XCTAssertEqual(harness.nextWakeup, 190)
    harness.advance(to: 12)
    XCTAssertEqual(harness.bar, "Standup now")

    harness.controller.updateTemplate(.init(template: "#[align=right]%H"))
    harness.drain()
    XCTAssertEqual(harness.observed, [true, false])
    // Events published once no surface reads them are dropped.
    harness.controller.updateCalendarAgenda(Self.agenda(Self.event("Review", 60, 90)))
    harness.controller.updateTemplate(.init(template: "#[align=right]#{flash.calendar.next}"))
    harness.drain()
    XCTAssertEqual(harness.observed, [true, false, true])
    XCTAssertEqual(harness.bar, "")
    harness.controller.stop()
    harness.drain()
    XCTAssertEqual(harness.observed, [true, false, true, false])
  }

  func testATemplateWithoutCalendarValuesNeverAsks() {
    let harness = Harness("#[align=right]#{flash.calendar} %H:%M #{flash.date}")
    defer { harness.controller.stop() }
    harness.controller.updateCalendarAgenda(Self.agenda(Self.event("Standup", 12, 42)))
    harness.drain()
    XCTAssertEqual(harness.observed, [])
  }

  /// The documented reminder: a monitor on the countdown alerts once the
  /// meeting is two minutes away, with the bar off.
  func testAMonitorOnTheCountdownAlertsBeforeTheMeeting() {
    let monitor = StatusMonitorSpec(
      value: .init(template: "#{flash.calendar.next_minutes}"),
      message: .init(template: "#{flash.calendar.next}"),
      warning: 2, direction: .below)
    let harness = Harness("", monitors: ["meeting": monitor])
    defer { harness.controller.stop() }
    XCTAssertEqual(harness.observed, [true])
    harness.controller.updateCalendarAgenda(Self.agenda(Self.event("Standup", 5, 30)))
    harness.drain()
    XCTAssertNotNil(harness.nextWakeup, "a monitor alone still wakes for the countdown")
    harness.advance(to: 2)
    harness.settle()
    XCTAssertTrue(harness.alerts.isEmpty)
    harness.advance(to: 3)
    harness.settle()
    XCTAssertEqual(harness.alerts.map(\.title), ["Standup in 2m"])
    XCTAssertEqual(harness.alerts.map(\.value), ["2"])
  }

  // MARK: - Commands and the bundle

  func testCommandsParseAndRoundTrip() {
    for command in CalendarCommand.allCases {
      let text = "calendar \(command.rawValue)"
      XCTAssertEqual(command.name.description, text)
      XCTAssertEqual(
        parseMappingCommand(argv: ["flash", "calendar", command.rawValue]),
        .flashCommand(.calendar(command)))
      XCTAssertEqual(URLCommand.calendar(command).diagnosticDescription, "flash " + text)
      XCTAssertEqual(NormalModeDispatcher.commandLineCoreCommand(":" + text), .calendar(command))
      XCTAssertNil(parseMappingCommand(argv: ["flash", "calendar", command.rawValue, "--now"]))
      XCTAssertFalse(URLCommand.calendar(command).explanation.isEmpty)
    }
    XCTAssertTrue(URLEventHandler.isTopic("calendar"))
    XCTAssertFalse(PluginRepository.declaresCommand("calendar"))
  }

  func testConfigurationReadsTheCalendarSection() {
    let config = ConfigLoader.parse(
      """
      [calendar]
      calendars = ["Work", "Family"]
      all_day = true
      declined = true
      lookahead_hours = 8
      """)
    XCTAssertEqual(
      config.calendar,
      CalendarSettings(
        calendars: ["Work", "Family"], allDay: true, declined: true, lookaheadHours: 8))
    XCTAssertTrue(config.loadingDiagnostics.isEmpty, "\(config.loadingDiagnostics.map(\.message))")
    let invalid = ConfigLoader.parse(
      """
      [calendar]
      calendars = "Work"
      all_day = "yes"
      lookahead_hours = 0
      unknown = 1
      """)
    XCTAssertEqual(invalid.calendar, CalendarSettings())
    let messages = invalid.loadingDiagnostics.map(\.message)
    for key in ["calendar.calendars", "calendar.all_day", "calendar.lookahead_hours", "unknown"] {
      XCTAssertTrue(messages.contains { $0.contains(key) }, "\(key): \(messages)")
    }
  }

  /// The regression: `flash config check` called every next-meeting value an
  /// unknown Flash value. Each value the controller provides validates in
  /// every status format that can read it: the bar, a text popup, a widget
  /// and a monitor.
  func testEveryNextMeetingValueValidatesWhereverAStatusFormatReadsIt() {
    let provided = values(Self.agenda(Self.event("Standup", 12, 42, link: Self.zoom)), at: 13)
    let names = CalendarStatusValue.allCases.map(\.rawValue)
    XCTAssertEqual(Set(provided.keys), Set(names))
    let all = names.map { "#{\($0)}" }.joined(separator: " ")
    let config = ConfigLoader.parse(
      """
      [statusbar]
      template = "\(all)"

      [popup.meeting]
      text = "\(all)"

      [widgets.meeting]
      template = "\(all)"

      [monitors.meeting]
      value = "#{flash.calendar.next_minutes}"
      direction = "below"
      warning = 2
      message = "\(all)"
      detail = "#{flash.calendar.next_link}"
      """)
    XCTAssertEqual(config.loadingDiagnostics.map(\.message), [])
    XCTAssertEqual(config.monitors["meeting"]?.value, "#{flash.calendar.next_minutes}")
  }

  func testAMisspelledNextMeetingValueIsUnknownAndNamesTheRealOnes() {
    let config = ConfigLoader.parse(
      """
      [statusbar]
      template = "#{flash.calendar.next_tilte} #{flash.calendar}"
      """)
    XCTAssertEqual(
      config.loadingDiagnostics.map(\.message),
      [
        "statusbar.template has unknown Flash value flash.calendar.next_tilte; the next-meeting "
          + "values are flash.calendar.next, flash.calendar.next_title, flash.calendar.next_in, "
          + "flash.calendar.next_minutes, flash.calendar.next_start, flash.calendar.next_end, "
          + "flash.calendar.next_ongoing, flash.calendar.next_link"
      ])
  }

  /// Every next-meeting value the manual, the README and the reference
  /// configuration name is one the controller provides, and the calendar
  /// guide documents each of them.
  func testTheDocumentedNextMeetingValuesAreTheProvidedOnes() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let pattern = try NSRegularExpression(pattern: #"flash\.calendar\.next[a-z_]*"#)
    func tokens(_ path: String) throws -> Set<String> {
      let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
      return Set(
        pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
          Range($0.range, in: text).map { String(text[$0]) }
        })
    }
    let names = Set(CalendarStatusValue.allCases.map(\.rawValue))
    XCTAssertEqual(try tokens("docs/calendar.md"), names)
    let docs = root.appendingPathComponent("docs")
    let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: docs.path))
    let pages = enumerator.compactMap { $0 as? String }.filter { $0.hasSuffix(".md") }
      .map { "docs/\($0)" }
    for path in pages + ["README.md", "config.default.toml"] {
      let unknown = try tokens(path).subtracting(names)
      XCTAssertTrue(unknown.isEmpty, "\(path) names \(unknown.sorted())")
    }
  }

  /// macOS kills an app that reads Calendar without saying why. macOS 14
  /// reads the full-access key, macOS 13 the original one.
  func testTheBundleExplainsTheRead() throws {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Resources/Info.plist")
    let info = try XCTUnwrap(
      try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        as? [String: Any])
    XCTAssertNotNil(info["NSCalendarsFullAccessUsageDescription"] as? String)
    XCTAssertEqual(
      info["NSCalendarsUsageDescription"] as? String,
      info["NSCalendarsFullAccessUsageDescription"] as? String)
  }
}
