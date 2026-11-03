import AppKit
import XCTest

@testable import flash

/// Stepping a status-bar carousel by hand: the wheel arithmetic over a run,
/// the step it asks of the cycle, and the key that ties a drawn run to the
/// carousel it shows.
final class StatusBarCycleScrollTests: XCTestCase {
  /// Down is the next line and up the previous, as the system reports the
  /// scroll: the line moves the way a scroll view's content would, natural
  /// scrolling or not.
  func testTheSystemScrollDirectionPicksTheLine() {
    var scroll = StatusBarCycleScroll()
    XCTAssertEqual(scroll.advance(deltaY: -1, phase: .wheel, at: 10), 1)
    XCTAssertEqual(scroll.advance(deltaY: 3, phase: .wheel, at: 20), -1)
    XCTAssertEqual(scroll.advance(deltaY: 0, phase: .wheel, at: 30), 0)
  }

  /// A swipe is one step, however long it runs or fast it flicks, and the
  /// glide after it is nothing: one gesture, one line.
  func testASwipeStepsOnceAndItsGlideIsIgnored() {
    var scroll = StatusBarCycleScroll()
    let step = StatusBarCycleScroll.pointsPerStep
    XCTAssertEqual(scroll.advance(deltaY: -step / 2, phase: .began, at: 10), 0)
    XCTAssertEqual(scroll.advance(deltaY: -step / 2, phase: .changed, at: 10.016), 1)
    for frame in 2..<20 {
      XCTAssertEqual(
        scroll.advance(deltaY: -step * 3, phase: .changed, at: 10 + Double(frame) * 0.016), 0)
    }
    XCTAssertEqual(scroll.advance(deltaY: 0, phase: .ended, at: 10.4), 0)
    XCTAssertEqual(scroll.advance(deltaY: -step * 4, phase: .momentum, at: 10.6), 0)

    // The next swipe, once the line has landed, steps again; a short touch
    // that never reaches a step does nothing.
    XCTAssertEqual(scroll.advance(deltaY: step / 3, phase: .began, at: 11), 0)
    XCTAssertEqual(scroll.advance(deltaY: 0, phase: .ended, at: 11.1), 0)
    XCTAssertEqual(scroll.advance(deltaY: step, phase: .began, at: 12), -1)
  }

  /// A step never starts while the last one's push is still playing, so
  /// every change runs the whole animation; a quick wheel spin is one step.
  func testNoStepStartsWhileThePushIsStillPlaying() {
    var scroll = StatusBarCycleScroll()
    let settle = StatusBarCycleScroll.settleSeconds
    XCTAssertEqual(settle, NativeStatusBarSurface.cycleTransitionDuration)
    XCTAssertEqual(scroll.advance(deltaY: -1, phase: .wheel, at: 10), 1)
    for notch in 1..<6 {
      XCTAssertEqual(scroll.advance(deltaY: -1, phase: .wheel, at: 10 + Double(notch) * 0.05), 0)
    }
    XCTAssertEqual(scroll.advance(deltaY: -1, phase: .wheel, at: 10 + settle + 0.001), 1)

    // A swipe that reaches its step mid-push is spent, not deferred.
    let step = StatusBarCycleScroll.pointsPerStep
    XCTAssertEqual(scroll.advance(deltaY: -step, phase: .began, at: 10 + settle + 0.1), 0)
    XCTAssertEqual(scroll.advance(deltaY: -step, phase: .changed, at: 10 + settle * 3), 0)
  }

  /// A hand-picked line shows at once and keeps a full period, so the clock
  /// does not push the reader off the article a moment later.
  func testSteppingWrapsBothWaysAndRestartsTheDwell() {
    var cycle = FlashStatusBarCycleState(
      lines: ["one", "two", "three"], periodSeconds: 30, now: 100)
    XCTAssertEqual(cycle.visibleLine, "one")
    XCTAssertEqual(cycle.nextRotationAt, 130)

    XCTAssertTrue(cycle.step(by: 1, now: 110))
    XCTAssertEqual(cycle.visibleLine, "two")
    XCTAssertEqual(cycle.nextRotationAt, 140, "the dwell restarts from the step")

    XCTAssertTrue(cycle.step(by: -1, now: 115))
    XCTAssertEqual(cycle.visibleLine, "one")
    // Wrapping, in both directions.
    XCTAssertTrue(cycle.step(by: -1, now: 120))
    XCTAssertEqual(cycle.visibleLine, "three")
    XCTAssertTrue(cycle.step(by: 1, now: 125))
    XCTAssertEqual(cycle.visibleLine, "one")
    XCTAssertTrue(cycle.step(by: 4, now: 130))
    XCTAssertEqual(cycle.visibleLine, "two")

    XCTAssertFalse(cycle.step(by: 0, now: 135))
    var single = FlashStatusBarCycleState(lines: ["only"], periodSeconds: 30, now: 100)
    XCTAssertFalse(single.step(by: 1, now: 110), "nothing to rotate is no step")
  }

  /// A line reached by stepping back arrives from above; the clock's next
  /// rotation, and any step forward, arrive from below again.
  func testAStepBackArrivesFromAboveUntilTheNextForwardChange() {
    var cycle = FlashStatusBarCycleState(
      lines: ["one", "two", "three"], periodSeconds: 30, now: 100)
    XCTAssertFalse(cycle.arrivedBackward)
    cycle.step(by: -1, now: 110)
    XCTAssertTrue(cycle.arrivedBackward)
    cycle.refresh(lines: ["one", "two", "three"], periodSeconds: 30, now: 115)
    XCTAssertTrue(cycle.arrivedBackward, "a republish leaves the line as it arrived")
    XCTAssertTrue(cycle.advanceIfDue(now: 140))
    XCTAssertFalse(cycle.arrivedBackward)
    cycle.step(by: -1, now: 150)
    cycle.step(by: 1, now: 160)
    XCTAssertFalse(cycle.arrivedBackward)
  }

  /// After a refresh drops the visible line, down reveals the first new
  /// line, as the clock would, and up the last; a single new line waiting
  /// for its reveal shows at once.
  func testSteppingFromALineARefreshDroppedStartsAtTheNewEnds() {
    var cycle = FlashStatusBarCycleState(lines: ["old", "gone"], periodSeconds: 30, now: 100)
    cycle.refresh(lines: ["a", "b", "c"], periodSeconds: 30, now: 105)
    XCTAssertEqual(cycle.visibleLine, "old")
    var down = cycle
    XCTAssertTrue(down.step(by: 1, now: 110))
    XCTAssertEqual(down.visibleLine, "a")
    var up = cycle
    XCTAssertTrue(up.step(by: -1, now: 110))
    XCTAssertEqual(up.visibleLine, "c")

    cycle.refresh(lines: ["fresh"], periodSeconds: 30, now: 105)
    XCTAssertTrue(cycle.step(by: 1, now: 110))
    XCTAssertEqual(cycle.visibleLine, "fresh")
    XCTAssertFalse(cycle.step(by: 1, now: 111), "a lone line already showing has nowhere to go")
  }

  /// The marker carries which carousel a run shows, so a scroll over it
  /// names the one to step; a plain `#[cyc]` run is still carousel content.
  func testACarouselRunCarriesItsKey() {
    let key = StatusCycleKey.plugin("feed", segment: "label")
    XCTAssertEqual(key, "plugin:feed.label")
    XCTAssertEqual(StatusCycleKey.pluginSegment(key), "feed.label")
    XCTAssertNil(StatusCycleKey.sourceName(key))
    XCTAssertEqual(StatusCycleKey.sourceName(StatusCycleKey.source("news")), "news")
    XCTAssertNil(StatusCycleKey.pluginSegment("source:news"))

    let line = PluginStatusSegment.carouselLine(key: key, prefix: "NEWS ", line: "a headline")
    let segments = FlashStatusBarRenderer.segments(from: line)
    let carousel = segments.filter(\.cycle)
    XCTAssertEqual(carousel.map(\.text).joined(), "a headline")
    XCTAssertEqual(carousel.compactMap(\.cycleKey), [key])
    XCTAssertTrue(
      segments.filter { !$0.cycle }.allSatisfy { $0.cycleKey == nil },
      "the marker closes with the run")
  }

  /// A source is any TOML key: its case, and the commas, spaces and
  /// brackets the style marker splits on, survive the trip through the
  /// drawn run back to the source a scroll steps.
  func testASourceKeySurvivesTheMarkerWhateverItsName() {
    for name in ["News", "Daily News, EU]", "#{x}"] {
      let key = StatusCycleKey.source(name)
      let line = PluginStatusSegment.carouselLine(key: key, prefix: "", line: "headline")
      let carousel = FlashStatusBarRenderer.segments(from: line).filter(\.cycle)
      XCTAssertEqual(carousel.map(\.text).joined(), "headline", name)
      XCTAssertEqual(carousel.compactMap(\.cycleKey), [key], name)
      XCTAssertEqual(carousel.first?.cycleKey.flatMap(StatusCycleKey.sourceName), name)
    }
    XCTAssertTrue(
      FlashStatusBarRenderer.segments(from: "#[cyc=]x").allSatisfy { !$0.cycle },
      "a carousel marker without its key is malformed")
  }

  /// The line's direction rides on its marker, from the controller to every
  /// surface drawing it, and survives the document's own serialization.
  func testABackwardLineCarriesItsDirectionThroughTheMarker() throws {
    let key = StatusCycleKey.plugin("feed", segment: "label")
    let back = PluginStatusSegment.carouselLine(
      key: key, prefix: "", line: "older", backward: true)
    let run = try XCTUnwrap(FlashStatusBarRenderer.segments(from: back).first(where: \.cycle))
    XCTAssertTrue(run.cycleBackward)
    XCTAssertEqual(run.cycleKey, key)
    let forward = PluginStatusSegment.carouselLine(key: key, prefix: "", line: "newer")
    XCTAssertFalse(
      try XCTUnwrap(FlashStatusBarRenderer.segments(from: forward).first(where: \.cycle))
        .cycleBackward)

    let document = StatusFormatDocument.parse(back)
    let reparsed = StatusFormatDocument.parse(StatusFormatDocument.serialize(document.runs))
    XCTAssertEqual(reparsed.runs.first(where: \.cycle)?.cycleBackward, true)
    XCTAssertEqual(reparsed.runs.first(where: \.cycle)?.cycleKey, key)

    XCTAssertTrue(
      FlashStatusBarRenderer.segments(from: "#[cycback]x").allSatisfy { !$0.cycleBackward },
      "a direction outside a carousel is malformed")
    XCTAssertFalse(
      try XCTUnwrap(
        FlashStatusBarRenderer.segments(from: back + "#[cyc=\(key)]x").last
      ).cycleBackward, "a new carousel marker starts forward")
  }

  /// The click windows carry the carousel spans a scroll hits. A carousel
  /// that appears, or whose line changes width, without moving a link or a
  /// popup still reaches them.
  func testTheClickWindowsFollowTheCarouselSpans() throws {
    let panel = OverlayPanel()
    defer { panel.hideStatusBarClickWindows() }
    let band = CGRect(x: 0, y: 900, width: 800, height: 24)
    panel.syncStatusBarClickWindows(bandRects: [band], links: [])
    let view = try XCTUnwrap(panel.statusBarClickWindows.first?.clickView)
    XCTAssertEqual(view.cycles, [])

    let key = StatusCycleKey.plugin("feed", segment: "label")
    panel.syncStatusBarClickWindows(
      bandRects: [band], links: [],
      cycles: [.init(rect: CGRect(x: 100, y: 900, width: 200, height: 24), key: key)])
    XCTAssertEqual(
      view.cycles, [.init(rect: CGRect(x: 100, y: 0, width: 200, height: 24), key: key)])

    panel.syncStatusBarClickWindows(
      bandRects: [band], links: [],
      cycles: [.init(rect: CGRect(x: 100, y: 900, width: 260, height: 24), key: key)])
    XCTAssertEqual(view.cycles.map(\.rect.width), [260])
  }
}
