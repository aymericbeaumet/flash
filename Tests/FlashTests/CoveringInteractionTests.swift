import CoreGraphics
import XCTest

@testable import flash

final class CoveringInteractionTests: XCTestCase {
  private let screen = CGRect(x: 0, y: 0, width: 2000, height: 1200)
  private let front = pid_t(10)
  private let agent = pid_t(20)
  private let other = pid_t(30)

  private func entry(
    _ pid: pid_t, layer: Int, x: CGFloat = 400, y: CGFloat = 400, width: CGFloat = 440,
    height: CGFloat = 320
  ) -> WindowSnapshot.Entry {
    WindowSnapshot.Entry(
      pid: pid, layer: layer, nsBounds: CGRect(x: x, y: y, width: width, height: height))
  }

  private func owners(_ regular: Set<pid_t> = []) -> (pid_t) -> CoveringInteractionOwner? {
    { pid in
      let bundle: String
      switch pid {
      case self.agent: bundle = "com.apple.coreservices.uiagent"
      case self.other: bundle = "com.example.Other"
      default: bundle = "com.example.Front"
      }
      return CoveringInteractionOwner(bundleIdentifier: bundle, isRegularApp: regular.contains(pid))
    }
  }

  func testAnAgentDialogAboveTheFrontAppIsTheHintSurface() {
    let dialog = entry(agent, layer: Int(CGWindowLevelForKey(.modalPanelWindow)))
    let app = entry(front, layer: 0, x: 0, y: 0, width: 2000, height: 1200)
    let chosen = AppMonitor.coveringInteractionWindow(
      entries: [dialog, app], frontPid: front, screen: screen, owner: owners([front]))
    XCTAssertEqual(chosen?.window?.pid, agent)
    XCTAssertEqual(chosen?.window?.nsBounds, dialog.nsBounds)
  }

  func testANormalLevelAgentWindowIsTheHintSurface() {
    let dialog = entry(agent, layer: 0)
    let app = entry(front, layer: 0, x: 0, y: 0, width: 2000, height: 1200)
    let chosen = AppMonitor.coveringInteractionWindow(
      entries: [dialog, app], frontPid: front, screen: screen, owner: owners([front]))
    XCTAssertEqual(chosen?.window?.pid, agent)
  }

  func testGatekeeperIsTheSurfaceEvenWhenItReportsARegularPolicy() {
    let dialog = entry(agent, layer: 0)
    let app = entry(front, layer: 0, x: 0, y: 0, width: 2000, height: 1200)
    let chosen = AppMonitor.coveringInteractionWindow(
      entries: [dialog, app], frontPid: front, screen: screen, owner: owners([front, agent]))
    XCTAssertEqual(chosen?.window?.pid, agent)
  }

  func testAnotherRegularAppsNormalWindowIsActivationLag() {
    let behind = entry(other, layer: 0, x: 0, y: 0, width: 2000, height: 1200)
    let app = entry(front, layer: 0, x: 100, y: 100, width: 800, height: 600)
    let chosen = AppMonitor.coveringInteractionWindow(
      entries: [behind, app], frontPid: front, screen: screen, owner: owners([front, other]))
    XCTAssertNil(chosen)
  }

  func testADialogInFrontOfThatLagWindowStillWins() {
    let dialog = entry(agent, layer: Int(CGWindowLevelForKey(.modalPanelWindow)))
    let behind = entry(other, layer: 0, x: 0, y: 0, width: 2000, height: 1200)
    let app = entry(front, layer: 0, x: 100, y: 100, width: 800, height: 600)
    let chosen = AppMonitor.coveringInteractionWindow(
      entries: [dialog, behind, app], frontPid: front, screen: screen,
      owner: owners([front, other])
    )
    XCTAssertEqual(chosen?.window?.pid, agent)
  }

  func testPictureInPictureDoesNotStealTheFrontApp() {
    let player = entry(
      other, layer: Int(CGWindowLevelForKey(.floatingWindow)), x: 1400, y: 800, width: 480,
      height: 270)
    let app = entry(front, layer: 0, x: 0, y: 0, width: 2000, height: 1200)
    let chosen = AppMonitor.coveringInteractionWindow(
      entries: [player, app], frontPid: front, screen: screen, owner: owners([front, other]))
    XCTAssertNil(chosen)
  }

  func testADialogUnderPictureInPictureIsStillTheSurface() {
    let player = WindowSnapshot.Entry(
      pid: 99, layer: Int(CGWindowLevelForKey(.floatingWindow)),
      nsBounds: CGRect(x: 1400, y: 800, width: 480, height: 270))
    let dialog = entry(agent, layer: Int(CGWindowLevelForKey(.modalPanelWindow)))
    let app = entry(front, layer: 0, x: 0, y: 0, width: 2000, height: 1200)
    let chosen = AppMonitor.coveringInteractionWindow(
      entries: [player, dialog, app], frontPid: front, screen: screen
    ) { pid in
      if pid == 99 {
        return CoveringInteractionOwner(
          bundleIdentifier: ScreenScopeSurfaces.pictureInPictureBundleID, isRegularApp: false)
      }
      return self.owners([self.front])(pid)
    }
    XCTAssertEqual(chosen?.window?.pid, agent)
  }

  func testStatusStripsAreSkipped() {
    let status = entry(
      other, layer: Int(CGWindowLevelForKey(.statusWindow)), x: 1800, y: 1170, width: 180,
      height: 24)
    let dialog = entry(agent, layer: 0)
    let app = entry(front, layer: 0, x: 0, y: 0, width: 2000, height: 1200)
    let chosen = AppMonitor.coveringInteractionWindow(
      entries: [status, dialog, app], frontPid: front, screen: screen
    ) { pid in
      if pid == self.other {
        return CoveringInteractionOwner(bundleIdentifier: "com.example.Menu", isRegularApp: true)
      }
      return self.owners([self.front])(pid)
    }
    XCTAssertEqual(chosen?.window?.pid, agent)
  }

  func testATooltipSizedAgentWindowDoesNotHideTheApp() {
    let tip = entry(agent, layer: 0, x: 500, y: 700, width: 280, height: 40)
    let app = entry(front, layer: 0, x: 0, y: 0, width: 2000, height: 1200)
    let chosen = AppMonitor.coveringInteractionWindow(
      entries: [tip, app], frontPid: front, screen: screen, owner: owners([front]))
    XCTAssertNil(chosen)
  }

  func testTheFrontAppsOwnWindowStopsTheScan() {
    let panel = entry(front, layer: Int(CGWindowLevelForKey(.floatingWindow)))
    let dialog = entry(agent, layer: Int(CGWindowLevelForKey(.modalPanelWindow)))
    let chosen = AppMonitor.coveringInteractionWindow(
      entries: [panel, dialog], frontPid: front, screen: screen, owner: owners([front]))
    XCTAssertNil(chosen)
  }

  func testStageManagerThumbnailsAreNotTheHintSurface() {
    let thumb = entry(other, layer: 0, x: 20, y: 200, width: 200, height: 140)
    let app = entry(front, layer: 0, x: 240, y: 0, width: 1700, height: 1200)
    let chosen = AppMonitor.coveringInteractionWindow(
      entries: [thumb, app], frontPid: front, screen: screen
    ) { pid in
      if pid == self.other {
        return CoveringInteractionOwner(
          bundleIdentifier: ScreenScopeSurfaces.stageManagerBundleID, isRegularApp: false)
      }
      return self.owners([self.front])(pid)
    }
    XCTAssertNil(chosen)
  }

  // MARK: System overlays

  private let system = pid_t(50)

  /// One system process's window above the front app, decided with that
  /// process as `bundle`.
  private func overlay(
    _ bundle: String, layer: Int, frame: CGRect, regular: Bool = false
  ) -> CoveringSurface? {
    let window = WindowSnapshot.Entry(pid: system, layer: layer, nsBounds: frame)
    let app = entry(front, layer: 0, x: 0, y: 0, width: 2000, height: 1200)
    return AppMonitor.coveringInteractionWindow(
      entries: [window, app], frontPid: front, screen: screen
    ) { pid in
      pid == self.system
        ? CoveringInteractionOwner(bundleIdentifier: bundle, isRegularApp: regular)
        : self.owners([self.front])(pid)
    }
  }

  /// The regression: with Notification Center's panel open over the front
  /// app (level 21, as the live log recorded it), `f` walked the covered app
  /// and found nothing. The panel is the surface, widgets included.
  func testTheNotificationCenterPanelIsTheHintSurface() {
    let panel = CGRect(x: 1600, y: 0, width: 400, height: 1170)
    XCTAssertEqual(
      overlay("com.apple.notificationcenterui", layer: 21, frame: panel)?.window?.nsBounds, panel)
  }

  /// A banner comes and goes on its own: it never takes `f` from the app
  /// (`mouse notifications` hints it).
  func testANotificationBannerDoesNotStealTheFrontApp() {
    XCTAssertNil(
      overlay(
        "com.apple.notificationcenterui", layer: 21,
        frame: CGRect(x: 1620, y: 1060, width: 360, height: 90)))
  }

  /// Desktop widgets sit below every window; the lock and login shields sit
  /// above the screen saver.
  func testDesktopWidgetsAndLockShieldsAreNotTheHintSurface() {
    XCTAssertNil(
      overlay(
        "com.apple.notificationcenterui", layer: Int(CGWindowLevelForKey(.desktopIconWindow)),
        frame: CGRect(x: 40, y: 600, width: 340, height: 340)))
    XCTAssertNil(
      overlay("com.apple.loginwindow", layer: 2004, frame: screen))
  }

  func testControlCenterAndMenuExtrasAreTheHintSurface() {
    let module = CGRect(x: 1640, y: 760, width: 320, height: 400)
    for layer in [24, Int(CGWindowLevelForKey(.statusWindow)), 101] {
      XCTAssertEqual(
        overlay("com.apple.controlcenter", layer: layer, frame: module)?.window?.nsBounds, module,
        "layer \(layer)")
    }
    XCTAssertNotNil(
      overlay(
        "com.apple.systemuiserver", layer: 101,
        frame: CGRect(x: 1500, y: 900, width: 260, height: 240)))
    // A third-party status item's popover, drawn at the status level.
    XCTAssertNotNil(
      overlay(
        "com.example.MenuExtra", layer: Int(CGWindowLevelForKey(.statusWindow)),
        frame: CGRect(x: 1500, y: 800, width: 360, height: 380)))
  }

  func testTheDockBarIsNotTheHintSurfaceButItsStacksAre() {
    XCTAssertNil(
      overlay("com.apple.dock", layer: 20, frame: CGRect(x: 0, y: 200, width: 80, height: 800)))
    XCTAssertNil(
      overlay("com.apple.dock", layer: 20, frame: CGRect(x: 400, y: 0, width: 1200, height: 90)))
    let stack = CGRect(x: 120, y: 300, width: 520, height: 420)
    XCTAssertEqual(overlay("com.apple.dock", layer: 20, frame: stack)?.window?.nsBounds, stack)
  }

  func testSpotlightAndTheScreenshotToolbarAreTheHintSurface() {
    XCTAssertNotNil(
      overlay(
        "com.apple.Spotlight", layer: 24, frame: CGRect(x: 650, y: 500, width: 700, height: 480)))
    XCTAssertNotNil(
      overlay(
        "com.apple.screencaptureui", layer: 101,
        frame: CGRect(x: 700, y: 80, width: 600, height: 56)))
  }

  /// A password or Touch ID prompt is neither walked nor clicked: `f` does
  /// nothing while it shows, and never reaches the window behind it.
  func testAnAuthenticationPromptRefusesHints() {
    let prompt = CGRect(x: 780, y: 450, width: 440, height: 300)
    for bundle in ["com.apple.SecurityAgent", "com.apple.LocalAuthentication.UIAgent"] {
      XCTAssertEqual(
        overlay(bundle, layer: Int(CGWindowLevelForKey(.modalPanelWindow)), frame: prompt),
        .refused(bundleIdentifier: bundle), bundle)
    }
  }
}
