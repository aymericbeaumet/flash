import CoreGraphics
import FlashCore
import XCTest

@testable import flash

/// `f` while Mission Control or App Exposé is up labels the Dock's view: the
/// window thumbnails, the Spaces bar's desktops and its add-desktop button.
/// The targets come from fake Dock trees, so no test opens anything on screen.
final class MissionControlSurfaceTests: XCTestCase {
  private typealias Node = MissionControlSurface.Node<String>

  private func container(
    _ id: String, identifier: String? = nil, frame: CGRect? = nil, hidden: Bool = false,
    role: String = "AXGroup", _ children: [Node] = []
  ) -> Node {
    Node(
      element: id, identifier: identifier, role: role, frame: frame, hidden: hidden,
      children: children)
  }

  private func button(
    _ id: String, identifier: String? = nil, x: CGFloat, y: CGFloat, width: CGFloat = 240,
    height: CGFloat = 150, hidden: Bool = false, frame: Bool = true
  ) -> Node {
    Node(
      element: id, identifier: identifier, role: "AXButton",
      frame: frame ? CGRect(x: x, y: y, width: width, height: height) : nil, hidden: hidden,
      children: [])
  }

  private func spacesBar(_ desktops: [Node], add: String, x: CGFloat, y: CGFloat) -> Node {
    container(
      "spaces-\(add)", identifier: "mc.spaces",
      [
        container("list-\(add)", identifier: "mc.spaces.list", role: "AXList", desktops),
        button(add, identifier: "mc.spaces.add", x: x, y: y, width: 40, height: 40),
      ])
  }

  /// Two displays, the right one first in the tree, and the Dock's own tile
  /// list beside Mission Control's group.
  private func missionControlTree() -> [Node] {
    let left = container(
      "display-left", identifier: "mc.display", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
      [
        container(
          "windows-left", identifier: "mc.windows",
          [
            button("low", x: 100, y: 100),
            button("top-right", x: 800, y: 500),
            button("top-left", x: 100, y: 500),
            button("hidden", x: 400, y: 300, hidden: true),
            button("frameless", x: 0, y: 0, frame: false),
            container(
              "caption", frame: CGRect(x: 0, y: 0, width: 50, height: 10), role: "AXStaticText"),
          ]),
        spacesBar(
          [
            button("desktop-1", x: 600, y: 860, width: 80, height: 20),
            button("desktop-2", x: 700, y: 860, width: 80, height: 20),
          ], add: "add-left", x: 1380, y: 850),
      ])
    let right = container(
      "display-right", identifier: "mc.display",
      frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
      [
        container("windows-right", identifier: "mc.windows", [button("right", x: 1600, y: 400)]),
        spacesBar(
          [button("desktop-3", x: 2300, y: 1040, width: 80, height: 20)], add: "add-right",
          x: 3300, y: 1030),
      ])
    return [
      container(
        "tiles", role: "AXList",
        [
          Node(
            element: "tile", identifier: nil, role: "AXDockItem", frame: nil, hidden: false,
            children: [])
        ]
      ),
      container("mc", identifier: "mc", [right, left]),
    ]
  }

  private func picks(_ reading: MissionControlSurface.Reading<String>) -> [String]? {
    guard case .ready(let picks) = reading else { return nil }
    return picks.map(\.element)
  }

  private func kinds(_ reading: MissionControlSurface.Reading<String>) -> [MissionControlSurface
    .Kind]?
  {
    guard case .ready(let picks) = reading else { return nil }
    return picks.map(\.kind)
  }

  // MARK: - Extraction and order

  /// Windows get the easiest labels, display by display from the left and in
  /// reading order on each; then the desktops in Spaces-bar order; then each
  /// display's add-desktop button. Hidden and frameless elements, text and the
  /// Dock's own tiles are not targets.
  func testMissionControlLabelsWindowsThenDesktopsThenTheAddButtons() {
    let reading = MissionControlSurface.reading(of: .missionControl, in: missionControlTree())
    XCTAssertEqual(
      picks(reading),
      [
        "top-left", "top-right", "low", "right", "desktop-1", "desktop-2", "desktop-3", "add-left",
        "add-right",
      ])
    XCTAssertEqual(
      kinds(reading),
      [.window, .window, .window, .window, .desktop, .desktop, .desktop, .addDesktop, .addDesktop])
  }

  /// App Exposé shows one app's windows; every button in its group is one.
  func testAppExposeLabelsTheAppsWindows() {
    let tree = [
      container(
        "appexpose", identifier: "appexpose",
        [
          container(
            "display", identifier: "appexpose.display",
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            [
              button("second", x: 700, y: 400),
              button("first", x: 100, y: 400),
              button("minimized", x: 100, y: 20, width: 80, height: 60),
            ])
        ])
    ]
    let reading = MissionControlSurface.reading(of: .appWindows, in: tree)
    XCTAssertEqual(picks(reading), ["first", "second", "minimized"])
    XCTAssertEqual(kinds(reading), [.window, .window, .window])
    XCTAssertNil(
      picks(MissionControlSurface.reading(of: .appWindows, in: missionControlTree())),
      "Mission Control's tree is no App Exposé")
  }

  /// With "Displays have separate Spaces" off, one Spaces bar serves every
  /// display: a display without one still has its windows labelled.
  func testOneSpacesBarIsEnough() {
    let tree = [
      container(
        "mc", identifier: "mc",
        [
          container(
            "main", identifier: "mc.display", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            [
              container("w", identifier: "mc.windows", [button("main-window", x: 100, y: 100)]),
              spacesBar(
                [button("desktop", x: 600, y: 860, width: 80, height: 20)], add: "add", x: 1380,
                y: 850),
            ]),
          container(
            "side", identifier: "mc.display",
            frame: CGRect(x: 1440, y: 0, width: 1440, height: 900),
            [container("w2", identifier: "mc.windows", [button("side-window", x: 1600, y: 100)])]),
        ])
    ]
    XCTAssertEqual(
      picks(MissionControlSurface.reading(of: .missionControl, in: tree)),
      ["main-window", "side-window", "desktop", "add"])
  }

  /// The Dock builds the view's elements as its animation ends: a group with
  /// no displays yet, or displays whose Spaces bar has not appeared, is a tree
  /// still being built, never served as a partial set.
  func testATreeStillBeingBuiltIsNotServed() {
    func building(_ view: DockView, _ tree: [Node]) -> Bool {
      if case .building = MissionControlSurface.reading(of: view, in: tree) { return true }
      return false
    }
    XCTAssertTrue(building(.missionControl, []))
    XCTAssertTrue(building(.missionControl, [container("tiles", role: "AXList")]))
    XCTAssertTrue(building(.missionControl, [container("mc", identifier: "mc")]))
    XCTAssertTrue(
      building(
        .missionControl,
        [
          container(
            "mc", identifier: "mc",
            [
              container(
                "display", identifier: "mc.display",
                [container("w", identifier: "mc.windows", [button("window", x: 0, y: 0)])])
            ])
        ]))
    XCTAssertTrue(building(.appWindows, [container("appexpose", identifier: "appexpose")]))
    XCTAssertTrue(building(.missionControl, [container("mc", identifier: "mc", hidden: true)]))
  }

  // MARK: - Targets and commits

  /// Every target is the Dock's, clicked at its centre through the click
  /// queue: it carries its kind, no pid (the Dock never becomes the frontmost
  /// app, so the click waits on no activation) and is no typing surface.
  func testTargetsCarryTheirKindNoPidAndNoTextInput() {
    let picks: [MissionControlSurface.Pick<String>] = [
      .init(element: "window", kind: .window),
      .init(element: "gone", kind: .window),
      .init(element: "desktop", kind: .desktop),
      .init(element: "add", kind: .addDesktop),
    ]
    let targets = MissionControlSurface.jumpTargets(picks) { element, id in
      guard element != "gone" else { return nil }
      return JumpTarget(
        id: id, frame: CGRect(x: 10, y: 10, width: 200, height: 100), role: "AXButton",
        accessibilityLabel: element, pid: 99, isTextInput: true, providerID: "accessibility")
    }
    XCTAssertEqual(targets.map(\.accessibilityLabel), ["window", "desktop", "add"])
    XCTAssertEqual(
      targets.map(\.contextID),
      [
        MissionControlSurface.Kind.window.rawValue, MissionControlSurface.Kind.desktop.rawValue,
        MissionControlSurface.Kind.addDesktop.rawValue,
      ])
    XCTAssertEqual(Set(targets.map(\.id)).count, 3, "ids are unique")
    for target in targets {
      XCTAssertEqual(target.providerID, MissionControlSurface.providerID)
      XCTAssertNil(target.pid)
      XCTAssertFalse(target.isTextInput)
      XCTAssertEqual(target.role, "AXButton")
    }
    XCTAssertEqual(
      targets.map { MissionControlSurface.kind(of: $0) }, [.window, .desktop, .addDesktop])
  }

  func testMissionControlHintsAreClickedAtTheirCentre() {
    let frame = CGRect(x: 300, y: 200, width: 240, height: 150)
    let hint = AssignedHint(
      target: JumpTarget(
        id: "window", frame: frame, contextID: MissionControlSurface.Kind.window.rawValue,
        providerID: MissionControlSurface.providerID), label: "a")
    XCTAssertEqual(
      AppDelegate.hintCommitPoint(for: hint, fontSize: 12), CGPoint(x: frame.midX, y: frame.midY))
  }

  /// A window or a desktop leaves Mission Control, so a chain ends on it; the
  /// add-desktop button keeps Mission Control open, so a chain discovers
  /// again and labels the desktop it added.
  func testOnlyTheAddDesktopButtonKeepsMissionControlOpen() {
    func target(
      _ kind: MissionControlSurface.Kind?, provider: String = MissionControlSurface.providerID
    )
      -> JumpTarget
    {
      JumpTarget(
        id: "t", frame: CGRect(x: 0, y: 0, width: 10, height: 10), contextID: kind?.rawValue,
        providerID: provider)
    }
    XCTAssertTrue(MissionControlSurface.clickLeavesView(target(.window)))
    XCTAssertTrue(MissionControlSurface.clickLeavesView(target(.desktop)))
    XCTAssertFalse(MissionControlSurface.clickLeavesView(target(.addDesktop)))
    XCTAssertFalse(
      MissionControlSurface.clickLeavesView(target(.window, provider: "accessibility")))
    XCTAssertFalse(MissionControlSurface.clickLeavesView(nil))
    XCTAssertEqual(
      ClickChain.step(
        after: ClickChain.Click(
          action: .leftClick, modifiers: [], inMenuBar: false,
          leavesSurface: MissionControlSurface.clickLeavesView(target(.addDesktop))),
        sticky: false),
      .rediscover)
  }

  // MARK: - When `f` labels the Dock's view

  /// Mission Control and App Exposé are labelled; Show Desktop moves the
  /// windows aside but shows nothing of the Dock's to press, and an unknown
  /// view labels nothing of the Dock's.
  func testOnlyMissionControlAndAppExposeAreLabelled() {
    XCTAssertEqual(MissionControlSurface.labelledView(.missionControl), .missionControl)
    XCTAssertEqual(MissionControlSurface.labelledView(.appWindows), .appWindows)
    XCTAssertNil(MissionControlSurface.labelledView(.desktop))
    XCTAssertNil(MissionControlSurface.labelledView(DockView.none))
    XCTAssertNil(MissionControlSurface.labelledView(nil))
  }

  /// Labels drawn for one side of the change are wrong on the other: the
  /// app's labels once Mission Control opens over it, Mission Control's once
  /// it closes. A click on its way out, a grid, and a session that is not
  /// over a window (a confirmation, the menu bar) are left alone.
  func testADockViewChangeEndsTheLabelsItInvalidates() {
    func ends(
      _ request: HintActivationRequest?, labelling: DockView?, now: DockView?,
      surface: HintSession.Surface = .targets, committing: Bool = false
    ) -> Bool {
      var session = HintSession()
      session.request = request
      session.missionControl = labelling
      session.surface = surface
      return AppDelegate.dockViewChangeEndsHintSession(
        session, labelled: now, committing: committing)
    }
    let target = HintActivationRequest.target(.click(.leftClick, modifiers: []), nil)
    XCTAssertTrue(ends(target, labelling: nil, now: .missionControl))
    XCTAssertTrue(ends(target, labelling: .missionControl, now: nil))
    XCTAssertTrue(ends(target, labelling: .missionControl, now: .appWindows))
    XCTAssertTrue(
      ends(.screen(.click(.leftClick, modifiers: [])), labelling: nil, now: .appWindows))
    XCTAssertFalse(ends(target, labelling: .missionControl, now: .missionControl))
    XCTAssertFalse(ends(target, labelling: nil, now: nil))
    XCTAssertFalse(ends(target, labelling: nil, now: .missionControl, committing: true))
    XCTAssertFalse(
      ends(
        .grid(MouseGridRequest(.click(.leftClick, modifiers: [])), nil), labelling: nil,
        now: .missionControl, surface: .grid))
    XCTAssertFalse(ends(.menuBar, labelling: nil, now: .missionControl))
    XCTAssertFalse(ends(nil, labelling: nil, now: .missionControl))
  }
}
