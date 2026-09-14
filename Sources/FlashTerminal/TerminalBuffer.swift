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

public struct TerminalFrame: Equatable, Sendable {
  public let columns: Int
  public let rows: Int
  public let cells: [TerminalCell]
  public let foreground: TerminalColor
  public let background: TerminalColor
  public let cursorX: Int
  public let cursorY: Int
  public let cursorVisible: Bool
  public let cursorBlinking: Bool
  public let cursorStyle: Int
  public let mouseTracking: Bool
  public let wrappedRows: Set<Int>
  /// Whether any cell carries the blink attribute; computed while the grid is
  /// built so a view never rescans the cells per frame to decide on a timer.
  public let hasBlinkingCells: Bool
  /// Position in the owning buffer's snapshot sequence; consecutive values
  /// mean `changedRows` describes the difference from the previous frame.
  public let generation: UInt64
  /// Rows whose cells differ from the previous snapshot, or nil when every
  /// row may have changed (first frame, resize, scroll, reset, palette).
  public let changedRows: Set<Int>?

  func link(atColumn column: Int, row: Int) -> URL? {
    guard (0..<columns).contains(column), (0..<rows).contains(row) else { return nil }
    var index = row * columns + column
    while index > row * columns && cells[index].width == 0 { index -= 1 }
    guard cells[index].flags & 32 == 0 else { return nil }
    if let hyperlink = cells[index].hyperlink { return Self.webURL(hyperlink) }
    var firstRow = row
    var lastRow = row
    while firstRow > 0 && wrappedRows.contains(firstRow - 1) { firstRow -= 1 }
    while lastRow + 1 < rows && wrappedRows.contains(lastRow) { lastRow += 1 }
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
    (0..<rows).map { row in
      cells[(row * columns)..<((row + 1) * columns)].map(\.text).joined()
        .replacingOccurrences(of: " +$", with: "", options: .regularExpression)
    }.joined(separator: "\n")
  }
}

/// All terminal access, including input encoding, stays on the owning worker queue.
final class TerminalBuffer {
  let handle: OpaquePointer
  var output: ((Data) -> Void)?
  init(columns: Int, rows: Int, scrollback: Bool) {
    let callback: FlashVTWrite = { context, bytes, length in
      guard let context, let bytes else { return }
      Unmanaged<TerminalBuffer>.fromOpaque(context).takeUnretainedValue().output?(
        Data(bytes: bytes, count: length))
    }
    // Allocate without a callback until self is fully initialized.
    guard
      let created = flash_vt_new(
        UInt16(clamping: max(1, columns)),
        UInt16(clamping: max(1, rows)), scrollback, nil, nil)
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
  /// Forces the next snapshot to rebuild every row regardless of dirty flags.
  func invalidate() { forceFullSnapshot = true }
  private var forceFullSnapshot = true
  private var previous: TerminalFrame?
  private var generation: UInt64 = 0
  private var scratch: [FlashVTCell] = []
  /// Single-byte cells share these immutable strings instead of decoding.
  private static let asciiText: [String] = (0..<128).map {
    String(UnicodeScalar(UInt8($0)))
  }

  /// Extracts the viewport, reusing the previous snapshot's cells for rows
  /// libghostty reports clean so steady-state output costs one row, not the
  /// whole grid. Returns the previous frame unchanged when nothing visible
  /// moved.
  func snapshot() -> TerminalFrame? {
    var header = FlashVTFrame()
    guard flash_vt_frame(handle, &header) else { return nil }
    let columns = Int(header.columns)
    let rows = Int(header.rows)
    let reusable =
      !forceFullSnapshot && header.dirty != 2
      && previous.map { $0.columns == columns && $0.rows == rows } == true
    var cells: [TerminalCell] = []
    cells.reserveCapacity(columns * rows)
    var wrappedRows = Set<Int>()
    var changedRows = Set<Int>()
    var hasBlinkingCells = false
    if scratch.count < columns { scratch = Array(repeating: FlashVTCell(), count: columns) }
    for row in 0..<rows {
      var info = FlashVTRow()
      guard flash_vt_next_row(handle, &info) else { return nil }
      if info.wrapped { wrappedRows.insert(row) }
      if reusable, !info.dirty, let previous {
        let range = (row * columns)..<((row + 1) * columns)
        for cell in previous.cells[range] where cell.flags & 8 != 0 {
          hasBlinkingCells = true
          break
        }
        cells.append(contentsOf: previous.cells[range])
        continue
      }
      changedRows.insert(row)
      guard scratch.withUnsafeMutableBufferPointer({ flash_vt_row_cells(handle, $0.baseAddress) })
      else { return nil }
      for column in 0..<columns {
        let cell = scratch[column]
        let text: String
        if cell.length == 0 {
          text = cell.width > 0 ? " " : ""
        } else if cell.length == 1, let byte = cell.text?.pointee, byte < 128 {
          text = Self.asciiText[Int(byte)]
        } else {
          text = String(
            decoding: UnsafeBufferPointer(start: cell.text, count: cell.length), as: UTF8.self)
        }
        if cell.flags & 8 != 0 { hasBlinkingCells = true }
        let hyperlink = cell.hyperlink.flatMap { bytes -> String? in
          guard cell.hyperlink_length > 0 else { return nil }
          return String(
            decoding: UnsafeBufferPointer(start: bytes, count: cell.hyperlink_length), as: UTF8.self
          )
        }
        cells.append(
          TerminalCell(
            text: text,
            foreground: TerminalColor(cell.foreground), background: TerminalColor(cell.background),
            underlineColor: TerminalColor(cell.underline_color), flags: cell.flags,
            width: Int(cell.width), underline: Int(cell.underline), hyperlink: hyperlink))
      }
    }
    flash_vt_clean(handle)
    forceFullSnapshot = false
    let frame = TerminalFrame(
      columns: columns, rows: rows, cells: cells,
      foreground: TerminalColor(header.foreground), background: TerminalColor(header.background),
      cursorX: Int(header.cursor_x), cursorY: Int(header.cursor_y),
      cursorVisible: header.cursor_visible,
      cursorBlinking: header.cursor_blinking, cursorStyle: Int(header.cursor_style),
      mouseTracking: header.mouse_tracking, wrappedRows: wrappedRows,
      hasBlinkingCells: hasBlinkingCells, generation: generation + 1,
      changedRows: reusable ? changedRows : nil)
    if let previous, reusable, changedRows.isEmpty, frame.sameViewport(as: previous) {
      return previous
    }
    generation += 1
    previous = frame
    return frame
  }
}

extension TerminalFrame {
  /// Everything a view draws besides the cells.
  fileprivate func sameViewport(as other: TerminalFrame) -> Bool {
    foreground == other.foreground && background == other.background
      && cursorX == other.cursorX && cursorY == other.cursorY
      && cursorVisible == other.cursorVisible && cursorBlinking == other.cursorBlinking
      && cursorStyle == other.cursorStyle && mouseTracking == other.mouseTracking
      && wrappedRows == other.wrappedRows
  }
}

public final class TerminalDocument {
  private let queue = DispatchQueue(label: "com.flash.terminal.document", qos: .userInitiated)
  private let buffer: TerminalBuffer
  public var onFrame: ((TerminalFrame) -> Void)?
  public private(set) var frame: TerminalFrame?
  public init(columns: Int = 80, rows: Int = 24) {
    buffer = TerminalBuffer(columns: columns, rows: rows, scrollback: true)
  }
  public func replace(data: Data) {
    queue.async { [self] in
      buffer.invalidate()
      flash_vt_reset(buffer.handle)
      buffer.write(data)
      flash_vt_scroll(buffer.handle, -Int32.max)
      publish()
    }
  }
  public func replace(data: Data, columns: Int, rows: Int) {
    queue.async { [self] in
      buffer.invalidate()
      flash_vt_reset(buffer.handle)
      flash_vt_resize(
        buffer.handle, UInt16(clamping: max(1, columns)), UInt16(clamping: max(1, rows)))
      buffer.write(data)
      flash_vt_scroll(buffer.handle, -Int32.max)
      publish()
    }
  }
  public func resize(columns: Int, rows: Int) {
    queue.async { [self] in
      buffer.invalidate()
      flash_vt_resize(
        buffer.handle, UInt16(clamping: max(1, columns)), UInt16(clamping: max(1, rows)))
      publish()
    }
  }
  public func scroll(lines: Int) {
    queue.async { [self] in
      buffer.invalidate()
      flash_vt_scroll(buffer.handle, Int32(clamping: lines))
      publish()
    }
  }
  public func setColors(foreground: NSColor, background: NSColor) {
    let fg = foreground.terminalRGB
    let bg = background.terminalRGB
    queue.async { [self] in
      buffer.invalidate()
      flash_vt_colors(buffer.handle, fg, bg)
      publish()
    }
  }
  private var publishedGeneration: UInt64 = 0
  private func publish() {
    guard let snapshot = buffer.snapshot(), snapshot.generation != publishedGeneration else {
      return
    }
    publishedGeneration = snapshot.generation
    DispatchQueue.main.async { [weak self] in
      self?.frame = snapshot
      self?.onFrame?(snapshot)
    }
  }
  public static func cellWidth(of text: String) -> Int {
    let codepoints = text.unicodeScalars.map(\.value)
    return codepoints.withUnsafeBufferPointer { Int(flash_unicode_width($0.baseAddress, $0.count)) }
  }

  /// Literal content cannot inject terminal commands; LF and TAB retain their document meaning.
  public static func sanitize(text: String) -> String {
    String(
      String.UnicodeScalarView(
        text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars.map { scalar in
          if scalar == "\n" || scalar == "\t" { return scalar }
          if scalar.value < 32 || (127...159).contains(scalar.value) { return "�" }
          return scalar
        })
    )
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
