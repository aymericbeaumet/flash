import CoreGraphics
import XCTest

@testable import flash

/// `mouse_button` and pointer mode's `v` share one held button, owned by
/// `ActionDispatcher`; every transition says which events to post.
final class MouseButtonHoldTests: XCTestCase {
  func testDownPressesOnceAndUpReleasesOnce() {
    var hold = MouseButtonHold()
    XCTAssertEqual(hold.apply(.down, .primary, for: .hold, at: .zero), [.press(.primary)])
    XCTAssertEqual(hold.held?.button, .primary)
    XCTAssertEqual(hold.apply(.down, .primary, for: .hold, at: .zero), [], "already held")
    XCTAssertEqual(hold.apply(.up, .primary, for: .hold, at: .zero), [.release(.primary)])
    XCTAssertNil(hold.held)
    XCTAssertEqual(hold.apply(.up, .primary, for: .hold, at: .zero), [], "nothing held")
  }

  func testToggleAlternates() {
    var hold = MouseButtonHold()
    XCTAssertEqual(hold.apply(.toggle, .secondary, for: .hold, at: .zero), [.press(.secondary)])
    XCTAssertEqual(hold.apply(.toggle, .secondary, for: .hold, at: .zero), [.release(.secondary)])
    XCTAssertEqual(hold.apply(.toggle, .middle, for: .hold, at: .zero), [.press(.middle)])
    XCTAssertEqual(hold.held?.button, .middle)
  }

  /// One button at a time: pressing another releases the first, and
  /// releasing a button that is not held leaves the held one alone.
  func testAnotherButtonReplacesTheHeldOne() {
    var hold = MouseButtonHold()
    _ = hold.apply(.down, .primary, for: .hold, at: .zero)
    XCTAssertEqual(hold.apply(.up, .secondary, for: .hold, at: .zero), [])
    XCTAssertEqual(hold.held?.button, .primary)
    XCTAssertEqual(
      hold.apply(.down, .secondary, for: .hold, at: .zero),
      [.release(.primary), .press(.secondary)])
    XCTAssertEqual(
      hold.apply(.toggle, .primary, for: .hold, at: .zero),
      [.release(.secondary), .press(.primary)])
    XCTAssertEqual(hold.held?.button, .primary)
  }

  /// Escape, leave_mode, quit and a committed gesture all release through
  /// `release()`, exactly once however many of them run.
  func testReleaseConsumesTheHoldExactlyOnce() {
    var hold = MouseButtonHold()
    XCTAssertEqual(hold.release(), [])
    _ = hold.apply(.down, .middle, for: .hold, at: .zero)
    XCTAssertEqual(hold.release(), [.release(.middle)])
    XCTAssertEqual(hold.release(), [])
    XCTAssertNil(hold.held)
  }

  /// The hold remembers its purpose and
  /// where it went down, so a cancelled drag can be put back.
  func testTheHoldRecordsItsPurposeAndWhereItWentDown() {
    var hold = MouseButtonHold()
    let origin = CGPoint(x: 120, y: 340)
    XCTAssertEqual(hold.apply(.down, .primary, for: .hold, at: origin), [.press(.primary)])
    XCTAssertEqual(hold.held, .init(button: .primary, purpose: .hold, origin: origin))
    XCTAssertEqual(
      hold.apply(.toggle, .secondary, for: .hold, at: .zero),
      [.release(.primary), .press(.secondary)])
    XCTAssertEqual(hold.held?.purpose, .hold)
    XCTAssertEqual(hold.held?.origin, .zero)
    XCTAssertEqual(hold.apply(.cancel, .secondary, for: .hold, at: .zero), [.release(.secondary)])
    XCTAssertNil(hold.held)
    XCTAssertEqual(hold.apply(.cancel, .primary, for: .hold, at: .zero), [], "nothing to cancel")
  }

  func testVerbParsesTheModeAndCancel() {
    func parse(_ args: [String: String]) -> URLCommand? {
      URLEventHandler.parse(verb: "mouse_button", args: args)
    }
    XCTAssertNil(parse(["state": "toggle", "mode": "visual"]))
    XCTAssertEqual(
      parse(["state": "toggle", "secondary": "1", "mode": "hold"]),
      .mouseButton(.init(state: .toggle, button: .secondary, hold: .hold)))
    XCTAssertEqual(
      parse(["state": "cancel"]), .mouseButton(.init(state: .cancel, button: .primary, hold: .hold))
    )
    XCTAssertNil(parse(["state": "toggle", "mode": "select"]))
    // `enter_hold_mode` is the drag toggle by name.
    XCTAssertEqual(
      URLEventHandler.parse(verb: "enter_hold_mode", args: [:]), .holdMode(.primary))
    XCTAssertEqual(
      URLEventHandler.parse(verb: "enter_hold_mode", args: ["secondary": "1"]),
      .holdMode(.secondary))
    XCTAssertNil(
      URLEventHandler.parse(verb: "enter_hold_mode", args: ["secondary": "1", "middle": "1"]))
    XCTAssertEqual(
      URLCommand.holdMode(.middle).diagnosticDescription, "flash enter_hold_mode --middle")
    XCTAssertEqual(
      URLCommand.mouseButton(.init(state: .toggle, button: .primary, hold: .hold))
        .diagnosticDescription,
      "flash mouse_button --state=toggle --mode=hold")
  }

  func testHoldVerbReplacesDragVerb() {
    XCTAssertEqual(
      URLEventHandler.parse(verb: "enter_hold_mode", args: [:]), .holdMode(.primary))
    XCTAssertNil(URLEventHandler.parse(verb: "enter_drag_mode", args: [:]))
    XCTAssertEqual(
      URLEventHandler.parse(verb: "mouse_button", args: ["state": "toggle", "mode": "hold"]),
      .mouseButton(.init(state: .toggle, button: .primary, hold: .hold)))
    XCTAssertNil(
      URLEventHandler.parse(verb: "mouse_button", args: ["state": "toggle", "mode": "drag"]))
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
    XCTAssertEqual(
      parse(["state": "down"]), .mouseButton(.init(state: .down, button: .primary, hold: .hold)))
    XCTAssertEqual(
      parse(["state": "up", "secondary": "1"]),
      .mouseButton(.init(state: .up, button: .secondary, hold: .hold)))
    XCTAssertEqual(
      parse(["state": "toggle", "middle": "true"]),
      .mouseButton(.init(state: .toggle, button: .middle, hold: .hold)))
    XCTAssertNil(parse([:]), "--state is required")
    XCTAssertNil(parse(["state": "press"]))
    XCTAssertNil(parse(["state": ""]))
    XCTAssertNil(parse(["state": "down", "secondary": "1", "middle": "1"]))
    XCTAssertNil(parse(["state": "down", "double": "1"]))
    XCTAssertEqual(
      parse(["state": "down", "secondary": "0"]),
      .mouseButton(.init(state: .down, button: .primary, hold: .hold)))
  }

  func testVerbRoundTripsThroughMappingsAndDiagnostics() {
    let command = URLCommand.mouseButton(.init(state: .toggle, button: .secondary, hold: .hold))
    XCTAssertEqual(
      command.diagnosticDescription, "flash mouse_button --state=toggle --secondary --mode=hold")
    XCTAssertEqual(
      URLCommand.mouseButton(.init(state: .down, button: .primary, hold: .hold))
        .diagnosticDescription,
      "flash mouse_button --state=down --mode=hold")
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
    XCTAssertTrue(
      URLEventHandler.usageText.contains(
        "flash mouse_button --state=<down|up|toggle|release|cancel>"))
  }
}
