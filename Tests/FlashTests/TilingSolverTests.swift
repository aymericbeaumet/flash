import CoreGraphics
import XCTest

@testable import flash

/// Frames from trees, in NSScreen coordinates (y up).
final class TilingSolverTests: XCTestCase {
  private let usable = CGRect(x: 0, y: 0, width: 1000, height: 600)

  private func tree(_ windows: String..., orientation: TilingOrientation = .horizontal)
    -> TilingTree<String>
  {
    var tree = TilingTree<String>(orientation: orientation)
    for window in windows { tree.insert(window) }
    return tree
  }

  func testTilesSplitTheAreaEvenlyWithGaps() {
    let frames = TilingSolver.frames(
      tree("a", "b"), in: usable, gaps: TilingGaps(inner: 10, outer: 20))
    XCTAssertEqual(frames["a"], CGRect(x: 20, y: 20, width: 475, height: 560))
    XCTAssertEqual(frames["b"], CGRect(x: 505, y: 20, width: 475, height: 560))
  }

  func testAVerticalContainerPutsItsFirstChildOnTop() {
    let frames = TilingSolver.frames(tree("a", "b", orientation: .vertical), in: usable)
    XCTAssertEqual(frames["a"], CGRect(x: 0, y: 300, width: 1000, height: 300))
    XCTAssertEqual(frames["b"], CGRect(x: 0, y: 0, width: 1000, height: 300))
  }

  func testNestedContainersSplitTheirShare() {
    var nested = tree("a", "b", "c")
    nested.join("c", .left)
    let frames = TilingSolver.frames(nested, in: usable)
    XCTAssertEqual(frames["a"], CGRect(x: 0, y: 0, width: 500, height: 600))
    XCTAssertEqual(frames["b"], CGRect(x: 500, y: 300, width: 500, height: 300))
    XCTAssertEqual(frames["c"], CGRect(x: 500, y: 0, width: 500, height: 300))
  }

  /// Where a hand drag lands: the tile under the drop point, never the
  /// dragged window's own tile, a gap, or an accordion sibling it already
  /// shares its area with.
  func testADropLandsOnTheTileUnderThePoint() {
    let tiles = tree("a", "b", "c")
    let frames = TilingSolver.frames(tiles, in: usable, gaps: TilingGaps(inner: 10, outer: 0))
    XCTAssertEqual(
      TilingSolver.dropTarget(for: "a", at: CGPoint(x: 800, y: 300), in: tiles, frames: frames),
      "c")
    XCTAssertNil(
      TilingSolver.dropTarget(for: "a", at: CGPoint(x: 100, y: 300), in: tiles, frames: frames),
      "its own tile")
    XCTAssertNil(
      TilingSolver.dropTarget(for: "a", at: CGPoint(x: 333, y: 300), in: tiles, frames: frames),
      "the gap between a and b")
    XCTAssertNil(
      TilingSolver.dropTarget(for: "a", at: CGPoint(x: 1200, y: 300), in: tiles, frames: frames),
      "off the tiles")
    var nested = tree("a", "b", "c")
    nested.join("c", .left)
    nested.setLayout(.accordion, around: "c")
    let stacked = TilingSolver.frames(nested, in: usable, accordionPadding: 30)
    XCTAssertNil(
      TilingSolver.dropTarget(for: "b", at: CGPoint(x: 750, y: 100), in: nested, frames: stacked),
      "b and c share the accordion's area already")
    XCTAssertEqual(
      TilingSolver.dropTarget(for: "a", at: CGPoint(x: 750, y: 20), in: nested, frames: stacked),
      "c", "the smallest tile under the point when accordion tiles overlap")
  }

  func testWeightsSizeTheTilesAndEdgesMeetExactly() {
    var weighted = tree("a", "b", "c")
    weighted.resize("a", along: .horizontal, by: 1.0 / 6)
    let frames = TilingSolver.frames(weighted, in: usable)
    XCTAssertEqual(frames["a"]?.width, 500)
    XCTAssertEqual(frames["a"]!.maxX, frames["b"]!.minX)
    XCTAssertEqual(frames["b"]!.maxX, frames["c"]!.minX)
    XCTAssertEqual(frames["c"]!.maxX, usable.maxX, "the last tile ends at the edge")
  }

  func testAnAccordionInsetsEachWindowOnTheSidesWithSiblings() {
    var accordion = tree("a", "b", "c")
    accordion.setLayout(.accordion, around: "a")
    let frames = TilingSolver.frames(accordion, in: usable, accordionPadding: 30)
    XCTAssertEqual(frames["a"], CGRect(x: 0, y: 0, width: 970, height: 600))
    XCTAssertEqual(frames["b"], CGRect(x: 30, y: 0, width: 940, height: 600))
    XCTAssertEqual(frames["c"], CGRect(x: 30, y: 0, width: 970, height: 600))
    let single = TilingSolver.frames(tree("a"), in: usable)
    XCTAssertEqual(single["a"], usable, "one window fills the area")
  }

  func testSolvingTwiceGivesTheSameFrames() {
    var nested = tree("a", "b", "c", "d")
    nested.join("d", .left)
    nested.resize("a", along: .horizontal, by: 0.137)
    let area = CGRect(x: 13.4, y: 7.7, width: 1511.3, height: 941.9)
    XCTAssertEqual(
      TilingSolver.frames(nested, in: area, gaps: TilingGaps(inner: 7, outer: 9)),
      TilingSolver.frames(nested, in: area, gaps: TilingGaps(inner: 7, outer: 9)))
    for frame in TilingSolver.frames(nested, in: area).values {
      XCTAssertEqual(frame, frame.integral, "whole points: re-applying moves nothing")
    }
  }
}

/// Emulated workspaces over displays.
final class TilingWorkspacesTests: XCTestCase {
  private let main = TilingDisplay(identity: "MAIN", isMain: true, isWide: true)
  private let side = TilingDisplay(identity: "SIDE", isMain: false, isWide: false)

  func testEachDisplayShowsAWorkspaceAndNewWindowsJoinTheFocusedOne() {
    var spaces = TilingWorkspaces<String>(persistent: ["1", "2", "3"])
    spaces.setDisplays([main, side])
    XCTAssertEqual(spaces.visible, ["MAIN": "1", "SIDE": "2"])
    XCTAssertEqual(spaces.focused, "1")
    spaces.add("a")
    spaces.add("b", display: "SIDE")
    XCTAssertEqual(spaces.workspace(of: "a"), "1")
    XCTAssertEqual(spaces.workspace(of: "b"), "2")
    XCTAssertEqual(
      spaces.workspaces["2"]?.tree.layout(around: nil).orientation, .vertical,
      "a tall display lays out top to bottom")
  }

  func testSwitchingHidesTheOldWorkspaceAndBackAndForthReturns() {
    var spaces = TilingWorkspaces<String>(persistent: ["1", "2", "3"])
    spaces.setDisplays([main])
    spaces.add("a")
    spaces.switchTo("3")
    XCTAssertEqual(spaces.visible["MAIN"], "3")
    XCTAssertEqual(spaces.hiddenWindows, ["a"])
    spaces.add("b")
    XCTAssertEqual(spaces.workspace(of: "b"), "3")
    spaces.backAndForth()
    XCTAssertEqual(spaces.focused, "1")
    XCTAssertEqual(spaces.hiddenWindows, ["b"])
    spaces.switchTo("scratch")
    XCTAssertEqual(spaces.listed, ["1", "2", "3", "scratch"], "created on demand")
    spaces.switchTo("1")
    XCTAssertEqual(spaces.listed, ["1", "2", "3"], "an empty hidden workspace is dropped")
  }

  func testMovingAWindowToAHiddenWorkspaceParksIt() {
    var spaces = TilingWorkspaces<String>(persistent: ["1", "2"])
    spaces.setDisplays([main])
    spaces.add("a")
    spaces.add("b")
    spaces.move("b", to: "2")
    XCTAssertEqual(spaces.workspace(of: "b"), "2")
    XCTAssertEqual(spaces.hiddenWindows, ["b"])
    XCTAssertEqual(spaces.workspaces["1"]?.tree.windows, ["a"])
  }

  func testAPinnedWorkspaceShowsOnlyOnItsDisplay() {
    var spaces = TilingWorkspaces<String>(persistent: ["1", "2", "9"], pinned: ["9": .secondary])
    spaces.setDisplays([main, side])
    XCTAssertEqual(spaces.visible, ["MAIN": "1", "SIDE": "9"])
    spaces.switchTo("2")
    XCTAssertEqual(spaces.visible, ["MAIN": "2", "SIDE": "9"])
    spaces.switchTo("9")
    XCTAssertEqual(spaces.focusedDisplay, "SIDE", "focus moves to where it shows")
  }

  func testAWorkspaceReturnsToItsDisplayWhenItIsPluggedBackIn() {
    var spaces = TilingWorkspaces<String>(persistent: ["1", "2"])
    spaces.setDisplays([main, side])
    spaces.add("a", display: "SIDE")
    spaces.setDisplays([main])
    XCTAssertEqual(spaces.visible, ["MAIN": "1"])
    XCTAssertEqual(spaces.hiddenWindows, ["a"], "the unplugged display's workspace hides")
    spaces.setDisplays([main, side])
    XCTAssertEqual(spaces.visible["SIDE"], "2", "back on its display")
    XCTAssertEqual(spaces.hiddenWindows, [])
  }

  func testCyclingSkipsWorkspacesOtherDisplaysShow() {
    var spaces = TilingWorkspaces<String>(persistent: ["1", "2", "3"])
    spaces.setDisplays([main, side])
    spaces.cycle(1)
    XCTAssertEqual(spaces.visible["MAIN"], "3", "2 shows on the side display")
    spaces.cycle(1)
    XCTAssertEqual(spaces.visible["MAIN"], "1")
    spaces.cycle(-1)
    XCTAssertEqual(spaces.visible["MAIN"], "3")
  }

  func testMovingTheFocusedWorkspaceToAnotherDisplay() {
    var spaces = TilingWorkspaces<String>(persistent: ["1", "2", "3"])
    spaces.setDisplays([main, side])
    spaces.add("a")
    spaces.moveFocusedWorkspace(1)
    XCTAssertEqual(spaces.visible["SIDE"], "1")
    XCTAssertEqual(spaces.focusedDisplay, "SIDE")
    XCTAssertEqual(spaces.visible["MAIN"], "2", "the one it displaced: the two swap")
    XCTAssertEqual(spaces.hiddenWindows, [], "the side's old workspace held nothing")
  }

  /// The displaced workspace takes the display the moved one left, even
  /// when a free persistent one comes before it.
  func testMovingAWorkspaceSwapsItWithTheOneItDisplaces() {
    var spaces = TilingWorkspaces<String>(persistent: ["1", "2", "3"])
    spaces.setDisplays([main, side])
    spaces.focusDisplay("SIDE")
    spaces.switchTo("3")
    spaces.focusDisplay("MAIN")
    spaces.moveFocusedWorkspace(1)
    XCTAssertEqual(spaces.visible, ["SIDE": "1", "MAIN": "3"])
  }

  func testFloatingAndFullscreenStayInTheirWorkspace() {
    var spaces = TilingWorkspaces<String>()
    spaces.setDisplays([main])
    spaces.add("a")
    spaces.add("dialog", floating: true)
    XCTAssertEqual(spaces.workspaces["1"]?.floating, ["dialog"])
    spaces.toggleFloating("dialog")
    XCTAssertEqual(spaces.workspaces["1"]?.tree.windows, ["a", "dialog"])
    spaces.toggleFullscreen("a")
    XCTAssertEqual(spaces.workspaces["1"]?.fullscreen, "a")
    spaces.remove("a")
    XCTAssertNil(spaces.workspaces["1"]?.fullscreen)
  }

  func testMonitorPatternsName() {
    let displays = [main, side]
    XCTAssertEqual(TilingMonitorPattern("main")?.resolve(displays), "MAIN")
    XCTAssertEqual(TilingMonitorPattern("secondary")?.resolve(displays), "SIDE")
    XCTAssertEqual(TilingMonitorPattern("2")?.resolve(displays), "SIDE")
    XCTAssertNil(TilingMonitorPattern("3")?.resolve(displays))
    XCTAssertNil(TilingMonitorPattern("left"))
    XCTAssertNil(TilingMonitorPattern("0"))
  }
}
