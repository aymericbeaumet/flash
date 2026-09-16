import Foundation

enum CalendarStatusDocument {
  private static let months = [
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
  ]
  private static let weekdays = [
    "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
  ]
  private static let weekdayHeader = "Mo Tu We Th Fr Sa Su"

  static func render(now: Date, timeZone: TimeZone) -> String {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = timeZone
    guard let monthStart = calendar.dateInterval(of: .month, for: now)?.start,
      let previous = calendar.date(byAdding: .month, value: -1, to: monthStart),
      let next = calendar.date(byAdding: .month, value: 1, to: monthStart),
      let ordinal = calendar.ordinality(of: .day, in: .year, for: now),
      let yearDays = calendar.range(of: .day, in: .year, for: now)?.count
    else { return "" }
    let day = calendar.component(.day, from: now)
    let month = calendar.component(.month, from: now)
    let year = calendar.component(.year, from: now)
    let weekday = weekdays[calendar.component(.weekday, from: now) - 1]
    let week = calendar.component(.weekOfYear, from: now)
    var lines = [
      "#[bold]\(weekday), \(months[month - 1]) \(day), \(year)#[default]",
      "#[dim]Week \(String(format: "%02d", week)) · Day \(ordinal)/\(yearDays) · Q\((month - 1) / 3 + 1)#[default]",
      "",
    ]
    lines += monthLines(monthStart, calendar: calendar, today: day, weekNumbers: true).map {
      "         " + $0
    }
    lines.append("")
    let left = monthLines(previous, calendar: calendar)
    let right = monthLines(next, calendar: calendar)
    for row in 0..<max(left.count, right.count) {
      let before = row < left.count ? left[row] : String(repeating: " ", count: 20)
      let after = row < right.count ? right[row] : ""
      lines.append(before + "   " + after)
    }
    return lines.joined(separator: "\n")
  }

  private static func monthLines(
    _ start: Date, calendar: Calendar, today: Int? = nil, weekNumbers: Bool = false
  ) -> [String] {
    guard let days = calendar.range(of: .day, in: .month, for: start) else { return [] }
    let month = calendar.component(.month, from: start)
    let year = calendar.component(.year, from: start)
    let leading = (calendar.component(.weekday, from: start) + 5) % 7
    let width = weekNumbers ? 24 : 20
    let title = "\(months[month - 1]) \(year)"
    let leftPadding = max(0, (width - title.count) / 2)
    var lines = [
      String(repeating: " ", count: leftPadding) + "#[bold]" + title + "#[default]"
        + String(repeating: " ", count: max(0, width - title.count - leftPadding)),
      "#[dim]" + (weekNumbers ? "Wk  " : "") + weekdayHeader + "#[default]",
    ]
    for row in 0..<((leading + days.count + 6) / 7) {
      var prefix = ""
      if weekNumbers,
        let monday = calendar.date(byAdding: .day, value: row * 7 - leading, to: start)
      {
        prefix =
          "#[dim]" + String(format: "%02d", calendar.component(.weekOfYear, from: monday))
          + "#[default]  "
      }
      let cells = (0..<7).map { column -> String in
        let day = row * 7 + column - leading + 1
        guard days.contains(day) else { return "  " }
        let value = String(format: "%2d", day)
        if day == today { return "#[bold,reverse]" + value + "#[default]" }
        return column >= 5 ? "#[dim]" + value + "#[default]" : value
      }
      lines.append(prefix + cells.joined(separator: " "))
    }
    return lines
  }
}
