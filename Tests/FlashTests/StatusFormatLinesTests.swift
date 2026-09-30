import XCTest

@testable import flash

/// Stacked status lines, the shape a desktop widget draws: one document per
/// line, styles carried across line breaks, alignment reset on each line.
final class StatusFormatLinesTests: XCTestCase {
  private func lines(_ source: String) -> [StatusFormatDocument] {
    let program = StatusFormatProgram.compile(source: source)
    return StatusFormatDocument.parse(
      program.evaluate(StatusFormatContext(), expandTime: false), lineBreaksResetAlignment: true
    ).lines()
  }

  private func text(_ line: StatusFormatDocument) -> String {
    line.runs.filter { !$0.isStyleBoundary }.map(\.text).joined()
  }

  private func row(_ line: StatusFormatDocument, _ columns: Int) -> String {
    StatusFormatLayout.layout(line, columns: columns).text
  }

  func testLineBreaksSplitTheDocumentAndBlankEdgeLinesAreTrimmed() {
    XCTAssertEqual(lines("a\nb").map(text), ["a", "b"])
    XCTAssertEqual(lines("\n\na\n\nb\n\n").map(text), ["a", "", "b"])
    XCTAssertEqual(lines("a\r\nb\r\n").map(text), ["a", "b"])
    XCTAssertEqual(lines("").count, 0)
    XCTAssertEqual(lines("\n \n").map(text), [" "], "a line of spaces is content")
  }

  func testColoursAndAttributesCarryOverToTheNextLine() throws {
    let result = lines("#[fg=red,bold]a\nb#[default]\nc")
    XCTAssertEqual(result.map(text), ["a", "b", "c"])
    let b = try XCTUnwrap(result[1].runs.first { $0.text == "b" })
    XCTAssertEqual(b.foreground, .palette(1))
    XCTAssertTrue(b.bold)
    let c = try XCTUnwrap(result[2].runs.first { $0.text == "c" })
    XCTAssertEqual(c.foreground, .defaultForeground)
    XCTAssertFalse(c.bold)
    // A style set on an otherwise blank first line still colours the next.
    let styled = lines("#[fg=blue]\nx")
    XCTAssertEqual(styled.map(text), ["x"])
    XCTAssertEqual(styled[0].runs.first { $0.text == "x" }?.foreground, .palette(4))
  }

  func testAlignmentResetsOnEveryLine() {
    let result = lines("#[align=right]a\nb#[align=right]c\n#[fg=red]d\n#[align=right]e")
    XCTAssertEqual(result.map { row($0, 5) }, ["    a", "b   c", "d    ", "    e"])
    XCTAssertEqual(
      lines("x\n#[align=centre]y\nz").map { row($0, 5) }, ["x    ", "  y  ", "z    "])
  }

  func testEachLineKeepsItsOwnFill() {
    let result = lines("#[fill=red]a\n#[fill=blue]b")
    XCTAssertEqual(StatusFormatLayout.layout(result[0], columns: 3).fill, .palette(1))
    XCTAssertEqual(StatusFormatLayout.layout(result[1], columns: 3).fill, .palette(4))
  }

  func testSingleLineDocumentIsUnchanged() {
    let document = StatusFormatDocument.parse("#[fg=red]a#[align=right]b")
    XCTAssertEqual(document.lines(), [document])
  }

  func testNaturalColumnsIgnoreStylesAndControlCharacters() {
    XCTAssertEqual(lines("#[fg=red]abc#[align=right]de\n界").map(\.naturalColumns), [5, 2])
  }

  func testDocumentEvaluationReportsJobsDependenciesAndRequirements() {
    let template = FlashStatusBarTemplate(
      template: "#{flash.source.a} #{flash.history.b} #(echo hi)\n#{flash.date}")
    let evaluation = FlashStatusBarTemplateEngine.evaluateDocument(
      template, native: FlashStatusBarTemplateEngine.formatContext(.init()),
      lineBreaksResetAlignment: true)
    XCTAssertEqual(evaluation.jobs.map(\.command), ["echo hi"])
    XCTAssertTrue(evaluation.dependencies.values.contains("flash.history.b"))
    let requirements = FlashStatusBarTemplateEngine.requirements(of: evaluation.dependencies)
    XCTAssertEqual(requirements.sources, ["a", "b"])
    XCTAssertEqual(requirements.clock, .minute, "#{flash.date} shows minutes")
    XCTAssertEqual(StatusFormatDocument(runs: evaluation.runs).lines().count, 2)
    XCTAssertNil(
      FlashStatusBarTemplateEngine.requirements(
        of: StatusFormatProgram.compile(source: "#{flash.source.a}").dependencies
      ).clock)
  }

  /// A surface's clock ticks at the finest unit it shows: seconds only when a
  /// seconds field is expanded, the day when nothing finer is.
  func testTheClockFollowsTheFinestTimeUnitShown() {
    func clock(_ template: String) -> StatusFormatTimeResolution? {
      let evaluation = FlashStatusBarTemplateEngine.evaluateDocument(
        FlashStatusBarTemplate(template: template),
        native: FlashStatusBarTemplateEngine.formatContext(.init()))
      return FlashStatusBarTemplateEngine.requirements(of: evaluation.dependencies).clock
    }
    XCTAssertEqual(clock("%H:%M"), .minute)
    XCTAssertEqual(clock("%a %d %b"), .day)
    XCTAssertEqual(clock("#{flash.calendar}"), .day)
    XCTAssertEqual(clock("#{flash.calendar} %H:%M"), .minute)
    for seconds in ["%S", "%T", "%s", "%X", "%r", "%c", "%+", "%-S", "%OS", "%H:%M:%S"] {
      XCTAssertEqual(clock(seconds), .second, seconds)
    }
    // A literal percent is not a clock.
    XCTAssertNil(clock("CPU 50%%"))
    XCTAssertNil(clock("static"))
  }

  func testTimeResolutionScansStrftimeConversions() {
    XCTAssertNil(StatusFormatTimeResolution.of(strftime: "100%% %n%t"))
    XCTAssertEqual(StatusFormatTimeResolution.of(strftime: "%Y-%m-%d"), .day)
    XCTAssertEqual(StatusFormatTimeResolution.of(strftime: "%d %H"), .minute)
    XCTAssertEqual(StatusFormatTimeResolution.of(strftime: "%d %_H:%M:%S"), .second)
    // Unknown conversions stay conservative.
    XCTAssertEqual(StatusFormatTimeResolution.of(strftime: "%Q"), .minute)
    XCTAssertNil(StatusFormatTimeResolution.of(strftime: "trailing %"))
  }
}
