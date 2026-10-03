import CoreGraphics
import XCTest

@testable import flash

final class WindowAutomationTests: XCTestCase {
  func testDirectionalFocusPrefersAlignedWindowOverCloserDiagonal() {
    let windows = [
      WindowFocusCandidate(id: 1, frame: CGRect(x: 500, y: 400, width: 200, height: 200)),
      WindowFocusCandidate(id: 2, frame: CGRect(x: 260, y: 420, width: 180, height: 160)),
      WindowFocusCandidate(id: 3, frame: CGRect(x: 450, y: 150, width: 100, height: 100)),
    ]
    XCTAssertEqual(WindowFocusPlanner.nearest(.left, from: 1, in: windows), 2)
    XCTAssertEqual(WindowFocusPlanner.nearest(.down, from: 1, in: windows), 3)
  }

  func testDirectionalFocusRejectsSameWindowAndWrongSide() {
    let windows = [
      WindowFocusCandidate(id: 1, frame: CGRect(x: 500, y: 400, width: 200, height: 200)),
      WindowFocusCandidate(id: 2, frame: CGRect(x: 800, y: 400, width: 200, height: 200)),
    ]
    XCTAssertNil(WindowFocusPlanner.nearest(.left, from: 1, in: windows))
    XCTAssertEqual(WindowFocusPlanner.nearest(.right, from: 1, in: windows), 2)
  }

  func testWindowRuleMatchesExactBundleAndOptionalTitle() {
    let all = WindowPlacementRule(
      bundleID: "com.example.Editor", titleContains: nil,
      move: MoveWindowParams(layout: .position(.leftHalf), screen: 0))
    let titled = WindowPlacementRule(
      bundleID: "com.example.Editor", titleContains: "notes",
      move: MoveWindowParams(layout: .position(.rightHalf), screen: 0))
    XCTAssertTrue(all.matches(bundleID: "com.example.Editor", title: "Anything"))
    XCTAssertFalse(all.matches(bundleID: "com.example.Other", title: "Anything"))
    XCTAssertTrue(titled.matches(bundleID: "com.example.Editor", title: "Meeting Notes"))
    XCTAssertFalse(titled.matches(bundleID: "com.example.Editor", title: "Inbox"))
  }

  func testDirectionalVerbRequiresValidDirection() {
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "window_focus", "--direction=left"])?.command,
      .focusWindow(.left))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "window_focus"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "window_focus", "--direction=diagonal"]))
  }
}
