import AppKit
import FlashTerminal
import XCTest

@testable import flash

final class CalendarStatusDocumentTests: XCTestCase {
  private let utc = TimeZone(secondsFromGMT: 0)!

  private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
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

  private func currentMonthRows(_ text: String) throws -> [String] {
    let lines = text.components(separatedBy: "\n")
    let header = try XCTUnwrap(lines.firstIndex(where: { $0.contains("Wk  Mo Tu We Th Fr Sa Su") }))
    return Array(lines.dropFirst(header + 1).prefix(while: { !$0.isEmpty }))
  }

  func testLeapDayIncludesCalendarContextAndOnlyHighlightsToday() throws {
    let runs = popup(at: date(2024, 2, 29))
    let plain = text(runs)

    XCTAssertTrue(plain.contains("Thursday, February 29, 2024"))
    XCTAssertTrue(plain.contains("Week 09 · Day 60/366 · Q1"))
    XCTAssertTrue(plain.contains("January 2024"))
    XCTAssertTrue(plain.contains("March 2024"))
    let highlighted = runs.filter { $0.reverse && !$0.text.isEmpty }
    XCTAssertEqual(highlighted.map(\.text), ["29"])
    XCTAssertTrue(highlighted.allSatisfy(\.bold))

    let rows = try currentMonthRows(plain)
    XCTAssertEqual(rows.count, 5)
    XCTAssertTrue(rows[0].contains("05            1  2  3  4"))
    XCTAssertTrue(rows[4].contains("09  26 27 28 29"))
    XCTAssertFalse(rows[4].contains("30"))
  }

  func testISOWeekNumbersRemainCorrectAcrossCalendarYearBoundary() throws {
    let plain = text(popup(at: date(2021, 1, 1)))

    XCTAssertTrue(plain.contains("Friday, January 1, 2021"))
    XCTAssertTrue(plain.contains("Week 53 · Day 1/365 · Q1"))
    XCTAssertTrue(plain.contains("December 2020"))
    XCTAssertTrue(plain.contains("February 2021"))
    let rows = try currentMonthRows(plain)
    XCTAssertTrue(rows[0].contains("53               1  2  3"))
    XCTAssertTrue(rows[1].contains("01   4  5  6  7  8  9 10"))
  }

  func testCalendarRefreshesAtLocalMidnightAndAcrossTimeZoneChanges() throws {
    let losAngeles = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
    let cache = FlashStatusBarTemplateEngine.PopupEvaluationCache()
    let utcMidnight = date(2026, 1, 1, hour: 0)
    let before = popup(
      at: utcMidnight.addingTimeInterval(8 * 3600 - 1), timeZone: losAngeles, cache: cache)
    let after = popup(
      at: utcMidnight.addingTimeInterval(8 * 3600), timeZone: losAngeles, cache: cache)

    XCTAssertTrue(text(before).contains("Wednesday, December 31, 2025"))
    XCTAssertTrue(text(before).contains("Week 01 · Day 365/365 · Q4"))
    XCTAssertTrue(text(after).contains("Thursday, January 1, 2026"))
    XCTAssertEqual(before.filter { $0.reverse && !$0.text.isEmpty }.map(\.text), ["31"])
    XCTAssertEqual(after.filter { $0.reverse && !$0.text.isEmpty }.map(\.text), [" 1"])
    XCTAssertEqual(
      text(popup(at: utcMidnight, timeZone: utc, cache: cache)), text(after))
    XCTAssertTrue(
      text(popup(at: utcMidnight, timeZone: losAngeles, cache: cache)).contains(
        "Wednesday, December 31, 2025"))
  }

  func testCalendarOnlyPopupRequestsClockWithoutJobsOrPluginSources() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    let result = FlashStatusBarTemplateEngine.evaluate(
      template: FlashStatusBarTemplate(template: "#[popup=date]calendar#[nopopup]"),
      popupTemplates: ["date": FlashStatusBarTemplate(template: "#{flash.calendar}")],
      context: FlashStatusBarContext(now: date(2026, 9, 16), calendar: calendar))

    XCTAssertTrue(result.needsClock)
    XCTAssertTrue(result.dependencies.values.contains("flash.calendar"))
    XCTAssertTrue(result.jobs.isEmpty)
    XCTAssertTrue(result.sources.isEmpty)
    XCTAssertEqual(result.model.modeDocument.map(\.text).joined(), "calendar")
    XCTAssertEqual(result.model.modeDocument.first(where: { $0.text == "calendar" })?.popup, "date")
    XCTAssertFalse(result.model.popupDocuments["date", default: []].isEmpty)
  }

  func testAllMonthLayoutsFitExistingPopupWithoutWrappingOrClipping() {
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
    let terminal = TerminalView()
    terminal.font = font
    let inset: CGFloat = 11
    let availableColumns = Int((420 - inset * 2) / terminal.cellSize.width)
    let maximumRows = Int((600 - inset * 2) / terminal.cellSize.height)

    for year in 2023...2026 {
      for month in 1...12 {
        let runs = popup(at: date(year, month, 15))
        let plain = text(runs)
        let lines = plain.components(separatedBy: "\n")
        let grid = StatusPopupController.documentGrid(
          text: plain, availableColumns: availableColumns, maximumRows: maximumRows)
        XCTAssertFalse(plain.isEmpty, "\(year)-\(month)")
        XCTAssertLessThanOrEqual(lines.count, 20)
        XCTAssertLessThanOrEqual(lines.map(\.count).max() ?? 0, 43)
        XCTAssertEqual(grid.rows, lines.count, "\(year)-\(month) must not wrap or clip")
        XCTAssertLessThanOrEqual(CGFloat(grid.columns) * terminal.cellSize.width + inset * 2, 420)
        XCTAssertLessThanOrEqual(CGFloat(grid.rows) * terminal.cellSize.height + inset * 2, 600)
        XCTAssertLessThan(StatusPopupController.documentVT(runs).count, 4096)
      }
    }
  }
}
