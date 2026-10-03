import CoreGraphics
import FlashCore
import XCTest

@testable import flash

final class ActionDispatcherTests: XCTestCase {
  func testCurrentContextHintIsPlainAcrossTargets() {
    for role in ["AXLink", "AXButton", "AXTextField", "AXTab", "tmux-pane"] {
      let modifiers = ActionDispatcher.hintClickModifiers(
        for: target(role: role), requested: [])

      XCTAssertEqual(modifiers, [], "\(role) should receive a plain click")
    }
  }

  func testNewContextHintCarriesCommandAndShiftAcrossTargets() {
    for role in ["AXLink", "AXButton", "AXTextField", "AXTab", "tmux-pane"] {
      let modifiers = ActionDispatcher.hintClickModifiers(
        for: target(role: role), requested: [.command, .shift])

      XCTAssertEqual(
        modifiers, [.command, .shift], "\(role) should receive the new-context gesture")
    }
  }

  func testEveryRequestedModifierIsPreservedAcrossTargets() {
    for role in ["AXLink", "AXButton", "AXTextField", "AXTab", "tmux-pane"] {
      let modifiers = ActionDispatcher.hintClickModifiers(
        for: target(role: role), requested: .all)

      XCTAssertEqual(modifiers, .all, "\(role) should preserve requested modifiers")
    }
  }

  func testCurrentContextTerminalLinkHintAddsShift() {
    let modifiers = ActionDispatcher.hintClickModifiers(
      for: target(role: JumpTarget.terminalLinkRole),
      requested: [])

    XCTAssertEqual(modifiers, [.shift])
  }

  func testNewContextTerminalLinkHintCarriesCommandAndShift() {
    let modifiers = ActionDispatcher.hintClickModifiers(
      for: target(role: JumpTarget.terminalLinkRole),
      requested: [.command, .shift])

    XCTAssertEqual(modifiers, [.command, .shift])
  }

  func testTerminalLinkClickPrimesHoverWithShiftBeforeButtonEvents() throws {
    let point = CGPoint(x: 240, y: 360)
    let events = try XCTUnwrap(
      ActionDispatcher.clickEvents(
        at: point, from: CGPoint(x: 100, y: 200), action: .leftClick,
        modifiers: ActionDispatcher.hintClickModifiers(
          for: target(role: JumpTarget.terminalLinkRole), requested: []),
        source: CGEventSource(stateID: .privateState)))

    XCTAssertEqual(events.map(\.type), [.mouseMoved, .leftMouseDown, .leftMouseUp])
    for event in events {
      XCTAssertEqual(event.flags, .maskShift)
      XCTAssertEqual(event.location, point)
      XCTAssertEqual(
        event.getIntegerValueField(.eventSourceUserData), ActionDispatcher.syntheticMouseEventTag)
    }
    XCTAssertEqual(events.first?.getIntegerValueField(.mouseEventDeltaX), 140)
    XCTAssertEqual(events.first?.getIntegerValueField(.mouseEventDeltaY), 160)
  }

  func testStationaryClickStillPrimesHoverBeforeButtonEvents() throws {
    let point = CGPoint(x: 240, y: 360)
    let events = try XCTUnwrap(
      ActionDispatcher.clickEvents(
        at: point, from: point, action: .leftClick, modifiers: .shift,
        source: CGEventSource(stateID: .privateState)))

    XCTAssertEqual(events.map(\.type), [.mouseMoved, .leftMouseDown, .leftMouseUp])
    XCTAssertEqual(events.first?.flags, .maskShift)
    XCTAssertEqual(events.first?.getIntegerValueField(.mouseEventDeltaX), 0)
    XCTAssertEqual(events.first?.getIntegerValueField(.mouseEventDeltaY), 0)
  }

  func testNewContextDoubleClickUsesOneModifiedHoverAndTaggedMousePairs() throws {
    let events = try XCTUnwrap(
      ActionDispatcher.clickEvents(
        at: CGPoint(x: 240, y: 360), from: .zero, action: .doubleClick,
        modifiers: ActionDispatcher.hintClickModifiers(
          for: target(role: "AXLink"), requested: [.command, .shift]),
        source: CGEventSource(stateID: .privateState)))

    XCTAssertEqual(
      events.map(\.type),
      [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp])
    XCTAssertEqual(
      events.dropFirst().map { $0.getIntegerValueField(.mouseEventClickState) }, [1, 1, 2, 2])
    for event in events {
      XCTAssertEqual(event.flags, [.maskCommand, .maskShift])
      XCTAssertEqual(
        event.getIntegerValueField(.eventSourceUserData), ActionDispatcher.syntheticMouseEventTag)
    }
  }

  /// `[hints] restore_pointer`: committed gestures leave the pointer where a
  /// hardware click would unless the option asks for it back; a grid that
  /// moved the pointer (cursor-follow) returns it to where the grid started.
  func testCommittedGesturesRestoreThePointerOnlyWhenAsked() {
    XCTAssertEqual(
      ActionDispatcher.PointerRestore.afterCommit(restorePointer: false, gridOrigin: nil), .stay)
    XCTAssertEqual(
      ActionDispatcher.PointerRestore.afterCommit(
        restorePointer: false, gridOrigin: CGPoint(x: 5, y: 6)),
      .stay)
    XCTAssertEqual(
      ActionDispatcher.PointerRestore.afterCommit(restorePointer: true, gridOrigin: nil),
      .gestureStart)
    XCTAssertEqual(
      ActionDispatcher.PointerRestore.afterCommit(
        restorePointer: true, gridOrigin: CGPoint(x: 5, y: 6)),
      .point(CGPoint(x: 5, y: 6)))
  }

  func testRestoreDestinationIsInEventSpace() {
    let start = CGPoint(x: 120, y: 80)
    XCTAssertNil(ActionDispatcher.restoreDestination(.stay, gestureStart: start, screenH: 900))
    XCTAssertEqual(
      ActionDispatcher.restoreDestination(.gestureStart, gestureStart: start, screenH: 900), start)
    // A grid origin is an NSScreen point (bottom-left origin).
    XCTAssertEqual(
      ActionDispatcher.restoreDestination(
        .point(CGPoint(x: 300, y: 700)), gestureStart: start, screenH: 900),
      CGPoint(x: 300, y: 200))
  }

  func testRestoringThePointerPostsATaggedMoveSoHoverFollows() throws {
    let event = try XCTUnwrap(
      ActionDispatcher.pointerMoveEvent(
        to: CGPoint(x: 100, y: 200), from: CGPoint(x: 240, y: 360),
        source: CGEventSource(stateID: .privateState)))
    XCTAssertEqual(event.type, .mouseMoved)
    XCTAssertEqual(event.location, CGPoint(x: 100, y: 200))
    XCTAssertEqual(event.getIntegerValueField(.mouseEventDeltaX), -140)
    XCTAssertEqual(event.getIntegerValueField(.mouseEventDeltaY), -160)
    XCTAssertEqual(
      event.getIntegerValueField(.eventSourceUserData), ActionDispatcher.syntheticMouseEventTag)
  }

  private func target(role: String) -> JumpTarget {
    JumpTarget(
      id: "target",
      frame: CGRect(x: 10, y: 20, width: 30, height: 40),
      role: role,
      pid: 42,
      providerID: "test")
  }
}
