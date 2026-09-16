import CoreGraphics
import XCTest

@testable import flash

final class HintWindowSnapshotTests: XCTestCase {
  func testMovedWindowKeepsItsIdentityAndUsesPrimaryHeight() throws {
    let original = try XCTUnwrap(
      HintWindowSnapshot.resolve(
        [window(8, x: 40, y: 200)], pid: 42, primaryHeight: 900))
    let moved = try XCTUnwrap(
      HintWindowSnapshot.resolve(
        [window(8, x: -300, y: 300)], pid: 42, primaryHeight: 900))
    XCTAssertEqual(original.number, moved.number)
    XCTAssertEqual(original.frame, CGRect(x: 40, y: 400, width: 600, height: 300))
    XCTAssertEqual(moved.frame, CGRect(x: -300, y: 300, width: 600, height: 300))
  }

  func testReplacementWindowAtIdenticalCoordinatesHasADifferentIdentity() throws {
    let original = try XCTUnwrap(
      HintWindowSnapshot.resolve(
        [window(8)], pid: 42, primaryHeight: 900))
    let replacement = try XCTUnwrap(
      HintWindowSnapshot.resolve(
        [window(9), window(8)], pid: 42, primaryHeight: 900))
    XCTAssertEqual(original.frame, replacement.frame)
    XCTAssertNotEqual(original.number, replacement.number)
    XCTAssertNil(HintWindowSnapshot.resolve([], pid: 42, primaryHeight: 900))
  }

  private func window(_ number: CGWindowID, x: CGFloat = 40, y: CGFloat = 200) -> [String: Any] {
    [
      kCGWindowNumber as String: number, kCGWindowOwnerPID as String: pid_t(42),
      kCGWindowLayer as String: 0,
      kCGWindowBounds as String: CGRect(x: x, y: y, width: 600, height: 300)
        .dictionaryRepresentation,
    ]
  }

  func testCapturedStatusWindowFollowsItsIDWhenSiblingItemsReorder() throws {
    let selected = try XCTUnwrap(
      HintWindowSnapshot.resolve(
        [window(9, x: 100), window(8, x: 250)], pid: 42, primaryHeight: 900, windowNumber: 8))
    XCTAssertEqual(selected.number, 8)
    XCTAssertEqual(selected.frame.minX, 250)
    XCTAssertNil(
      HintWindowSnapshot.resolve(
        [window(9, x: 250)], pid: 42, primaryHeight: 900, windowNumber: 8))
    XCTAssertNil(
      HintWindowSnapshot.resolve(
        [window(8, x: 250)], pid: 99, primaryHeight: 900, windowNumber: 8))
  }
}
