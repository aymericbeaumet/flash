import XCTest

@testable import flash

/// Trackpad gestures Flash emulates, following macOS's default trackpad
/// gestures, and the events that carry the ones AppKit receives as gestures.
final class TrackpadGestureTests: XCTestCase {
  func testFingersAndMotionsFollowTheMacOSTrackpad() {
    func action(_ fingers: Int, _ motion: TrackpadGesture.Motion) -> TrackpadGesture.Action? {
      TrackpadGesture.action(fingers: fingers, motion: motion)
    }
    XCTAssertEqual(action(2, .tap), .secondaryClick)
    XCTAssertEqual(action(2, .doubleTap), .smartZoom)
    XCTAssertEqual(action(2, .spread), .zoom(in: true))
    XCTAssertEqual(action(2, .pinch), .zoom(in: false))
    XCTAssertEqual(action(2, .rotateLeft), .rotate(counterclockwise: true))
    XCTAssertEqual(action(2, .swipeRight), .historyBack, "content follows the fingers")
    XCTAssertEqual(action(2, .swipeLeft), .historyForward)
    XCTAssertEqual(action(3, .tap), .lookUp)
    XCTAssertEqual(action(3, .swipeUp), .missionControl)
    XCTAssertEqual(action(3, .swipeDown), .appExpose)
    XCTAssertEqual(action(3, .swipeLeft), .spaceRight, "the Space to the right slides in")
    XCTAssertEqual(action(3, .swipeRight), .spaceLeft)
    XCTAssertEqual(action(4, .swipeUp), .missionControl)
    XCTAssertEqual(action(4, .pinch), .launchpad)
    XCTAssertEqual(action(4, .spread), .showDesktop)
    XCTAssertEqual(action(5, .pinch), .launchpad)
    XCTAssertEqual(action(5, .spread), .showDesktop)
    XCTAssertNil(action(1, .tap), "one finger is a plain click: mouse_target")
    XCTAssertNil(action(5, .tap))
    XCTAssertNil(action(3, .pinch))
  }

  /// A pinch is a began, a few changes summing to the amount, and an end,
  /// on the zoom gesture type; AppKit delivers them to `magnify(with:)`.
  func testAPinchIsOneMagnifyGesture() {
    let events = TrackpadGesture.events(for: .magnify(0.6), steps: 3)
    XCTAssertEqual(events.map(\.hidType), [8, 8, 8, 8, 8])
    XCTAssertEqual(events.map(\.phase), [1, 2, 2, 2, 4])
    XCTAssertEqual(events.compactMap(\.magnification).reduce(0, +), 0.6, accuracy: 1e-9)
    XCTAssertEqual(events.first?.delayMs, 0)
    XCTAssertTrue(zip(events, events.dropFirst()).allSatisfy { $0.delayMs < $1.delayMs })
  }

  func testRotateSmartZoomAndSwipeUseTheirGestureTypes() {
    let rotate = TrackpadGesture.events(for: .rotate(15), steps: 2)
    XCTAssertEqual(rotate.map(\.hidType), [5, 5, 5, 5])
    XCTAssertEqual(rotate.compactMap(\.rotation).reduce(0, +), 15, accuracy: 1e-9)
    XCTAssertEqual(TrackpadGesture.events(for: .smartMagnify).map(\.hidType), [22])
    let swipe = TrackpadGesture.events(for: .swipe(.left))
    XCTAssertEqual(swipe.map(\.hidType), [16, 16])
    XCTAssertEqual(swipe.map(\.phase), [1, 4])
    XCTAssertEqual(swipe.compactMap(\.swipeDirection), [4, 4])
  }

  func testTheVerbParsesFingersAndMotion() {
    func parse(_ args: [String: String]) -> URLCommand? {
      URLEventHandler.parse(verb: "gesture", args: args)
    }
    XCTAssertEqual(
      parse(["fingers": "4", "motion": "spread"]), .trackpadGesture(fingers: 4, motion: .spread))
    XCTAssertNil(parse(["fingers": "3", "motion": "pinch"]), "no such trackpad gesture")
    XCTAssertNil(parse(["fingers": "6", "motion": "tap"]))
    XCTAssertNil(parse(["motion": "tap"]))
    XCTAssertEqual(
      URLCommand.trackpadGesture(fingers: 2, motion: .doubleTap).diagnosticDescription,
      "flash gesture --fingers=2 --motion=double_tap")
  }

  func testACountBeforeAMouseFinisherIsAFingerCount() {
    let click = MouseCommand.click(.leftClick, modifiers: [])
    XCTAssertEqual(click.withFingers(1), click)
    XCTAssertEqual(click.withFingers(2), .click(.rightClick, modifiers: []))
    XCTAssertEqual(click.withFingers(3), .gesture(.lookUp))
    XCTAssertEqual(click.withFingers(4), click, "no four-finger tap on a target")
    XCTAssertEqual(
      MouseCommand.click(.doubleClick, modifiers: []).withFingers(2), .gesture(.smartZoom))
    XCTAssertEqual(
      MouseCommand.click(.leftClick, modifiers: [.command]).withFingers(2),
      .click(.rightClick, modifiers: [.command]))
    XCTAssertEqual(MouseCommand.move.withFingers(2), .move)
    XCTAssertEqual(MouseCommand.drag(modifiers: []).withFingers(3), .drag(modifiers: []))
  }

  func testTheMouseVerbsTakeATargetGesture() {
    XCTAssertEqual(
      URLEventHandler.parse(verb: "mouse_target", args: ["gesture": "look_up"]),
      .mouseTarget(.gesture(.lookUp)))
    XCTAssertEqual(
      URLEventHandler.parse(verb: "mouse_bigram", args: ["gesture": "smart_zoom"]),
      .mouseBigram(.gesture(.smartZoom)))
    XCTAssertEqual(
      URLEventHandler.parse(verb: "mouse_grid", args: ["gesture": "look_up"]),
      .mouseGrid(.init(.gesture(.lookUp))))
    XCTAssertNil(URLEventHandler.parse(verb: "mouse_target", args: ["gesture": "pinch"]))
    XCTAssertNil(
      URLEventHandler.parse(verb: "mouse_target", args: ["gesture": "look_up", "move": ""]))
    XCTAssertNil(
      URLEventHandler.parse(verb: "mouse_target", args: ["gesture": "look_up", "secondary": ""]))
    XCTAssertNil(
      URLEventHandler.parse(
        verb: "mouse_target", args: ["gesture": "look_up", "scope": "screen"]))
    XCTAssertEqual(
      URLCommand.mouseTarget(.gesture(.smartZoom)).diagnosticDescription,
      "flash mouse_target --gesture=smart_zoom")
  }
}
