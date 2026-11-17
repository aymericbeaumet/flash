import FlashTerminal
import XCTest

/// A full-screen program that paints its own background (btop, tokscale)
/// names it, so the surface around the grid can match; text on the
/// terminal's default background names nothing.
final class TerminalPaintedBackgroundTests: XCTestCase {
  func testAProgramPaintingMostCellsNamesItsBackground() throws {
    // Erasing with a background set fills the screen with it.
    let painted = try frameFromPTY(
      "\u{1B}[48;2;10;20;30m\u{1B}[2J\u{1B}[Hbtop", columns: 20, rows: 6)
    XCTAssertEqual(painted.paintedBackground?.red, 10)
    XCTAssertEqual(painted.paintedBackground?.green, 20)
    XCTAssertEqual(painted.paintedBackground?.blue, 30)
    XCTAssertNotEqual(painted.paintedBackground, painted.background)
  }

  func testTextOnTheDefaultBackgroundNamesNothing() throws {
    XCTAssertNil(try frameFromPTY("plain text", columns: 20, rows: 6).paintedBackground)
    // One painted row of six is a panel, not the program's background.
    let panel = try frameFromPTY("\u{1B}[48;2;10;20;30m\u{1B}[2K\u{1B}[0m", columns: 20, rows: 6)
    XCTAssertNil(panel.paintedBackground)
  }
}
