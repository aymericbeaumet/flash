import CoreGraphics
import XCTest

@testable import FlashProviders

final class AXHintTargetSnapshotTests: XCTestCase {
  private var original: AXHintTargetSnapshot {
    AXHintTargetSnapshot(
      role: "AXLink", title: "Original article", url: "https://example.com/original",
      enabled: true, hidden: false, frame: CGRect(x: 100, y: 200, width: 160, height: 40))
  }

  func testScrollMovesTheSameCapturedControl() {
    var current = original
    current.frame.origin.y += 120
    XCTAssertEqual(
      original.resolvedClickPoint(preferred: CGPoint(x: 120, y: 210), current: current),
      CGPoint(x: 120, y: 330))
  }

  func testReusedControlWithChangedPropertiesCannotReceiveTheClick() {
    let changes: [(inout AXHintTargetSnapshot) -> Void] = [
      { $0.role = "AXButton" }, { $0.subrole = "AXTabButton" },
      { $0.title = "Replacement article" }, { $0.description = "Replacement" },
      { $0.value = "Changed value" }, { $0.url = "https://example.com/replacement" },
      { $0.enabled = false }, { $0.hidden = true }, { $0.frame = .zero },
    ]
    for change in changes {
      var current = original
      change(&current)
      XCTAssertNil(
        original.resolvedClickPoint(preferred: CGPoint(x: 120, y: 210), current: current))
    }
  }

  func testIntentionallyDisabledActionableRowsRemainResolvable() {
    var row = original
    row.role = "AXRow"
    row.enabled = false
    XCTAssertNotNil(row.resolvedClickPoint(preferred: CGPoint(x: 120, y: 210), current: row))
  }
}
