import XCTest

@testable import flash

/// `core:clock.minute`: which minutes a read announces, when the clock is
/// read next, and which event monitors fire.
final class ClockScheduleTests: XCTestCase {
  private func calendar(_ zone: String = "UTC") -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
  }

  private func date(_ text: String, _ calendar: Calendar) -> Date {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return formatter.date(from: text)!
  }

  private func times(_ texts: String...) -> Set<ClockTime> { Set(texts.compactMap(ClockTime.init)) }

  /// Every read `run` makes from `start` to `end`, each at its step's next
  /// minute, as the monitor arms it.
  private func run(
    _ wants: ClockWatch.Wants, from start: Date, to end: Date, calendar: Calendar
  ) -> [ClockWatch.Announcement] {
    var watch = ClockWatch()
    var step = watch.read(now: start, calendar: calendar, wanted: wants)
    var heard: [ClockWatch.Announcement] = []
    var reads = 0
    while let next = step.next, next < end {
      reads += 1
      XCTAssertLessThan(reads, 5_000, "the watch must move forward")
      if reads >= 5_000 { break }
      step = watch.read(now: next.addingTimeInterval(0.05), calendar: calendar)
      heard += step.announcements
    }
    return heard
  }

  func testATimeIsTwoDigitHoursAndMinutes() {
    XCTAssertEqual(ClockTime("09:55")?.description, "09:55")
    XCTAssertEqual(ClockTime("00:00"), ClockTime(hour: 0, minute: 0))
    XCTAssertEqual(ClockTime("23:59"), ClockTime(hour: 23, minute: 59))
    for typo in ["9:55", "24:00", "09:60", "09:55:00", "ab:cd", "0955", "", "+9:55", "09:5５"] {
      XCTAssertNil(ClockTime(typo), typo)
    }
  }

  func testADayAnnouncesEachTimeOnceOnTimeWithItsDate() {
    let utc = calendar()
    let heard = run(
      .init(times: times("17:30", "09:55")), from: date("2026-10-23 08:00:00.000", utc),
      to: date("2026-10-24 08:00:00.000", utc), calendar: utc)
    XCTAssertEqual(heard.map(\.time.description), ["09:55", "17:30"])
    XCTAssertEqual(heard.map(\.lateSeconds), [0, 0])
    XCTAssertEqual(heard.first?.weekday, .fri)
    XCTAssertEqual(heard.first?.date, "2026-10-23")
    let payload = heard.first?.payload ?? [:]
    XCTAssertEqual(payload["time"] as? String, "09:55")
    XCTAssertEqual(payload["weekday"] as? String, "fri")
    XCTAssertEqual(payload["date"] as? String, "2026-10-23")
    XCTAssertEqual(payload["late_seconds"] as? Int, 0)
  }

  func testAPluginHearsEveryMinute() {
    let utc = calendar()
    let heard = run(
      .init(everyMinute: true), from: date("2026-10-23 00:00:30.000", utc),
      to: date("2026-10-24 00:00:30.000", utc), calendar: utc)
    XCTAssertEqual(heard.count, 1_440)
    XCTAssertEqual(heard.first?.time.description, "00:01")
    XCTAssertEqual(Set(heard.map(\.minute)).count, heard.count, "each minute once")
  }

  func testNothingWantedReadsNothing() {
    var watch = ClockWatch()
    let step = watch.read(now: Date(), calendar: calendar(), wanted: .init())
    XCTAssertNil(step.next)
    XCTAssertEqual(step.announcements, [])
  }

  /// A wake announces today's missed times once each, late, and only the
  /// current one of the every-minute stream.
  func testAWakeAnnouncesTodaysMissedTimesOnce() {
    let utc = calendar()
    var watch = ClockWatch()
    _ = watch.read(
      now: date("2026-10-23 08:00:00.050", utc), calendar: utc,
      wanted: .init(everyMinute: true, times: times("09:00", "12:00", "23:00")))
    let step = watch.read(now: date("2026-10-23 13:00:20.000", utc), calendar: utc)
    XCTAssertEqual(step.announcements.map(\.time.description), ["09:00", "12:00", "13:00"])
    XCTAssertEqual(step.announcements.map(\.lateSeconds), [14_420, 3_620, 20])
    XCTAssertEqual(step.next, date("2026-10-23 13:01:00.000", utc))
  }

  func testAWakeDoesNotReplayAnEarlierDay() {
    let utc = calendar()
    var watch = ClockWatch()
    _ = watch.read(
      now: date("2026-10-23 16:00:00.000", utc), calendar: utc,
      wanted: .init(times: times("17:00", "09:00")))
    let monday = watch.read(now: date("2026-10-26 10:00:00.000", utc), calendar: utc)
    XCTAssertEqual(monday.announcements.map(\.date), ["2026-10-26"])
    XCTAssertEqual(monday.announcements.map(\.time.description), ["09:00"])
    XCTAssertEqual(monday.next, date("2026-10-26 17:00:00.000", utc))
  }

  /// Changing the listeners first announces what fell due for the old ones,
  /// and a time added just after it passed waits for tomorrow.
  func testNewListenersStartFromNow() {
    let utc = calendar()
    var watch = ClockWatch()
    _ = watch.read(
      now: date("2026-10-23 09:50:00.000", utc), calendar: utc,
      wanted: .init(times: times("09:55")))
    var step = watch.read(
      now: date("2026-10-23 09:56:00.000", utc), calendar: utc,
      wanted: .init(times: times("09:53")))
    XCTAssertEqual(step.announcements.map(\.time.description), ["09:55"], "the old time was due")
    XCTAssertEqual(step.next, date("2026-10-24 09:53:00.000", utc))
    step = watch.read(now: date("2026-10-23 09:57:00.000", utc), calendar: utc)
    XCTAssertEqual(step.announcements, [], "the new time had passed when it was added")
  }

  func testAClockSteppedBackAnnouncesNoMinuteTwice() {
    let utc = calendar()
    var watch = ClockWatch()
    let wants = ClockWatch.Wants(times: times("09:55"))
    _ = watch.read(now: date("2026-10-23 09:54:00.000", utc), calendar: utc, wanted: wants)
    XCTAssertEqual(
      watch.read(now: date("2026-10-23 09:55:00.050", utc), calendar: utc).announcements.count, 1)
    XCTAssertEqual(
      watch.read(now: date("2026-10-23 09:54:59.900", utc), calendar: utc).announcements, [])
    XCTAssertEqual(
      watch.read(now: date("2026-10-23 09:55:00.100", utc), calendar: utc).announcements, [])
  }

  /// Daylight saving: a repeated time fires once, a skipped one at most
  /// once, and the watch always moves on.
  func testDaylightSavingDaysAnnounceATimeAtMostOnce() {
    let paris = calendar("Europe/Paris")
    let wants = ClockWatch.Wants(times: times("02:30", "12:00"))
    let autumn = run(
      wants, from: date("2026-10-25 00:00:00.000", paris),
      to: date("2026-10-26 00:00:00.000", paris), calendar: paris)
    XCTAssertEqual(autumn.map(\.time.description), ["02:30", "12:00"])
    let spring = run(
      wants, from: date("2026-03-29 00:00:00.000", paris),
      to: date("2026-03-30 00:00:00.000", paris), calendar: paris)
    XCTAssertEqual(spring.filter { $0.time.description == "12:00" }.count, 1)
    XCTAssertLessThanOrEqual(spring.count, 2)
  }

  func testAMonitorFiresAtItsTimesOnItsDays() throws {
    let config = ConfigLoader.parse(
      """
      [monitors.standup]
      event = "core:clock.minute"
      at = ["09:55", "13:55"]
      days = ["mon", "fri"]
      run = ["/bin/echo", "standup"]

      [monitors.daily]
      event = "core:clock.minute"
      at = "18:00"
      run = ["/bin/echo", "daily"]

      [monitors.everything]
      event = "core:*"
      run = ["/bin/echo", "any"]
      """)
    XCTAssertEqual(config.loadingDiagnostics.map(\.message), [])
    let standup = try XCTUnwrap(config.eventMonitorSpecs["standup"])
    func minute(_ time: String, _ weekday: String) -> PluginEvent {
      PluginEvent(
        .clockMinute,
        payload: ["time": time, "weekday": weekday, "date": "2026-10-23", "late_seconds": 0])
    }
    XCTAssertTrue(standup.matches(minute("09:55", "fri")))
    XCTAssertTrue(standup.matches(minute("13:55", "mon")))
    XCTAssertFalse(standup.matches(minute("09:55", "tue")), "not its day")
    XCTAssertFalse(standup.matches(minute("09:56", "fri")), "not its time")
    let daily = try XCTUnwrap(config.eventMonitorSpecs["daily"])
    XCTAssertTrue(daily.matches(minute("18:00", "sun")), "no days is every day")
    XCTAssertEqual(daily.clockTimes, times("18:00"))
    let everything = try XCTUnwrap(config.eventMonitorSpecs["everything"])
    XCTAssertFalse(everything.matches(minute("18:00", "sun")), "a glob without at hears no time")
    XCTAssertFalse(everything.listensToClock)
  }

  func testMalformedSchedulesAreReported() {
    let cases: [(String, String)] = [
      (#"event = "core:clock.minute"\#nat = "9:55""#, "monitors.m.at must be a time of day"),
      (
        #"event = "core:clock.minute"\#nat = "09:55"\#ndays = ["monday"]"#,
        "monitors.m.days must be a day of the week"
      ),
      (#"event = "core:system.woke"\#nat = "09:55""#, "monitors.m.at and .days time"),
      (#"event = "core:clock.minute"\#ndays = ["mon"]"#, "monitors.m.days narrows .at"),
      (#"event = "core:clock.minute""#, "monitors.m listens to core:clock.minute, which needs .at"),
    ]
    for (body, expected) in cases {
      let config = ConfigLoader.parse(
        """
        [monitors.m]
        \(body)
        run = ["/bin/echo", "m"]
        """)
      XCTAssertTrue(
        config.loadingDiagnostics.contains { $0.message.hasPrefix(expected) },
        "\(body): \(config.loadingDiagnostics.map(\.message))")
    }
  }

  func testTheMonitorArmsOnlyWhileATimeIsWanted() {
    var wants = ClockWatch.Wants()
    let deadline = PollDeadline(
      "test:clock-minute", priority: .normal, on: .main, scheduler: PollScheduler())
    let monitor = ClockMinuteMonitor(
      wants: { wants }, deadline: deadline, announce: { _ in XCTFail("nothing is due at start") })
    monitor.start()
    XCTAssertFalse(deadline.isArmed)
    wants.times = times("09:55")
    monitor.refresh()
    XCTAssertTrue(deadline.isArmed)
    monitor.stop()
    XCTAssertFalse(deadline.isArmed)
  }
}
