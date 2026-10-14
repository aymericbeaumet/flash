import CoreGraphics
import FlashCore
import XCTest

@testable import flash

final class BigramMatchTests: XCTestCase {
  func testADigitAndItsShiftedSymbolMatchTheSameGlyphs() {
    let text = "3 # 3# #"
    let digit = BigramMatcher.occurrences(in: text, query: "3").map(\.location)
    XCTAssertEqual(digit, [0, 2, 4, 5, 7])
    XCTAssertEqual(BigramMatcher.occurrences(in: text, query: "#").map(\.location), digit)
    XCTAssertEqual(BigramMatcher.occurrences(in: "3$", query: "3").map(\.location), [0])
    XCTAssertTrue(BigramMatcher.sliceMatches(text: "#", location: 0, length: 1, query: "3"))
    XCTAssertTrue(BigramMatcher.sliceMatches(text: "3", location: 0, length: 1, query: "#"))
    XCTAssertFalse(BigramMatcher.sliceMatches(text: "$", location: 0, length: 1, query: "3"))
  }

  /// The pairs are the ones printed on a US key, so a layout change that
  /// moves `#` off Shift-3 fails here instead of in a session.
  func testShiftPartnersFollowTheUSKeyboard() {
    let layout = KeyboardLayout.usANSI
    for code in UInt16(0)..<UInt16(KeyboardLayout.keyCodeCount) {
      guard let plain = layout.character(keyCode: code, shift: false),
        let shifted = layout.character(keyCode: code, shift: true),
        plain.count == 1, shifted.count == 1, plain != shifted,
        let plainChar = plain.first, let shiftedChar = shifted.first,
        !plainChar.isLetter, !shiftedChar.isLetter
      else { continue }
      let text = plain + shifted
      let fromPlain = BigramMatcher.occurrences(in: text, query: plain).map(\.location)
      XCTAssertEqual(
        fromPlain, BigramMatcher.occurrences(in: text, query: shifted).map(\.location),
        "\(plain) and \(shifted)")
      XCTAssertEqual(fromPlain, [0, (plain as NSString).length], "\(plain) and \(shifted)")
    }
  }

  func testEitherCaseMatchesTheSameLetters() {
    let folded = "Vv vV"
    let lower = BigramMatcher.occurrences(in: folded, query: "v").map(\.location)
    XCTAssertEqual(lower, [0, 1, 3, 4])
    XCTAssertEqual(
      BigramMatcher.occurrences(in: folded, query: "V").map(\.location), lower)
    XCTAssertEqual(
      BigramMatcher.occurrences(in: "Aaa a", query: "a").map(\.location),
      [0, 1, 2, 4])
    XCTAssertEqual(
      BigramMatcher.occurrences(in: "Aaa a", query: "A").map(\.location),
      [0, 1, 2, 4])
    XCTAssertEqual(
      BigramMatcher.occurrences(in: "th Th tH TH", query: "T").map(\.location),
      BigramMatcher.occurrences(in: "th Th tH TH", query: "t").map(\.location))
  }

  func testAQueryThatIsNotOneCharacterMatchesNothing() {
    XCTAssertTrue(BigramMatcher.occurrences(in: "the", query: "").isEmpty)
    XCTAssertTrue(BigramMatcher.occurrences(in: "the", query: "th").isEmpty)
    XCTAssertTrue(BigramMatcher.occurrences(in: "the", query: "the").isEmpty)
  }

  func testOneEmojiIsACompleteQuery() {
    let mark = "👍"
    XCTAssertEqual(mark.count, 1)
    let hits = BigramMatcher.occurrences(in: "👍👍👍", query: mark)
    XCTAssertEqual(hits.map(\.location), [0, 2, 4])
    XCTAssertEqual(hits.map(\.length), [2, 2, 2])
  }

  func testSliceMatchFoldsCase() {
    XCTAssertTrue(BigramMatcher.sliceMatches(text: " The", location: 1, length: 2, query: "th"))
    XCTAssertTrue(BigramMatcher.sliceMatches(text: "the", location: 0, length: 2, query: "Th"))
    XCTAssertTrue(BigramMatcher.sliceMatches(text: "TH", location: 0, length: 2, query: "th"))
    XCTAssertFalse(BigramMatcher.sliceMatches(text: "th", location: 0, length: 3, query: "th"))
    XCTAssertFalse(BigramMatcher.sliceMatches(text: "th", location: -1, length: 2, query: "th"))
  }

  func testACommonLetterUsesTheSameLineBoxesAsARareOne() {
    let line = BigramMatcher.BigramLineBox(
      location: 0, length: 5, bounds: CGRect(x: 10, y: 30, width: 50, height: 12))
    let text = "eevee"
    let e = BigramMatcher.glyphRects(in: text, query: "e", lines: [line])
    let v = BigramMatcher.glyphRects(in: text, query: "v", lines: [line])
    XCTAssertEqual(e.map(\.occurrence.location), [0, 1, 3, 4])
    XCTAssertEqual(v.map(\.occurrence.location), [2])
    XCTAssertEqual(e.map(\.rect.minY), [30, 30, 30, 30])
    XCTAssertEqual(v.map(\.rect.minY), [30])
    XCTAssertGreaterThan(v[0].rect.minX, e[1].rect.minX)
    XCTAssertLessThan(v[0].rect.minX, e[2].rect.minX)
  }

  // MARK: Glyph advances

  /// Narrow letters before a wide one: by character count the `W` would sit
  /// at nine tenths of the line, but its glyph starts much earlier.
  func testAKnownFontPlacesALetterByItsAdvancesNotItsIndex() throws {
    let advances = try XCTUnwrap(GlyphAdvances(TextFont(name: "Helvetica", size: 13)))
    let line = BigramMatcher.BigramLineBox(
      location: 0, length: 10, bounds: CGRect(x: 0, y: 0, width: 100, height: 16))
    let counted = try XCTUnwrap(
      BigramMatcher.glyphRects(in: "iiiiiiiiiW", query: "w", lines: [line]).first)
    XCTAssertEqual(counted.rect.minX, 90, accuracy: 0.01)
    let measured = try XCTUnwrap(
      BigramMatcher.glyphRects(
        in: "iiiiiiiiiW", query: "w", lines: [line], advances: advances
      ).first)
    XCTAssertLessThan(measured.rect.minX, 75)
    XCTAssertGreaterThan(measured.rect.width, 25)
    XCTAssertEqual(measured.rect.maxX, 100, accuracy: 0.5)
  }

  func testAMonospacedFontKeepsTheColumnPlacement() throws {
    let advances = try XCTUnwrap(GlyphAdvances(TextFont(name: "Menlo-Regular", size: 12)))
    let line = BigramMatcher.BigramLineBox(
      location: 0, length: 10, bounds: CGRect(x: 0, y: 0, width: 100, height: 16))
    let hit = try XCTUnwrap(
      BigramMatcher.glyphRects(
        in: "iiiiiiiiiW", query: "w", lines: [line], advances: advances
      ).first)
    XCTAssertEqual(hit.rect.minX, 90, accuracy: 0.01)
    XCTAssertEqual(hit.rect.width, 10, accuracy: 0.01)
  }

  func testWordsUseTheSameAdvances() throws {
    let advances = try XCTUnwrap(GlyphAdvances(TextFont(name: "Helvetica", size: 13)))
    let line = BigramMatcher.BigramLineBox(
      location: 0, length: 12, bounds: CGRect(x: 0, y: 0, width: 120, height: 16))
    let words = WordMatcher.wordRects(in: "iiiiiiiii WW", lines: [line], advances: advances)
    XCTAssertEqual(words.map(\.occurrence.location), [0, 10])
    XCTAssertLessThan(words[1].rect.minX, 80)
  }

  /// The system UI face is reported under a private dotted name; a font that
  /// is not installed would be substituted, so it measures nothing.
  func testOnlyAnInstalledOrSystemFontMeasures() {
    XCTAssertNotNil(GlyphAdvances(TextFont(name: ".SFNS-Regular", size: 13)))
    XCTAssertNotNil(GlyphAdvances(TextFont(name: "Helvetica Neue", size: 13)))
    XCTAssertNil(GlyphAdvances(TextFont(name: "NoSuchFace-Regular", size: 13)))
    XCTAssertNil(GlyphAdvances(TextFont(name: "Helvetica", size: 0)))
  }

  /// The commit re-reads the glyph's bounds and keeps the landing the caller
  /// chose on the captured rect: one point left of centre in NORMAL, one
  /// point right in VISUAL.
  func testTheCommitKeepsTheCallersLandingOnTheReReadGlyph() {
    let captured = CGRect(x: 10, y: 0, width: 8, height: 10)
    let reread = CGRect(x: 100, y: 20, width: 6, height: 10)
    XCTAssertEqual(
      BigramMatcher.clickPoint(
        in: reread,
        keeping: BigramMatcher.clickPoint(in: captured, selectingThrough: true), from: captured),
      CGPoint(x: 104, y: 25))
    XCTAssertEqual(
      BigramMatcher.clickPoint(
        in: reread,
        keeping: BigramMatcher.clickPoint(in: captured, selectingThrough: false), from: captured),
      CGPoint(x: 102, y: 25))
  }

  func testATrailingNewlineDoesNotTakeAColumn() {
    let line = BigramMatcher.BigramLineBox(
      location: 0, length: 3, bounds: CGRect(x: 0, y: 0, width: 20, height: 10))
    XCTAssertEqual(
      BigramMatcher.glyphRects(in: "ab\n", query: "b", lines: [line]).map(\.rect),
      [CGRect(x: 10, y: 0, width: 10, height: 10)])
  }

  func testNewlineBoxesStackFromTheTopOfTheFrame() {
    let frame = CGRect(x: 0, y: 0, width: 30, height: 20)
    let boxes = BigramMatcher.newlineBoxes(text: "ee\nv", frame: frame)
    XCTAssertEqual(boxes.map(\.location), [0, 3])
    XCTAssertEqual(boxes.map(\.bounds.minY), [10, 0])
    let hits = BigramMatcher.glyphRects(in: "ee\nv", query: "e", lines: boxes)
    XCTAssertEqual(hits.map(\.occurrence.location), [0, 1])
    XCTAssertEqual(hits.map(\.rect.minY), [10, 10])
  }

  func testWrappedBoxesFollowTheSampleGlyph() {
    let frame = CGRect(x: 0, y: 0, width: 20, height: 20)
    let glyph = CGRect(x: 0, y: 10, width: 10, height: 10)
    let boxes = BigramMatcher.wrappedBoxes(text: "eeee", frame: frame, glyph: glyph)
    XCTAssertEqual(boxes.map(\.location), [0, 2])
    XCTAssertEqual(boxes.map(\.length), [2, 2])
    XCTAssertEqual(boxes.map(\.bounds.minY), [10, 0])
  }

  func testASecondLineKeepsItsOwnBounds() {
    let lines = [
      BigramMatcher.BigramLineBox(
        location: 0, length: 4, bounds: CGRect(x: 0, y: 20, width: 30, height: 10)),
      BigramMatcher.BigramLineBox(
        location: 4, length: 1, bounds: CGRect(x: 0, y: 0, width: 10, height: 10)),
    ]
    let hits = BigramMatcher.glyphRects(in: "eve\nv", query: "v", lines: lines)
    XCTAssertEqual(hits.map(\.occurrence.location), [1, 4])
    XCTAssertEqual(hits.map(\.rect.minY), [20, 0])
  }

  func testProportionalFallbackIsSingleLineOnly() {
    let line = CGRect(x: 0, y: 0, width: 100, height: 64)
    XCTAssertTrue(BigramMatcher.allowsProportionalFallback(text: "hello", frame: line))
    XCTAssertFalse(
      BigramMatcher.allowsProportionalFallback(
        text: "hello", frame: CGRect(x: 0, y: 0, width: 100, height: 65)))
    XCTAssertFalse(BigramMatcher.allowsProportionalFallback(text: "hel\nlo", frame: line))
    XCTAssertFalse(
      BigramMatcher.allowsProportionalFallback(
        text: "hello", frame: CGRect(x: 0, y: 0, width: 100, height: 0)))
  }

  func testProportionalRectStaysInsideTheFrame() {
    let frame = CGRect(x: 10, y: 20, width: 100, height: 16)
    let head = BigramMatcher.proportionalRect(frame: frame, location: 0, length: 2, totalUTF16: 10)
    XCTAssertEqual(head, CGRect(x: 10, y: 20, width: 20, height: 16))
    let tail = BigramMatcher.proportionalRect(frame: frame, location: 8, length: 2, totalUTF16: 10)
    XCTAssertEqual(tail?.maxX, frame.maxX)
    XCTAssertEqual(tail?.width, 20)
    let thin = BigramMatcher.proportionalRect(
      frame: frame, location: 0, length: 1, totalUTF16: 1000)
    XCTAssertEqual(thin?.width, 4)
    XCTAssertNil(
      BigramMatcher.proportionalRect(frame: frame, location: 0, length: 2, totalUTF16: 0))
  }

  func testDedupeKeepsTheFirstOfTwoCloseCenters() {
    let first = CGRect(x: 0, y: 0, width: 10, height: 10)
    let same = CGRect(x: 1, y: 1, width: 10, height: 10)
    let other = CGRect(x: 30, y: 0, width: 10, height: 10)
    let kept = BigramMatcher.dedupe([
      (rect: first, value: "a"),
      (rect: same, value: "b"),
      (rect: other, value: "c"),
    ])
    XCTAssertEqual(kept.map(\.value), ["a", "c"])
  }

  func testOwnStringPrefersTheVisibleAttributeAndKeepsRawText() {
    XCTAssertEqual(
      BigramText.ownString(
        role: "AXStaticText", title: "title", value: "  th  ", descendantEmitted: false),
      "  th  ")
    XCTAssertEqual(
      BigramText.ownString(
        role: "AXButton", title: "OK", value: "value", descendantEmitted: false),
      "OK")
    XCTAssertEqual(
      BigramText.ownString(role: "AXButton", title: "x", value: "Go", descendantEmitted: false),
      "x")
    XCTAssertEqual(
      BigramText.ownString(role: "AXStaticText", title: nil, value: "a", descendantEmitted: false),
      "a")
    XCTAssertNil(
      BigramText.ownString(role: "AXButton", title: "OK", value: nil, descendantEmitted: true))
    XCTAssertNil(
      BigramText.ownString(role: "AXImage", title: "icon", value: nil, descendantEmitted: false))
    XCTAssertNil(
      BigramText.ownString(role: "AXStaticText", title: " ", value: " ", descendantEmitted: false))
  }

  func testEasyMotionUsesTheSameWindowFrameAsTargetHints() {
    let window = CGRect(x: 10, y: 20, width: 800, height: 400)
    XCTAssertEqual(BigramSearch.hintWindow(window, fallback: .zero), window)
    XCTAssertEqual(BigramSearch.hintWindow(.null, fallback: window), window)
    XCTAssertEqual(BigramSearch.hintWindow(.zero, fallback: window), window)
  }

  func testTmuxGridPlacesALetterOnItsCellAndFindsTheClientOfTheFocusedApp() {
    let window = CGRect(x: 10, y: 20, width: 800, height: 400)
    let cells = TmuxBigramGrid.metrics(
      bundleIdentifier: "com.example.term", window: window, columns: 80, rows: 20)
    let grid = TmuxBigramGrid.Grid(
      cellWidth: cells.cellWidth,
      cellHeight: cells.cellHeight,
      padX: cells.padX,
      padY: cells.padY,
      origin: CGPoint(x: window.minX, y: window.minY),
      windowHeight: window.height,
      topOffset: 0,
      panes: [TmuxBigramGrid.Pane(left: 0, top: 0, lines: ["v"])])
    let targets = grid.targets(matching: "v", pid: 7, bundleIdentifier: "com.example.term")
    XCTAssertEqual(targets.count, 1)
    XCTAssertEqual(
      targets[0].resolvedClickPoint(preferred: .zero),
      BigramMatcher.clickPoint(in: targets[0].frame))
    // VISUAL lands one point right instead, so a held button's selection
    // ends on the letter rather than before it.
    let frame = targets[0].frame
    XCTAssertEqual(
      BigramMatcher.clickPoint(in: frame, selectingThrough: true),
      CGPoint(x: frame.midX + 1, y: frame.midY))
    XCTAssertEqual(
      BigramMatcher.clickPoint(in: frame, selectingThrough: false),
      CGPoint(x: frame.midX - 1, y: frame.midY))
    XCTAssertEqual(targets[0].frame.minX, window.minX, accuracy: 0.01)
    XCTAssertEqual(
      targets[0].frame.maxY, window.maxY, accuracy: 0.01,
      "row 0 sits on the top edge of the window")
    XCTAssertEqual(
      TmuxBigramGrid.clientTTY(
        lines: ["100 /dev/ttys001", "200 /dev/ttys002"],
        focusedPID: 50,
        parent: { pid in
          switch pid {
          case 200: return 50
          default: return nil
          }
        }),
      "/dev/ttys002")
    XCTAssertEqual(TmuxBigramGrid.statusTopOffset(status: "on", position: "top"), 1)
    XCTAssertEqual(TmuxBigramGrid.statusTopOffset(status: "on", position: "bottom"), 0)
  }

  func testTmuxLetterSearchIncludesTheStatusLineAndCentredPaneTitles() throws {
    let snapshot = try XCTUnwrap(
      TmuxBigramGrid.parseSnapshot(
        geometry: "20 6 on top|||#[fg=colour178 bold]za",
        paneList: """
          %7 10 1 9 4 top|||#[align=centre] a
          %8 0 1 9 4 off|||#[align=left]hidden
          """))
    XCTAssertEqual(snapshot.topOffset, 1)
    let status = try XCTUnwrap(snapshot.status)
    XCTAssertEqual(status.row, 0)
    XCTAssertFalse(status.text.contains("#"))
    XCTAssertFalse(status.text.contains("colour"))
    XCTAssertEqual(status.span(location: 1, length: 1)?.column, 1)

    XCTAssertEqual(snapshot.panes.count, 2)
    XCTAssertNil(snapshot.panes[1].title)
    let title = try XCTUnwrap(snapshot.panes[0].title)
    XCTAssertEqual(title.row, 1)
    XCTAssertFalse(title.text.contains("#"))
    let titleHit = try XCTUnwrap(BigramMatcher.occurrences(in: title.text, query: "a").first)
    XCTAssertEqual(title.span(location: titleHit.location, length: 1)?.column, 14)

    let grid = TmuxBigramGrid.Grid(
      cellWidth: 10, cellHeight: 10, padX: 0, padY: 0,
      origin: .zero, windowHeight: 60, topOffset: snapshot.topOffset,
      panes: [TmuxBigramGrid.Pane(left: 10, top: 1, lines: ["xa"])],
      chrome: [status, title])
    let hits = grid.targets(matching: "a", pid: 3, bundleIdentifier: "org.alacritty")
    XCTAssertEqual(hits.count, 3)
    XCTAssertEqual(hits.map(\.frame.maxY).sorted(by: >), [60, 50, 40])
    let content = try XCTUnwrap(hits.first { $0.frame.maxY == 40 })
    XCTAssertEqual(content.frame.minX, 110, accuracy: 0.01)
    let statusHit = try XCTUnwrap(hits.first { $0.frame.maxY == 60 })
    XCTAssertEqual(statusHit.frame.minX, 10, accuracy: 0.01)
    let titleHitFrame = try XCTUnwrap(hits.first { $0.frame.maxY == 50 })
    XCTAssertEqual(titleHitFrame.frame.minX, 140, accuracy: 0.01)
    XCTAssertEqual(hits.map(\.accessibilityLabel), ["a", "a", "a"])
  }

  func testTmuxStatusAndPaneTitleRowsFollowTheClientGrid() throws {
    XCTAssertEqual(
      TmuxBigramGrid.paneTitleRow(border: "top", topOffset: 1, paneTop: 1, paneHeight: 68), 1)
    XCTAssertEqual(TmuxBigramGrid.statusRow(status: "on", position: "top", clientRows: 70), 0)
    XCTAssertNil(
      TmuxBigramGrid.paneTitleRow(border: "off", topOffset: 1, paneTop: 0, paneHeight: 10))
    let bottom = try XCTUnwrap(
      TmuxBigramGrid.parseSnapshot(
        geometry: "9 5 on bottom|||#[align=left]s",
        paneList: "%1 0 0 9 3 bottom|||#[align=left]t"))
    XCTAssertEqual(bottom.topOffset, 0)
    XCTAssertEqual(bottom.status?.row, 4)
    XCTAssertEqual(bottom.panes.first?.title?.row, 3)

    let statusLine = try XCTUnwrap(
      TmuxBigramGrid.placedLine(
        format:
          "#[align=left] #[fg=colour178 bold][scratch@macbook]#[fg=colour245 nobold]  #[range=user|3 fg=colour245]3:flash#[norange fg=colour245]  ",
        width: 256, row: 0, origin: 0))
    XCTAssertFalse(statusLine.text.contains("#"))
    XCTAssertTrue(statusLine.text.contains("[scratch@macbook]"))
    XCTAssertTrue(statusLine.text.contains("3:flash"))
    XCTAssertEqual(statusLine.units.first?.column, 0)

    let live = try XCTUnwrap(
      TmuxBigramGrid.placedLine(
        format: "#[align=centre] [codex busy] Mirror | tma-monorepo ",
        width: 128, row: 1, origin: 0))
    XCTAssertFalse(live.text.contains("#"))
    XCTAssertTrue(live.text.contains("tma-monorepo"))
    XCTAssertTrue(live.text.contains("[codex busy]"))
    let hits = BigramMatcher.occurrences(in: live.text, query: "a")
    XCTAssertFalse(hits.isEmpty)
    for hit in hits {
      let column = try XCTUnwrap(live.span(location: hit.location, length: hit.length)).column
      XCTAssertGreaterThanOrEqual(column, 0)
      XCTAssertLessThan(column, 128)
    }
  }

  func testABigramCommitAimsOnePointLeftOfTheMatchCenter() {
    let frame = CGRect(x: 10, y: 20, width: 30, height: 10)
    XCTAssertEqual(
      BigramMatcher.clickPoint(in: frame),
      CGPoint(x: frame.midX - 1, y: frame.midY))
    let hint = AssignedHint(
      target: JumpTarget(id: "bigram-1-0", frame: frame, providerID: "bigram"),
      label: "a")
    XCTAssertEqual(
      AppDelegate.hintCommitPoint(for: hint, fontSize: 14),
      BigramMatcher.clickPoint(in: frame))
  }

  func testDefaultSClicksABigram() {
    let config = Config.default
    let key = NormalModeInterpreter.canonicalizeMappingKey("s")
    let mapping = config.mode.normal.first { $0.key == key }
    XCTAssertEqual(
      mapping?.action,
      .flashCommand(.mouseBigram(.click(.leftClick, modifiers: []))))
  }
}
