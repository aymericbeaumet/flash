import CoreGraphics
import FlashCore
import XCTest

@testable import flash

/// `mouse_target --scope=screen` also walks Picture in Picture players and
/// the Stage Manager strip. Pure over one window-list snapshot (NSScreen
/// coordinates, front-most first).
final class ScreenScopeSurfacesTests: XCTestCase {
  private let screen = CGRect(x: 0, y: 0, width: 1512, height: 945)
  private let floating = Int(CGWindowLevelForKey(.floatingWindow))
  private let browser: pid_t = 10
  private let pipAgent: pid_t = 20
  private let windowManager: pid_t = 30
  private let utility: pid_t = 40

  private func owner(_ pid: pid_t) -> ScreenScopeSurfaces.Owner? {
    switch pid {
    case browser: return .init(bundleIdentifier: "org.mozilla.firefox", isRegularApp: true)
    case pipAgent: return .init(bundleIdentifier: "com.apple.PIPAgent", isRegularApp: false)
    case windowManager:
      return .init(bundleIdentifier: "com.apple.WindowManager", isRegularApp: false)
    case utility: return .init(bundleIdentifier: "com.example.agent", isRegularApp: false)
    default: return nil
    }
  }

  private func entry(_ pid: pid_t, _ layer: Int, _ frame: CGRect, alpha: Double = 1)
    -> WindowSnapshot.Entry
  {
    WindowSnapshot.Entry(pid: pid, layer: layer, nsBounds: frame, alpha: alpha)
  }

  private func surfaces(_ entries: [WindowSnapshot.Entry]) -> [ScreenScopeSurfaces.Surface] {
    ScreenScopeSurfaces.auxiliary(entries: entries, screen: screen, owner: owner)
  }

  func testThePictureInPictureAgentsWindowIsAPlayer() {
    let player = CGRect(x: 1100, y: 40, width: 384, height: 216)
    XCTAssertEqual(
      surfaces([entry(pipAgent, 3, player), entry(browser, 0, screen)]),
      [.init(entryIndex: 0, pid: pipAgent, frame: player, kind: .pictureInPicture)])
  }

  /// A browser's own player is a floating window, often over its own
  /// maximized window. A pop-up menu, a palette too large for a player and a
  /// tiny floating bit are not players.
  func testAnAppsFloatingPlayerSizedWindowIsAPlayer() {
    let main = screen
    let player = CGRect(x: 1080, y: 60, width: 400, height: 225)
    let menu = CGRect(x: 200, y: 600, width: 300, height: 200)
    let palette = CGRect(x: 1000, y: 0, width: 512, height: 945)
    let tiny = CGRect(x: 1100, y: 800, width: 80, height: 40)
    let popUpMenu = Int(CGWindowLevelForKey(.popUpMenuWindow))
    XCTAssertEqual(
      surfaces([
        entry(browser, popUpMenu, menu), entry(browser, floating, player),
        entry(browser, floating, tiny), entry(browser, floating, palette),
        entry(browser, 0, main),
      ]),
      [.init(entryIndex: 1, pid: browser, frame: player, kind: .pictureInPicture)])
  }

  func testTheStageManagerStripThumbnailsAreSurfaces() {
    let first = CGRect(x: 8, y: 600, width: 150, height: 110)
    let second = CGRect(x: 8, y: 450, width: 150, height: 110)
    let backdrop = screen
    XCTAssertEqual(
      surfaces([
        entry(windowManager, 0, first), entry(windowManager, 0, second),
        entry(windowManager, -20, backdrop),
      ]),
      [
        .init(entryIndex: 0, pid: windowManager, frame: first, kind: .stageManager),
        .init(entryIndex: 1, pid: windowManager, frame: second, kind: .stageManager),
      ])
  }

  /// Other screens, invisible windows, other agents and unknown owners are
  /// never surfaces.
  func testEverythingElseIsIgnored() {
    let offScreen = CGRect(x: 2000, y: 40, width: 384, height: 216)
    let player = CGRect(x: 1100, y: 40, width: 384, height: 216)
    XCTAssertEqual(
      surfaces([
        entry(pipAgent, 3, offScreen),
        entry(pipAgent, 3, player, alpha: 0),
        entry(utility, floating, player),
        entry(99, floating, player),
        entry(browser, 0, player),
      ]), [])
  }

  func testSurfacesAreCapped() {
    let many = (0..<20).map { index in
      entry(windowManager, 0, CGRect(x: 8, y: CGFloat(index) * 40, width: 150, height: 30))
    }
    XCTAssertEqual(surfaces(many).count, ScreenScopeSurfaces.maxSurfaces)
  }

  /// A surface's visible part is its window minus everything in front.
  func testASurfacesVisibleRegionIsItsWindowMinusThoseInFront() {
    let player = CGRect(x: 1100, y: 40, width: 384, height: 216)
    let cover = CGRect(x: 1100, y: 40, width: 384, height: 100)
    let entries = [entry(browser, 25, cover), entry(pipAgent, 3, player)]
    let regions = WindowSnapshot.visibleRegions(ofEntryAt: 1, in: entries)
    XCTAssertEqual(regions, [CGRect(x: 1100, y: 140, width: 384, height: 116)])
    XCTAssertEqual(WindowSnapshot.visibleRegions(ofEntryAt: 5, in: entries), [])
    let transparentCover = [entry(browser, 25, cover, alpha: 0), entry(pipAgent, 3, player)]
    XCTAssertEqual(WindowSnapshot.visibleRegions(ofEntryAt: 1, in: transparentCover), [player])
  }

  /// A player of the app's own is its surface, not the app's: the app's
  /// front window region stays its main window.
  func testAnAppsPlayerIsNotItsFrontSurface() {
    let main = CGRect(x: 0, y: 0, width: 1000, height: 900)
    let player = CGRect(x: 1080, y: 60, width: 400, height: 225)
    let entries = [entry(browser, floating, player), entry(browser, 0, main)]
    XCTAssertEqual(
      WindowSnapshot.buildMultiSurfaceVisibleRegions(entries: entries, focusedPids: [browser])[
        browser], [player], "without the exclusion the player wins")
    XCTAssertEqual(
      WindowSnapshot.buildMultiSurfaceVisibleRegions(
        entries: entries, focusedPids: [browser], excludingIndexes: [0])[browser], [main])
  }

  /// A system agent's targets carry no pid, so the commit never waits for an
  /// agent to activate; an app's player keeps its app's. Ids are namespaced
  /// per surface so they never collide with the app window's walk.
  func testRetargetedIdsAreUniqueAndAgentsCarryNoPid() {
    let target = JumpTarget(
      id: "ax-20-r-3", frame: CGRect(x: 1110, y: 50, width: 30, height: 30), role: "AXButton",
      accessibilityLabel: "Play", pid: pipAgent, entersInsertMode: false,
      providerID: "accessibility")
    let agent = ScreenScopeSurfaces.retarget(
      target,
      surface: .init(
        entryIndex: 0, pid: pipAgent, frame: .zero, kind: .pictureInPicture),
      ordinal: 2, keepsPID: false)
    XCTAssertEqual(agent.id, "picture_in_picture-2-ax-20-r-3")
    XCTAssertNil(agent.pid)
    XCTAssertEqual(agent.frame, target.frame)
    XCTAssertEqual(agent.accessibilityLabel, "Play")
    XCTAssertEqual(agent.role, "AXButton")
    XCTAssertEqual(agent.providerID, "accessibility")
    let app = ScreenScopeSurfaces.retarget(
      target,
      surface: .init(entryIndex: 0, pid: browser, frame: .zero, kind: .pictureInPicture),
      ordinal: 0, keepsPID: true)
    XCTAssertEqual(app.pid, pipAgent)
    XCTAssertEqual(
      ScreenScopeSurfaces.keepsPID(
        .init(bundleIdentifier: "com.apple.PIPAgent", isRegularApp: false)),
      false)
    XCTAssertEqual(
      ScreenScopeSurfaces.keepsPID(
        .init(bundleIdentifier: "org.mozilla.firefox", isRegularApp: true)),
      true)
  }
}
