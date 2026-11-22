import AppKit
import FlashCore
import XCTest

@testable import flash

final class PluginSpatialContextTests: XCTestCase {
  private let displays: [AppContext.Display] = [
    .init(frame: CGRect(x: -1000, y: 0, width: 1000, height: 800), scale: 1),
    .init(frame: CGRect(x: 0, y: 0, width: 1000, height: 800), scale: 2),
  ]

  private func context(_ frame: CGRect, displays: [AppContext.Display]? = nil) -> AppContext {
    AppContext(
      bundleIdentifier: "org.alacritty", processID: 123,
      runningApp: NSRunningApplication.current, frontWindowFrame: frame,
      allScreensFrame: CGRect(x: -1000, y: 0, width: 2000, height: 800),
      displays: displays ?? self.displays)
  }

  func testSpatialRequestsUseTheWindowDisplayRatherThanThePrimaryDisplay() {
    let window = CGRect(x: -100, y: 20, width: 800, height: 400)
    let captured = context(window)
    XCTAssertEqual(captured.displayScale, 2)
    let payload = PluginWireCodec.spatialContextJSON(captured)
    XCTAssertEqual(payload["display_scale"] as? Double, 2)
    XCTAssertEqual(
      payload["front_window_frame"] as? [String: CGFloat],
      ["x": -100, "y": 20, "width": 800, "height": 400])
    XCTAssertNil(PluginWireCodec.contextJSON(captured)["display_scale"])
    XCTAssertEqual(context(window.offsetBy(dx: -800, dy: 0)).displayScale, 1)
  }

  func testAmbiguousOrUnavailableDisplayGeometryDoesNotClaimAnExactScale() {
    let window = CGRect(x: -100, y: 20, width: 200, height: 400)
    XCTAssertNil(context(window).displayScale)
    XCTAssertNil(PluginWireCodec.spatialContextJSON(context(window))["display_scale"])
    XCTAssertNil(context(window, displays: []).displayScale)
    XCTAssertNil(context(window.offsetBy(dx: 3000, dy: 0)).displayScale)
    XCTAssertNil(context(.null).displayScale)
    XCTAssertNil(context(.infinite).displayScale)
    for scale in [CGFloat.zero, -1, .infinity, .nan] {
      XCTAssertNil(context(window, displays: [.init(frame: window, scale: scale)]).displayScale)
    }
    XCTAssertEqual(
      context(
        window,
        displays: [
          .init(frame: CGRect(x: -1000, y: 0, width: 1000, height: 800), scale: 2),
          .init(frame: CGRect(x: 0, y: 0, width: 1000, height: 800), scale: 2),
        ]
      ).displayScale, 2)
  }
}
