import Foundation

/// The core `#{flash.calendar}` value: today's date, the previous, current and
/// next months side by side, the day's progress through its week, month,
/// quarter and year, and the time zone, daylight-saving and moon facts of the
/// day. Everything derives from the date and timezone alone.
enum CalendarStatusDocument {
  /// Content columns of every calendar: three months and the gaps between them.
  static let columns = 3 * monthWidth + 2 * monthGap
  private static let monthWidth = 23
  private static let monthGap = 3
  private static let labelWidth = 12
  private static let barWidth = 20
  private static let months = [
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
  ]
  private static let weekdays = [
    "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
  ]
  private static let weekdayHeader = "Mo Tu We Th Fr Sa Su"
  private static let moonPhases = [
    "New moon", "Waxing crescent", "First quarter", "Waxing gibbous",
    "Full moon", "Waning gibbous", "Last quarter", "Waning crescent",
  ]

  /// One line of status-format markup and its width in terminal cells.
  private struct Line {
    var markup = ""
    var width = 0

    mutating func append(_ text: String, _ style: String = "") {
      append(markup: style.isEmpty ? text : "#[\(style)]\(text)#[default]", width: text.count)
    }

    mutating func append(markup: String, width: Int) {
      self.markup += markup
      self.width += width
    }

    mutating func pad(to column: Int) {
      append(String(repeating: " ", count: max(0, column - width)))
    }
  }

  static func render(now: Date, timeZone: TimeZone) -> String {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = timeZone
    let date = calendar.dateComponents([.year, .month, .day, .weekday, .weekOfYear], from: now)
    guard let year = date.year, let month = date.month, let day = date.day,
      let weekday = date.weekday, let week = date.weekOfYear,
      let today = calendar.dateInterval(of: .day, for: now),
      let monthStart = calendar.dateInterval(of: .month, for: now)?.start,
      let previous = calendar.date(byAdding: .month, value: -1, to: monthStart),
      let next = calendar.date(byAdding: .month, value: 1, to: monthStart),
      let monthDays = calendar.range(of: .day, in: .month, for: now)?.count,
      let quarterStart = calendar.date(
        from: DateComponents(year: year, month: month - (month - 1) % 3)),
      let quarterEnd = calendar.date(byAdding: .month, value: 3, to: quarterStart),
      let yearDay = calendar.ordinality(of: .day, in: .year, for: now),
      let yearDays = calendar.range(of: .day, in: .year, for: now)?.count
    else { return "" }

    var header = Line()
    header.append("\(weekdays[weekday - 1]), \(months[month - 1]) \(day), \(year)", "bold")
    header.pad(to: max(header.width + 2, columns - timeZone.identifier.count))
    header.append(timeZone.identifier, "dim")
    var lines = [header, Line()]

    let blocks = [
      monthLines(previous, calendar: calendar),
      monthLines(monthStart, calendar: calendar, today: day, week: week),
      monthLines(next, calendar: calendar),
    ]
    for row in 0..<(blocks.map(\.count).max() ?? 0) {
      var line = Line()
      for (index, block) in blocks.enumerated() where row < block.count {
        line.pad(to: index * (monthWidth + monthGap))
        line.append(markup: block[row].markup, width: block[row].width)
      }
      lines.append(line)
    }

    lines.append(Line())
    for (label, elapsed, total) in [
      ("Week \(twoDigits(week))", (weekday + 5) % 7 + 1, 7),
      (months[month - 1], day, monthDays),
      (
        "Q\((month + 2) / 3)", daysBetween(quarterStart, today.start, calendar: calendar) + 1,
        daysBetween(quarterStart, quarterEnd, calendar: calendar)
      ),
      (String(year), yearDay, yearDays),
    ] {
      lines.append(progressLine(label, elapsed: elapsed, total: total))
    }

    lines.append(Line())
    lines.append(factLine("Time zone", timeZoneFact(now: now, timeZone: timeZone)))
    lines.append(
      factLine(
        "DST", daylightSavingFact(now: now, today: today.start, calendar: calendar)))
    lines.append(factLine("Moon", moonFact(today: today, calendar: calendar)))
    return lines.map(\.markup).joined(separator: "\n")
  }

  private static func monthLines(
    _ start: Date, calendar: Calendar, today: Int? = nil, week currentWeek: Int? = nil
  ) -> [Line] {
    guard let days = calendar.range(of: .day, in: .month, for: start) else { return [] }
    let month = calendar.component(.month, from: start)
    let year = calendar.component(.year, from: start)
    let leading = (calendar.component(.weekday, from: start) + 5) % 7
    let title = "\(months[month - 1]) \(year)"
    var titleLine = Line()
    titleLine.pad(to: 3 + (weekdayHeader.count - title.count) / 2)
    titleLine.append(title, today == nil ? "" : "bold")
    var header = Line()
    header.append("Wk " + weekdayHeader, "dim")
    var lines = [titleLine, header]
    for row in 0..<((leading + days.count + 6) / 7) {
      var line = Line()
      let monday = calendar.date(byAdding: .day, value: row * 7 - leading, to: start) ?? start
      let week = calendar.component(.weekOfYear, from: monday)
      line.append(twoDigits(week), week == currentWeek ? "bold" : "dim")
      for column in 0..<7 {
        let day = row * 7 + column - leading + 1
        guard day <= days.count else { break }
        line.append(" ")
        guard days.contains(day) else {
          line.append("  ")
          continue
        }
        let value = String(format: "%2d", day)
        line.append(value, day == today ? "bold,reverse" : column >= 5 ? "dim" : "")
      }
      lines.append(line)
    }
    return lines
  }

  /// `label ████▋     3/7  4 days left`: the day's position in a period,
  /// counting today, drawn by the status format's own meter.
  private static func progressLine(_ label: String, elapsed: Int, total: Int) -> Line {
    var line = Line()
    line.append(label, "dim")
    line.pad(to: labelWidth)
    line.append(
      markup: "#[bg=colour238]#[meter=\(barWidth)/\(total)]\(elapsed)#[nometer]#[default]",
      width: barWidth)
    let count = "\(elapsed)/\(total)"
    line.pad(to: line.width + 2 + 7 - count.count)
    line.append(count)
    let left = total - elapsed
    line.append(left == 0 ? "  last day" : left == 1 ? "  1 day left" : "  \(left) days left")
    return line
  }

  private static func factLine(_ label: String, _ value: String) -> Line {
    var line = Line()
    line.append(label, "dim")
    line.pad(to: labelWidth)
    line.append(value)
    return line
  }

  private static func timeZoneFact(now: Date, timeZone: TimeZone) -> String {
    let offset = "UTC" + offset(timeZone.secondsFromGMT(for: now))
    guard
      let name = timeZone.localizedName(
        for: timeZone.isDaylightSavingTime(for: now) ? .daylightSaving : .standard,
        locale: Locale(identifier: "en_US_POSIX"))
    else { return offset }
    return offset + " · " + name
  }

  /// The next daylight-saving transition as the wall clock sees it.
  private static func daylightSavingFact(now: Date, today: Date, calendar: Calendar) -> String {
    let timeZone = calendar.timeZone
    guard let transition = timeZone.nextDaylightSavingTimeTransition(after: now) else {
      return "Not observed"
    }
    let before = clock(transition, offset: timeZone.secondsFromGMT(for: transition - 1))
    let after = clock(transition, offset: timeZone.secondsFromGMT(for: transition))
    let verb = timeZone.isDaylightSavingTime(for: transition) ? "Starts" : "Ends"
    let days = daysBetween(today, calendar.startOfDay(for: transition), calendar: calendar)
    guard days > 0 else { return "\(verb) today · \(before) → \(after)" }
    return "\(verb) \(shortDate(transition, calendar: calendar)) · \(before) → \(after) · "
      + (days == 1 ? "tomorrow" : "in \(days) days")
  }

  /// Today's phase, the lit fraction at local noon, and the dates of the next
  /// new and full moons. A principal phase names the local day its instant
  /// falls in; the days between take the name of their quarter.
  private static func moonFact(today: DateInterval, calendar: Calendar) -> String {
    let start = moonElongation(today.start)
    let end = start + normalized(moonElongation(today.end) - start)
    let noon = moonElongation(today.start + today.duration / 2)
    let phase =
      floor(end / 90) > floor(start / 90)
      ? moonPhases[Int(end / 90) % 4 * 2] : moonPhases[Int(noon / 90) * 2 + 1]
    let lit = Int(((1 - cos(noon * .pi / 180)) / 2 * 100).rounded())
    var facts = [phase, "\(lit)% lit"]
    var pending: [(elongation: Double, name: String)] = [(180, "full"), (360, "new")]
    var day = today.end
    var elongation = moonElongation(day)
    // A lunation is under 30 days, so each principal phase recurs within 31.
    for _ in 0..<31 where !pending.isEmpty {
      guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
      let reached = elongation + normalized(moonElongation(next) - elongation)
      if let index = pending.firstIndex(where: {
        elongation < $0.elongation && $0.elongation <= reached
      }) {
        facts.append(
          pending.remove(at: index).name + " " + shortDate(day, calendar: calendar, weekday: false))
      }
      day = next
      elongation = normalized(reached)
    }
    return facts.joined(separator: " · ")
  }

  /// The largest periodic terms of the Moon's longitude: multiples of the
  /// mean elongation, the Sun's and the Moon's mean anomalies and the Moon's
  /// argument of latitude, and the amplitude in degrees (Meeus,
  /// *Astronomical Algorithms*, table 47.A).
  private static let moonLongitudeTerms: [(Double, Double, Double, Double, Double)] = [
    (0, 0, 1, 0, 6.288_774), (2, 0, -1, 0, 1.274_027), (2, 0, 0, 0, 0.658_314),
    (0, 0, 2, 0, 0.213_618), (0, 1, 0, 0, -0.185_116), (0, 0, 0, 2, -0.114_332),
    (2, 0, -2, 0, 0.058_793), (2, -1, -1, 0, 0.057_066), (2, 0, 1, 0, 0.053_322),
    (2, -1, 0, 0, 0.045_758), (0, 1, -1, 0, -0.040_923), (1, 0, 0, 0, -0.034_720),
    (0, 1, 1, 0, -0.030_383), (2, 0, 0, -2, 0.015_327), (0, 0, 1, 2, -0.012_528),
    (0, 0, 1, -2, 0.010_980), (4, 0, -1, 0, 0.010_675), (0, 0, 3, 0, 0.010_034),
  ]

  /// The Moon's elongation from the Sun in degrees, 0 at new moon and 180 at
  /// full moon: the mean elongation, plus the Moon's periodic terms, minus
  /// the Sun's equation of the centre. Within a few hundredths of a degree,
  /// a few minutes of the Moon's motion.
  static func moonElongation(_ date: Date) -> Double {
    let t = (date.timeIntervalSince1970 / 86_400 - 10_957.5) / 36_525
    let d = 297.850_192_1 + 445_267.111_403_4 * t
    let sun = 357.529_109_2 + 35_999.050_290_9 * t
    let moon = 134.963_396_4 + 477_198.867_505_5 * t
    let latitude = 93.272_095_0 + 483_202.017_523_3 * t
    func sine(_ degrees: Double) -> Double {
      sin(degrees.truncatingRemainder(dividingBy: 360) * .pi / 180)
    }
    let periodic = moonLongitudeTerms.reduce(0) { sum, term in
      sum + term.4 * sine(term.0 * d + term.1 * sun + term.2 * moon + term.3 * latitude)
    }
    return normalized(d + periodic - 1.914_602 * sine(sun) - 0.019_993 * sine(2 * sun))
  }

  private static func normalized(_ degrees: Double) -> Double {
    let value = degrees.truncatingRemainder(dividingBy: 360)
    return value < 0 ? value + 360 : value
  }

  private static func daysBetween(_ start: Date, _ end: Date, calendar: Calendar) -> Int {
    calendar.dateComponents([.day], from: start, to: end).day ?? 0
  }

  private static func shortDate(_ date: Date, calendar: Calendar, weekday: Bool = true) -> String {
    let parts = calendar.dateComponents([.month, .day, .weekday], from: date)
    let day = "\(months[(parts.month ?? 1) - 1].prefix(3)) \(parts.day ?? 1)"
    return weekday ? "\(weekdays[(parts.weekday ?? 1) - 1].prefix(3)) \(day)" : day
  }

  private static func clock(_ date: Date, offset: Int) -> String {
    let minutes = ((Int(date.timeIntervalSince1970) + offset) / 60 % 1_440 + 1_440) % 1_440
    return twoDigits(minutes / 60) + ":" + twoDigits(minutes % 60)
  }

  private static func offset(_ seconds: Int) -> String {
    let minutes = abs(seconds) / 60
    return (seconds < 0 ? "-" : "+") + twoDigits(minutes / 60) + ":" + twoDigits(minutes % 60)
  }

  private static func twoDigits(_ value: Int) -> String { String(format: "%02d", value) }
}
