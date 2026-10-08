import AppKit
import Darwin
import FlashCore
import Foundation

/// Visible tmux cells for an EasyMotion letter, used when the focused
/// terminal's accessibility tree has no text. Geometry matches the tmux
/// plugin: Alacritty centres its font grid in the window; other terminals
/// divide the window by the client cell count. The grid is the same client
/// surface `f` reads: pane text, the status line, and each pane-border title.
enum TmuxBigramGrid {
  /// Same field marker the tmux plugin uses. A newline inside
  /// `display-message -p` is not a reliable break, and a title is split once
  /// so it may itself contain the marker.
  static let fieldSeparator = "|||"

  struct Pane: Equatable {
    var left: Int
    var top: Int
    var lines: [String]
  }

  /// One UTF-16 unit of a laid-out line. `column` is the screen column.
  /// `width` is the glyph's cell span on its first unit and 0 on the rest,
  /// so a match covers the cells tmux drew.
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

  struct SnapshotPane: Equatable {
    var id: String
    var left: Int
    var top: Int
    var width: Int
    var height: Int
    var title: PlacedLine?
  }

  struct Snapshot: Equatable {
    var columns: Int
    var rows: Int
    var topOffset: Int
    var status: PlacedLine?
    var panes: [SnapshotPane]
  }

  struct Grid: Equatable {
    var cellWidth: CGFloat
    var cellHeight: CGFloat
    var padX: CGFloat
    var padY: CGFloat
    var origin: CGPoint
    var windowHeight: CGFloat
    var topOffset: Int
    var panes: [Pane]
    /// Status line and pane-border titles. Rows are already client rows.
    var chrome: [PlacedLine] = []

    func targets(matching query: String, pid: pid_t, bundleIdentifier: String) -> [JumpTarget] {
      guard query.count == 1 else { return [] }
      var targets: [JumpTarget] = []
      func append(_ line: PlacedLine) {
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
              id: "bigram-tmux-\(pid)-\(targets.count)",
              frame: frame,
              role: "AXTextArea",
              accessibilityLabel: label,
              pid: pid,
              resolveClickPoint: { _ in BigramMatcher.clickPoint(in: frame) },
              entersInsertMode: true,
              providerID: "bigram"))
        }
      }
      for pane in panes {
        for (row, line) in pane.lines.enumerated() {
          append(
            contentLine(line, row: topOffset + pane.top + row, origin: pane.left))
        }
      }
      for line in chrome { append(line) }
      return targets
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

  /// The tty of the tmux client whose process is the focused app or one of
  /// its descendants. `parent` walks one step; nil ends the walk.
  static func clientTTY(
    lines: [String], focusedPID: pid_t, parent: (pid_t) -> pid_t?
  ) -> String? {
    for line in lines {
      let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
      guard parts.count >= 2, let clientPID = pid_t(parts[0]) else { continue }
      if serves(clientPID, focusedPID: focusedPID, parent: parent) {
        return parts[1]
      }
    }
    return nil
  }

  static func statusTopOffset(status: String, position: String) -> Int {
    let lines = Int(status) ?? (status == "on" || status == "1" ? 1 : 0)
    return position == "top" ? lines : 0
  }

  /// Client row of `status-format[0]`. A top status occupies row 0; a bottom
  /// status occupies the last status rows, and line 0 is the first of them.
  static func statusRow(status: String, position: String, clientRows: Int) -> Int? {
    let lines = Int(status) ?? (status == "on" ? 1 : 0)
    guard lines > 0, clientRows > 0 else { return nil }
    switch position {
    case "top": return 0
    case "bottom": return max(0, clientRows - lines)
    default: return nil
    }
  }

  /// Client row of a pane-border title. `pane_top` is the content origin, so
  /// a top border sits on the row above the content and a bottom border on
  /// the row after it. `off` has no title.
  static func paneTitleRow(
    border: String, topOffset: Int, paneTop: Int, paneHeight: Int
  ) -> Int? {
    switch border {
    case "top":
      let row = topOffset + paneTop - 1
      return row >= 0 ? row : nil
    case "bottom":
      return topOffset + paneTop + paneHeight
    default:
      return nil
    }
  }

  /// One captured pane line. Each UTF-16 unit is one cell, which is how
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

  static func parseSnapshot(geometry: String, paneList: String) -> Snapshot? {
    let geometry = trimTrailingBreak(geometry)
    let (head, statusFormat) = splitOnce(geometry, separator: fieldSeparator)
    let fields = head.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard fields.count >= 4,
      let columns = Int(fields[0]), columns > 0,
      let rows = Int(fields[1]), rows > 0
    else { return nil }
    let topOffset = statusTopOffset(status: fields[2], position: fields[3])
    let status: PlacedLine?
    if let row = statusRow(status: fields[2], position: fields[3], clientRows: rows) {
      status = placedLine(format: statusFormat, width: columns, row: row, origin: 0)
    } else {
      status = nil
    }
    var panes: [SnapshotPane] = []
    for raw in trimTrailingBreak(paneList).components(separatedBy: "\n") {
      let line = trimTrailingBreak(raw)
      if line.isEmpty { continue }
      let (paneGeometry, titleFormat) = splitOnce(line, separator: fieldSeparator)
      let parts = paneGeometry.split(whereSeparator: { $0.isWhitespace }).map(String.init)
      guard parts.count == 6,
        !parts[0].isEmpty,
        let left = Int(parts[1]), left >= 0,
        let top = Int(parts[2]), top >= 0,
        let width = Int(parts[3]), width > 0,
        let height = Int(parts[4]), height > 0
      else { continue }
      var title: PlacedLine?
      if let row = paneTitleRow(
        border: parts[5], topOffset: topOffset, paneTop: top, paneHeight: height),
        row < rows,
        let placed = placedLine(format: titleFormat, width: width, row: row, origin: left)
      {
        title = placed
      }
      panes.append(
        SnapshotPane(
          id: parts[0], left: left, top: top, width: width, height: height, title: title))
    }
    return Snapshot(
      columns: columns, rows: rows, topOffset: topOffset, status: status, panes: panes)
  }

  static func capture(pid: pid_t, bundleIdentifier: String, window: CGRect) -> Grid? {
    guard let tmux = PluginSandbox.resolveExecutable(named: "tmux") else { return nil }
    guard
      let clients = run(tmux, ["list-clients", "-F", "#{client_pid} #{client_tty}"]),
      let tty = clientTTY(
        lines: clients.components(separatedBy: "\n"), focusedPID: pid, parent: parentPID)
    else { return nil }
    guard
      let geometry = run(
        tmux,
        [
          "display-message", "-c", tty, "-p",
          "#{client_width} #{client_height} #{status} #{status-position}\(fieldSeparator)#{T:status-format[0]}",
        ]),
      let paneList = run(
        tmux,
        [
          "list-panes", "-t", tty, "-F",
          "#{pane_id} #{pane_left} #{pane_top} #{pane_width} #{pane_height} #{pane-border-status}\(fieldSeparator)#{T:pane-border-format}",
        ]),
      let snapshot = parseSnapshot(geometry: geometry, paneList: paneList)
    else { return nil }
    var panes: [Pane] = []
    var chrome: [PlacedLine] = []
    if let status = snapshot.status { chrome.append(status) }
    for pane in snapshot.panes {
      if let title = pane.title { chrome.append(title) }
      guard let text = run(tmux, ["capture-pane", "-t", pane.id, "-p"]) else { continue }
      var lines = text.components(separatedBy: "\n")
      if lines.last?.isEmpty == true { lines.removeLast() }
      panes.append(Pane(left: pane.left, top: pane.top, lines: lines))
    }
    guard !panes.isEmpty || !chrome.isEmpty else { return nil }
    let cells = metrics(
      bundleIdentifier: bundleIdentifier, window: window,
      columns: CGFloat(snapshot.columns), rows: CGFloat(snapshot.rows))
    return Grid(
      cellWidth: cells.cellWidth,
      cellHeight: cells.cellHeight,
      padX: cells.padX,
      padY: cells.padY,
      origin: CGPoint(x: window.minX, y: window.minY),
      windowHeight: window.height,
      topOffset: snapshot.topOffset,
      panes: panes,
      chrome: chrome)
  }

  private static func splitOnce(_ text: String, separator: String) -> (String, String) {
    guard let range = text.range(of: separator) else { return (text, "") }
    return (String(text[..<range.lowerBound]), String(text[range.upperBound...]))
  }

  private static func trimTrailingBreak(_ text: String) -> String {
    if text.hasSuffix("\r\n") { return String(text.dropLast(2)) }
    if text.hasSuffix("\n") || text.hasSuffix("\r") { return String(text.dropLast()) }
    return text
  }

  private static func serves(
    _ clientPID: pid_t, focusedPID: pid_t, parent: (pid_t) -> pid_t?
  ) -> Bool {
    var current: pid_t? = clientPID
    var steps = 0
    while let pid = current, steps < 12 {
      if pid == focusedPID { return true }
      current = parent(pid)
      steps += 1
    }
    return false
  }

  private static func parentPID(_ pid: pid_t) -> pid_t? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    let read = withUnsafeMutablePointer(to: &info) {
      proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size)
    }
    guard read == size else { return nil }
    let parent = pid_t(info.pbi_ppid)
    return parent > 1 ? parent : nil
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

  private static func run(_ executable: String, _ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    // Discard stderr. An unread pipe fills and stalls the child at 64KB, and
    // a full terminal pane is large enough to hit that on stdout too, so
    // stdout is drained on another queue while the child runs.
    process.standardError = FileHandle.nullDevice
    let reader = DispatchSemaphore(value: 0)
    let box = LockedData()
    DispatchQueue.global(qos: .userInitiated).async {
      box.set(output.fileHandleForReading.readDataToEndOfFile())
      reader.signal()
    }
    do {
      try process.run()
    } catch {
      try? output.fileHandleForReading.close()
      _ = reader.wait(timeout: .now() + .milliseconds(50))
      return nil
    }
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    guard finished.wait(timeout: .now() + .milliseconds(500)) == .success else {
      process.terminate()
      _ = reader.wait(timeout: .now() + .milliseconds(50))
      return nil
    }
    guard reader.wait(timeout: .now() + .milliseconds(50)) == .success,
      process.terminationStatus == 0
    else { return nil }
    return String(data: box.get(), encoding: .utf8)
  }

  /// stdout bytes published from the drain queue.
  private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ data: Data) {
      lock.lock()
      self.data = data
      lock.unlock()
    }
    func get() -> Data {
      lock.lock()
      defer { lock.unlock() }
      return data
    }
  }
}
