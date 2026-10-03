import AppKit
import FlashTerminal
import XCTest

@testable import flash

final class CalendarStatusDocumentTests: XCTestCase {
  private let utc = TimeZone(secondsFromGMT: 0)!
  private let paris = TimeZone(identifier: "Europe/Paris")!
  private let monthStarts = [0, 26, 52]

  private func date(
    _ year: Int, _ month: Int, _ day: Int, hour: Int = 12, minute: Int = 0,
    in timeZone: TimeZone? = nil
  ) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone ?? utc
    return calendar.date(
      from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
  }

  private func popup(
    at now: Date, timeZone: TimeZone? = nil,
    cache: FlashStatusBarTemplateEngine.PopupEvaluationCache? = nil
  ) -> [FlashStatusTextSegment] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone ?? utc
    let result = FlashStatusBarTemplateEngine.evaluate(
      template: FlashStatusBarTemplate(template: "#[popup=date]date#[nopopup]"),
      popupTemplates: ["date": FlashStatusBarTemplate(template: "#{flash.calendar}")],
      context: FlashStatusBarContext(now: now, calendar: calendar), popupCache: cache)
    return result.model.popupDocuments["date"] ?? []
  }

  private func text(_ runs: [FlashStatusTextSegment]) -> String {
    runs.map(\.text).joined()
  }

  private func lines(at now: Date, in timeZone: TimeZone? = nil) -> [String] {
    text(popup(at: now, timeZone: timeZone)).components(separatedBy: "\n")
  }

  private func line(_ label: String, in lines: [String]) throws -> String {
    try XCTUnwrap(lines.first { $0.hasPrefix(label + " ") }, label)
  }

  /// The month titles line and the week rows under the weekday header.
  private func monthRows(_ lines: [String]) throws -> (titles: String, weeks: [String]) {
    let header = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("Wk Mo") })
    return (
      lines[header - 1], Array(lines.dropFirst(header + 1).prefix { !$0.isEmpty })
    )
  }

  private func block(_ line: String, _ index: Int) -> String {
    let characters = Array(line)
    let start = monthStarts[index]
    guard start < characters.count else { return "" }
    return String(characters[start..<min(characters.count, start + 23)])
      .trimmingCharacters(in: .whitespaces)
  }

  func testTodaySitsInTheCentreOfThreeAlignedMonths() throws {
    let runs = popup(at: date(2026, 9, 30, in: paris), timeZone: paris)
    let lines = text(runs).components(separatedBy: "\n")

    XCTAssertEqual(
      lines[0],
      "Wednesday, September 30, 2026" + String(repeating: " ", count: 34) + "Europe/Paris")
    let rows = try monthRows(lines)
    XCTAssertEqual(
      rows.titles, "       August 2026              September 2026             October 2026")
    XCTAssertEqual(
      lines[3],
      "Wk Mo Tu We Th Fr Sa Su   Wk Mo Tu We Th Fr Sa Su   Wk Mo Tu We Th Fr Sa Su")
    XCTAssertEqual(
      rows.weeks,
      [
        "31                 1  2   36     1  2  3  4  5  6   40           1  2  3  4",
        "32  3  4  5  6  7  8  9   37  7  8  9 10 11 12 13   41  5  6  7  8  9 10 11",
        "33 10 11 12 13 14 15 16   38 14 15 16 17 18 19 20   42 12 13 14 15 16 17 18",
        "34 17 18 19 20 21 22 23   39 21 22 23 24 25 26 27   43 19 20 21 22 23 24 25",
        "35 24 25 26 27 28 29 30   40 28 29 30               44 26 27 28 29 30 31",
        "36 31",
      ])
    XCTAssertEqual(runs.filter { $0.reverse && !$0.text.isEmpty }.map(\.text), ["30"])
    XCTAssertTrue(runs.filter(\.reverse).allSatisfy(\.bold))
    XCTAssertEqual(
      runs.filter { $0.bold && $0.text.hasSuffix("2026") }.map(\.text),
      ["Wednesday, September 30, 2026", "September 2026"], "only the centre month is bold")
    XCTAssertEqual(
      runs.filter { $0.bold && !$0.dim && $0.text == "40" }.count, 1,
      "today's week number stands out once")
    XCTAssertTrue(
      runs.contains { $0.dim && $0.text == "27" }, "weekends stay dimmed in every month")
    for line in lines {
      XCTAssertLessThanOrEqual(line.count, CalendarStatusDocument.columns, line)
      XCTAssertFalse(line.hasSuffix(" "), "no trailing blanks: \(line)")
    }
  }

  func testEveryMonthLandsOnItsISOWeekdaysAndWeeks() throws {
    var iso = Calendar(identifier: .gregorian)
    iso.timeZone = utc
    iso.firstWeekday = 2
    iso.minimumDaysInFirstWeek = 4
    iso.locale = Locale(identifier: "en_US_POSIX")
    for year in 2023...2027 {
      for month in 1...12 {
        let lines = lines(at: date(year, month, 15))
        let rows = try monthRows(lines)
        for (index, offset) in [-1, 0, 1].enumerated() {
          let first = iso.date(byAdding: .month, value: offset, to: date(year, month, 1))!
          let days = iso.range(of: .day, in: .month, for: first)!.count
          let leading = (iso.component(.weekday, from: first) + 5) % 7
          let context = "\(year)-\(month) block \(index)"
          XCTAssertEqual(
            block(rows.titles, index),
            "\(iso.monthSymbols[iso.component(.month, from: first) - 1]) "
              + "\(iso.component(.year, from: first))", context)
          let used = (leading + days + 6) / 7
          for (row, line) in rows.weeks.enumerated() {
            let cells = Array(line)
            guard row < used else {
              XCTAssertEqual(block(line, index), "", "\(context) row \(row) is blank")
              continue
            }
            let start = monthStarts[index]
            let monday = iso.date(byAdding: .day, value: row * 7 - leading, to: first)!
            XCTAssertEqual(
              String(cells[start..<start + 2]),
              String(format: "%02d", iso.component(.weekOfYear, from: monday)), context)
            for column in 0..<7 {
              let day = row * 7 + column - leading + 1
              let position = start + 3 + column * 3
              let cell =
                position < cells.count
                ? String(cells[position..<min(cells.count, position + 2)]) : ""
              XCTAssertEqual(
                cell.trimmingCharacters(in: .whitespaces),
                (1...days).contains(day) ? String(day) : "", "\(context) \(row):\(column)")
            }
          }
          XCTAssertGreaterThanOrEqual(rows.weeks.count, used, context)
        }
        XCTAssertEqual(
          rows.weeks.count,
          [-1, 0, 1].map { offset -> Int in
            let first = iso.date(byAdding: .month, value: offset, to: date(year, month, 1))!
            let leading = (iso.component(.weekday, from: first) + 5) % 7
            return (leading + iso.range(of: .day, in: .month, for: first)!.count + 6) / 7
          }.max(), "\(year)-\(month) has only the rows its tallest month needs")
      }
    }
  }

  func testDecemberAndJanuaryRollTheYearOver() throws {
    let december = lines(at: date(2026, 12, 31))
    let rows = try monthRows(december)
    XCTAssertEqual(
      [0, 1, 2].map { block(rows.titles, $0) },
      ["November 2026", "December 2026", "January 2027"])
    XCTAssertEqual(block(rows.weeks[0], 2), "53              1  2  3")
    XCTAssertEqual(block(rows.weeks[1], 2), "01  4  5  6  7  8  9 10")
    XCTAssertEqual(block(rows.weeks[4], 1), "53 28 29 30 31")
    XCTAssertTrue(try line("2026", in: december).hasSuffix("365/365  last day"))
    XCTAssertTrue(try line("Q4", in: december).hasSuffix("92/92  last day"))
    XCTAssertTrue(try line("Week 53", in: december).hasSuffix("4/7  3 days left"))

    let january = lines(at: date(2027, 1, 1))
    let next = try monthRows(january)
    XCTAssertTrue(january[0].hasPrefix("Friday, January 1, 2027"))
    XCTAssertEqual(
      [0, 1, 2].map { block(next.titles, $0) },
      ["December 2026", "January 2027", "February 2027"])
    XCTAssertEqual(block(next.weeks[4], 0), "53 28 29 30 31")
    XCTAssertTrue(try line("2027", in: january).hasSuffix("1/365  364 days left"))
    XCTAssertTrue(try line("January", in: january).hasSuffix("1/31  30 days left"))
    XCTAssertTrue(try line("Q1", in: january).hasSuffix("1/90  89 days left"))
    XCTAssertTrue(try line("Week 53", in: january).hasSuffix("5/7  2 days left"))
  }

  func testProgressCountsTodayThroughItsWeekMonthQuarterAndYear() throws {
    let lines = lines(at: date(2026, 9, 30, in: paris), in: paris)
    XCTAssertEqual(
      try line("Week 40", in: lines), "Week 40     ████████▋                 3/7  4 days left")
    XCTAssertEqual(
      try line("September", in: lines), "September   ████████████████████    30/30  last day")
    XCTAssertEqual(
      try line("Q3", in: lines), "Q3          ████████████████████    92/92  last day")
    XCTAssertEqual(
      try line("2026", in: lines), "2026        ███████████████       273/365  92 days left")

    let leap = self.lines(at: date(2024, 2, 29))
    XCTAssertTrue(try line("Week 09", in: leap).hasSuffix("4/7  3 days left"))
    XCTAssertTrue(try line("February", in: leap).hasSuffix("29/29  last day"))
    XCTAssertTrue(try line("Q1", in: leap).hasSuffix("60/91  31 days left"))
    XCTAssertTrue(try line("2024", in: leap).hasSuffix("60/366  306 days left"))
  }

  func testTimeZoneAndNextDaylightSavingTransition() throws {
    let september = lines(at: date(2026, 9, 30, in: paris), in: paris)
    XCTAssertTrue(try line("Time zone", in: september).hasPrefix("Time zone   UTC+02:00 · "))
    XCTAssertEqual(
      try line("DST", in: september), "DST         Ends Sun Oct 25 · 03:00 → 02:00 · in 25 days")
    XCTAssertEqual(
      try line("DST", in: lines(at: date(2026, 10, 24, in: paris), in: paris)),
      "DST         Ends Sun Oct 25 · 03:00 → 02:00 · tomorrow")

    let losAngeles = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
    let spring = lines(at: date(2026, 3, 1, in: losAngeles), in: losAngeles)
    XCTAssertTrue(try line("Time zone", in: spring).hasPrefix("Time zone   UTC-08:00"))
    XCTAssertEqual(
      try line("DST", in: spring), "DST         Starts Sun Mar 8 · 02:00 → 03:00 · in 7 days")

    let lordHowe = try XCTUnwrap(TimeZone(identifier: "Australia/Lord_Howe"))
    let halfHour = lines(at: date(2026, 10, 1, in: lordHowe), in: lordHowe)
    XCTAssertTrue(try line("Time zone", in: halfHour).hasPrefix("Time zone   UTC+10:30"))
    XCTAssertEqual(
      try line("DST", in: halfHour), "DST         Starts Sun Oct 4 · 02:00 → 02:30 · in 3 days")
  }

  func testZonesWithoutDaylightSavingSayNotObserved() throws {
    for (identifier, offset) in [
      ("UTC", "+00:00"), ("Asia/Tokyo", "+09:00"), ("Asia/Kolkata", "+05:30"),
    ] {
      let zone = try XCTUnwrap(TimeZone(identifier: identifier))
      let lines = lines(at: date(2026, 7, 1, in: zone), in: zone)
      XCTAssertTrue(lines[0].hasSuffix(zone.identifier), lines[0])
      XCTAssertTrue(try line("Time zone", in: lines).hasPrefix("Time zone   UTC\(offset)"))
      XCTAssertEqual(try line("DST", in: lines), "DST         Not observed", identifier)
    }
  }

  func testCalendarSwitchesItsOffsetAtTheDaylightSavingTransition() {
    let transition = date(2026, 10, 25, hour: 1)
    let before = FlashStatusBarRenderer.calendarText(now: transition - 1, timeZone: paris)
    let after = FlashStatusBarRenderer.calendarText(now: transition, timeZone: paris)

    XCTAssertTrue(before.hasPrefix("#[bold]Sunday, October 25, 2026"))
    XCTAssertTrue(before.contains("UTC+02:00"))
    XCTAssertTrue(before.contains("Ends today · 03:00 → 02:00"))
    XCTAssertTrue(after.hasPrefix("#[bold]Sunday, October 25, 2026"))
    XCTAssertTrue(after.contains("UTC+01:00"))
    XCTAssertTrue(after.contains("Starts Sun Mar 28 · 02:00 → 03:00 · in 154 days"))
    XCTAssertEqual(
      FlashStatusBarRenderer.calendarText(now: transition + 3_600, timeZone: paris), after)
  }

  func testMoonPhasesFallOnTheDaysOfKnownEclipses() throws {
    for (month, day, phase) in [
      (2, 17, "New moon"), (3, 3, "Full moon"), (8, 12, "New moon"), (8, 28, "Full moon"),
    ] {
      XCTAssertTrue(
        try line("Moon", in: lines(at: date(2026, month, day))).hasPrefix(
          "Moon        \(phase) · "), "2026-\(month)-\(day)")
    }
    XCTAssertEqual(
      try line("Moon", in: lines(at: date(2026, 9, 30, in: paris), in: paris)),
      "Moon        Waning gibbous · 83% lit · new Oct 10 · full Oct 26")
    XCTAssertEqual(
      try line("Moon", in: lines(at: date(2026, 8, 28))),
      "Moon        Full moon · 100% lit · new Sep 11 · full Sep 26")
  }

  func testMoonPhasesCycleInOrderWithOneDayPerPrincipalPhase() throws {
    let cycle = [
      "New moon", "Waxing crescent", "First quarter", "Waxing gibbous",
      "Full moon", "Waning gibbous", "Last quarter", "Waning crescent",
    ]
    var phases: [String] = []
    for day in 0..<365 {
      let now = date(2026, 1, 1).addingTimeInterval(Double(day) * 86_400)
      let moon = try XCTUnwrap(
        CalendarStatusDocument.render(now: now, timeZone: utc).components(separatedBy: "\n")
          .last)
      let phase = try XCTUnwrap(
        moon.components(separatedBy: "#[default]").last?.components(separatedBy: " · ").first?
          .trimmingCharacters(in: .whitespaces))
      if let last = phases.last, last == phase {
        XCTAssertFalse(cycle.firstIndex(of: phase)! % 2 == 0, "\(phase) lasts one day")
        continue
      }
      if let last = phases.last {
        XCTAssertEqual(
          cycle.firstIndex(of: phase), (cycle.firstIndex(of: last)! + 1) % 8, "after \(last)")
      }
      phases.append(phase)
    }
    XCTAssertEqual(phases.filter { $0 == "Full moon" }.count, 13)
    XCTAssertEqual(phases.filter { $0 == "New moon" }.count, 12)
  }

  func testCalendarRefreshesAtLocalMidnightAndAcrossTimeZoneChanges() throws {
    let losAngeles = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
    let cache = FlashStatusBarTemplateEngine.PopupEvaluationCache()
    let utcMidnight = date(2026, 1, 1, hour: 0)
    let before = popup(
      at: utcMidnight.addingTimeInterval(8 * 3600 - 1), timeZone: losAngeles, cache: cache)
    let after = popup(
      at: utcMidnight.addingTimeInterval(8 * 3600), timeZone: losAngeles, cache: cache)

    XCTAssertTrue(text(before).hasPrefix("Wednesday, December 31, 2025"))
    XCTAssertTrue(text(before).contains("2025        ████████████████████  365/365  last day"))
    XCTAssertTrue(text(after).hasPrefix("Thursday, January 1, 2026"))
    XCTAssertEqual(before.filter { $0.reverse && !$0.text.isEmpty }.map(\.text), ["31"])
    XCTAssertEqual(after.filter { $0.reverse && !$0.text.isEmpty }.map(\.text), [" 1"])
    let utcNewYear = text(popup(at: utcMidnight, timeZone: utc, cache: cache))
    XCTAssertTrue(utcNewYear.hasPrefix("Thursday, January 1, 2026"))
    XCTAssertTrue(utcNewYear.contains("UTC+00:00"))
    XCTAssertTrue(
      text(popup(at: utcMidnight, timeZone: losAngeles, cache: cache)).hasPrefix(
        "Wednesday, December 31, 2025"))
  }

  func testCalendarOnlyPopupRequestsClockWithoutJobsOrPluginSources() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    let result = FlashStatusBarTemplateEngine.evaluate(
      template: FlashStatusBarTemplate(template: "#[popup=date]calendar#[nopopup]"),
      popupTemplates: ["date": FlashStatusBarTemplate(template: "#{flash.calendar}")],
      context: FlashStatusBarContext(now: date(2026, 9, 16), calendar: calendar))

    XCTAssertEqual(result.clock, .day, "the calendar changes once a day")
    XCTAssertTrue(result.dependencies.values.contains("flash.calendar"))
    XCTAssertTrue(result.jobs.isEmpty)
    XCTAssertTrue(result.sources.isEmpty)
    XCTAssertEqual(result.model.modeDocument.map(\.text).joined(), "calendar")
    XCTAssertEqual(result.model.modeDocument.first(where: { $0.text == "calendar" })?.popup, "date")
    XCTAssertFalse(result.model.popupDocuments["date", default: []].isEmpty)
  }

  /// The standard popup, `[popup] padding = 10` at the 13-point font, holds
  /// every month without wrapping, clipping or horizontal scrolling.
  func testEveryMonthFitsTheDefaultPopupWidth() {
    let cell = TerminalView.cellSize(for: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium))
    let inset: CGFloat = 10 + 1
    let availableColumns = Int((CGFloat(Config.PopupStyle().maxWidth) - inset * 2) / cell.width)
    for identifier in ["UTC", "Europe/Paris", "America/Argentina/ComodRivadavia"] {
      let zone = TimeZone(identifier: identifier)!
      for year in 2023...2027 {
        for month in 1...12 {
          let runs = popup(at: date(year, month, 15, in: zone), timeZone: zone)
          let plain = text(runs)
          let lines = plain.components(separatedBy: "\n")
          let grid = StatusPopupController.documentGrid(
            text: plain, availableColumns: availableColumns, maximumRows: 40)
          XCTAssertLessThanOrEqual(lines.count, 19)
          XCTAssertEqual(lines.map(\.count).max(), CalendarStatusDocument.columns)
          XCTAssertEqual(grid.columns, CalendarStatusDocument.columns, "\(year)-\(month)")
          XCTAssertEqual(grid.rows, lines.count, "\(year)-\(month) must not wrap")
          XCTAssertLessThan(StatusPopupController.documentVT(runs).count, 8192)
        }
      }
    }
    XCTAssertEqual(CGFloat(CalendarStatusDocument.columns) * cell.width + inset * 2, 697)
  }

  func testPagerDrawsTheCalendarAtItsOwnWidthWithoutWrapping() throws {
    _ = NSApplication.shared
    let runs = popup(at: date(2026, 9, 30, in: paris), timeZone: paris)
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    let controller = StatusPopupController(terminals: registry, windowActionsEnabled: false)
    var style = Config.PopupStyle()
    style.padding = 10
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 945)
    controller.preview(
      StatusBarPopupRegion(
        rect: CGRect(x: 1400, y: 925, width: 40, height: 20), name: "date",
        content: text(runs), document: runs),
      visibleFrame: screen, style: style, font: font)
    let drawn = expectation(
      for: NSPredicate { _, _ in
        controller.terminalView.terminalFrame?.text.contains("Moon") == true
      },
      evaluatedWith: nil)
    wait(for: [drawn], timeout: 5)

    let frame = try XCTUnwrap(controller.terminalView.terminalFrame)
    XCTAssertEqual(frame.columns, CalendarStatusDocument.columns)
    XCTAssertTrue(frame.text.hasPrefix(text(runs)), frame.text)
    XCTAssertEqual(
      controller.frame.width,
      CGFloat(CalendarStatusDocument.columns) * TerminalView.cellSize(for: font).width + 22)
    XCTAssertGreaterThanOrEqual(controller.frame.minX, screen.minX)
    XCTAssertLessThanOrEqual(controller.frame.maxX, screen.maxX)
    controller.dismiss()
  }
}
