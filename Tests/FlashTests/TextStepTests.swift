import CoreGraphics
import FlashCore
import XCTest

/// `mouse_step`: one text line or one character from the glyph under the
/// pointer, in Accessibility's top-left coordinates.
final class TextStepTests: XCTestCase {
  /// Three lines of 10pt-wide glyphs, 20pt apart, with a 4pt gap between
  /// lines; the third line is shorter.
  private func glyph(at point: CGPoint) -> CGRect? {
    let lines: [(top: CGFloat, columns: Int)] = [(100, 10), (120, 10), (140, 3)]
    for line in lines where point.y >= line.top && point.y < line.top + 16 {
      let column = Int((point.x - 50) / 10)
      guard column >= 0, column < line.columns else { return nil }
      return CGRect(x: 50 + CGFloat(column) * 10, y: line.top, width: 10, height: 16)
    }
    return nil
  }

  private func neighbour(of pointer: CGPoint) -> (Int) -> CGRect? {
    { offset in
      guard let here = self.glyph(at: pointer) else { return nil }
      return self.glyph(at: CGPoint(x: here.midX + CGFloat(offset) * 10, y: here.midY))
    }
  }

  private func step(_ pointer: CGPoint, _ direction: TextStep.Direction) -> CGPoint {
    TextStep.target(
      pointer: pointer, direction: direction, glyphAt: glyph(at:),
      neighbour: neighbour(of: pointer), landing: { CGPoint(x: $0.midX, y: $0.midY) })
  }

  func testDownAndUpReachTheNextLineInThePointersColumn() {
    XCTAssertEqual(step(CGPoint(x: 83, y: 108), .down), CGPoint(x: 83, y: 128))
    XCTAssertEqual(step(CGPoint(x: 83, y: 128), .up), CGPoint(x: 83, y: 108))
  }

  /// Past the end of a shorter line the column has no glyph: the step still
  /// lands on that line, as Vim keeps the cursor's wanted column.
  func testAShorterLineStillTakesTheStep() {
    XCTAssertEqual(step(CGPoint(x: 133, y: 128), .down), CGPoint(x: 133, y: 148))
  }

  func testLeftAndRightLandOnTheNeighbouringCharacter() {
    XCTAssertEqual(step(CGPoint(x: 83, y: 108), .right), CGPoint(x: 95, y: 108))
    XCTAssertEqual(step(CGPoint(x: 83, y: 108), .left), CGPoint(x: 75, y: 108))
  }

  /// Off the text, or with no neighbour on the line, the pointer moves by a
  /// fixed line height or column so the motion is never a silent no-op.
  func testWithoutTextTheStepIsAFixedDistance() {
    XCTAssertEqual(
      step(CGPoint(x: 500, y: 500), .down), CGPoint(x: 500, y: 500 + TextStep.fallbackLine))
    XCTAssertEqual(
      step(CGPoint(x: 500, y: 500), .left), CGPoint(x: 500 - TextStep.fallbackColumn, y: 500))
    XCTAssertEqual(step(CGPoint(x: 143, y: 108), .right).x, 143 + TextStep.fallbackColumn)
  }

  func testDirectionsParseFromTheirNames() {
    XCTAssertEqual(TextStep.Direction.allCases.map(\.rawValue), ["up", "down", "left", "right"])
  }
}
