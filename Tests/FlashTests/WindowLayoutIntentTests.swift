import CoreGraphics
import XCTest

@testable import flash

/// What a placed window's layout does across display changes: it stays the
/// same layout on whatever display it lands on, and goes back to the display
/// it was placed on when that one returns.
final class WindowLayoutIntentTests: XCTestCase {
  private let laptop = WindowScreenLayout(
    id: 1,
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    usableFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
    identity: "laptop-uuid")
  private let external = WindowScreenLayout(
    id: 2,
    frame: CGRect(x: 1512, y: -200, width: 2560, height: 1440),
    usableFrame: CGRect(x: 1512, y: -200, width: 2560, height: 1408),
    identity: "external-uuid")

  private func frame(_ layout: WindowLayout, on screen: WindowScreenLayout) -> CGRect {
    WindowMover.rectFor(layout: layout, in: screen.usableFrame)
  }

  /// The regression: recovery rewrote the window's display to the fallback,
  /// so a replug pulled it back off the display macOS had returned it to.
  func testALayoutReturnsToItsHomeDisplayWhenItReconnects() throws {
    for layout in Self.layouts {
      var intent = WindowLayoutIntent(layout: layout, placedOn: external)
      // Unplugged: macOS parks the window on the laptop; the layout follows.
      let unplugged = try XCTUnwrap(
        intent.recoveryPlan(
          currentFrame: CGRect(x: 100, y: 100, width: 800, height: 600), screens: [laptop]))
      XCTAssertEqual(unplugged.screen, laptop)
      XCTAssertEqual(
        unplugged.frame, frame(layout, on: laptop), WindowMover.description(of: layout))
      intent.recovered(on: unplugged.screen)
      // Focusing it on the laptop is no new placement.
      intent = try XCTUnwrap(
        WindowLayoutIntent.observed(
          frame: unplugged.frame, screens: [laptop], existing: intent, declared: []))
      XCTAssertEqual(intent.home, external.identity)
      // Replugged: back to the external display, same layout, wherever the
      // window sits when the pass reads it.
      for current in [unplugged.frame, frame(layout, on: external)] {
        let replugged = try XCTUnwrap(
          intent.recoveryPlan(currentFrame: current, screens: [laptop, external]))
        XCTAssertEqual(replugged.screen, external)
        XCTAssertEqual(
          replugged.frame, frame(layout, on: external), WindowMover.description(of: layout))
      }
    }
  }

  /// A display's CGDirectDisplayID can change when it reconnects; its
  /// identity does not.
  func testHomeIsMatchedByIdentityNotByDisplayID() throws {
    let intent = WindowLayoutIntent(layout: .position(.leftHalf), placedOn: external)
    let renumbered = WindowScreenLayout(
      id: 7, frame: external.frame, usableFrame: external.usableFrame, identity: external.identity)
    let plan = try XCTUnwrap(intent.recoveryPlan(currentFrame: nil, screens: [laptop, renumbered]))
    XCTAssertEqual(plan.screen, renumbered)
  }

  /// While home is away, every pass keeps the display recovery chose rather
  /// than chasing the window macOS is still moving.
  func testWhileHomeIsAwayTheFallbackDisplayIsKept() throws {
    let third = WindowScreenLayout(
      id: 3, frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
      usableFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1050), identity: "third-uuid")
    var intent = WindowLayoutIntent(layout: .position(.rightHalf), placedOn: external)
    intent.recovered(on: third)
    let plan = try XCTUnwrap(
      intent.recoveryPlan(
        currentFrame: frame(.position(.rightHalf), on: laptop), screens: [laptop, third]))
    XCTAssertEqual(plan.screen, third)
  }

  /// Placing the window again while home is away, or moving it to another
  /// display, makes that display its home.
  func testANewPlacementMovesHome() throws {
    var intent = WindowLayoutIntent(layout: .position(.leftHalf), placedOn: external)
    intent.recovered(on: laptop)
    let snapped = try XCTUnwrap(
      WindowLayoutIntent.observed(
        frame: frame(.position(.rightHalf), on: laptop), screens: [laptop], existing: intent,
        declared: []))
    XCTAssertEqual(snapped.layout, .position(.rightHalf))
    XCTAssertEqual(snapped.home, laptop.identity)
    XCTAssertEqual(
      try XCTUnwrap(snapped.recoveryPlan(currentFrame: nil, screens: [laptop, external])).screen,
      laptop)

    let onExternal = WindowLayoutIntent(layout: .position(.leftHalf), placedOn: external)
    let dragged = try XCTUnwrap(
      WindowLayoutIntent.observed(
        frame: frame(.position(.leftHalf), on: laptop), screens: [laptop, external],
        existing: onExternal, declared: []))
    XCTAssertEqual(dragged.home, laptop.identity, "the same layout on another display is a move")
  }

  /// A free-form frame is the user's own placement: nothing to keep.
  func testAFreeFormFrameCarriesNoIntent() {
    let intent = WindowLayoutIntent(layout: .position(.leftHalf), placedOn: laptop)
    XCTAssertNil(
      WindowLayoutIntent.observed(
        frame: CGRect(x: 40, y: 60, width: 700, height: 500), screens: [laptop], existing: intent,
        declared: []))
    XCTAssertNil(
      WindowLayoutIntent.observed(
        frame: CGRect(x: 40, y: 60, width: 700, height: 500), screens: [laptop], existing: nil,
        declared: []))
  }

  /// A window seen sitting in a slot (placed before Flash started, or while
  /// Flash was not looking) is recognized, its display its home; a window a
  /// departed display left behind keeps that display as home.
  func testARecognizedSlotIsAdoptedWithItsDisplayAsHome() throws {
    let adopted = try XCTUnwrap(
      WindowLayoutIntent.observed(
        frame: frame(.position(.maximized), on: external), screens: [laptop, external],
        existing: nil, declared: []))
    XCTAssertEqual(adopted, WindowLayoutIntent(layout: .position(.maximized), placedOn: external))
    let stranded = try XCTUnwrap(
      WindowLayoutIntent.observed(
        frame: frame(.position(.maximized), on: laptop), screens: [laptop], existing: nil,
        declared: [], home: external.identity))
    XCTAssertEqual(stranded.home, external.identity)
    XCTAssertEqual(stranded.screenID, laptop.id)
    let declared = WindowLayout.proportional(
      ProportionalWindowFrame(xPercent: 10, yPercent: 10, widthPercent: 80, heightPercent: 80))
    XCTAssertEqual(
      WindowLayoutIntent.observed(
        frame: frame(declared, on: laptop), screens: [laptop], existing: nil, declared: [declared]
      )?.layout, declared)
  }

  func testASnapshotNamesEachDisplayByItsIdentity() {
    let snapshot = OverlayPanel.makeScreenSnapshot(
      screens: [(scale: 2, frame: laptop.frame, visibleFrame: laptop.usableFrame, notch: nil)],
      nativeStatusBarFallbackHeight: 24)
    let layouts = WindowMover.screenLayouts(
      screens: [
        (id: 1, frame: laptop.frame, visibleFrame: laptop.usableFrame),
        (id: 2, frame: external.frame, visibleFrame: external.usableFrame),
      ],
      snapshot: snapshot, statusBarReservesSpace: false, statusBarMonitor: .primary,
      identities: [1: "laptop-uuid"])
    XCTAssertEqual(layouts.map(\.identity), ["laptop-uuid", "display-2"])
    XCTAssertEqual(
      WindowScreenLayout(id: 9, frame: .zero, usableFrame: .zero).identity, "display-9")
  }

  /// A display that went away while the session slept or was locked still
  /// counts as a topology change once it resumes: windows it stranded are
  /// fitted onto the displays that remain, even with no tracked restore
  /// pending.
  func testATopologyChangeWhileSuspendedIsRecoveredOnResume() {
    let discovered = expectation(description: "the stranded-window pass ran after resuming")
    var resumed = false
    let manager = WindowLayoutManager(
      screenRecoveryDelaysMs: [0],
      recoveryApplications: {
        XCTAssertTrue(resumed, "no window discovery while suspended")
        if resumed { discovered.fulfill() }
        return []
      },
      screenLayouts: { _, _ in [self.laptop] })
    manager.screenParametersDidChange(screens: [laptop, external])
    manager.setSessionSuspended(true, statusBarReservesSpace: false, statusBarMonitor: .primary)
    let suspendedPass = expectation(description: "the suspended pass ran")
    manager.screenParametersDidChange(screens: [laptop]) { _ in suspendedPass.fulfill() }
    wait(for: [suspendedPass], timeout: 2)
    resumed = true
    manager.setSessionSuspended(false, statusBarReservesSpace: false, statusBarMonitor: .primary)
    wait(for: [discovered], timeout: 2)
  }

  private static let layouts: [WindowLayout] = [
    .position(.leftHalf), .position(.rightHalf), .position(.topHalf), .position(.bottomHalf),
    .position(.topLeft), .position(.bottomRight), .position(.centered), .position(.maximized),
    .proportional(
      ProportionalWindowFrame(
        xPercent: 10.6925, yPercent: 10.6925, widthPercent: 78.615, heightPercent: 78.615)),
  ]
}
