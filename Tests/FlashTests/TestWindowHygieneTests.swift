import AppKit
import XCTest

@testable import flash

final class TestWindowHygieneTests: XCTestCase {
  private func window(
    pid: Int32, number: Int, alpha: Double, bounds: CGRect, layer: Int = 3
  ) -> [String: Any] {
    [
      kCGWindowOwnerPID as String: pid,
      kCGWindowNumber as String: number,
      kCGWindowLayer as String: layer,
      kCGWindowAlpha as String: alpha,
      kCGWindowBounds as String: bounds.dictionaryRepresentation as NSDictionary,
    ]
  }

  /// The guard flags only this process's windows that are drawn over a
  /// display: transparent, foreign and off-screen windows cover nothing.
  func testOnlyOwnVisibleWindowsOverADisplayCountAsOccluding() {
    let display = CGRect(x: 0, y: 0, width: 2_048, height: 1_152)
    let list = [
      window(pid: 7, number: 1, alpha: 1, bounds: display),
      window(pid: 7, number: 2, alpha: 0, bounds: display),
      window(pid: 8, number: 3, alpha: 1, bounds: display),
      window(pid: 7, number: 4, alpha: 1, bounds: CGRect(x: -5_000, y: 0, width: 100, height: 100)),
      window(pid: 7, number: 5, alpha: 0.02, bounds: CGRect(x: 0, y: 0, width: 2_048, height: 30)),
    ]
    XCTAssertEqual(
      TestWindowHygiene.occludingWindows(owner: 7, in: list, displays: [display]).map(\.number),
      [1, 5])
  }

  /// A window a test orders in is on screen as the test expects, but fully
  /// transparent, so it never covers the user's focused app.
  func testWindowsOrderedInByTestsAreTransparent() {
    let panel = NSPanel(
      contentRect: CGRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless],
      backing: .buffered, defer: false)
    defer { panel.orderOut(nil) }
    panel.orderFrontRegardless()
    XCTAssertTrue(panel.isVisible)
    XCTAssertEqual(panel.alphaValue, 0)
    panel.orderOut(nil)
    panel.alphaValue = 1
    panel.makeKeyAndOrderFront(nil)
    XCTAssertTrue(panel.isVisible)
    XCTAssertEqual(panel.alphaValue, 0)
  }
}
