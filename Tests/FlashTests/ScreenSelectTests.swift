import AppKit
import FlashCore
import XCTest

@testable import flash

/// `mouse screens`, monitor select: which display a pick names on a
/// multi-display layout, where the pointer lands, which window keyboard focus
/// follows to, the command's grammar, the NORMAL count and default key, and
/// the hint session it runs in.
final class ScreenSelectTests: XCTestCase {
  // Four displays in NSScreen coordinates: one to the left of the primary
  // (taller, lower), one above the primary, one to its right (offset up).
  private let left = WindowScreenLayout(
    id: 2, frame: CGRect(x: -1920, y: -180, width: 1920, height: 1080),
    usableFrame: CGRect(x: -1920, y: -180, width: 1920, height: 1055), identity: "left")
  private let primary = WindowScreenLayout(
    id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
    usableFrame: CGRect(x: 0, y: 60, width: 1440, height: 810), identity: "primary")
  private let above = WindowScreenLayout(
    id: 3, frame: CGRect(x: 0, y: 900, width: 1440, height: 900),
    usableFrame: CGRect(x: 0, y: 900, width: 1440, height: 900), identity: "above")
  private let right = WindowScreenLayout(
    id: 4, frame: CGRect(x: 1440, y: 100, width: 1280, height: 800),
    usableFrame: CGRect(x: 1440, y: 100, width: 1280, height: 776), identity: "right")
  /// `NSScreen.screens` order only promises the primary first.
  private var screens: [WindowScreenLayout] { [primary, right, left, above] }

  // MARK: Numbering

  func testDisplaysAreNumberedLeftToRightThenTopToBottom() {
    let arranged = ScreenSelect.arranged(screens)
    XCTAssertEqual(arranged.map(\.identity), ["left", "above", "primary", "right"])
    // The numbers `[widgets.<name>] screen = <n>` uses.
    for (index, layout) in arranged.enumerated() {
      XCTAssertEqual(
        WidgetPlacement.screens(.index(index + 1), layouts: screens, widget: "w").map(\.identity),
        [layout.identity])
    }
  }

  // MARK: Picks

  func testAPickNamesADisplayOrAsksForLabels() {
    let frames = ScreenSelect.arranged(screens).map(\.frame)
    let onPrimary = CGPoint(x: 700, y: 400)
    func plan(_ pick: ScreenSelectRequest.Pick, _ pointer: CGPoint = onPrimary)
      -> ScreenSelect.Plan
    {
      ScreenSelect.plan(pick, displays: frames, pointer: pointer)
    }
    XCTAssertEqual(plan(.labels), .labels)
    XCTAssertEqual(plan(.index(1)), .display(0))
    XCTAssertEqual(plan(.index(4)), .display(3))
    XCTAssertEqual(plan(.index(5)), .none, "past the last display: nothing")
    XCTAssertEqual(plan(.next), .display(3), "primary is display 3; the next is the right one")
    XCTAssertEqual(plan(.previous), .display(1))
    XCTAssertEqual(plan(.next, CGPoint(x: 2000, y: 500)), .display(0), "wraps after the last")
    XCTAssertEqual(plan(.previous, CGPoint(x: -100, y: 0)), .display(3), "wraps before the first")
    // A pointer in a gap between displays counts from the nearest one: 50
    // points left of the display above, 100 points over the left one.
    XCTAssertEqual(plan(.next, CGPoint(x: -50, y: 1000)), .display(2))
  }

  func testOneDisplayIsPickedWithoutLabelsAndNoneIsSilent() {
    let one = [primary.frame]
    for pick: ScreenSelectRequest.Pick in [.labels, .index(1), .next, .previous] {
      XCTAssertEqual(
        ScreenSelect.plan(pick, displays: one, pointer: .zero), .display(0), "\(pick)")
    }
    XCTAssertEqual(ScreenSelect.plan(.index(2), displays: one, pointer: .zero), .none)
    XCTAssertEqual(ScreenSelect.plan(.labels, displays: [], pointer: .zero), .none)
  }

  // MARK: Labels

  func testEachDisplayIsLabelledWithItsNumberAtTheCentre() throws {
    let targets = ScreenSelect.targets(ScreenSelect.arranged(screens))
    let hints = try XCTUnwrap(ScreenSelect.numberedHints(targets))
    XCTAssertEqual(hints.map(\.label), ["1", "2", "3", "4"])
    XCTAssertEqual(
      hints.map(\.target.id), ["screen:left", "screen:above", "screen:primary", "screen:right"])
    XCTAssertEqual(
      hints.map { ScreenSelect.identity(of: $0.target) },
      [
        "left", "above", "primary", "right",
      ])
    XCTAssertEqual(hints[2].target.frame.midX, 720)
    XCTAssertEqual(hints[2].target.frame.midY, 465, "the centre of the usable frame")
    XCTAssertEqual(hints[0].target.accessibilityLabel, "Display 1")
    XCTAssertEqual(hints[0].target.providerID, AppDelegate.screensProviderID)
    XCTAssertEqual(hints[0].target.priority, .important)
    XCTAssertNil(hints[0].target.resolveClickPoint, "a display is checked by identity at commit")
    XCTAssertFalse(hints[0].target.isTextInput)
  }

  func testTenDisplaysOutgrowSingleDigitLabels() {
    let ten = (0..<10).map { index in
      WindowScreenLayout(
        id: CGDirectDisplayID(index + 1),
        frame: CGRect(x: CGFloat(index) * 100, y: 0, width: 100, height: 100),
        usableFrame: CGRect(x: CGFloat(index) * 100, y: 0, width: 100, height: 100),
        identity: "d\(index)")
    }
    let targets = ScreenSelect.targets(ten)
    XCTAssertEqual(targets.count, 10)
    XCTAssertNil(ScreenSelect.numberedHints(targets), "1 would prefix 10: the hint alphabet labels")
    XCTAssertNil(ScreenSelect.identity(of: JumpTarget(id: "other", frame: .zero, providerID: "x")))
  }

  // MARK: Landing

  func testThePointerLandsOnTheCentreOrWhereItLeftThatDisplay() {
    var memory = ScreenPointerMemory()
    let centre = CGPoint(x: 720, y: 465)
    XCTAssertEqual(ScreenSelect.landing(on: primary, .center, memory: memory), centre)
    XCTAssertEqual(
      ScreenSelect.landing(on: primary, .last, memory: memory), centre, "first visit: the centre")
    memory.leave(pointer: CGPoint(x: 100, y: 200), layouts: screens)
    XCTAssertEqual(memory.point(on: primary), CGPoint(x: 100, y: 200))
    XCTAssertEqual(
      ScreenSelect.landing(on: primary, .last, memory: memory), CGPoint(x: 100, y: 200))
    XCTAssertEqual(ScreenSelect.landing(on: primary, .center, memory: memory), centre)
    // The display shrank under the remembered point: its centre again.
    let shrunk = WindowScreenLayout(
      id: 1, frame: CGRect(x: 0, y: 300, width: 1440, height: 600),
      usableFrame: CGRect(x: 0, y: 300, width: 1440, height: 600), identity: "primary")
    XCTAssertEqual(ScreenSelect.landing(on: shrunk, .last, memory: memory), CGPoint(x: 720, y: 600))
  }

  func testThePointerMemoryKeepsOnePointPerConnectedDisplay() {
    var memory = ScreenPointerMemory()
    memory.leave(pointer: CGPoint(x: 5000, y: 5000), layouts: screens)
    XCTAssertEqual(memory.points, [:], "a pointer on no display remembers nothing")
    memory.leave(pointer: CGPoint(x: 100, y: 200), layouts: screens)
    memory.leave(pointer: CGPoint(x: 1500, y: 200), layouts: screens)
    memory.leave(pointer: CGPoint(x: 1600, y: 300), layouts: screens)
    XCTAssertEqual(
      memory.points, ["primary": CGPoint(x: 100, y: 200), "right": CGPoint(x: 1600, y: 300)])
    memory.leave(pointer: CGPoint(x: 1700, y: 400), layouts: [right])
    XCTAssertEqual(memory.points, ["right": CGPoint(x: 1700, y: 400)], "unplugged: forgotten")
  }

  /// The commit, against the displays connected when the label is typed.
  func testAPickRemembersWhereThePointerLeftAndCancelsOnAVanishedDisplay() throws {
    let start = ScreenPointerMemory()
    let toRight = try XCTUnwrap(
      ScreenSelect.select(
        identity: "right", landing: .last, layouts: screens, pointer: CGPoint(x: 100, y: 200),
        memory: start))
    XCTAssertEqual(toRight.display, right)
    XCTAssertEqual(toRight.point, CGPoint(x: 2080, y: 488), "first visit: the centre")
    let back = try XCTUnwrap(
      ScreenSelect.select(
        identity: "primary", landing: .last, layouts: screens, pointer: CGPoint(x: 2000, y: 300),
        memory: toRight.memory))
    XCTAssertEqual(back.point, CGPoint(x: 100, y: 200), "where the pointer left the primary")
    let again = try XCTUnwrap(
      ScreenSelect.select(
        identity: "right", landing: .last, layouts: screens, pointer: back.point,
        memory: back.memory))
    XCTAssertEqual(again.point, CGPoint(x: 2000, y: 300))
    let stay = try XCTUnwrap(
      ScreenSelect.select(
        identity: "primary", landing: .last, layouts: screens, pointer: CGPoint(x: 300, y: 300),
        memory: start))
    XCTAssertEqual(stay.point, CGPoint(x: 300, y: 300), "--to=last on its own display: stays")
    XCTAssertNil(
      ScreenSelect.select(
        identity: "gone", landing: .center, layouts: screens, pointer: .zero, memory: start),
      "a display unplugged under its label cancels, never its old coordinates")
  }

  // MARK: Focus

  func testFocusFollowsToTheFrontmostWindowOnThePickedDisplay() {
    // Front first. The spanning window's centre (x 1300) is on the primary.
    let ordered = ["spanning", "browser", "editor", "terminal"]
    let frames: [String: CGRect] = [
      "spanning": CGRect(x: 1000, y: 100, width: 600, height: 400),
      "browser": CGRect(x: 1500, y: 150, width: 800, height: 600),
      "editor": CGRect(x: 100, y: 100, width: 600, height: 400),
      "terminal": CGRect(x: 1600, y: 200, width: 400, height: 300),
    ]
    func frontmost(_ identity: String) -> String? {
      WindowFocusPlanner.frontmost(
        onScreen: identity, screens: screens, ordered: ordered, frames: frames)
    }
    XCTAssertEqual(frontmost("right"), "browser")
    XCTAssertEqual(frontmost("primary"), "spanning")
    XCTAssertNil(frontmost("left"), "a display without windows focuses nothing")
    XCTAssertNil(frontmost("gone"))
  }

  // MARK: Grammar

  func testTheCommandParsesAndRendersItsOptions() {
    func parse(_ words: [String]) -> URLCommand? {
      parseMappingCommand(argv: ["flash", "mouse", "screens"] + words)?.command
    }
    XCTAssertEqual(parse([]), .mouseScreens(.init()))
    XCTAssertEqual(parse(["--index=2"]), .mouseScreens(.init(pick: .index(2))))
    XCTAssertEqual(parse(["--direction=next"]), .mouseScreens(.init(pick: .next)))
    XCTAssertEqual(
      parse(["--direction=previous", "--to=last", "--focus"]),
      .mouseScreens(.init(pick: .previous, landing: .last, focus: true)))
    XCTAssertEqual(parse(["--to=center"]), .mouseScreens(.init()))
    for invalid in [
      ["--index=0"], ["--index=two"], ["--direction=up"], ["--to=middle"],
      ["--index=1", "--direction=next"], ["--move"],
    ] {
      XCTAssertNil(parse(invalid), "\(invalid)")
    }
    let commands: [URLCommand] = [
      .mouseScreens(.init()), .mouseScreens(.init(pick: .index(3), focus: true)),
      .mouseScreens(.init(pick: .next, landing: .last)), .mouseScreens(.init(pick: .previous)),
    ]
    for command in commands {
      XCTAssertFalse(command.explanation.isEmpty)
      XCTAssertEqual(parseMappingCommand(argv: command.argv)?.command, command, "\(command.argv)")
    }
    XCTAssertEqual(
      URLCommand.mouseScreens(.init(pick: .index(2), landing: .last, focus: true)).argv,
      ["flash", "mouse", "screens", "--index=2", "--to=last", "--focus"])
  }

  // MARK: NORMAL

  func testGmPicksADisplayAndFocusFollows() throws {
    let defaults = CompiledMappings(Config.Mode.defaultNormalMappings)
    let gm = try XCTUnwrap(NormalModeInterpreter.canonicalizeMappingKey("gm"))
    XCTAssertEqual(
      defaults.mapping(for: gm)?.action, .flashCommand(.mouseScreens(.init(focus: true))))
  }

  /// As `{count}gt` is tab `count`, a count before a display pick is that
  /// display rather than a repeat.
  func testACountBeforeTheScreensKeyPicksThatDisplay() {
    let defaults = CompiledMappings(Config.Mode.defaultNormalMappings)
    func action(_ keys: String) -> (action: MappingCommand, count: Int)? {
      AppDelegate.normalKeysAction(keys, leader: nil, mappings: defaults, recordingMacro: false)
    }
    XCTAssertEqual(
      action("2gm")?.action, .flashCommand(.mouseScreens(.init(pick: .index(2), focus: true))))
    XCTAssertEqual(action("2gm")?.count, 1)
    XCTAssertEqual(action("gm")?.action, .flashCommand(.mouseScreens(.init(focus: true))))
    XCTAssertEqual(action("3gt")?.action, .flashCommand(.tabSelect(index: 3)))
    // A pick that already names its display keeps it; the count repeats.
    let direct = [
      ModeMapping(
        key: NormalModeInterpreter.canonicalizeMappingKey("gm") ?? "gm",
        action: .flashCommand(.mouseScreens(.init(pick: .next))))
    ]
    XCTAssertEqual(
      AppDelegate.normalKeysAction(
        "2gm", leader: nil, mappings: CompiledMappings(direct), recordingMacro: false)?.count, 2)
  }

  // MARK: The session

  func testLabelsAreAHintSessionThatKeepsNormal() throws {
    let delegate = AppDelegate()
    delegate.registry = SourceRegistry(descriptors: [], runningApplications: [])
    delegate.monitor = AppMonitor(registry: delegate.registry, config: delegate.config)
    delegate.overlay = OverlayPanel()
    delegate.modeStore.dispatch(.startup(advancedEnabled: true))
    XCTAssertEqual(delegate.modeStore.mode, .normal)
    delegate.activateScreens(
      .init(landing: .last), layouts: [primary, right], pointer: CGPoint(x: 10, y: 10))
    defer { delegate.cancelOverlay() }
    XCTAssertTrue(delegate.hintSession.isActive)
    XCTAssertEqual(delegate.hintSession.hints.map(\.label), ["1", "2"])
    guard case .screens(let request)? = delegate.hintSession.request else {
      return XCTFail("the session carries its request to the commit")
    }
    XCTAssertEqual(request.landing, .last)
    // Typing a label whose display is no longer connected (these are not the
    // test host's displays) cancels: the pointer stays where it is.
    let pointer = NSEvent.mouseLocation
    delegate.overlayDidCommit(prefix: "2", clickModifiers: [])
    XCTAssertFalse(delegate.hintSession.isActive)
    XCTAssertEqual(NSEvent.mouseLocation, pointer)
    XCTAssertEqual(delegate.modeStore.mode, .normal, "a display pick never enters INSERT")
  }

  func testAnEmptyLayoutStaysSilent() {
    let delegate = AppDelegate()
    delegate.overlay = OverlayPanel()
    delegate.activateScreens(.init(), layouts: [], pointer: .zero)
    XCTAssertFalse(delegate.hintSession.isActive, "no session, no banner")
  }
}
