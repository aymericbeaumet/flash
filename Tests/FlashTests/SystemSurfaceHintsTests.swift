import CoreGraphics
import FlashCore
import XCTest

@testable import flash

/// `mouse_notifications` picks the pressable parts of Notification Center's
/// windows; `mouse_menubar` commits menu titles and status items.
final class SystemSurfaceHintsTests: XCTestCase {
  private typealias Node = NotificationCenterSurface.Node<String>

  private func node(
    _ id: String, _ role: String, frame: CGRect? = CGRect(x: 0, y: 0, width: 40, height: 20),
    hidden: Bool = false, pressable: Bool = false, _ children: [Node] = []
  ) -> Node {
    Node(
      element: id, role: role, frame: frame, hidden: hidden, pressable: pressable,
      children: children)
  }

  func testNotificationTargetsAreBannersAndTheirControlsInTreeOrder() {
    let banner = CGRect(x: 1500, y: 900, width: 350, height: 70)
    let stack = CGRect(x: 1500, y: 780, width: 350, height: 90)
    let windows = [
      node(
        "window", "AXWindow", frame: CGRect(x: 1480, y: 700, width: 400, height: 300),
        [
          node(
            "chrome", "AXGroup",
            [
              node(
                "scroll", "AXScrollArea",
                [
                  node(
                    "banner", "AXGroup", frame: banner, pressable: true,
                    [
                      node("title", "AXStaticText"),
                      node("close", "AXButton", frame: CGRect(x: 1492, y: 958, width: 18, height: 18)),
                      node(
                        "options", "AXMenuButton", frame: CGRect(x: 1800, y: 930, width: 40, height: 20)),
                      // The same banner again as an inner pressable wrapper.
                      node("banner-body", "AXGroup", frame: banner, pressable: true),
                    ]),
                  node(
                    "stack", "AXGroup", frame: stack, pressable: true,
                    [node("stacked", "AXGroup", frame: stack.insetBy(dx: 0, dy: 10), pressable: true)]),
                  node("inert", "AXGroup", frame: CGRect(x: 1500, y: 700, width: 350, height: 60)),
                  node(
                    "hidden", "AXGroup", hidden: true, pressable: true,
                    [node("hidden-button", "AXButton")]),
                  node("frameless", "AXButton", frame: nil),
                ]),
            ])
        ])
    ]
    XCTAssertEqual(
      NotificationCenterSurface.pressableElements(in: windows),
      ["banner", "close", "options", "stack", "stacked"])
  }

  func testNoNotificationWindowMeansNoTargets() {
    XCTAssertEqual(NotificationCenterSurface.pressableElements(in: [Node]()), [])
    XCTAssertEqual(
      NotificationCenterSurface.pressableElements(in: [
        node("window", "AXWindow", [node("text", "AXStaticText")])
      ]), [])
  }

  /// A menu title, status item or notification control is clicked at its
  /// centre; every other hint aims at its chip. A banner's chip sits on its
  /// top-left corner, where the close button appears on hover.
  func testSystemSurfaceHintsCommitAtTheTargetCentre() {
    let frame = CGRect(x: 1500, y: 900, width: 350, height: 70)
    for provider in [AppDelegate.menuBarProviderID, AppDelegate.notificationsProviderID] {
      let hint = AssignedHint(
        target: JumpTarget(id: provider, frame: frame, providerID: provider), label: "a")
      XCTAssertEqual(
        AppDelegate.hintCommitPoint(for: hint, fontSize: 12),
        CGPoint(x: frame.midX, y: frame.midY), provider)
    }
    let control = AssignedHint(
      target: JumpTarget(id: "ax", frame: frame, providerID: "accessibility"), label: "a")
    let chip = OverlayPanel.chipFrame(for: control, fontSize: 12)
    XCTAssertEqual(
      AppDelegate.hintCommitPoint(for: control, fontSize: 12), CGPoint(x: chip.midX, y: chip.midY))
  }

  /// Both kinds of menu-bar target open a menu that owns the keyboard.
  func testMenuBarTargetsSuspendForTheMenuTheyOpen() {
    let frame = CGRect(x: 10, y: 1050, width: 40, height: 30)
    XCTAssertTrue(
      AppDelegate.hintOpensMenuBarMenu(
        JumpTarget(
          id: "title", frame: frame, role: "AXMenuBarItem",
          providerID: AppDelegate.menuBarProviderID)))
    XCTAssertTrue(
      AppDelegate.hintOpensMenuBarMenu(
        JumpTarget(
          id: "item", frame: frame, role: AppDelegate.statusItemHintRole,
          providerID: AppDelegate.menuBarProviderID)))
    XCTAssertFalse(
      AppDelegate.hintOpensMenuBarMenu(
        JumpTarget(
          id: "button", frame: frame, role: "AXButton",
          providerID: AppDelegate.notificationsProviderID)))
  }

  func testStatusItemsComeFromMenuBarLayerGeometryOnly() {
    let raw: [[String: Any]] = [
      window(pid: 7, number: 11, layer: 25, x: 1700, width: 30),
      window(pid: 7, number: 12, layer: 0, x: 100, width: 300),
      window(pid: 99, number: 13, layer: 25, x: 1650, width: 30),
      window(pid: 8, number: 14, layer: 25, x: 1600, width: 500),
    ]
    let targets = AppDelegate.statusItemTargets(raw, ownPID: 99, screenH: 1080)
    XCTAssertEqual(targets.map(\.id), ["status_item_7_11"])
    XCTAssertEqual(targets.first?.providerID, AppDelegate.menuBarProviderID)
    XCTAssertEqual(targets.first?.role, AppDelegate.statusItemHintRole)
    XCTAssertEqual(targets.first?.frame, CGRect(x: 1700, y: 1056, width: 30, height: 24))
  }

  private func window(pid: Int, number: Int, layer: Int, x: CGFloat, width: CGFloat)
    -> [String: Any]
  {
    [
      kCGWindowLayer as String: layer,
      kCGWindowOwnerPID as String: pid,
      kCGWindowNumber as String: CGWindowID(number),
      kCGWindowOwnerName as String: "Owner",
      kCGWindowBounds as String: ["X": x, "Y": CGFloat(0), "Width": width, "Height": CGFloat(24)],
    ]
  }
}
