import CoreGraphics
import FlashCore
import XCTest

final class CapturedHintTargetTests: XCTestCase {
  func testVanishedTargetCannotFallBackToTheOldScreenLocation() {
    let target = JumpTarget(
      id: "original", frame: CGRect(x: 10, y: 20, width: 100, height: 40),
      resolveClickPoint: { _ in nil }, providerID: "test")

    XCTAssertNil(target.resolvedClickPoint(preferred: CGPoint(x: 25, y: 30)))
  }

  func testCoordinateOnlyTargetsKeepTheSelectedPoint() {
    let target = JumpTarget(
      id: "coordinate", frame: CGRect(x: 10, y: 20, width: 100, height: 40),
      providerID: "test")
    let selected = CGPoint(x: 25, y: 30)

    XCTAssertEqual(target.resolvedClickPoint(preferred: selected), selected)
  }

  func testMovedTargetPreservesSelectedPositionWithinIt() {
    let original = target(frame: CGRect(x: 10, y: 20, width: 100, height: 40))
    let moved = target(frame: CGRect(x: 210, y: 120, width: 200, height: 80))

    XCTAssertEqual(
      original.matchingClickPoint(preferred: CGPoint(x: 35, y: 30), among: [moved]),
      CGPoint(x: 260, y: 140))
  }

  func testReusedIDDoesNotSelectAReplacementLink() {
    let original = target()
    let replacement = target(label: "Next article", url: "https://example.com/next")

    XCTAssertNil(original.matchingClickPoint(preferred: .zero, among: [replacement]))
    XCTAssertNil(original.matchingClickPoint(preferred: .zero, among: []))
  }

  func testRepeatedLinkTextResolvesToTheCopyAtTheCapturedPosition() {
    // A terminal pane showing `../../scripts/toggle_sleep.sh` on three lines:
    // every copy shares label, URL, and role, so only position tells them apart.
    let original = target(frame: CGRect(x: 10, y: 200, width: 100, height: 20))
    let above = target(id: "l0", frame: CGRect(x: 10, y: 260, width: 100, height: 20))
    let redrawn = target(id: "l1", frame: CGRect(x: 10, y: 201, width: 100, height: 20))
    let below = target(id: "l2", frame: CGRect(x: 10, y: 140, width: 100, height: 20))

    XCTAssertEqual(
      original.matchingClickPoint(
        preferred: CGPoint(x: 35, y: 210), among: [above, redrawn, below]),
      CGPoint(x: 35, y: 211))
  }

  func testEquidistantDuplicatesStayAmbiguous() {
    let original = target(frame: CGRect(x: 10, y: 200, width: 100, height: 20))
    let above = target(id: "l0", frame: CGRect(x: 10, y: 240, width: 100, height: 20))
    let below = target(id: "l1", frame: CGRect(x: 10, y: 160, width: 100, height: 20))

    XCTAssertNil(original.matchingClickPoint(preferred: .zero, among: [above, below]))
  }

  func testChangedURLCancelsEvenWhenTheLinkLabelIsUnchanged() {
    XCTAssertNil(
      target().matchingClickPoint(
        preferred: .zero, among: [target(url: "https://example.com/replacement")]))
  }

  func testTargetWithoutSemanticPropertiesCannotBeRecoveredByItsOrdinal() {
    let unknown = JumpTarget(
      id: "1", frame: .init(x: 0, y: 0, width: 20, height: 20), providerID: "plugin")
    XCTAssertNil(unknown.matchingClickPoint(preferred: .zero, among: [unknown]))
  }

  func testInvalidGeometryCannotProduceAClick() {
    let original = target()
    for frame in [
      CGRect.zero, .null, .infinite, CGRect(x: 0, y: 0, width: CGFloat.nan, height: 20),
    ] {
      XCTAssertNil(original.matchingClickPoint(preferred: .zero, among: [target(frame: frame)]))
    }
  }

  private func target(
    id: String = "ordinal-1", label: String = "Original article",
    url: String = "https://example.com/original",
    frame: CGRect = CGRect(x: 10, y: 20, width: 100, height: 40)
  ) -> JumpTarget {
    JumpTarget(
      id: id, frame: frame, role: "AXLink", accessibilityLabel: label, url: url, pid: 42,
      providerID: "plugin")
  }
}
