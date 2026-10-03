import CoreGraphics
import XCTest

@testable import flash

/// `[mode] scroll_smooth_ms`: one vertical line scroll becomes several
/// smaller line events spread over the duration.
final class SmoothScrollTests: XCTestCase {
  func testZeroDurationOrASingleLineScrollsAtOnce() {
    XCTAssertEqual(SmoothScroll.steps(lines: -20, durationMs: 0), [.init(delayMs: 0, lines: -20)])
    XCTAssertEqual(SmoothScroll.steps(lines: 1, durationMs: 200), [.init(delayMs: 0, lines: 1)])
    XCTAssertEqual(SmoothScroll.steps(lines: -1, durationMs: 200), [.init(delayMs: 0, lines: -1)])
    XCTAssertEqual(SmoothScroll.steps(lines: 0, durationMs: 200), [.init(delayMs: 0, lines: 0)])
  }

  func testStepsKeepTheTotalAndDirectionAndStartAtOnce() {
    for lines: Int32 in [2, 3, 7, 20, 1000, -3, -20, -999] {
      for duration in [1, 16, 40, 120, 300] {
        let steps = SmoothScroll.steps(lines: lines, durationMs: duration)
        XCTAssertEqual(steps.map(\.lines).reduce(0, +), lines, "\(lines) over \(duration)ms")
        XCTAssertEqual(steps.first?.delayMs, 0, "the first lines move on the keypress")
        XCTAssertTrue(steps.allSatisfy { $0.lines != 0 && ($0.lines > 0) == (lines > 0) })
        XCTAssertEqual(steps.map(\.delayMs), steps.map(\.delayMs).sorted())
        XCTAssertTrue(steps.allSatisfy { $0.delayMs < max(duration, 1) })
        XCTAssertGreaterThan(steps.count, 1)
        XCTAssertLessThanOrEqual(steps.count, Int(lines.magnitude))
      }
    }
  }

  func testStepsAreAtLeastAFrameApartAndFrontLoaded() {
    let steps = SmoothScroll.steps(lines: -20, durationMs: 200)
    XCTAssertEqual(steps.count, 12)
    XCTAssertEqual(steps.map(\.lines), [-2, -2, -2, -2, -2, -2, -2, -2, -1, -1, -1, -1])
    XCTAssertEqual(steps.map(\.delayMs), [0, 16, 33, 50, 66, 83, 100, 116, 133, 150, 166, 183])
    XCTAssertEqual(
      SmoothScroll.steps(lines: 3, durationMs: 120),
      [.init(delayMs: 0, lines: 1), .init(delayMs: 40, lines: 1), .init(delayMs: 80, lines: 1)])
  }

  func testDurationIsCappedAtTheConfigMaximum() {
    XCTAssertEqual(
      SmoothScroll.steps(lines: 1000, durationMs: 5_000),
      SmoothScroll.steps(lines: 1000, durationMs: SmoothScroll.maxDurationMs))
  }

  func testConfigParsesValidatesAndResolves() throws {
    XCTAssertEqual(Config().mode.scrollSmoothMs, 0, "off by default")
    let config = ConfigLoader.parse("[mode]\nscroll_smooth_ms = 120")
    XCTAssertEqual(config.diagnostics, [])
    XCTAssertEqual(config.mode.scrollSmoothMs, 120)
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(config.resolvedConfigJSON.utf8)) as? [String: Any])
    let mode = try XCTUnwrap(json["mode"] as? [String: Any])
    XCTAssertEqual(mode["scroll_smooth_ms"] as? Int, 120)
    for invalid in ["-1", "301", "1.5", "\"120\"", "true"] {
      let rejected = ConfigLoader.parse("[mode]\nscroll_smooth_ms = \(invalid)")
      XCTAssertEqual(rejected.diagnostics.count, 1, invalid)
      XCTAssertTrue(
        rejected.diagnostics[0].message.contains("mode.scroll_smooth_ms"), invalid)
      XCTAssertEqual(rejected.mode.scrollSmoothMs, 0, invalid)
    }
    XCTAssertEqual(ConfigLoader.parse("[mode]\nscroll_smooth_ms = 300").diagnostics, [])
  }

  /// Every step is a line event, so a terminal scrolls the same distance.
  func testSmoothScrollPostsLineEventsThatAddUpToTheStep() throws {
    let restore = NormalModeDispatcher.wheelEventPoster
    defer {
      NormalModeDispatcher.wheelEventPoster = restore
      FlashTunables.apply(.default)
    }
    FlashTunables.scrollSmoothMs = 60
    let posted = WheelLog()
    let done = expectation(description: "three line events")
    done.expectedFulfillmentCount = 3
    NormalModeDispatcher.wheelEventPoster = { event in
      posted.append(event)
      done.fulfill()
    }
    XCTAssertTrue(NormalModeDispatcher.scroll(.down, pid: -1, bundleID: "org.alacritty"))
    wait(for: [done], timeout: 2)
    XCTAssertEqual(posted.lines, [-1, -1, -1])
    XCTAssertEqual(posted.continuous, [0, 0, 0])
  }

  /// A new scroll takes over: what the previous one had left is dropped.
  func testANewScrollCancelsTheRemainderOfThePreviousOne() throws {
    let restore = NormalModeDispatcher.wheelEventPoster
    defer {
      NormalModeDispatcher.wheelEventPoster = restore
      FlashTunables.apply(.default)
    }
    FlashTunables.scrollSmoothMs = 200
    let posted = WheelLog()
    NormalModeDispatcher.wheelEventPoster = { posted.append($0) }
    XCTAssertTrue(NormalModeDispatcher.scroll(.halfPageDown, pid: -1, bundleID: "org.alacritty"))
    XCTAssertTrue(NormalModeDispatcher.scroll(.up, pid: -1, bundleID: "org.alacritty"))
    let settled = expectation(description: "both schedules elapsed")
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(450)) { settled.fulfill() }
    wait(for: [settled], timeout: 2)
    XCTAssertEqual(posted.lines, [-2, 1, 1, 1], "only the first step of ctrl-d went out")
  }

  /// `gg` / `G` in a terminal stay one bounded line event, and still cancel
  /// a smooth scroll in progress so they land on the edge.
  func testTerminalEdgesStayInstantAndCancelASmoothScroll() throws {
    let restore = NormalModeDispatcher.wheelEventPoster
    defer {
      NormalModeDispatcher.wheelEventPoster = restore
      FlashTunables.apply(.default)
    }
    FlashTunables.scrollSmoothMs = 200
    let posted = WheelLog()
    NormalModeDispatcher.wheelEventPoster = { posted.append($0) }
    XCTAssertTrue(NormalModeDispatcher.scroll(.halfPageDown, pid: -1, bundleID: "org.alacritty"))
    XCTAssertTrue(NormalModeDispatcher.scroll(.top, pid: -1, bundleID: "org.alacritty"))
    let settled = expectation(description: "schedule elapsed")
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(350)) { settled.fulfill() }
    wait(for: [settled], timeout: 2)
    XCTAssertEqual(posted.lines, [-2, Int64(NormalModeDispatcher.edgeScrollLines)])
  }
}

/// Wheel events posted from the click queue, read on the test thread.
private final class WheelLog: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [CGEvent] = []

  func append(_ event: CGEvent) {
    lock.lock()
    events.append(event)
    lock.unlock()
  }

  private var snapshot: [CGEvent] {
    lock.lock()
    defer { lock.unlock() }
    return events
  }

  var lines: [Int64] { snapshot.map { $0.getIntegerValueField(.scrollWheelEventDeltaAxis1) } }
  var continuous: [Int64] {
    snapshot.map { $0.getIntegerValueField(.scrollWheelEventIsContinuous) }
  }
}
