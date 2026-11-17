import AppKit
import XCTest

@testable import flash

/// A snapshot's configuration-only parts are built once per configuration
/// and never outlive it.
final class InspectorConfigSnapshotTests: XCTestCase {
  func testASnapshotFollowsEachNewConfiguration() throws {
    _ = NSApplication.shared
    let delegate = AppDelegate()
    delegate.overlay = OverlayPanel()
    delegate.overlay.statusPopupController = StatusPopupController(
      terminals: delegate.overlay.statusTerminals, windowActionsEnabled: false)
    defer { delegate.overlay.statusTerminals.shutdown() }
    func overlayFontSize() throws -> Double? {
      let config = try XCTUnwrap(delegate.debugStateJSON()["config"] as? [String: Any])
      return (config["overlay"] as? [String: Any])?["font_size"] as? Double
    }
    func mapsZ() throws -> Bool {
      let mappings = try XCTUnwrap(delegate.debugStateJSON()["mappings"] as? [String: Any])
      let rows = try XCTUnwrap(mappings["rows"] as? [[String: String]])
      return rows.contains { $0["scope"] == "normal" && $0["key"] == "z" }
    }
    delegate.config = ConfigLoader.parse("[overlay]\nfont_size = 20\n")
    XCTAssertEqual(try overlayFontSize(), 20)
    XCTAssertTrue(delegate.inspectorConfigCache != nil, "kept for the next snapshot")
    XCTAssertEqual(try overlayFontSize(), 20)
    XCTAssertFalse(try mapsZ())
    delegate.config = ConfigLoader.parse(
      "[overlay]\nfont_size = 30\n[mode.normal.mappings]\n\"z\" = [\"flash\", \"tab\", \"next\"]\n")
    XCTAssertNil(delegate.inspectorConfigCache, "a new configuration drops it")
    XCTAssertEqual(try overlayFontSize(), 30)
    XCTAssertTrue(try mapsZ())
  }
}
