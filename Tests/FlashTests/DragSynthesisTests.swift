import FlashCore
import XCTest

@testable import flash

final class DragSynthesisTests: XCTestCase {
  func testDragWaypointsEndExactlyOnDestination() {
    let from = CGPoint(x: 100, y: 100)
    let to = CGPoint(x: 900, y: 500)
    let waypoints = ActionDispatcher.dragWaypoints(from: from, to: to)
    XCTAssertEqual(waypoints.last, to)
    XCTAssertFalse(waypoints.contains(from))
  }

  func testDragWaypointsScaleWithDistanceWithinBounds() {
    // Short drags still produce a movement stream apps can recognise…
    let short = ActionDispatcher.dragWaypoints(
      from: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 0))
    XCTAssertEqual(short.count, 2)
    // …and long ones are clamped so the gesture stays brief.
    let long = ActionDispatcher.dragWaypoints(
      from: CGPoint(x: 0, y: 0), to: CGPoint(x: 4000, y: 3000))
    XCTAssertEqual(long.count, 16)
    // Mid-length drags land ~one waypoint per 40pt.
    let mid = ActionDispatcher.dragWaypoints(
      from: CGPoint(x: 0, y: 0), to: CGPoint(x: 400, y: 0))
    XCTAssertEqual(mid.count, 10)
  }

  func testDragWaypointsProgressMonotonically() {
    let from = CGPoint(x: 50, y: 400)
    let to = CGPoint(x: 650, y: 40)
    let waypoints = ActionDispatcher.dragWaypoints(from: from, to: to)
    var previousDistance: CGFloat = 0
    for point in waypoints {
      let dx = point.x - from.x
      let dy = point.y - from.y
      let distance = (dx * dx + dy * dy).squareRoot()
      XCTAssertGreaterThan(distance, previousDistance)
      previousDistance = distance
    }
  }

  func testDragMouseCommandArgTokensRoundTrip() {
    XCTAssertEqual(MouseCommand.drag(modifiers: []).argTokens, ["--drag"])
    XCTAssertEqual(
      MouseCommand.drag(modifiers: .option).argTokens, ["--drag", "--modifiers=alt"])
    XCTAssertEqual(MouseCommand.select(modifiers: []).argTokens, ["--select"])
    XCTAssertEqual(
      MouseCommand.multi(.rightClick, modifiers: []).argTokens, ["--multi", "--secondary"])
    XCTAssertEqual(
      MouseCommand.adjust(.doubleClick, modifiers: []).argTokens, ["--adjust", "--double"])
  }

  func testAdjustmentInterpreterKeymap() {
    func cmd(_ keyCode: UInt16, _ chars: String? = nil) -> HintAdjustmentCommand? {
      HintAdjustmentInterpreter.command(keyCode: keyCode, charactersIgnoringModifiers: chars)
    }
    XCTAssertEqual(cmd(53), .cancel)
    XCTAssertEqual(cmd(36), .commit)
    XCTAssertEqual(cmd(49), .commit)
    XCTAssertEqual(cmd(123), .snapLeft)
    XCTAssertEqual(cmd(126), .snapTop)
    XCTAssertEqual(cmd(4, "h"), .snapLeft)
    XCTAssertEqual(cmd(37, "l"), .snapRight)
    XCTAssertEqual(cmd(40, "k"), .snapTop)
    XCTAssertEqual(cmd(38, "j"), .snapBottom)
    XCTAssertEqual(cmd(29, "0"), .reset)
    XCTAssertEqual(cmd(22, "6"), .interpolate(6))
    XCTAssertNil(cmd(0, "a"))
  }

  func testPointerModeInterpreterKeymap() {
    func cmd(
      _ keyCode: UInt16, _ chars: String? = nil,
      flags: NSEvent.ModifierFlags = []
    ) -> PointerModeCommand? {
      PointerModeInterpreter.command(
        keyCode: keyCode, charactersIgnoringModifiers: chars, modifierFlags: flags)
    }
    XCTAssertEqual(cmd(53), .exit)
    XCTAssertEqual(cmd(12, "q"), .exit)
    XCTAssertEqual(cmd(36), .commitClick)
    XCTAssertEqual(cmd(49), .commitClick)
    XCTAssertEqual(cmd(4, "h"), .move(dx: -1, dy: 0, fine: false))
    XCTAssertEqual(cmd(38, "j"), .move(dx: 0, dy: -1, fine: false))
    XCTAssertEqual(cmd(40, "k"), .move(dx: 0, dy: 1, fine: false))
    XCTAssertEqual(cmd(37, "l", flags: .shift), .move(dx: 1, dy: 0, fine: true))
    XCTAssertEqual(cmd(126), .move(dx: 0, dy: 1, fine: false))
    XCTAssertEqual(cmd(46, "m"), .clickLeft)
    XCTAssertEqual(cmd(43, ","), .clickMiddle)
    XCTAssertEqual(cmd(47, "."), .clickRight)
    XCTAssertEqual(cmd(9, "v"), .toggleDrag)
    XCTAssertNil(cmd(0, "a"))
  }

  func testPointerModeStepAcceleratesAndClamps() {
    XCTAssertEqual(PointerModeInterpreter.step(streak: 0, fine: false), 12)
    XCTAssertEqual(PointerModeInterpreter.step(streak: 3, fine: false), 30)
    XCTAssertEqual(PointerModeInterpreter.step(streak: 100, fine: false), 90)
    XCTAssertEqual(PointerModeInterpreter.step(streak: 100, fine: true), 2)
    XCTAssertEqual(PointerModeInterpreter.nextStreak(previous: 4, sinceLastMoveMs: 80), 5)
    XCTAssertEqual(PointerModeInterpreter.nextStreak(previous: 4, sinceLastMoveMs: 500), 0)
    XCTAssertEqual(PointerModeInterpreter.nextStreak(previous: 4, sinceLastMoveMs: nil), 0)
  }

  func testSearchInterpreterKeymapAndFilter() {
    func cmd(
      _ keyCode: UInt16, _ chars: String? = nil,
      flags: NSEvent.ModifierFlags = []
    ) -> HintSearchCommand? {
      HintSearchInterpreter.command(
        keyCode: keyCode, charactersIgnoringModifiers: chars, modifierFlags: flags)
    }
    XCTAssertEqual(cmd(53), .cancel)
    XCTAssertEqual(cmd(36), .commit)
    XCTAssertEqual(cmd(48), .cycle)
    XCTAssertEqual(cmd(51), .backspace)
    XCTAssertEqual(cmd(0, "a"), .append("a"))
    XCTAssertEqual(cmd(49, " "), .append(" "))
    // Modified chords are swallowed, not appended.
    XCTAssertNil(cmd(0, "a", flags: .command))

    func hint(_ label: String, url: String? = nil) -> AssignedHint {
      AssignedHint(
        target: JumpTarget(
          id: label, frame: CGRect(x: 0, y: 0, width: 10, height: 10), role: "AXButton",
          accessibilityLabel: label, url: url, providerID: "test"),
        label: "a")
    }
    let hints = [hint("Submit form"), hint("Cancel"), hint("Send by mail")]
    XCTAssertEqual(
      HintSearchInterpreter.filter(hints, query: "sub").map(\.target.id), ["Submit form"])
    // Substring beats subsequence when both exist.
    XCTAssertEqual(
      HintSearchInterpreter.filter(hints, query: "can").map(\.target.id), ["Cancel"])
    // Subsequence fallback: "sbm" has no substring match but matches Submit.
    XCTAssertEqual(
      HintSearchInterpreter.filter(hints, query: "sbm").map(\.target.id),
      ["Submit form", "Send by mail"])
    // Empty query keeps everything.
    XCTAssertEqual(HintSearchInterpreter.filter(hints, query: "").count, 3)
    XCTAssertTrue(HintSearchInterpreter.filter(hints, query: "zzz").isEmpty)
  }

  func testMultiSurfaceVisibleRegionsCoverEachPidsFrontSurface() {
    // Front-to-back: pid 2's window partially covers pid 1's; pid 3 is fully
    // hidden behind pid 1. Multi-surface regions must expose pid 1 minus the
    // overlap, pid 2 whole, and pid 3 not at all.
    let entries = [
      WindowSnapshot.Entry(pid: 2, layer: 0, nsBounds: CGRect(x: 0, y: 0, width: 50, height: 100)),
      WindowSnapshot.Entry(
        pid: 1, layer: 0, nsBounds: CGRect(x: 0, y: 0, width: 100, height: 100)),
      WindowSnapshot.Entry(
        pid: 3, layer: 0, nsBounds: CGRect(x: 10, y: 10, width: 20, height: 20)),
    ]
    let regions = WindowSnapshot.buildMultiSurfaceVisibleRegions(
      entries: entries, focusedPids: [1, 2, 3])
    XCTAssertEqual(regions[2], [CGRect(x: 0, y: 0, width: 50, height: 100)])
    XCTAssertEqual(regions[1], [CGRect(x: 50, y: 0, width: 50, height: 100)])
    XCTAssertNil(regions[3])
    // The single-pid build agrees on the focused surface.
    let single = WindowSnapshot.build(entries: entries, focusedPid: 1)
    XCTAssertEqual(single.visibleRegions[1], regions[1])
  }

  func testAdjustmentApplySnapsClampsAndInterpolates() {
    let frame = CGRect(x: 100, y: 200, width: 200, height: 50)
    let center = CGPoint(x: 200, y: 225)
    XCTAssertEqual(
      HintAdjustmentInterpreter.apply(.snapLeft, to: center, in: frame),
      CGPoint(x: 102, y: 225))
    XCTAssertEqual(
      HintAdjustmentInterpreter.apply(.snapRight, to: center, in: frame),
      CGPoint(x: 298, y: 225))
    // NSScreen coordinates: top is maxY.
    XCTAssertEqual(
      HintAdjustmentInterpreter.apply(.snapTop, to: center, in: frame),
      CGPoint(x: 200, y: 248))
    XCTAssertEqual(
      HintAdjustmentInterpreter.apply(.snapBottom, to: center, in: frame),
      CGPoint(x: 200, y: 202))
    XCTAssertEqual(
      HintAdjustmentInterpreter.apply(.interpolate(3), to: center, in: frame),
      CGPoint(x: 160, y: 225))
    XCTAssertEqual(
      HintAdjustmentInterpreter.apply(.reset, to: CGPoint(x: 298, y: 248), in: frame),
      center)
    // A point outside the frame is clamped back in.
    XCTAssertEqual(
      HintAdjustmentInterpreter.apply(.snapLeft, to: CGPoint(x: 0, y: 0), in: frame),
      CGPoint(x: 102, y: 200))
    // Degenerate frames don't cross their own edges.
    let thin = CGRect(x: 10, y: 10, width: 2, height: 2)
    let snapped = HintAdjustmentInterpreter.apply(.snapLeft, to: .zero, in: thin)
    XCTAssertGreaterThanOrEqual(snapped.x, thin.minX)
    XCTAssertLessThanOrEqual(snapped.x, thin.maxX)
  }
}
