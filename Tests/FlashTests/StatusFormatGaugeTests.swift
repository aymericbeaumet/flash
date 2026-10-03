import AppKit
import CoreText
import XCTest

@testable import flash

/// Flash's numeric style extensions: `#[meter=W/MAX]…#[nometer]` draws the
/// first number of the enclosed text as an eighth-block bar, and
/// `#[spark=MIN/MAX]…#[nospark]` draws each number as one block of a
/// sparkline. Both replace text once the document is parsed.
final class StatusFormatGaugeTests: XCTestCase {
  private func document(
    _ source: String, options: [String: String] = [:], lines: Bool = false
  ) -> StatusFormatDocument {
    var context = StatusFormatContext()
    context.options = options
    return StatusFormatDocument.parse(
      StatusFormatProgram.compile(source: source).evaluate(context),
      lineBreaksResetAlignment: lines)
  }

  private func text(_ source: String, options: [String: String] = [:]) -> String {
    text(document(source, options: options))
  }

  private func text(_ document: StatusFormatDocument) -> String {
    document.runs.filter { !$0.isStyleBoundary }.map(\.text).joined()
  }

  // MARK: meter

  func testMeterFillsWholeAndEighthCellsAndPadsTheTrackWithSpaces() {
    XCTAssertEqual(text("[#[meter=4]50#[nometer]]"), "[██  ]")
    XCTAssertEqual(text("#[meter=4]30#[nometer]"), "█▎  ", "30% of 32 eighths rounds to 10")
    XCTAssertEqual(text("#[meter=1]50#[nometer]"), "▌")
    XCTAssertEqual(text("#[meter=10]100#[nometer]"), "██████████")
    XCTAssertEqual(text("#[meter=10]0#[nometer]"), "          ")
    let partials = (1...7).map { text("#[meter=1/8]\($0)#[nometer]") }
    XCTAssertEqual(partials, ["▏", "▎", "▍", "▌", "▋", "▊", "▉"])
  }

  func testMeterClampsToItsRange() {
    XCTAssertEqual(text("#[meter=4]150#[nometer]"), "████")
    XCTAssertEqual(text("#[meter=4]-20#[nometer]"), "    ")
    XCTAssertEqual(text("#[meter=4/8]9#[nometer]"), "████")
  }

  func testMeterMaximumScalesTheValue() {
    XCTAssertEqual(text("#[meter=4/8]2#[nometer]"), "█   ")
    XCTAssertEqual(text("#[meter=10/1]0.55#[nometer]"), "█████▌    ")
    XCTAssertEqual(text("#[meter=8/2.5]1.25#[nometer]"), "████    ")
  }

  func testMeterReadsTheFirstNumberAndReplacesTheEnclosedText() {
    XCTAssertEqual(text("#[meter=4]CPU 75.0% of 100#[nometer]!"), "███ !")
    XCTAssertEqual(text("#[meter=4]x-50#[nometer]"), "    ", "a sign counts after a letter")
    XCTAssertEqual(text("#[meter=4]10-20#[nometer]"), "▍   ", "a dash after a digit is not a sign")
  }

  func testNonNumericMeterKeepsItsTextUnchanged() {
    XCTAssertEqual(text("#[meter=4]n/a#[nometer]"), "n/a")
    XCTAssertEqual(text("#[meter=4]#[nometer]x"), "x")
    XCTAssertEqual(text("#[meter=4]#{@missing}#[nometer]"), "")
  }

  func testMeterMergesTheRunsItEnclosesBeforeReadingTheNumber() throws {
    let result = document(
      "#[meter=4]#{@a}#{@b}#[fg=red]%#[nometer]", options: ["@a": "5", "@b": "0"])
    XCTAssertEqual(text(result), "██  ")
    let bar = try XCTUnwrap(result.runs.first { !$0.isStyleBoundary })
    XCTAssertEqual(bar.foreground, .defaultForeground, "the bar takes its first run's style")
    XCTAssertEqual(result.runs.filter { !$0.isStyleBoundary }.count, 1)
  }

  func testEachMeterMarkerStartsItsOwnBar() {
    XCTAssertEqual(text("#[meter=2]100#[meter=2]0#[nometer]"), "██  ")
    XCTAssertEqual(text("#[meter=2]100 #[meter=2]50 #[nometer]"), "███ ")
  }

  func testMeterKeepsItsStyleSoTheBackgroundPaintsTheTrack() throws {
    let result = document("#[meter=4 fg=green bg=colour8]50#[nometer default]x")
    XCTAssertEqual(text(result), "██  x")
    let bar = try XCTUnwrap(result.runs.first { $0.text == "██  " })
    XCTAssertEqual(bar.foreground, .palette(2))
    XCTAssertEqual(bar.background, .palette(8))
  }

  func testMalformedMeterMarkersAreRejectedTransactionally() throws {
    for marker in [
      "meter", "meter=", "meter=0", "meter=201", "meter=x", "meter=4/", "meter=4/0", "meter=4/-1",
      "meter=4/x", "meter=4/8/9", "meter=-4", "meter=4/inf", "meter=4/nan",
    ] {
      let result = document("#[fg=red]#[\(marker),bold]50")
      XCTAssertEqual(text(result), "50", marker)
      let run = try XCTUnwrap(result.runs.last)
      XCTAssertEqual(run.foreground, .palette(1), marker)
      XCTAssertFalse(run.bold, "\(marker) must roll back the whole marker")
    }
    XCTAssertEqual(text("#[meter=200]100#[nometer]").count, 200)
  }

  func testNometerOnlyEndsAMeterAndDefaultDoesNotEndIt() {
    XCTAssertEqual(text("#[meter=2]#[default]100#[nometer]"), "██")
    XCTAssertEqual(text("#[meter=2]#[nospark]100#[nometer]"), "██")
    XCTAssertEqual(text("#[nometer]100"), "100")
  }

  func testConditionalsCanSelectAMeter() {
    let format = "#{?@on,#[meter=4]#{@v}#[nometer],off}"
    XCTAssertEqual(text(format, options: ["@on": "1", "@v": "50"]), "██  ")
    XCTAssertEqual(text(format, options: ["@on": "0", "@v": "50"]), "off")
    XCTAssertEqual(
      text("#[meter=4]#{?@hot,100,0}#[nometer]", options: ["@hot": "1"]), "████")
  }

  func testGaugesNeverSpanALineBreak() {
    let result = document("A #[meter=2]100\n0#[nometer] B\nC", lines: true).lines()
    XCTAssertEqual(result.map(text), ["A ██", "   B", "C"])
  }

  func testMeterOccupiesExactlyItsCellsInLayout() {
    let line = document("#[align=right]#[meter=4]50#[nometer]|", lines: true)
    XCTAssertEqual(line.naturalColumns, 5)
    XCTAssertEqual(StatusFormatLayout.layout(line, columns: 8).text, "   ██  |")
    let bar = StatusFormatLayout.layout(document("#[meter=3/8]4#[nometer]"), columns: 3)
    XCTAssertEqual(bar.cells.map(\.segment.text), ["█", "▌", " "])
    XCTAssertTrue(bar.cells.allSatisfy { $0.columns == 1 })
    for glyph in Self.blocks {
      XCTAssertEqual(StatusFormatCells.width(glyph), 1, glyph)
    }
  }

  // MARK: spark

  func testSparkScalesFromZeroToTheLargestValueLikeTheRustSDK() {
    XCTAssertEqual(text("#[spark]0 1 2 3#[nospark]"), "▁▃▅█")
    XCTAssertEqual(text("#[spark]0 0#[nospark]"), "▁▁", "an all-zero window is flat")
    XCTAssertEqual(text("#[spark]12, 40;33.5 -3#[nospark]"), "▃█▆▁")
    XCTAssertEqual(text("#[spark]7#[nospark]"), "█")
  }

  func testSparkWithAnExplicitRangeClampsAndWorksAsAGaugeGlyph() {
    XCTAssertEqual(text("#[spark=0/100]0 50 100 150 -5#[nospark]"), "▁▄██▁")
    XCTAssertEqual(text("#[spark=0/100]42#[nospark]"), "▃")
    XCTAssertEqual(text("#[spark=-10/10]-10 0 10#[nospark]"), "▁▄█")
    XCTAssertEqual(text("#[spark=0/1]0.5#[nospark]"), "▄")
  }

  func testSparkReadsHistoriesAndKeepsNonNumericText() {
    XCTAssertEqual(text("load #[spark]#{flash.history.load}#[nospark]."), "load .")
    var context = StatusFormatContext()
    context.values["flash.history.load"] = "1.5 3 0.75"
    let result = StatusFormatDocument.parse(
      StatusFormatProgram.compile(source: "#[spark]#{flash.history.load}#[nospark]").evaluate(
        context))
    XCTAssertEqual(text(result), "▄█▂")
    XCTAssertEqual(text("#[spark]idle#[nospark]"), "idle")
  }

  func testMalformedSparkMarkersAreRejectedTransactionally() throws {
    for marker in ["spark=", "spark=5", "spark=5/5", "spark=9/1", "spark=a/b", "spark=0/1/2"] {
      let result = document("#[fg=red]#[\(marker),bold]1 2")
      XCTAssertEqual(text(result), "1 2", marker)
      XCTAssertFalse(try XCTUnwrap(result.runs.last).bold, marker)
    }
  }

  func testSparkAndMeterReplaceEachOther() {
    XCTAssertEqual(text("#[meter=2]#[spark]0 1#[nospark]"), "▁█")
    XCTAssertEqual(text("#[spark]#[meter=2]100#[nospark]#[nometer]"), "██")
  }

  // MARK: serialization and rendering

  func testSerializationOmitsGaugeTokensAndRoundTripsTheRenderedText() {
    let parsed = document("a #[meter=4 fg=red]50#[nometer] #[spark]1 2#[nospark]")
    XCTAssertTrue(parsed.runs.allSatisfy { $0.gauge == nil })
    let serialized = StatusFormatDocument.serialize(parsed.runs)
    XCTAssertFalse(serialized.contains("meter"))
    XCTAssertFalse(serialized.contains("spark"))
    let reparsed = StatusFormatDocument.parse(serialized)
    XCTAssertEqual(text(reparsed), "a ██   ▄█")
    XCTAssertEqual(text(reparsed), text(parsed))
    XCTAssertEqual(
      reparsed.runs.first { $0.text.hasPrefix("█") }?.foreground, .palette(1))
  }

  func testDefaultStatusAndWidgetFontsResolveEveryBlockGlyph() throws {
    let fonts = [
      NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
      NSFont.monospacedSystemFont(ofSize: 13, weight: .bold),
      StatusWidgetFont.font(name: "", size: 13),
    ]
    for font in fonts {
      let cell = ("M" as NSString).size(withAttributes: [.font: font]).width
      for glyph in Self.blocks + ["─"] {
        var characters = Array(glyph.utf16)
        let resolved = CTFontCreateForString(
          font as CTFont, glyph as CFString, CFRange(location: 0, length: characters.count))
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        XCTAssertTrue(
          CTFontGetGlyphsForCharacters(resolved, &characters, &glyphs, characters.count),
          "\(font.fontName) has no glyph for \(glyph)")
        XCTAssertNotEqual(glyphs[0], 0, glyph)
        guard CFEqual(resolved, font as CTFont) else { continue }
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(resolved, .horizontal, &glyphs, &advance, 1)
        XCTAssertEqual(advance.width, cell, accuracy: 0.01, "\(glyph) fills one cell")
      }
    }
  }

  private static let blocks = [
    "▏", "▎", "▍", "▌", "▋", "▊", "▉", "█", "▁", "▂", "▃", "▄", "▅", "▆", "▇",
  ]
}
