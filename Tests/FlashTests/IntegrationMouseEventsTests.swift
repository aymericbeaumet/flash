import CoreGraphics
import FlashIntegrationTestSupport
import XCTest

final class IntegrationMouseEventsTests: XCTestCase {
  func testPlainOracleClicksIgnoreHeldKeyboardModifiers() throws {
    for type: CGEventType in [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp] {
      let point = CGPoint(x: -120, y: 350)
      let event = try XCTUnwrap(
        CGEvent(
          mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left))
      event.flags = [.maskCommand, .maskControl, .maskShift, .maskAlternate]
      let prepared = IntegrationMouseEvents.prepare(event)
      XCTAssertTrue(prepared.flags.isEmpty, "\(type) must be an unmodified fixture click")
      XCTAssertEqual(prepared.location, point)
      XCTAssertEqual(prepared.type, type)
      XCTAssertEqual(prepared.getIntegerValueField(.mouseEventClickState), 1)
    }
  }

  func testMenuBarRevealReachesTheScreenEdgeExactly() {
    let primary = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let point = IntegrationMouseEvents.menuBarRevealPoint(
      itemFrame: CGRect(x: 1400, y: 1120, width: 120, height: 24), screenFrame: primary)
    XCTAssertEqual(point, CGPoint(x: 1460, y: 1117))
    XCTAssertEqual(primary.height - point.y, 0, "Quartz y=1 is still below the reveal edge")
    let above = CGRect(x: -1280, y: 1117, width: 1280, height: 800)
    let clamped = IntegrationMouseEvents.menuBarRevealPoint(
      itemFrame: CGRect(x: 1000, y: 1920, width: 120, height: 24), screenFrame: above)
    XCTAssertEqual(clamped, CGPoint(x: -1, y: 1917))
  }

  func testRevealMovementCarriesTheDestinationAndActualDelta() throws {
    let event = try XCTUnwrap(
      IntegrationMouseEvents.movement(
        to: CGPoint(x: -120, y: 1), from: CGPoint(x: -90, y: 200), source: nil))
    XCTAssertEqual(event.type, .mouseMoved)
    XCTAssertEqual(event.location, CGPoint(x: -120, y: 1))
    XCTAssertEqual(event.getIntegerValueField(.mouseEventDeltaX), -30)
    XCTAssertEqual(event.getIntegerValueField(.mouseEventDeltaY), -199)
    XCTAssertTrue(event.flags.isEmpty)
  }

  func testMultipleClicksKeepTheirExplicitClickCount() throws {
    let event = try XCTUnwrap(
      CGEvent(
        mouseEventSource: nil, mouseType: .leftMouseDown,
        mouseCursorPosition: .zero, mouseButton: .left))
    event.flags = [.maskCommand]
    for count in 1...3 {
      let prepared = IntegrationMouseEvents.prepare(event, clickCount: count)
      XCTAssertEqual(prepared.getIntegerValueField(.mouseEventClickState), Int64(count))
      XCTAssertTrue(prepared.flags.isEmpty)
    }
  }
}
