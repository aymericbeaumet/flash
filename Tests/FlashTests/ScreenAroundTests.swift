import XCTest

@testable import flash

/// Where a surface opened for what the user looks at is centred: the display
/// around that point, else the primary, else any.
final class ScreenAroundTests: XCTestCase {
  func testTheDisplayAroundAPointElseThePrimary() {
    let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let external = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
    let snapshot = OverlayPanel.ScreenSnapshot(
      screens: [
        (scale: 2, frame: external, visibleFrame: external, notch: nil),
        (scale: 2, frame: primary, visibleFrame: primary, notch: nil),
      ],
      unionFrame: primary.union(external), mainFrame: primary, mainScale: 2,
      mainVisibleFrame: primary, nativeStatusBarFallbackHeight: 24)
    XCTAssertEqual(snapshot.screen(around: CGPoint(x: 2000, y: 500))?.frame, external)
    XCTAssertEqual(snapshot.screen(around: CGPoint(x: 100, y: 100))?.frame, primary)
    XCTAssertEqual(
      snapshot.screen(around: CGPoint(x: -500, y: 0))?.frame, primary, "off every display")
    XCTAssertEqual(snapshot.screen(around: nil)?.frame, primary, "no focused window")
    var unknownPrimary = snapshot
    unknownPrimary.mainFrame = nil
    XCTAssertEqual(unknownPrimary.screen(around: nil)?.frame, external, "any display at all")
  }
}
