import AppKit
import FlashCore
import Foundation

/// Visible terminal cells for an EasyMotion letter, used when the focused
/// terminal's accessibility tree has no text. The cells come from the plugin
/// that hints the app (`text_grid`; tmux reads its client), laid out here on
/// the window `f` measures. Geometry matches the terminals plugin: Alacritty
/// centres its font grid in the window; other terminals divide the window by
/// the grid's cell count.
enum TerminalTextGrid {
  /// One UTF-16 unit of a laid-out line. `column` is the screen column.
  /// `width` is the glyph's cell span on its first unit and 0 on the rest,
  /// so a match covers the cells the terminal drew.
  struct ColumnUnit: Equatable {
    var column: Int
    var width: Int
  }

  struct PlacedLine: Equatable {
    var row: Int
    var text: String
    var units: [ColumnUnit]

    func span(location: Int, length: Int) -> (column: Int, width: Int)? {
      guard location >= 0, length > 0, location + length <= units.count else { return nil }
      let start = units[location].column
      var end = start
      for unit in units[location..<(location + length)] {
        end = max(end, unit.column + max(unit.width, 1))
      }
      let width = end - start
      guard width > 0 else { return nil }
      return (start, width)
    }
  }

  struct Grid: Equatable {
    var cellWidth: CGFloat
    var cellHeight: CGFloat
    var padX: CGFloat
    var padY: CGFloat
    var origin: CGPoint
    var windowHeight: CGFloat
    /// Pane text, the status line and pane-border titles, on grid rows.
    var lines: [PlacedLine]

    func targets(matching query: String, pid: pid_t) -> [JumpTarget] {
      guard query.count == 1 else { return [] }
      var targets: [JumpTarget] = []
      for line in lines {
        let labelSource = line.text as NSString
        for occurrence in BigramMatcher.occurrences(in: line.text, query: query) {
          guard
            let span = line.span(location: occurrence.location, length: occurrence.length)
          else { continue }
          let frame = CGRect(
            x: origin.x + padX + CGFloat(span.column) * cellWidth,
            y: origin.y + windowHeight - padY - CGFloat(line.row + 1) * cellHeight,
            width: cellWidth * CGFloat(span.width),
            height: cellHeight)
          let label = labelSource.substring(
            with: NSRange(location: occurrence.location, length: occurrence.length))
          targets.append(
            JumpTarget(
              id: "bigram-grid-\(pid)-\(targets.count)",
              frame: frame,
              role: "AXTextArea",
              accessibilityLabel: label,
              pid: pid,
              resolveClickPoint: { _ in BigramMatcher.clickPoint(in: frame) },
              isTextInput: true,
              providerID: "bigram"))
        }
      }
      return targets
    }
  }

  /// Ask `providers` in order, one at a time; the first grid with a line
  /// wins and an empty or missing one asks the next. `completion` runs once,
  /// on whichever queue the deciding reply arrived.
  static func firstGrid<Provider>(
    from providers: ArraySlice<Provider>,
    request: @escaping (Provider, @escaping (PluginTextGrid?) -> Void) -> Void,
    completion: @escaping (PluginTextGrid?) -> Void
  ) {
    guard let provider = providers.first else {
      completion(nil)
      return
    }
    request(provider) { grid in
      if let grid, !grid.lines.isEmpty {
        completion(grid)
        return
      }
      firstGrid(from: providers.dropFirst(), request: request, completion: completion)
    }
  }

  /// Lay a `text_grid` reply on `window`. Nil when no line has text.
  static func grid(_ reply: PluginTextGrid, bundleIdentifier: String, window: CGRect) -> Grid? {
    let lines = placedLines(reply)
    guard !lines.isEmpty else { return nil }
    let cells = metrics(
      bundleIdentifier: bundleIdentifier, window: window,
      columns: CGFloat(reply.columns), rows: CGFloat(reply.rows))
    return Grid(
      cellWidth: cells.cellWidth,
      cellHeight: cells.cellHeight,
      padX: cells.padX,
      padY: cells.padY,
      origin: CGPoint(x: window.minX, y: window.minY),
      windowHeight: window.height,
      lines: lines)
  }

  /// Each reply line on its cells: captured text one unit per cell, a format
  /// through the status-line layout. A blank format is dropped.
  static func placedLines(_ reply: PluginTextGrid) -> [PlacedLine] {
    reply.lines.compactMap { line in
      switch line {
      case .text(let row, let column, let text):
        return contentLine(text, row: row, origin: column)
      case .format(let row, let column, let width, let format):
        return placedLine(format: format, width: width, row: row, origin: column)
      }
    }
  }

  static func metrics(
    bundleIdentifier: String, window: CGRect, columns: CGFloat, rows: CGFloat
  ) -> (cellWidth: CGFloat, cellHeight: CGFloat, padX: CGFloat, padY: CGFloat) {
    let columns = max(columns, 1)
    let rows = max(rows, 1)
    if isAlacritty(bundleIdentifier),
      let font = alacrittyFont(),
      let cell = cellMetrics(family: font.family, size: font.size)
    {
      let contentWidth = columns * cell.width
      let contentHeight = rows * cell.height
      let padX = max(0, (window.width - contentWidth) / 2)
      let padY = max(0, (window.height - contentHeight) / 2)
      return (cell.width, cell.height, padX, padY)
    }
    return (window.width / columns, window.height / rows, 0, 0)
  }

  /// One captured line. Each UTF-16 unit is one cell, which is how
  /// `capture-pane` text is already addressed.
  static func contentLine(_ text: String, row: Int, origin: Int) -> PlacedLine {
    let count = (text as NSString).length
    return PlacedLine(
      row: row, text: text,
      units: (0..<count).map { ColumnUnit(column: origin + $0, width: 1) })
  }

  /// Lays an expanded tmux format (`#{T:status-format[0]}` or
  /// `#{T:pane-border-format}`) into cells with the status-line rules `f`
  /// uses. Style markers are not letters. Empty and blank lines are omitted.
  static func placedLine(format: String, width: Int, row: Int, origin: Int) -> PlacedLine? {
    guard width > 0, !format.isEmpty else { return nil }
    let laid = StatusFormatLayout.layout(
      StatusFormatDocument.parse(format), columns: width)
    var text = ""
    var units: [ColumnUnit] = []
    for (column, cell) in laid.cells.enumerated() {
      if cell.isContinuation { continue }
      let piece = cell.segment.text
      let count = (piece as NSString).length
      guard count > 0 else { continue }
      let glyph = max(cell.columns, 1)
      for index in 0..<count {
        units.append(ColumnUnit(column: origin + column, width: index == 0 ? glyph : 0))
      }
      text += piece
    }
    guard text.unicodeScalars.contains(where: { !$0.properties.isWhitespace }) else { return nil }
    return PlacedLine(row: row, text: text, units: units)
  }

  private static func isAlacritty(_ bundleIdentifier: String) -> Bool {
    bundleIdentifier == "org.alacritty" || bundleIdentifier == "io.alacritty"
  }

  private static func alacrittyFont() -> (family: String, size: CGFloat)? {
    let home = NSHomeDirectory()
    let paths = [
      "\(home)/.config/alacritty/alacritty.toml",
      "\(home)/.alacritty.toml",
    ]
    for path in paths {
      guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
      let size = CGFloat(tomlNumber(text, section: "font", key: "size") ?? 11)
      let family = tomlString(text, section: "font.normal", key: "family") ?? "Menlo"
      return (family, size)
    }
    return nil
  }

  private static func cellMetrics(family: String, size: CGFloat) -> (
    width: CGFloat, height: CGFloat
  )? {
    let font =
      NSFont(name: family, size: size) ?? NSFont(name: "Menlo", size: size)
    guard let font else { return nil }
    let width = font.maximumAdvancement.width
    let height = font.ascender - font.descender
    guard width > 0, height > 0 else { return nil }
    return (width, height)
  }

  private static func tomlNumber(_ text: String, section: String, key: String) -> Double? {
    guard let raw = tomlRaw(text, section: section, key: key) else { return nil }
    return Double(raw)
  }

  private static func tomlString(_ text: String, section: String, key: String) -> String? {
    guard var raw = tomlRaw(text, section: section, key: key) else { return nil }
    if raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") {
      raw = String(raw.dropFirst().dropLast())
    }
    return raw.isEmpty ? nil : raw
  }

  private static func tomlRaw(_ text: String, section: String, key: String) -> String? {
    var inSection = false
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") { continue }
      if line.hasPrefix("["), line.hasSuffix("]") {
        inSection =
          String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces) == section
        continue
      }
      guard inSection, let split = line.split(separator: "=", maxSplits: 1).last else { continue }
      let name = line.split(separator: "=", maxSplits: 1).first?
        .trimmingCharacters(in: .whitespaces)
      guard name == key else { continue }
      return split.trimmingCharacters(in: .whitespaces)
    }
    return nil
  }
}
