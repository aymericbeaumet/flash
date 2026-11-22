import ApplicationServices
import CoreGraphics
import XCTest

@testable import flash

/// The tiling engine over a fake driver: no window is read or moved.
final class TilingEngineTests: XCTestCase {
  final class FakeDriver: TilingWindowDriver {
    typealias Key = String
    var frames: [String: CGRect] = [:]
    var titles: [String: String] = [:]
    var numbers: [String: UInt32] = [:]
    var applies: [(key: String, frame: CGRect)] = []
    var parks: [(key: String, topLeft: CGPoint)] = []
    var raises: [String] = []

    func tilingTitle(of key: String) -> String? { titles[key] }
    func tilingWindowNumber(of key: String) -> UInt32? { numbers[key] }
    func tilingFrame(of key: String) -> CGRect? { frames[key] }
    func tilingApply(_ frame: CGRect, to key: String, within bounds: CGRect) {
      applies.append((key, frame))
      frames[key] = frame
    }
    func tilingPark(_ key: String, topLeft: CGPoint) {
      parks.append((key, topLeft))
      if let frame = frames[key] {
        frames[key] = CGRect(
          x: topLeft.x, y: topLeft.y - frame.height, width: frame.width, height: frame.height)
      }
    }
    func tilingRaise(_ key: String) { raises.append(key) }
  }

  private let main = WindowScreenLayout(
    id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 600),
    usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 600), identity: "MAIN")
  private let side = WindowScreenLayout(
    id: 2, frame: CGRect(x: 1000, y: 0, width: 800, height: 600),
    usableFrame: CGRect(x: 1000, y: 0, width: 800, height: 600), identity: "SIDE")

  private var driver = FakeDriver()
  private var published: [TilingStatus] = []

  private func engine(
    _ settings: TilingSettings = TilingSettings(enabled: true, workspaces: ["1", "2", "3"]),
    screens: [WindowScreenLayout]? = nil
  ) -> TilingEngine<FakeDriver> {
    let engine = TilingEngine(driver: driver, settings: settings)
    engine.statusDidChange = { [unowned self] in self.published.append($0) }
    engine.setScreens(screens ?? [main])
    return engine
  }

  private func window(
    _ key: String, on frame: CGRect = CGRect(x: 100, y: 100, width: 300, height: 200),
    subrole: String? = kAXStandardWindowSubrole as String, bundle: String = "com.example.App"
  ) -> TilingEngine<FakeDriver>.Candidate {
    driver.frames[key] = frame
    return .init(key: key, pid: 1, bundleID: bundle, frame: frame, subrole: subrole)
  }

  func testAdoptedWindowsTileTheDisplayAndDialogsFloat() {
    let engine = engine()
    engine.adopt([window("a"), window("b"), window("dialog", subrole: "AXDialog")])
    XCTAssertEqual(driver.frames["a"], CGRect(x: 0, y: 0, width: 500, height: 600))
    XCTAssertEqual(driver.frames["b"], CGRect(x: 500, y: 0, width: 500, height: 600))
    XCTAssertFalse(driver.applies.contains { $0.key == "dialog" }, "a dialog keeps its frame")
    XCTAssertTrue(engine.manages("dialog"))
  }

  func testOnlyChangedFramesAreWritten() {
    let engine = engine()
    engine.adopt([window("a"), window("b")])
    let writes = driver.applies.count
    engine.relayout()
    XCTAssertEqual(driver.applies.count, writes, "nothing changed: nothing written")
  }

  func testRulesFloatOrSendAWindowToItsWorkspace() {
    var settings = TilingSettings(enabled: true, workspaces: ["1", "2"])
    settings.rules = [
      TilingRule(bundleID: "com.example.Chat", workspace: "2"),
      TilingRule(bundleID: "com.example.Tool", titleContains: "palette", floats: true),
    ]
    let engine = engine(settings)
    driver.titles["tool"] = "Color Palette"
    engine.adopt([
      window("a"), window("chat", bundle: "com.example.Chat"),
      window("tool", bundle: "com.example.Tool"),
    ])
    XCTAssertEqual(engine.workspaces.workspace(of: "chat"), "2")
    XCTAssertTrue(engine.isParked("chat"), "workspace 2 is hidden")
    XCTAssertEqual(driver.parks.last?.topLeft, CGPoint(x: 999, y: 1), "off the bottom-right")
    XCTAssertEqual(engine.workspaces.workspaces["1"]?.floating, ["tool"])
    XCTAssertEqual(driver.frames["a"], CGRect(x: 0, y: 0, width: 1000, height: 600))
  }

  func testSwitchingParksAndRestoresWorkspaces() {
    let engine = engine()
    engine.adopt([window("a"), window("b")])
    engine.focus("a")
    XCTAssertEqual(engine.perform(.switchTo("2")), .done)
    XCTAssertEqual(Set(driver.parks.map(\.key)), ["a", "b"])
    engine.adopt([window("c")])
    XCTAssertEqual(driver.frames["c"], CGRect(x: 0, y: 0, width: 1000, height: 600))
    driver.raises.removeAll()
    XCTAssertEqual(engine.perform(.backAndForth), .done)
    XCTAssertEqual(driver.frames["a"], CGRect(x: 0, y: 0, width: 500, height: 600))
    XCTAssertTrue(engine.isParked("c"))
    XCTAssertEqual(driver.raises, ["a"], "the window last focused there comes forward")
    XCTAssertEqual(published.last?.focused, "1")
    XCTAssertEqual(published.last?.previous, "2")
  }

  /// A display beyond the bottom-right corner would show a window parked
  /// there, so it hangs off the bottom-left instead.
  func testAWindowParksAwayFromTheNeighboringDisplay() throws {
    let engine = engine(screens: [main, side])
    engine.adopt([window("a")])
    engine.focus("a")
    XCTAssertEqual(engine.perform(.switchTo("3")), .done)
    XCTAssertEqual(driver.parks.last?.key, "a")
    XCTAssertEqual(driver.parks.last?.topLeft, CGPoint(x: -999, y: 1))
    let parked = try XCTUnwrap(driver.frames["a"])
    XCTAssertTrue(parked.intersection(side.frame).isNull, "nothing of it on the side display")
  }

  /// An app that pulls its parked window back on screen gets it parked
  /// again once; one that keeps doing it is left alone, not fought.
  func testAParkedWindowItsAppBringsBackParksAgainOnce() {
    let engine = engine(screens: [main, side])
    engine.adopt([window("a")])
    engine.focus("a")
    _ = engine.perform(.switchTo("3"))
    XCTAssertEqual(driver.parks.count, 1)
    engine.userMoved("a", to: CGRect(x: 1100, y: 100, width: 300, height: 200))
    XCTAssertEqual(driver.parks.count, 2)
    XCTAssertEqual(engine.workspaces.workspace(of: "a"), "1", "not adopted by the side display")
    engine.userMoved("a", to: CGRect(x: 1100, y: 100, width: 300, height: 200))
    XCTAssertEqual(driver.parks.count, 2)
    XCTAssertTrue(engine.isParked("a"))
  }

  func testFocusingAParkedWindowShowsItsWorkspace() {
    let engine = engine()
    engine.adopt([window("a")])
    _ = engine.perform(.switchTo("2"))
    engine.focus("a")
    XCTAssertEqual(engine.workspaces.focused, "1")
    XCTAssertFalse(engine.isParked("a"))
  }

  func testTreeCommandsActOnTheFocusedWindow() {
    let engine = engine()
    engine.adopt([window("a"), window("b"), window("c")])
    engine.focus("a")
    XCTAssertEqual(engine.perform(.move(.right)), .done)
    XCTAssertEqual(engine.workspaces.workspaces["1"]?.tree.windows, ["b", "a", "c"])
    XCTAssertEqual(engine.perform(.swap(.right)), .done)
    XCTAssertEqual(engine.workspaces.workspaces["1"]?.tree.windows, ["b", "c", "a"])
    XCTAssertEqual(engine.perform(.layout(.accordion)), .done)
    XCTAssertEqual(engine.workspaces.workspaces["1"]?.tree.layout(around: "a").layout, .accordion)
    XCTAssertEqual(engine.perform(.layout(.toggle)), .done)
    let before = driver.frames["a"]!.width
    XCTAssertEqual(engine.perform(.resize(.width, amount: 100)), .done)
    XCTAssertEqual(driver.frames["a"]!.width, before + 100, accuracy: 1)
    XCTAssertEqual(engine.perform(.balance), .done)
    XCTAssertEqual(driver.frames["a"]!.width, before, accuracy: 1)
  }

  func testFloatAndFullscreen() {
    let engine = engine()
    engine.adopt([window("a"), window("b")])
    engine.focus("a")
    XCTAssertEqual(engine.perform(.fullscreen), .done)
    XCTAssertEqual(driver.frames["a"], CGRect(x: 0, y: 0, width: 1000, height: 600))
    XCTAssertEqual(driver.raises.last, "a")
    XCTAssertEqual(engine.perform(.fullscreen), .done)
    XCTAssertEqual(engine.perform(.float), .done)
    XCTAssertEqual(driver.frames["b"], CGRect(x: 0, y: 0, width: 1000, height: 600))
    XCTAssertEqual(
      engine.perform(.move(.left)),
      .failed("the focused window floats: tile float tiles it again"))
  }

  func testADragOntoAnotherDisplayJoinsItsWorkspace() {
    let engine = engine(screens: [main, side])
    engine.adopt([window("a"), window("b")])
    engine.userMoved("b", to: CGRect(x: 1200, y: 100, width: 300, height: 200))
    XCTAssertEqual(engine.workspaces.workspace(of: "b"), "2")
    XCTAssertEqual(driver.frames["b"], side.usableFrame, "tiled on the side display")
    XCTAssertEqual(driver.frames["a"], main.usableFrame)
  }

  func testADragDroppedOnAnotherTileSwapsThem() {
    let engine = engine()
    engine.adopt([window("a"), window("b"), window("c")])
    let from = driver.frames["a"]!
    let onto = driver.frames["c"]!
    engine.userMoved(
      "a", to: from.offsetBy(dx: onto.midX - from.midX, dy: 0),
      at: CGPoint(x: onto.midX, y: 300))
    XCTAssertEqual(engine.workspaces.workspaces["1"]?.tree.windows, ["c", "b", "a"])
    XCTAssertEqual(driver.frames["a"], onto)
    XCTAssertEqual(driver.frames["c"], from)
    XCTAssertEqual(driver.frames["b"]?.minX, from.maxX, "b did not move")
  }

  func testADragDroppedAnywhereElseSnapsBack() {
    let engine = engine()
    engine.adopt([window("a"), window("b")])
    let tile = driver.frames["a"]!
    engine.userMoved("a", to: tile.offsetBy(dx: 40, dy: -30), at: CGPoint(x: 240, y: 270))
    XCTAssertEqual(engine.workspaces.workspaces["1"]?.tree.windows, ["a", "b"])
    XCTAssertEqual(driver.frames["a"], tile, "back to its tile")
  }

  /// An edge dragged by hand moves the split it sits on; one at the edge of
  /// the workspace has nothing to trade with and the window snaps back.
  func testAHandResizeMovesTheSplitInsteadOfSnappingBack() {
    var settings = TilingSettings(enabled: true, workspaces: ["1"])
    settings.gaps = TilingGaps(inner: 10, outer: 0)
    let engine = engine(settings)
    engine.adopt([window("a"), window("b")])
    XCTAssertEqual(driver.frames["a"], CGRect(x: 0, y: 0, width: 495, height: 600))
    engine.userResized("a", to: CGRect(x: 0, y: 0, width: 595, height: 600))
    XCTAssertEqual(driver.frames["a"], CGRect(x: 0, y: 0, width: 595, height: 600))
    XCTAssertEqual(driver.frames["b"], CGRect(x: 605, y: 0, width: 395, height: 600))
    engine.userResized("a", to: CGRect(x: -50, y: 0, width: 645, height: 600))
    XCTAssertEqual(
      driver.frames["a"], CGRect(x: 0, y: 0, width: 595, height: 600),
      "the left edge is the workspace's: back")
    engine.adopt([window("c")])
    engine.focus("c")
    XCTAssertEqual(engine.perform(.join(.left)), .done)
    XCTAssertEqual(engine.workspaces.workspaces["1"]?.tree.shape, "h_tiles[a, v_tiles[b, c]]")
    let c = driver.frames["c"]!
    XCTAssertEqual(c, CGRect(x: 605, y: 0, width: 395, height: 295))
    engine.userResized(
      "c", to: CGRect(x: c.minX, y: c.minY, width: c.width, height: c.height + 100))
    XCTAssertEqual(driver.frames["c"], CGRect(x: 605, y: 0, width: 395, height: 395))
    XCTAssertEqual(driver.frames["b"], CGRect(x: 605, y: 405, width: 395, height: 195))
  }

  func testWorkspaceListMarksTheFocusedOne() {
    let engine = engine(screens: [main, side])
    engine.adopt([window("a")])
    XCTAssertEqual(
      engine.perform(.list),
      .output("1\t1 window\tdisplay 1\t*\n2\t0 windows\tdisplay 2\n3\t0 windows"))
  }

  func testReleasingShowsEveryParkedWindowAgain() {
    let engine = engine()
    engine.adopt([window("a")])
    _ = engine.perform(.switchTo("2"))
    XCTAssertTrue(engine.isParked("a"))
    engine.releaseAll()
    XCTAssertEqual(driver.frames["a"], CGRect(x: 0, y: 0, width: 1000, height: 600))
    XCTAssertFalse(engine.isParked("a"))
  }

  func testForgettingAWindowRetilesTheRest() {
    let engine = engine()
    engine.adopt([window("a"), window("b")])
    engine.forget("b")
    XCTAssertEqual(driver.frames["a"], CGRect(x: 0, y: 0, width: 1000, height: 600))
    XCTAssertFalse(engine.manages("b"))
  }

  func testCommandsNeedAFocusedTiledWindow() {
    let engine = engine()
    XCTAssertEqual(
      engine.perform(.balance),
      .failed("no focused window is tiled: focus a window Flash tiles first"))
    XCTAssertEqual(
      engine.perform(.switchTo("two words")),
      .failed("a workspace name is one word, at most 32 characters"))
  }
}
