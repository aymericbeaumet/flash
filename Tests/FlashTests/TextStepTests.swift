import CoreGraphics
import FlashCore
import XCTest

@testable import flash

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

  // MARK: Word and line jumps

  /// Vim's `w`, `b` and `e` on one run of text, in UTF-16 indexes.
  func testWordJumpsFollowVim() {
    let text = "foo bar  baz"
    XCTAssertEqual(TextStep.wordTarget(in: text, from: 1, jump: .nextWord), 4)
    XCTAssertEqual(TextStep.wordTarget(in: text, from: 4, jump: .nextWord), 9)
    XCTAssertNil(TextStep.wordTarget(in: text, from: 9, jump: .nextWord), "no word after the last")
    XCTAssertEqual(
      TextStep.wordTarget(in: text, from: 5, jump: .previousWord), 4, "inside: its start")
    XCTAssertEqual(TextStep.wordTarget(in: text, from: 4, jump: .previousWord), 0, "at a start")
    XCTAssertNil(TextStep.wordTarget(in: text, from: 0, jump: .previousWord))
    XCTAssertEqual(TextStep.wordTarget(in: text, from: 4, jump: .wordEnd), 6)
    XCTAssertEqual(
      TextStep.wordTarget(in: text, from: 6, jump: .wordEnd), 11, "at an end: the next")
    XCTAssertEqual(TextStep.wordTarget(in: text, from: 3, jump: .wordEnd), 6, "from a space")
  }

  /// `0` and `$`: the first and last glyph of the pointer's line, across a
  /// gap no wider than a couple of glyphs.
  func testLineEdgesScanThePointersLine() {
    var glyphs: [CGRect] = (0..<10).map {
      CGRect(x: 50 + CGFloat($0) * 10, y: 100, width: 10, height: 16)
    }
    glyphs.remove(at: 4)  // a space with no glyph
    func glyphAt(_ point: CGPoint) -> CGRect? { glyphs.first { $0.contains(point) } }
    let landing: (CGRect) -> CGPoint = { CGPoint(x: $0.midX, y: $0.midY) }
    XCTAssertEqual(
      TextStep.lineEdge(
        pointer: CGPoint(x: 83, y: 108), toEnd: false, glyphAt: glyphAt, landing: landing),
      CGPoint(x: 55, y: 108))
    XCTAssertEqual(
      TextStep.lineEdge(
        pointer: CGPoint(x: 83, y: 108), toEnd: true, glyphAt: glyphAt, landing: landing),
      CGPoint(x: 145, y: 108))
    XCTAssertNil(
      TextStep.lineEdge(
        pointer: CGPoint(x: 500, y: 500), toEnd: true, glyphAt: glyphAt, landing: landing),
      "off text there is no line")
  }

  func testJumpsParseFromTheirNames() {
    XCTAssertEqual(
      TextStep.Jump.allCases.map(\.rawValue),
      ["next_word", "previous_word", "word_end", "line_start", "line_end"])
  }

  func testTheVerbsParseAndRoundTrip() {
    func parse(_ verb: String, _ args: [String: String]) -> URLCommand? {
      URLEventHandler.parse(verb: verb, args: args)
    }
    XCTAssertEqual(parse("mouse_step", ["to": "word_end"]), .mouseJump(.wordEnd))
    XCTAssertEqual(parse("mouse_step", ["direction": "up"]), .mouseStep(.up))
    XCTAssertNil(parse("mouse_step", ["direction": "up", "to": "word_end"]), "one or the other")
    XCTAssertNil(parse("mouse_step", [:]))
    XCTAssertNil(parse("mouse_step", ["to": "paragraph"]))
    XCTAssertEqual(parse("selection", ["action": "change"]), .selection(.change))
    XCTAssertEqual(
      parse("selection", ["action": "copy", "register": "a"]),
      .selection(.copy, register: "a"))
    XCTAssertNil(parse("selection", ["action": "copy", "register": "ab"]))
    XCTAssertNil(parse("selection", ["action": "copy", "register": "é"]))
    XCTAssertNil(parse("selection", ["action": "copy", "register": ""]))
    XCTAssertNil(parse("yank_selection", ["register": "ab"]))
    XCTAssertNil(parse("paste", ["register": "é"]))
    XCTAssertEqual(parse("yank_selection", ["register": "_"]), .yankSelection(register: "_"))
    XCTAssertNil(parse("selection", ["action": "delete"]))
    XCTAssertEqual(
      URLCommand.mouseJump(.lineEnd).diagnosticDescription, "flash mouse_step --to=line_end")
    XCTAssertEqual(
      URLCommand.selection(.copy).diagnosticDescription, "flash selection --action=copy")
    XCTAssertEqual(
      URLCommand.selection(.copy, register: "a").diagnosticDescription,
      "flash selection --action=copy --register=a")
    let drag = ConfigLoader.parse("").mode.compiledDrag
    XCTAssertEqual(drag.mapping(for: "w")?.action, .flashCommand(.mouseJump(.nextWord)))
    XCTAssertEqual(drag.mapping(for: "$")?.action, .flashCommand(.mouseJump(.lineEnd)))
    XCTAssertEqual(drag.mapping(for: "y")?.action, .flashCommand(.selection(.copy)))
    XCTAssertEqual(drag.mapping(for: "d")?.action, .flashCommand(.selection(.cut)))
    XCTAssertFalse(drag.hasStrictPrefix("d"), "DRAG's d does not wait on NORMAL's df")
  }
}
