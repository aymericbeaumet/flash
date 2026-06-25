import AppKit
import XCTest

@testable import flash

/// The `:apps` switcher's pure window→target selection: one front-most window
/// per switchable app, in z-order, skipping non-switchable pids and
/// non-interaction layers.
final class AppSwitcherTests: XCTestCase {
  private func entry(_ pid: pid_t, layer: Int = 0, _ frame: CGRect) -> WindowSnapshot.Entry {
    WindowSnapshot.Entry(pid: pid, layer: layer, nsBounds: frame)
  }

  func testOneFrontMostWindowPerAppInZOrder() {
    let entries = [
      entry(10, CGRect(x: 0, y: 0, width: 100, height: 100)),  // app 10, front
      entry(20, CGRect(x: 100, y: 0, width: 100, height: 100)),  // app 20
      entry(10, CGRect(x: 200, y: 0, width: 100, height: 100)),  // app 10, behind
    ]
    let tops = AppDelegate.appSwitcherTopWindows(entries: entries, switchablePIDs: [10, 20])
    XCTAssertEqual(tops.map(\.pid), [10, 20])
    XCTAssertEqual(tops.first?.frame, CGRect(x: 0, y: 0, width: 100, height: 100))
  }

  func testNonSwitchablePidsAndNonInteractionLayersAreSkipped() {
    let entries = [
      entry(30, CGRect(x: 0, y: 0, width: 10, height: 10)),  // not switchable
      entry(10, layer: 99, CGRect(x: 0, y: 0, width: 10, height: 10)),  // non-interaction layer
      entry(10, CGRect(x: 0, y: 0, width: 10, height: 10)),  // the one real window
    ]
    let tops = AppDelegate.appSwitcherTopWindows(entries: entries, switchablePIDs: [10])
    XCTAssertEqual(tops.map(\.pid), [10])
  }

  func testEmptyWhenNoSwitchableWindows() {
    let entries = [entry(30, CGRect(x: 0, y: 0, width: 10, height: 10))]
    XCTAssertTrue(AppDelegate.appSwitcherTopWindows(entries: entries, switchablePIDs: [10]).isEmpty)
  }
}
