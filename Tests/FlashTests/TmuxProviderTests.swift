import XCTest

@testable import FlashCore
@testable import FlashProviders

final class TmuxProviderTests: XCTestCase {

  // MARK: - extractWords

  func testExtractWordsSkipsSingleChars() {
    let provider = TmuxProvider()
    var out: [(Int, String)] = []
    provider.extractWords(line: "a hello x world", maxCols: 200) { c, t in
      out.append((c, t))
    }
    XCTAssertEqual(out.map { $0.1 }, ["hello", "world"])
  }

  func testExtractWordsPunctuationSplits() {
    let provider = TmuxProvider()
    var out: [(Int, String)] = []
    provider.extractWords(line: "/foo/bar/baz", maxCols: 200) { c, t in
      out.append((c, t))
    }
    XCTAssertEqual(out.map { $0.1 }, ["foo", "bar", "baz"])
    XCTAssertEqual(out.map { $0.0 }, [1, 5, 9])
  }

  // MARK: - tab targets

  func testTmuxWindowIndicesTrimEmptyLines() {
    let provider = TmuxProvider()
    XCTAssertEqual(provider.tmuxWindowIndices(from: "\n1\n  3 \n\n8\n"), ["1", "3", "8"])
  }

  func testTmuxOrdinalTabUsesWindowListOrderNotNumericIndex() {
    let provider = TmuxProvider()
    let indices = ["1", "4", "9"]
    XCTAssertEqual(
      provider.tmuxTargetForOrdinalTab(2, session: "work", windowIndices: indices),
      "work:4")
    XCTAssertNil(provider.tmuxTargetForOrdinalTab(4, session: "work", windowIndices: indices))
  }

  func testTmuxAdjacentTabWrapsOverWindowListOrder() {
    let provider = TmuxProvider()
    let indices = ["1", "4", "9"]
    XCTAssertEqual(
      provider.tmuxTargetForAdjacentTab(
        .next,
        session: "work",
        currentIndex: "9",
        windowIndices: indices),
      "work:1")
    XCTAssertEqual(
      provider.tmuxTargetForAdjacentTab(
        .previous,
        session: "work",
        currentIndex: "1",
        windowIndices: indices),
      "work:9")
  }

  func testExtractWordsAlphanumericMix() {
    let provider = TmuxProvider()
    var out: [(Int, String)] = []
    provider.extractWords(line: "var x123 abc42", maxCols: 200) { c, t in
      out.append((c, t))
    }
    XCTAssertEqual(out.map { $0.1 }, ["var", "x123", "abc42"])
    XCTAssertEqual(out.map { $0.0 }, [0, 4, 9])
  }

  func testExtractWordsMaxColsClamps() {
    let provider = TmuxProvider()
    var out: [(Int, String)] = []
    // "hello world" — with maxCols = 8 the loop accepts 'w' at col 6
    // and 'o' at col 7, then breaks on 'r' at col 8. End-of-scan
    // flush emits the 2-char "wo" word at col 6.
    provider.extractWords(line: "hello world", maxCols: 8) { c, t in
      out.append((c, t))
    }
    XCTAssertEqual(out.map { $0.1 }, ["hello", "wo"])
    XCTAssertEqual(out.map { $0.0 }, [0, 6])
  }

  func testExtractWordsMaxColsDropsTooShort() {
    let provider = TmuxProvider()
    var out: [String] = []
    // maxCols = 7 only sees 'w' from the second word — 1 char is
    // below the ≥2 threshold so it's dropped entirely.
    provider.extractWords(line: "hello world", maxCols: 7) { _, t in out.append(t) }
    XCTAssertEqual(out, ["hello"])
  }

  func testExtractWordsEmptyAndAllPunctuation() {
    let provider = TmuxProvider()
    var out: [String] = []
    provider.extractWords(line: "", maxCols: 80) { _, t in out.append(t) }
    XCTAssertTrue(out.isEmpty)
    provider.extractWords(line: "@@@!!!---", maxCols: 80) { _, t in out.append(t) }
    XCTAssertTrue(out.isEmpty)
  }

  func testExtractWordsNonASCIIBreaksWord() {
    let provider = TmuxProvider()
    var out: [String] = []
    // "hé" — `é` is letter but not ASCII, so it acts as a break;
    // "h" alone is < 2 chars and dropped.
    provider.extractWords(line: "hé world", maxCols: 80) { _, t in out.append(t) }
    XCTAssertEqual(out, ["world"])
  }

  // MARK: - parseTwoInts

  func testParseTwoIntsBasic() {
    let provider = TmuxProvider()
    XCTAssertEqual(provider.parseTwoInts("80 24")?.0, 80)
    XCTAssertEqual(provider.parseTwoInts("80 24")?.1, 24)
  }

  func testParseTwoIntsTabSeparated() {
    let provider = TmuxProvider()
    XCTAssertEqual(provider.parseTwoInts("160\t50")?.0, 160)
    XCTAssertEqual(provider.parseTwoInts("160\t50")?.1, 50)
  }

  func testParseTwoIntsRejectsMalformed() {
    let provider = TmuxProvider()
    XCTAssertNil(provider.parseTwoInts(""))
    XCTAssertNil(provider.parseTwoInts("80"))
    XCTAssertNil(provider.parseTwoInts("80 abc"))
    XCTAssertNil(provider.parseTwoInts("a b"))
  }

  // MARK: - parseStatusInfo

  func testParseStatusInfoOff() {
    let provider = TmuxProvider()
    let r = provider.parseStatusInfo("0 bottom")
    XCTAssertEqual(r.lines, 0)
    XCTAssertFalse(r.atTop)
    XCTAssertEqual(r.topOffset, 0)
  }

  func testParseStatusInfoBottomOneLine() {
    let provider = TmuxProvider()
    let r = provider.parseStatusInfo("1 bottom")
    XCTAssertEqual(r.lines, 1)
    XCTAssertFalse(r.atTop)
    XCTAssertEqual(r.topOffset, 0, "bottom status doesn't shift pane content")
  }

  func testParseStatusInfoTopOneLine() {
    let provider = TmuxProvider()
    let r = provider.parseStatusInfo("1 top")
    XCTAssertEqual(r.lines, 1)
    XCTAssertTrue(r.atTop)
    XCTAssertEqual(r.topOffset, 1)
  }

  func testParseStatusInfoTopMultiLine() {
    let provider = TmuxProvider()
    let r = provider.parseStatusInfo("3 top")
    XCTAssertEqual(r.lines, 3)
    XCTAssertTrue(r.atTop)
    XCTAssertEqual(r.topOffset, 3)
  }

  func testParseStatusInfoLegacyOnString() {
    // Older tmux versions returned "on" instead of an integer.
    let provider = TmuxProvider()
    let r = provider.parseStatusInfo("on top")
    XCTAssertEqual(r.lines, 1)
    XCTAssertTrue(r.atTop)
    XCTAssertEqual(r.topOffset, 1)
  }

  func testParseStatusInfoLegacyOffString() {
    let provider = TmuxProvider()
    let r = provider.parseStatusInfo("off bottom")
    XCTAssertEqual(r.lines, 0)
    XCTAssertEqual(r.topOffset, 0)
  }

  func testParseStatusInfoTabSeparated() {
    let provider = TmuxProvider()
    let r = provider.parseStatusInfo("2\ttop")
    XCTAssertEqual(r.lines, 2)
    XCTAssertTrue(r.atTop)
    XCTAssertEqual(r.topOffset, 2)
  }

  // MARK: - resolveGeometry

  func testResolveGeometryFallbackForUnknownBundle() {
    let provider = TmuxProvider()
    let window = CGRect(x: 0, y: 0, width: 800, height: 480)
    let g = provider.resolveGeometry(
      bundleID: "com.apple.Terminal",
      windowFrame: window,
      clientCols: 80, clientRows: 24)
    XCTAssertEqual(g.cellW, 10.0)
    XCTAssertEqual(g.cellH, 20.0)
    XCTAssertEqual(g.padX, 0.0)
    XCTAssertEqual(g.padY, 0.0)
  }

  func testResolveGeometryFallbackNonIntegerCells() {
    // Most real terminals don't divide evenly; the fallback should
    // still spread the entire window across `cells` (padding absorbed
    // into cell size).
    let provider = TmuxProvider()
    let window = CGRect(x: 100, y: 50, width: 805, height: 489)
    let g = provider.resolveGeometry(
      bundleID: "com.googlecode.iterm2",
      windowFrame: window,
      clientCols: 80, clientRows: 24)
    XCTAssertEqual(g.cellW, 805.0 / 80.0, accuracy: 1e-9)
    XCTAssertEqual(g.cellH, 489.0 / 24.0, accuracy: 1e-9)
    XCTAssertEqual(g.padX, 0.0)
    XCTAssertEqual(g.padY, 0.0)
  }

  // MARK: - TOML reader

  func testReadTOMLStringInSection() {
    let provider = TmuxProvider()
    let toml = """
      # comment
      [font]
      size = 14

      [font.normal]
      family = "JetBrains Mono"
      style = "Regular"
      """
    XCTAssertEqual(
      provider.readTOMLString(in: toml, section: "font.normal", key: "family"),
      "JetBrains Mono")
    XCTAssertEqual(
      provider.readTOMLString(in: toml, section: "font.normal", key: "style"),
      "Regular")
  }

  func testReadTOMLNumberInSection() {
    let provider = TmuxProvider()
    let toml = """
      [font]
      size = 13.5
      """
    XCTAssertEqual(provider.readTOMLNumber(in: toml, section: "font", key: "size"), 13.5)
  }

  func testReadTOMLMissingKeyReturnsNil() {
    let provider = TmuxProvider()
    let toml = """
      [font]
      size = 12
      """
    XCTAssertNil(provider.readTOMLString(in: toml, section: "font", key: "family"))
    XCTAssertNil(provider.readTOMLString(in: toml, section: "window", key: "size"))
  }

  func testReadTOMLIgnoresWrongSection() {
    let provider = TmuxProvider()
    let toml = """
      [window]
      family = "Wrong"

      [font.normal]
      family = "Right"
      """
    XCTAssertEqual(
      provider.readTOMLString(in: toml, section: "font.normal", key: "family"),
      "Right")
  }

  // MARK: - Cell metrics

  func testCellMetricsResolvesKnownFont() {
    let provider = TmuxProvider()
    // Menlo ships on every macOS and is the default fallback inside
    // cellMetrics, so it's the most reliable family for assertions.
    let m = provider.cellMetrics(family: "Menlo", size: 12)
    XCTAssertNotNil(m)
    XCTAssertGreaterThan(m!.width, 0)
    XCTAssertGreaterThan(m!.height, 0)
    // Monospace: same advance across the size range; height scales
    // roughly linearly. A 24pt cell should be ~2× taller than 12pt.
    let m24 = provider.cellMetrics(family: "Menlo", size: 24)
    XCTAssertNotNil(m24)
    XCTAssertEqual(m24!.height / m!.height, 2.0, accuracy: 0.05)
  }

  func testCellMetricsFallbackForUnknownFamily() {
    let provider = TmuxProvider()
    // Falls back to Menlo, then to monospacedSystemFont. Must never
    // return nil for a positive size — width/height are always > 0.
    let m = provider.cellMetrics(family: "DefinitelyNotAFont-XYZ", size: 12)
    XCTAssertNotNil(m)
    XCTAssertGreaterThan(m?.width ?? 0, 0)
    XCTAssertGreaterThan(m?.height ?? 0, 0)
  }

  // MARK: - Provider identity

  func testProviderIdentity() {
    let provider = TmuxProvider()
    XCTAssertEqual(provider.identifier, "tmux")
    XCTAssertEqual(provider.priority, 20)
    XCTAssertTrue(provider.resultsAreVolatile)
  }
}
