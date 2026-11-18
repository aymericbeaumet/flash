import CoreGraphics
import FlashCore
import Foundation

/// Visible terminal cells for an EasyMotion letter, used when the focused
/// terminal's accessibility tree has no text. The cells come from the plugin
/// that hints the app (`text_grid`; tmux reads its client), laid out here on
/// the window `f` measures. The plugin says where the cells are when the
/// terminal pads or centres its grid; otherwise the grid's cell count
/// divides the window.
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
  static func grid(_ reply: PluginTextGrid, window: CGRect) -> Grid? {
    let lines = placedLines(reply)
    guard !lines.isEmpty else { return nil }
    let cell = reply.cell ?? evenCell(window: window, columns: reply.columns, rows: reply.rows)
    return Grid(
      cellWidth: cell.width,
      cellHeight: cell.height,
      padX: cell.padX,
      padY: cell.padY,
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

  /// The cell of a grid that fills `window` evenly: what a reply without a
  /// measured cell means.
  static func evenCell(window: CGRect, columns: Int, rows: Int) -> PluginTextGrid.Cell {
    PluginTextGrid.Cell(
      width: window.width / CGFloat(max(columns, 1)),
      height: window.height / CGFloat(max(rows, 1)), padX: 0, padY: 0)
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
}
