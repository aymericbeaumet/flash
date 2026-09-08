import AppKit
import XCTest

@testable import FlashTerminal

final class TerminalLinkTests: XCTestCase {
  private func frame(_ text: String, columns: Int = 80, rows: Int = 5) throws -> TerminalFrame {
    let buffer = TerminalBuffer(columns: columns, rows: rows, scrollback: true)
    buffer.write(Data(text.utf8))
    return try XCTUnwrap(buffer.snapshot())
  }

  func testPlainLinksRespectCellHitAndTrailingPunctuation() throws {
    let snapshot = try frame("See (https://example.com/a_(b)). next")
    XCTAssertEqual(snapshot.link(atColumn: 7, row: 0)?.absoluteString, "https://example.com/a_(b)")
    XCTAssertNil(snapshot.link(atColumn: 0, row: 0))
    XCTAssertNil(snapshot.link(atColumn: 31, row: 0))
    XCTAssertNil(snapshot.link(atColumn: -1, row: 0))
    XCTAssertNil(snapshot.link(atColumn: 80, row: 0))
  }

  func testPlainURLsFollowSoftWrapsButNeverJoinSeparateLines() throws {
    let wrapped = try frame("https://example.com/long/path", columns: 16)
    XCTAssertEqual(
      wrapped.link(atColumn: 3, row: 1)?.absoluteString, "https://example.com/long/path")
    let hardBreak = try frame("https://example.\r\ncom/path", columns: 16)
    XCTAssertNil(hardBreak.link(atColumn: 2, row: 1))
  }

  func testOSC8DisplayLabelsAndWideCellsUseTheirActualDestination() throws {
    let snapshot = try frame(
      "\u{1B}]8;;https://example.com/article\u{1B}\\Read 界\u{1B}]8;;\u{1B}\\ done")
    for column in [0, 3, 5, 6] {
      XCTAssertEqual(
        snapshot.link(atColumn: column, row: 0)?.absoluteString, "https://example.com/article")
    }
    XCTAssertNil(snapshot.link(atColumn: 8, row: 0))
  }

  func testOSC8RejectsNonWebDestinationsAndCredentials() throws {
    for destination in [
      "file:///tmp/private", "javascript:alert(1)", "https://user:secret@example.com", "https://",
    ] {
      let snapshot = try frame("\u{1B}]8;;\(destination)\u{1B}\\Open\u{1B}]8;;\u{1B}\\")
      XCTAssertNil(snapshot.link(atColumn: 1, row: 0), destination)
    }
  }

  func testConcealedTextDoesNotExposePlainOrOSC8Links() throws {
    let plain = try frame("\u{1B}[8mhttps://example.com")
    XCTAssertNil(plain.link(atColumn: 5, row: 0))
    let labeled = try frame(
      "\u{1B}[8m\u{1B}]8;;https://example.com\u{1B}\\Hidden\u{1B}]8;;\u{1B}\\")
    XCTAssertNil(labeled.link(atColumn: 1, row: 0))
  }

  func testOverlongWrappedTokensAreBoundedAndNearbyURLsStillWork() throws {
    let text =
      "https://example.com/" + String(repeating: "x", count: 9000) + " https://short.example"
    let snapshot = try frame(text, columns: 100, rows: 100)
    XCTAssertNil(snapshot.link(atColumn: 5, row: 10))
    let index = text.count - 5
    XCTAssertEqual(
      snapshot.link(atColumn: index % 100, row: index / 100)?.absoluteString,
      "https://short.example")
  }

  private func view(_ text: String) throws -> (TerminalView, TerminalDocument) {
    let document = TerminalDocument(columns: 80, rows: 3)
    let ready = expectation(description: "document frame")
    document.onFrame = { _ in ready.fulfill() }
    document.replace(data: Data(text.utf8))
    wait(for: [ready], timeout: 2)
    document.onFrame = nil
    let view = TerminalView(frame: .zero)
    view.frame.size = NSSize(width: view.cellSize.width * 80, height: view.cellSize.height * 3)
    view.bind(document: document)
    return (view, document)
  }

  private func event(_ type: NSEvent.EventType, view: TerminalView, column: Int, shift: Bool = true)
    throws -> NSEvent
  {
    let point = view.convert(
      NSPoint(x: (CGFloat(column) + 0.5) * view.cellSize.width, y: view.cellSize.height * 0.5),
      to: nil)
    return try XCTUnwrap(
      NSEvent.mouseEvent(
        with: type, location: point,
        modifierFlags: shift ? .shift : [], timestamp: 0, windowNumber: 0, context: nil,
        eventNumber: 0, clickCount: 1, pressure: 1))
  }

  func testShiftClickOpensDocumentLinkEvenWithApplicationMouseTracking() throws {
    let (view, document) = try view("\u{1B}[?1000hhttps://example.com/path")
    defer { withExtendedLifetime(document) {} }
    var opened: [URL] = []
    view.openURL = { opened.append($0) }
    view.mouseDown(with: try event(.leftMouseDown, view: view, column: 5))
    XCTAssertTrue(opened.isEmpty)
    view.mouseUp(with: try event(.leftMouseUp, view: view, column: 5))
    XCTAssertEqual(opened.map(\.absoluteString), ["https://example.com/path"])
  }

  func testNormalClickAndShiftDragDoNotOpenLinks() throws {
    let (view, document) = try view("https://example.com/path")
    defer { withExtendedLifetime(document) {} }
    var opened: [URL] = []
    view.openURL = { opened.append($0) }
    view.mouseDown(with: try event(.leftMouseDown, view: view, column: 5, shift: false))
    view.mouseUp(with: try event(.leftMouseUp, view: view, column: 5, shift: false))
    view.mouseDown(with: try event(.leftMouseDown, view: view, column: 5))
    view.mouseDragged(with: try event(.leftMouseDragged, view: view, column: 10))
    view.mouseDragged(with: try event(.leftMouseDragged, view: view, column: 5))
    view.mouseUp(with: try event(.leftMouseUp, view: view, column: 5))
    XCTAssertTrue(opened.isEmpty)
  }
}
