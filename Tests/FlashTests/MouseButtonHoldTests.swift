import CoreGraphics
import XCTest

@testable import flash

/// `mouse_button` and pointer mode's `v` share one held button, owned by
/// `ActionDispatcher`; every transition says which events to post.
final class MouseButtonHoldTests: XCTestCase {
  func testDownPressesOnceAndUpReleasesOnce() {
    var hold = MouseButtonHold()
    XCTAssertEqual(hold.apply(.down, .primary), [.press(.primary)])
    XCTAssertEqual(hold.held, .primary)
    XCTAssertEqual(hold.apply(.down, .primary), [], "already held")
    XCTAssertEqual(hold.apply(.up, .primary), [.release(.primary)])
    XCTAssertNil(hold.held)
    XCTAssertEqual(hold.apply(.up, .primary), [], "nothing held")
  }

  func testToggleAlternates() {
    var hold = MouseButtonHold()
    XCTAssertEqual(hold.apply(.toggle, .secondary), [.press(.secondary)])
    XCTAssertEqual(hold.apply(.toggle, .secondary), [.release(.secondary)])
    XCTAssertEqual(hold.apply(.toggle, .middle), [.press(.middle)])
    XCTAssertEqual(hold.held, .middle)
  }

  /// One button at a time: pressing another releases the first, and
  /// releasing a button that is not held leaves the held one alone.
  func testAnotherButtonReplacesTheHeldOne() {
    var hold = MouseButtonHold()
    _ = hold.apply(.down, .primary)
    XCTAssertEqual(hold.apply(.up, .secondary), [])
    XCTAssertEqual(hold.held, .primary)
    XCTAssertEqual(hold.apply(.down, .secondary), [.release(.primary), .press(.secondary)])
    XCTAssertEqual(hold.apply(.toggle, .primary), [.release(.secondary), .press(.primary)])
    XCTAssertEqual(hold.held, .primary)
  }

  /// Escape, leave_mode, quit and a committed gesture all release through
  /// `release()`, exactly once however many of them run.
  func testReleaseConsumesTheHoldExactlyOnce() {
    var hold = MouseButtonHold()
    XCTAssertEqual(hold.release(), [])
    _ = hold.apply(.down, .middle)
    XCTAssertEqual(hold.release(), [.release(.middle)])
    XCTAssertEqual(hold.release(), [])
    XCTAssertNil(hold.held)
  }

  func testEachButtonPostsItsOwnEventTypes() {
    XCTAssertEqual(MouseButtonKind.primary.cgButton, .left)
    XCTAssertEqual(MouseButtonKind.secondary.cgButton, .right)
    XCTAssertEqual(MouseButtonKind.middle.cgButton, .center)
    XCTAssertEqual(MouseButtonKind.primary.eventType(pressed: true), .leftMouseDown)
    XCTAssertEqual(MouseButtonKind.primary.eventType(pressed: false), .leftMouseUp)
    XCTAssertEqual(MouseButtonKind.secondary.eventType(pressed: true), .rightMouseDown)
    XCTAssertEqual(MouseButtonKind.secondary.eventType(pressed: false), .rightMouseUp)
    XCTAssertEqual(MouseButtonKind.middle.eventType(pressed: true), .otherMouseDown)
    XCTAssertEqual(MouseButtonKind.middle.eventType(pressed: false), .otherMouseUp)
    XCTAssertEqual(MouseButtonKind.primary.draggedEventType, .leftMouseDragged)
    XCTAssertEqual(MouseButtonKind.secondary.draggedEventType, .rightMouseDragged)
    XCTAssertEqual(MouseButtonKind.middle.draggedEventType, .otherMouseDragged)
  }

  /// A pointer move while a button is held is that button's drag, tagged
  /// like every synthesized event.
  func testHeldPointerMovesAreDraggedEvents() throws {
    let event = try XCTUnwrap(
      ActionDispatcher.pointerMoveEvent(
        to: CGPoint(x: 40, y: 30), from: CGPoint(x: 10, y: 10), holding: .secondary,
        source: nil))
    XCTAssertEqual(event.type, .rightMouseDragged)
    XCTAssertEqual(event.getIntegerValueField(.mouseEventDeltaX), 30)
    XCTAssertEqual(event.getIntegerValueField(.mouseEventDeltaY), 20)
    XCTAssertEqual(
      event.getIntegerValueField(.eventSourceUserData), ActionDispatcher.syntheticMouseEventTag)
    let free = try XCTUnwrap(
      ActionDispatcher.pointerMoveEvent(
        to: CGPoint(x: 40, y: 30), from: CGPoint(x: 10, y: 10), holding: nil, source: nil))
    XCTAssertEqual(free.type, .mouseMoved)
  }

  func testVerbParsesStateAndButton() {
    func parse(_ args: [String: String]) -> URLCommand? {
      URLEventHandler.parse(verb: "mouse_button", args: args)
    }
    XCTAssertEqual(parse(["state": "down"]), .mouseButton(.init(state: .down, button: .primary)))
    XCTAssertEqual(
      parse(["state": "up", "secondary": "1"]), .mouseButton(.init(state: .up, button: .secondary)))
    XCTAssertEqual(
      parse(["state": "toggle", "middle": "true"]),
      .mouseButton(.init(state: .toggle, button: .middle)))
    XCTAssertNil(parse([:]), "--state is required")
    XCTAssertNil(parse(["state": "press"]))
    XCTAssertNil(parse(["state": ""]))
    XCTAssertNil(parse(["state": "down", "secondary": "1", "middle": "1"]))
    XCTAssertNil(parse(["state": "down", "double": "1"]))
    XCTAssertEqual(
      parse(["state": "down", "secondary": "0"]),
      .mouseButton(.init(state: .down, button: .primary)))
  }

  func testVerbRoundTripsThroughMappingsAndDiagnostics() {
    let command = URLCommand.mouseButton(.init(state: .toggle, button: .secondary))
    XCTAssertEqual(command.diagnosticDescription, "flash mouse_button --state=toggle --secondary")
    XCTAssertEqual(
      URLCommand.mouseButton(.init(state: .down, button: .primary)).diagnosticDescription,
      "flash mouse_button --state=down")
    let config = ConfigLoader.parse(
      """
      [mode.normal.mappings]
      "zv" = ["flash", "mouse_button", "--state=toggle", "--secondary"]
      "zb" = ["flash", "mouse_button"]
      """)
    XCTAssertEqual(
      config.mode.normal.first { $0.key == NormalModeInterpreter.canonicalizeMappingKey("zv") }?
        .action.command, command)
    XCTAssertNil(
      config.mode.normal.first { $0.key == NormalModeInterpreter.canonicalizeMappingKey("zb") },
      "a bare mouse_button is rejected")
    XCTAssertEqual(config.warnings.count, 1)
    XCTAssertTrue(URLEventHandler.usageText.contains("flash mouse_button --state=<down|up|toggle>"))
  }
}
