import AppKit
import XCTest

@testable import FlashTerminal

final class TerminalRenderingTests: XCTestCase {
  private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)

  private func view(for frame: TerminalFrame) -> TerminalView {
    let view = TerminalView(frame: .zero)
    view.font = font
    view.frame.size = NSSize(
      width: view.cellSize.width * CGFloat(frame.columns),
      height: view.cellSize.height * CGFloat(frame.rows))
    view.isRenderingEnabled = true
    view.receive(frame)
    return view
  }

  private func frame(_ text: String, columns: Int, rows: Int) throws -> TerminalFrame {
    let buffer = TerminalBuffer(columns: columns, rows: rows, scrollbackLines: 0)
    buffer.write(Data(text.utf8))
    return try XCTUnwrap(buffer.snapshot())
  }

  /// A run of ASCII text must stay on the grid: SF Mono advances 7.83 pt per
  /// character while cells are 8 pt, so text laid out by its own advances
  /// ends ~14 pt short of the 80th cell.
  func testGlyphsOfAnASCIIRunSitOnTheirCells() throws {
    let frame = try frame(String(repeating: "H", count: 80), columns: 80, rows: 1)
    let view = view(for: frame)
    let cell = view.cellSize
    XCTAssertNotEqual(
      (("H" as NSString).size(withAttributes: [.font: font]).width), cell.width,
      "the font's advance differs from the cell width, which is what makes drift visible")
    let bitmap = try XCTUnwrap(TerminalBitmap(size: view.bounds.size, scale: 2))
    view.render(in: bitmap.context, rect: view.bounds)
    for column in [0, 40, 79] {
      let inked = stride(
        from: CGFloat(column) * cell.width, to: CGFloat(column + 1) * cell.width, by: 0.5
      )
      .contains { x in
        stride(from: 0, to: cell.height, by: 0.5).contains { bitmap.pixel(x: x, y: $0).red > 128 }
      }
      XCTAssertTrue(inked, "column \(column) has no ink in its own cell")
    }
  }

  func testGlyphPositionsAreColumnTimesCellWidth() throws {
    let text = "ab \u{1B}[1mcd\u{1B}[0m┌─┐ 界x"
    let frame = try frame(text, columns: 20, rows: 1)
    let renderer = TerminalRenderer(font: font)
    let palette = TerminalRenderer.Palette(
      background: .black, selectedForeground: .white, selectedBackground: .white)
    renderer.layout(frame.grid[0], selection: nil, part: .base, palette: palette)
    let columns = [0, 1, 3, 4, 5, 6, 7, 9, 11]
    XCTAssertEqual(
      renderer.positions.map(\.x), columns.map { CGFloat($0) * renderer.cellSize.width })
    XCTAssertTrue(renderer.positions.allSatisfy { $0.y == 0 }, "positions lie on the baseline")
    XCTAssertTrue(renderer.lineDraws.isEmpty, "single scalars never need a Core Text line")
    // Regular, bold, box drawing (same font), the fallback CJK glyph clipped
    // to its two cells, then regular text again.
    XCTAssertEqual(renderer.runs.map(\.range.count), [2, 2, 3, 1, 1])
    XCTAssertEqual(renderer.runs[3].clip?.width, renderer.cellSize.width * 2)
  }

  func testColorEmojiDrawsInColorThroughTheGlyphPath() throws {
    let frame = try frame("🚀", columns: 4, rows: 1)
    let view = view(for: frame)
    let bitmap = try XCTUnwrap(TerminalBitmap(size: view.bounds.size, scale: 2))
    view.render(in: bitmap.context, rect: view.bounds)
    let cell = view.cellSize
    let colored = stride(from: 0, to: cell.width * 2, by: 0.5).contains { x in
      stride(from: 0, to: cell.height, by: 0.5).contains { y in
        let pixel = bitmap.pixel(x: x, y: y)
        return abs(Int(pixel.red) - Int(pixel.blue)) > 60
      }
    }
    XCTAssertTrue(colored)
  }

  func testLastRowChangeRedrawsOnlyThatRow() throws {
    let buffer = TerminalBuffer(columns: 20, rows: 6, scrollbackLines: 0)
    buffer.write(Data("one\r\ntwo\r\nthree\r\nfour\r\nfive\r\n\u{1B}[7mstatus 1\u{1B}[0m".utf8))
    let view = view(for: try XCTUnwrap(buffer.snapshot()))
    XCTAssertEqual(view.rowsNeedingDisplay, [0, 1, 2, 3, 4, 5])
    view.displayPendingRows()
    XCTAssertEqual(view.rowsNeedingDisplay, [])
    buffer.write(Data("\u{1B}[6;8H2\u{1B}[2;2H".utf8))
    view.receive(try XCTUnwrap(buffer.snapshot()))
    XCTAssertEqual(
      view.rowsNeedingDisplay, [5], "the cursor moving across rows repaints none of them")
    view.displayPendingRows()
    view.receive(try XCTUnwrap(buffer.snapshot()))
    XCTAssertEqual(view.rowsNeedingDisplay, [])
  }

  func testSelectionRepaintsOnlyTheRowsItTouches() throws {
    let view = view(for: try frame("a\r\nb\r\nc\r\nd", columns: 4, rows: 4))
    view.displayPendingRows()
    let cell = view.cellSize
    func event(_ type: NSEvent.EventType, column: Int, row: Int) throws -> NSEvent {
      try XCTUnwrap(
        NSEvent.mouseEvent(
          with: type,
          location: view.convert(
            NSPoint(x: (CGFloat(column) + 0.5) * cell.width, y: (CGFloat(row) + 0.5) * cell.height),
            to: nil),
          modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
          clickCount: 1, pressure: 1))
    }
    view.mouseDown(with: try event(.leftMouseDown, column: 0, row: 1))
    XCTAssertEqual(view.rowsNeedingDisplay, [1])
    view.displayPendingRows()
    view.mouseDragged(with: try event(.leftMouseDragged, column: 1, row: 2))
    XCTAssertEqual(view.rowsNeedingDisplay, [1, 2])
  }

  func testBlinkingTextBlinksThroughALayerAnimation() throws {
    let view = view(for: try frame("plain\r\n\u{1B}[5mblink\u{1B}[0m", columns: 8, rows: 2))
    XCTAssertNil(view.blinkAnimation(inRow: 0))
    let animation = try XCTUnwrap(view.blinkAnimation(inRow: 1) as? CAKeyframeAnimation)
    XCTAssertEqual(animation.keyPath, "opacity")
    XCTAssertEqual(animation.repeatCount, .infinity)
    XCTAssertEqual(animation.duration, 1)
  }

  func testCursorBlinkIsALayerAnimationThatStopsWhenSteady() throws {
    let session = TerminalSession(
      configuration: TerminalConfiguration(
        command: [
          "/bin/sh", "-c",
          "stty -echo; printf '\\033[1 qBLINK'; read line; printf '\\033[2 qSTEADY'; read line",
        ], columns: 20, rows: 2))
    defer { session.shutdown() }
    let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
    view.isRenderingEnabled = true
    view.bind(session: session)
    session.start()
    func waitForText(_ text: String) {
      let ready = expectation(
        for: NSPredicate { _, _ in view.terminalFrame?.text.contains(text) == true },
        evaluatedWith: nil)
      wait(for: [ready], timeout: 5)
    }
    waitForText("BLINK")
    XCTAssertEqual(view.cursorBlinkAnimation?.repeatCount, .infinity)
    session.send(Data("go\n".utf8))
    waitForText("STEADY")
    XCTAssertNil(view.cursorBlinkAnimation)
    view.drawsCursor = false
    XCTAssertNil(view.cursorBlinkAnimation)
  }

  func testBoundedCacheKeepsHotEntriesWhenFull() {
    var cache = TerminalCache<Int, Int>(limit: 4)
    for key in 0..<4 { cache[key] = key }
    cache[4] = 4
    XCTAssertEqual(cache[0], 0, "retired entries are promoted back, not wiped")
    for key in 5..<12 { cache[key] = key }
    XCTAssertLessThanOrEqual(cache.count, 8)
    XCTAssertEqual(cache[11], 11)
  }
}
