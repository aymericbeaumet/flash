import AppKit
import CFlashTerminal
import Foundation

public struct TerminalColor: Equatable, Sendable {
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
  func snapshot() -> TerminalFrame? {
    var frame = FlashVTFrame()
    guard flash_vt_frame(handle, &frame) else { return nil }
    var cells: [TerminalCell] = []
    cells.reserveCapacity(Int(frame.columns) * Int(frame.rows))
    for row in 0..<frame.rows {
      for column in 0..<frame.columns {
        var cell = FlashVTCell()
        guard flash_vt_cell(handle, column, row, &cell) else { return nil }
        let text =
          cell.text.map {
            String(decoding: UnsafeBufferPointer(start: $0, count: cell.length), as: UTF8.self)
          } ?? ""
        cells.append(
          TerminalCell(
            text: text.isEmpty && cell.width > 0 ? " " : text,
            foreground: TerminalColor(cell.foreground), background: TerminalColor(cell.background),
            underlineColor: TerminalColor(cell.underline_color), flags: cell.flags,
            width: Int(cell.width), underline: Int(cell.underline)))
      }
    }
    return TerminalFrame(
      columns: Int(frame.columns), rows: Int(frame.rows), cells: cells,
      foreground: TerminalColor(frame.foreground), background: TerminalColor(frame.background),
      cursorX: Int(frame.cursor_x), cursorY: Int(frame.cursor_y),
      cursorVisible: frame.cursor_visible,
      cursorBlinking: frame.cursor_blinking, cursorStyle: Int(frame.cursor_style),
      mouseTracking: frame.mouse_tracking)
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
      flash_vt_reset(buffer.handle)
      buffer.write(data)
      flash_vt_scroll(buffer.handle, -Int32.max)
      publish()
    }
  }
  public func replace(data: Data, columns: Int, rows: Int) {
    queue.async { [self] in
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
      flash_vt_resize(
        buffer.handle, UInt16(clamping: max(1, columns)), UInt16(clamping: max(1, rows)))
      publish()
    }
  }
  public func scroll(lines: Int) {
    queue.async { [self] in
      flash_vt_scroll(buffer.handle, Int32(clamping: lines))
      publish()
    }
  }
  public func setColors(foreground: NSColor, background: NSColor) {
    let fg = foreground.terminalRGB
    let bg = background.terminalRGB
    queue.async { [self] in
      flash_vt_colors(buffer.handle, fg, bg)
      publish()
    }
  }
  private func publish() {
    guard let snapshot = buffer.snapshot() else { return }
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
