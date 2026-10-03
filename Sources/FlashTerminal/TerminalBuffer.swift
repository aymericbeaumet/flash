import AppKit
import CFlashTerminal
import Foundation

public struct TerminalColor: Equatable, Hashable, Sendable {
  public let red: UInt8
  public let green: UInt8
  public let blue: UInt8
  init(_ rgb: FlashRGB) {
    red = rgb.r
    green = rgb.g
    blue = rgb.b
  }
  public var nsColor: NSColor {
    NSColor(
      srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255,
      blue: CGFloat(blue) / 255, alpha: 1)
  }
}

/// One cell as consumers read it, materialized on access from the compact
/// row storage (`FlashVTCell`: 20 bytes, byte-sized width and underline, a
/// per-row link index instead of a string).
public struct TerminalCell: Equatable, Sendable {
  public let text: String
  public let foreground: TerminalColor
  public let background: TerminalColor
  public let underlineColor: TerminalColor
  public let flags: UInt16
  public let width: Int
  public let underline: Int
  public let hyperlink: String?
}

/// One viewport row: plain 20-byte cells plus the few strings they refer to
/// (grapheme clusters, one entry per hyperlink run). Rows are copy-on-write
/// values, so a snapshot shares every unchanged row with its predecessor and
/// equal storage compares by identity before contents.
struct TerminalRow: Equatable, Sendable {
  var cells: [FlashVTCell]
  var clusters: [String]
  var links: [String]
  var wrapped: Bool
  /// Union of the cells' flags; a row without the blink bit has no blinking cell.
  var flags: UInt16

  static let blinkFlag: UInt16 = 8
  var hasBlinkingCells: Bool { flags & Self.blinkFlag != 0 }

  static func == (lhs: TerminalRow, rhs: TerminalRow) -> Bool {
    guard lhs.wrapped == rhs.wrapped, lhs.flags == rhs.flags, lhs.cells.count == rhs.cells.count,
      lhs.clusters == rhs.clusters, lhs.links == rhs.links
    else { return false }
    return lhs.cells.withUnsafeBytes { left in
      rhs.cells.withUnsafeBytes { right in
        left.baseAddress == right.baseAddress || left.count == 0
          || memcmp(left.baseAddress!, right.baseAddress!, left.count) == 0
      }
    }
  }

  /// Single-byte cells share these immutable strings instead of decoding.
  private static let asciiText: [String] = (0..<128).map { String(UnicodeScalar(UInt8($0))) }

  func text(at column: Int) -> String {
    let cell = cells[column]
    let content = cell.content
    if content == 0 { return cell.width > 0 ? " " : "" }
    if content < 128 { return Self.asciiText[Int(content)] }
    if content & FLASH_VT_CLUSTER != 0 { return clusters[Int(content & ~FLASH_VT_CLUSTER)] }
    return Unicode.Scalar(content).map { String($0) } ?? "\u{FFFD}"
  }

  func hyperlink(at column: Int) -> String? {
    let link = Int(cells[column].link)
    return link > 0 && link <= links.count ? links[link - 1] : nil
  }

  func cell(at column: Int) -> TerminalCell {
    let cell = cells[column]
    return TerminalCell(
      text: text(at: column), foreground: TerminalColor(cell.foreground),
      background: TerminalColor(cell.background),
      underlineColor: TerminalColor(cell.underline_color),
      flags: cell.flags, width: Int(cell.width), underline: Int(cell.underline),
      hyperlink: hyperlink(at: column))
  }
}

/// Row-major cells of a frame, materialized one at a time from its rows.
public struct TerminalCells: RandomAccessCollection, Sendable {
  let grid: [TerminalRow]
  let columns: Int
  public var startIndex: Int { 0 }
  public var endIndex: Int { grid.count * columns }
  public subscript(position: Int) -> TerminalCell {
    grid[position / columns].cell(at: position % columns)
  }
}

public struct TerminalFrame: Equatable, Sendable {
  public let columns: Int
  public let rows: Int
  let grid: [TerminalRow]
  public let foreground: TerminalColor
  public let background: TerminalColor
  public let cursorX: Int
  public let cursorY: Int
  public let cursorVisible: Bool
  public let cursorBlinking: Bool
  public let cursorStyle: Int
  public let mouseTracking: Bool
  /// Whether any cell carries the blink attribute, from the per-row flag
  /// unions, so a view never rescans the cells per frame.
  public let hasBlinkingCells: Bool
  /// Position in the owning buffer's snapshot sequence; consecutive values
  /// mean `changedRows` describes the difference from the previous frame.
  public let generation: UInt64
  /// Rows whose contents differ from the previous snapshot, or nil when there
  /// is no comparable predecessor (first frame or a resize).
  public let changedRows: Set<Int>?

  public var cells: TerminalCells { TerminalCells(grid: grid, columns: columns) }
  public var wrappedRows: Set<Int> { Set(grid.indices.filter { grid[$0].wrapped }) }

  func link(atColumn column: Int, row: Int) -> URL? {
    guard (0..<columns).contains(column), (0..<rows).contains(row) else { return nil }
    let cells = self.cells
    var index = row * columns + column
    while index > row * columns && cells[index].width == 0 { index -= 1 }
    guard cells[index].flags & 32 == 0 else { return nil }
    if let hyperlink = cells[index].hyperlink { return Self.webURL(hyperlink) }
    var firstRow = row
    var lastRow = row
    while firstRow > 0 && grid[firstRow - 1].wrapped { firstRow -= 1 }
    while lastRow + 1 < rows && grid[lastRow].wrapped { lastRow += 1 }
    let logicalStart = firstRow * columns
    let logicalEnd = (lastRow + 1) * columns
    guard !Self.linkBoundary(cells[index]) else { return nil }
    var lower = index
    var upper = index + 1
    var byteCount = cells[index].text.utf8.count
    guard byteCount <= 8192 else { return nil }
    while lower > logicalStart && !Self.linkBoundary(cells[lower - 1]) {
      lower -= 1
      byteCount += cells[lower].text.utf8.count
      guard byteCount <= 8192, upper - lower <= 16384 else { return nil }
    }
    while upper < logicalEnd && !Self.linkBoundary(cells[upper]) {
      byteCount += cells[upper].text.utf8.count
      upper += 1
      guard byteCount <= 8192, upper - lower <= 16384 else { return nil }
    }
    let text = cells[lower..<upper].map(\.text).joined()
    let hitOffset = cells[lower..<index].reduce(0) { $0 + $1.text.utf16.count }
    let fullRange = NSRange(location: 0, length: text.utf16.count)
    for match in Self.webLinkPattern.matches(in: text, range: fullRange) {
      guard let range = Range(match.range, in: text) else { continue }
      let candidate = Self.trimLinkPunctuation(String(text[range]))
      let linkRange = NSRange(location: match.range.location, length: candidate.utf16.count)
      if NSLocationInRange(hitOffset, linkRange) { return Self.webURL(candidate) }
    }
    return nil
  }

  private static let webLinkPattern = try! NSRegularExpression(
    pattern: #"(?i)https?://[^\s<>\"'`]+"#)

  private static func linkBoundary(_ cell: TerminalCell) -> Bool {
    cell.flags & 32 != 0
      || cell.text.unicodeScalars.contains {
        CharacterSet.whitespacesAndNewlines.contains($0) || "<>\"'`".unicodeScalars.contains($0)
      }
  }

  private static func trimLinkPunctuation(_ text: String) -> String {
    var characters = Array(text)
    let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{"]
    var balance: [Character: Int] = [:]
    for character in characters {
      if pairs[character] != nil { balance[character, default: 0] += 1 }
      if let closing = pairs.first(where: { $0.value == character })?.key {
        balance[closing, default: 0] -= 1
      }
    }
    while let last = characters.last {
      if ".,;:!?".contains(last) {
        characters.removeLast()
      } else if balance[last, default: 0] > 0 {
        balance[last, default: 0] -= 1
        characters.removeLast()
      } else {
        break
      }
    }
    return String(characters)
  }

  private static func webURL(_ text: String) -> URL? {
    guard text.utf8.count <= 8192,
      !text.unicodeScalars.contains(where: {
        CharacterSet.whitespacesAndNewlines.contains($0)
          || CharacterSet.controlCharacters.contains($0)
      }),
      let url = URL(string: text),
      ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
      let host = url.host, !host.isEmpty, url.user == nil, url.password == nil
    else { return nil }
    return url
  }

  public var text: String {
    grid.map { row in
      (0..<row.cells.count).map { row.text(at: $0) }.joined()
        .replacingOccurrences(of: " +$", with: "", options: .regularExpression)
    }.joined(separator: "\n")
  }
}

/// All terminal access, including input encoding, stays on the owning worker queue.
final class TerminalBuffer {
  let handle: OpaquePointer
  var output: ((Data) -> Void)?
  /// `scrollbackLines` caps the history above the screen; 0 keeps none.
  init(columns: Int, rows: Int, scrollbackLines: Int) {
    let callback: FlashVTWrite = { context, bytes, length in
      guard let context, let bytes else { return }
      Unmanaged<TerminalBuffer>.fromOpaque(context).takeUnretainedValue().output?(
        Data(bytes: bytes, count: length))
    }
    // Allocate without a callback until self is fully initialized.
    guard
      let created = flash_vt_new(
        UInt16(clamping: max(1, columns)),
        UInt16(clamping: max(1, rows)), UInt32(clamping: max(0, scrollbackLines)), nil, nil)
    else {
      preconditionFailure("Could not allocate terminal")
    }
    handle = created
    self.callback = callback
  }
  private let callback: FlashVTWrite
  deinit { flash_vt_free(handle) }
  func connectOutput() {
    flash_vt_output(handle, callback, Unmanaged.passUnretained(self).toOpaque())
  }
  func write(_ data: Data) {
    data.withUnsafeBytes { bytes in
      flash_vt_write(handle, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
    }
  }

  func write(_ bytes: UnsafePointer<UInt8>, count: Int) {
    flash_vt_write(handle, bytes, count)
  }
  /// Forces the next snapshot to reread every row regardless of dirty flags.
  func invalidate() { forceFullSnapshot = true }
  private var forceFullSnapshot = true
  private var previous: TerminalFrame?
  private var generation: UInt64 = 0

  /// Extracts the viewport. Only rows libghostty reports dirty are reread,
  /// and a reread row equal to its predecessor keeps the previous storage, so
  /// cursor motion and redundant dirty flags publish no changed rows. Returns
  /// the previous frame unchanged when nothing visible moved.
  func snapshot() -> TerminalFrame? {
    var header = FlashVTFrame()
    guard flash_vt_frame(handle, &header) else { return nil }
    let columns = Int(header.columns)
    let rows = Int(header.rows)
    let base = previous.flatMap { $0.columns == columns && $0.rows == rows ? $0 : nil }
    var grid = base?.grid ?? Array(repeating: Self.blankRow, count: rows)
    var changedRows = Set<Int>()
    var y: UInt16 = 0
    while flash_vt_next_row(handle, forceFullSnapshot || base == nil, &y) {
      let row = Int(y)
      guard row < rows, let built = readRow(columns: columns) else { return nil }
      if base != nil, grid[row] == built { continue }
      grid[row] = built
      changedRows.insert(row)
    }
    flash_vt_clean(handle)
    forceFullSnapshot = false
    let frame = TerminalFrame(
      columns: columns, rows: rows, grid: grid,
      foreground: TerminalColor(header.foreground), background: TerminalColor(header.background),
      cursorX: Int(header.cursor_x), cursorY: Int(header.cursor_y),
      cursorVisible: header.cursor_visible,
      cursorBlinking: header.cursor_blinking, cursorStyle: Int(header.cursor_style),
      mouseTracking: header.mouse_tracking,
      hasBlinkingCells: grid.contains(where: \.hasBlinkingCells), generation: generation + 1,
      changedRows: base == nil ? nil : changedRows)
    if let base, changedRows.isEmpty, frame.sameViewport(as: base) { return base }
    generation += 1
    previous = frame
    return frame
  }

  private static let blankRow = TerminalRow(
    cells: [], clusters: [], links: [], wrapped: false, flags: 0)

  private func readRow(columns: Int) -> TerminalRow? {
    var info = FlashVTRow()
    var filled = false
    let cells = [FlashVTCell](unsafeUninitializedCapacity: columns) { buffer, count in
      filled = flash_vt_row_cells(handle, buffer.baseAddress, &info)
      count = filled ? columns : 0
    }
    guard filled else { return nil }
    func strings(_ spans: UnsafePointer<FlashVTSpan>?, _ count: UInt16) -> [String] {
      guard let spans, let arena = info.arena, count > 0 else { return [] }
      return (0..<Int(count)).map {
        String(
          decoding: UnsafeBufferPointer(
            start: arena + Int(spans[$0].offset), count: Int(spans[$0].length)),
          as: UTF8.self)
      }
    }
    return TerminalRow(
      cells: cells, clusters: strings(info.clusters, info.cluster_count),
      links: strings(info.links, info.link_count), wrapped: info.wrapped, flags: info.flags)
  }
}

extension TerminalFrame {
  /// Everything a view draws besides the cells.
  fileprivate func sameViewport(as other: TerminalFrame) -> Bool {
    foreground == other.foreground && background == other.background
      && cursorX == other.cursorX && cursorY == other.cursorY
      && cursorVisible == other.cursorVisible && cursorBlinking == other.cursorBlinking
      && cursorStyle == other.cursorStyle && mouseTracking == other.mouseTracking
  }
}

extension NSColor {
  var terminalRGB: FlashRGB {
    let color = usingColorSpace(.sRGB) ?? .white
    return FlashRGB(
      r: UInt8(clamping: Int(color.redComponent * 255)),
      g: UInt8(clamping: Int(color.greenComponent * 255)),
      b: UInt8(clamping: Int(color.blueComponent * 255)))
  }
}
