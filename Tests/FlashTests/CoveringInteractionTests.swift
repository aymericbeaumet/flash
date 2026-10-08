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
    XCTAssertEqual(chosen?.pid, agent)
    XCTAssertEqual(chosen?.nsBounds, dialog.nsBounds)
  }

  func testANormalLevelAgentWindowIsTheHintSurface() {
    let dialog = entry(agent, layer: 0)
    let app = entry(front, layer: 0, x: 0, y: 0, width: 2000, height: 1200)
    let chosen = AppMonitor.coveringInteractionWindow(
      entries: [dialog, app], frontPid: front, screen: screen, owner: owners([front]))
    XCTAssertEqual(chosen?.pid, agent)
  }

  func testGatekeeperIsTheSurfaceEvenWhenItReportsARegularPolicy() {
    let dialog = entry(agent, layer: 0)
    let app = entry(front, layer: 0, x: 0, y: 0, width: 2000, height: 1200)
    let chosen = AppMonitor.coveringInteractionWindow(
      entries: [dialog, app], frontPid: front, screen: screen, owner: owners([front, agent]))
    XCTAssertEqual(chosen?.pid, agent)
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
    XCTAssertEqual(chosen?.pid, agent)
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
    XCTAssertEqual(chosen?.pid, agent)
  }

  func testSystemChromeAndStatusStripsAreSkipped() {
    let status = entry(
      other, layer: Int(CGWindowLevelForKey(.statusWindow)), x: 1800, y: 1170, width: 180,
      height: 24)
    let chrome = WindowSnapshot.Entry(
      pid: 40, layer: Int(CGWindowLevelForKey(.modalPanelWindow)),
      nsBounds: CGRect(x: 1600, y: 900, width: 360, height: 280))
    let dialog = entry(agent, layer: 0)
    let app = entry(front, layer: 0, x: 0, y: 0, width: 2000, height: 1200)
    let chosen = AppMonitor.coveringInteractionWindow(
      entries: [status, chrome, dialog, app], frontPid: front, screen: screen
    ) { pid in
      switch pid {
      case 40:
        return CoveringInteractionOwner(
          bundleIdentifier: "com.apple.controlcenter", isRegularApp: false)
      case self.other:
        return CoveringInteractionOwner(bundleIdentifier: "com.example.Menu", isRegularApp: true)
      default:
        return self.owners([self.front])(pid)
      }
    }
    XCTAssertEqual(chosen?.pid, agent)
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
}
