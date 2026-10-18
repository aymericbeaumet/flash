import AppKit
import Carbon.HIToolbox
import FlashCore
import XCTest

@testable import flash

/// In-session surface switching, path and sticky sessions, word, screen and
/// position verbs, and the grid's edge snap.
final class HintSessionShapesTests: XCTestCase {
  func testTabAndShiftTabSwitchSurfacesOnTheLabelRoute() {
    func action(_ flags: NSEvent.ModifierFlags) -> OverlayKeyAction {
      OverlayInputInterpreter.action(
        keyCode: UInt16(kVK_Tab), modifierFlags: flags, charactersIgnoringModifiers: "\t")
    }
    XCTAssertEqual(action([]), .switchSurface(.grid))
    XCTAssertEqual(action([.shift]), .switchSurface(.scope))
    XCTAssertEqual(action([.command]), .cancel, "a chord on Tab is nothing the labels know")
  }

  func testSurfaceSwitchRequests() {
    let click = MouseCommand.click(.rightClick, modifiers: [.command])
    guard
      case .grid(let request, let context)? = HintSurfaceSwitching.request(
        from: .target(click, nil), kind: .grid)
    else { return XCTFail("a target session moves to the grid") }
    XCTAssertEqual(request, MouseGridRequest(click))
    XCTAssertNil(context)

    guard
      case .grid(let fromAdjust, _)? = HintSurfaceSwitching.request(
        from: .target(.adjust(.leftClick, modifiers: []), nil), kind: .grid)
    else { return XCTFail("an adjust session becomes its click on the grid") }
    XCTAssertEqual(fromAdjust.mouse, .click(.leftClick, modifiers: []))

    guard
      case .grid(let fromMulti, _)? = HintSurfaceSwitching.request(
        from: .target(.multi(.leftClick, modifiers: []), nil), kind: .grid)
    else { return XCTFail("multi exists on the grid") }
    XCTAssertEqual(fromMulti.mouse, .multi(.leftClick, modifiers: []))

    guard
      case .screen(let widened)? = HintSurfaceSwitching.request(
        from: .target(click, nil), kind: .scope)
    else { return XCTFail("Shift-Tab widens a click to the screen") }
    XCTAssertEqual(widened, click)
    guard
      case .target(let narrowed, _)? = HintSurfaceSwitching.request(
        from: .screen(click), kind: .scope)
    else { return XCTFail("Shift-Tab narrows back to the app") }
    XCTAssertEqual(narrowed, click)

    XCTAssertNil(
      HintSurfaceSwitching.request(
        from: .target(.drag(modifiers: []), nil), kind: .scope),
      "screen scope is click-only")
    XCTAssertNil(HintSurfaceSwitching.request(from: .dock, kind: .grid))
    XCTAssertNil(HintSurfaceSwitching.request(from: .pointer, kind: .scope))
    XCTAssertNil(
      HintSurfaceSwitching.request(from: .grid(MouseGridRequest(click), nil), kind: .grid))
  }

  func testAsClickKeepsTheButtonAndModifiersOfASessionShape() {
    XCTAssertEqual(
      MouseCommand.sticky(.doubleClick, modifiers: [.shift]).asClick,
      .click(.doubleClick, modifiers: [.shift]))
    XCTAssertEqual(
      MouseCommand.path(.leftClick, modifiers: []).asClick, .click(.leftClick, modifiers: []))
    XCTAssertEqual(MouseCommand.move.asClick, .move)
    XCTAssertEqual(MouseCommand.select(modifiers: []).asClick, .select(modifiers: []))
  }

  func testPathIndexesRunFromTheFirstPickToTheSecond() {
    XCTAssertEqual(HintPath.indexes(from: 2, to: 5, count: 8), [2, 3, 4, 5])
    XCTAssertEqual(HintPath.indexes(from: 5, to: 2, count: 8), [5, 4, 3, 2])
    XCTAssertEqual(HintPath.indexes(from: 3, to: 3, count: 8), [3])
    XCTAssertEqual(HintPath.indexes(from: 3, to: 9, count: 8), [])
    XCTAssertEqual(HintPath.indexes(from: -1, to: 2, count: 8), [])
  }

  func testMouseTargetParsesThePathStickyAndWordsShapes() {
    func parse(_ args: [String]) -> URLCommand? {
      parseMappingCommand(argv: ["flash", "mouse_target"] + args)?.command
    }
    XCTAssertEqual(parse(["--path"]), .mouseTarget(.path(.leftClick, modifiers: [])))
    XCTAssertEqual(
      parse(["--sticky", "--secondary"]), .mouseTarget(.sticky(.rightClick, modifiers: [])))
    XCTAssertEqual(parse(["--words"]), .mouseTargetWords(.click(.leftClick, modifiers: [])))
    XCTAssertEqual(parse(["--words", "--select"]), .mouseTargetWords(.select(modifiers: [])))
    XCTAssertEqual(parse(["--words", "--move"]), .mouseTargetWords(.move))
    XCTAssertNil(parse(["--words", "--multi"]), "words are a text walk, not a control walk")
    XCTAssertNil(parse(["--words", "--scope=screen"]))
    XCTAssertNil(parse(["--path", "--sticky"]), "one shape per session")
    XCTAssertNil(parse(["--scope=screen", "--sticky"]), "screen scope is click-only")
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse_grid", "--path"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse_grid", "--sticky"]))
    XCTAssertEqual(
      URLCommand.mouseTarget(.path(.doubleClick, modifiers: [.command])).argv,
      ["flash", "mouse_target", "--path", "--double", "--modifiers=cmd"])
    XCTAssertEqual(
      URLCommand.mouseTargetWords(.select(modifiers: [])).argv,
      ["flash", "mouse_target", "--words", "--select"])
  }

  func testScreenWarpAndPositionVerbsParseAndRender() {
    func parse(_ argv: [String]) -> URLCommand? { parseMappingCommand(argv: argv)?.command }
    XCTAssertEqual(parse(["flash", "mouse_screens"]), .mouseScreens)
    XCTAssertNil(parse(["flash", "mouse_screens", "--move"]))
    XCTAssertEqual(parse(["flash", "mouse_warp"]), .mouseWarp(.init()))
    XCTAssertEqual(
      parse(["flash", "mouse_warp", "--area=screen", "--edge=top"]),
      .mouseWarp(.init(area: .screen, edge: .top)))
    XCTAssertNil(parse(["flash", "mouse_warp", "--edge=middle"]))
    XCTAssertEqual(parse(["flash", "mouse_position", "--action=save"]), .mousePosition(.save))
    XCTAssertEqual(parse(["flash", "mouse_position", "--action=next"]), .mousePosition(.next))
    XCTAssertEqual(
      parse(["flash", "mouse_position", "--action=hints", "--move"]),
      .mousePosition(.hints(.move)))
    XCTAssertEqual(
      parse(["flash", "mouse_position", "--action=hints", "--secondary"]),
      .mousePosition(.hints(.click(.rightClick, modifiers: []))))
    XCTAssertNil(parse(["flash", "mouse_position"]))
    XCTAssertNil(parse(["flash", "mouse_position", "--action=save", "--move"]))
    XCTAssertNil(parse(["flash", "mouse_position", "--action=hints", "--drag"]))
    XCTAssertEqual(
      URLCommand.mousePosition(.hints(.move)).argv,
      ["flash", "mouse_position", "--action=hints", "--move"])
    XCTAssertEqual(
      URLCommand.mouseWarp(.init(area: .screen, edge: .left)).argv,
      ["flash", "mouse_warp", "--area=screen", "--edge=left"])
    for command in [
      URLCommand.mouseScreens, .mouseWarp(.init()), .mousePosition(.clear),
      .mouseTarget(.sticky(.leftClick, modifiers: [])), .mouseTargetWords(.move),
      .focusWindow(.cycle(.next)),
    ] {
      XCTAssertFalse(command.explanation.isEmpty)
      XCTAssertEqual(parseMappingCommand(argv: command.argv)?.command, command, "\(command.argv)")
    }
  }

  func testWarpPointsSitInsideTheArea() {
    let frame = CGRect(x: 100, y: 200, width: 400, height: 300)
    XCTAssertEqual(MouseWarpRequest(edge: .center).point(in: frame), CGPoint(x: 300, y: 350))
    XCTAssertEqual(MouseWarpRequest(edge: .top).point(in: frame), CGPoint(x: 300, y: 492))
    XCTAssertEqual(MouseWarpRequest(edge: .bottom).point(in: frame), CGPoint(x: 300, y: 208))
    XCTAssertEqual(MouseWarpRequest(edge: .left).point(in: frame), CGPoint(x: 108, y: 350))
    XCTAssertEqual(MouseWarpRequest(edge: .right).point(in: frame), CGPoint(x: 492, y: 350))
    let tiny = CGRect(x: 0, y: 0, width: 4, height: 4)
    XCTAssertEqual(MouseWarpRequest(edge: .right).point(in: tiny), CGPoint(x: 2, y: 2))
  }

  func testWarpScreenPrefersTheFocusedWindowsDisplayThenThePointers() {
    let left = WindowScreenLayout(
      id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
      usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 760))
    let right = WindowScreenLayout(
      id: 2, frame: CGRect(x: 1000, y: 0, width: 1000, height: 800),
      usableFrame: CGRect(x: 1000, y: 0, width: 1000, height: 760))
    XCTAssertEqual(
      AppDelegate.warpScreenFrame(
        layouts: [left, right], window: CGRect(x: 1200, y: 100, width: 300, height: 300),
        pointer: CGPoint(x: 10, y: 10)),
      right.usableFrame)
    XCTAssertEqual(
      AppDelegate.warpScreenFrame(
        layouts: [left, right], window: nil, pointer: CGPoint(x: 1500, y: 10)),
      right.usableFrame)
    XCTAssertEqual(
      AppDelegate.warpScreenFrame(
        layouts: [left, right], window: .null, pointer: CGPoint(x: -5, y: -5)),
      left.usableFrame)
    XCTAssertNil(AppDelegate.warpScreenFrame(layouts: [], window: nil, pointer: .zero))
  }

  func testScreenTargetsSitOnEachDisplaysCentre() {
    let targets = AppDelegate.screenTargets([
      CGRect(x: 0, y: 0, width: 1000, height: 800),
      CGRect(x: 1000, y: 0, width: 500, height: 400),
      .null,
    ])
    XCTAssertEqual(targets.map(\.id), ["screen_0", "screen_1"])
    XCTAssertEqual(targets[0].frame.midX, 500)
    XCTAssertEqual(targets[0].frame.midY, 400)
    XCTAssertEqual(targets[1].frame.midX, 1250)
    XCTAssertEqual(targets[1].accessibilityLabel, "Display 2")
    XCTAssertEqual(targets[0].priority, .important)
    XCTAssertNil(targets[0].resolveClickPoint, "a display is a coordinate, never revalidated")
  }

  func testPositionTargetsKeepTheOrderPositionsWereSaved() {
    let targets = AppDelegate.positionTargets(
      [CGPoint(x: 10, y: 20), CGPoint(x: 30, y: 40)], pid: 7)
    XCTAssertEqual(targets.map(\.id), ["position_0", "position_1"])
    XCTAssertEqual(targets[1].frame.midX, 30)
    XCTAssertEqual(targets[1].frame.midY, 40)
    XCTAssertEqual(targets[0].pid, 7)
    XCTAssertFalse(targets[0].entersInsertMode)
  }

  func testShiftArrowsSnapTheGridPointerToAnEdge() {
    let qwerty = MouseGrid.Shape.keyboard(Alphabet.gridKeys(layoutName: "qwerty"))
    func cmd(_ keyCode: Int, _ flags: NSEvent.ModifierFlags) -> MouseGridKeyCommand {
      MouseGridInputInterpreter.command(
        keyCode: UInt16(keyCode), modifierFlags: flags, typed: nil, shape: qwerty,
        magicModifiers: .defaultMagic)
    }
    XCTAssertEqual(cmd(kVK_LeftArrow, [.shift]), .snap(.left))
    XCTAssertEqual(cmd(kVK_RightArrow, [.shift, .function]), .snap(.right))
    XCTAssertEqual(cmd(kVK_UpArrow, [.shift]), .snap(.up))
    XCTAssertEqual(cmd(kVK_DownArrow, [.shift]), .snap(.down))
    XCTAssertEqual(cmd(kVK_DownArrow, []), .move(.down))
    let region = CGRect(x: 100, y: 100, width: 200, height: 100)
    XCTAssertEqual(MouseGrid.edgePoint(of: region, .left), CGPoint(x: 102, y: 150))
    XCTAssertEqual(MouseGrid.edgePoint(of: region, .right), CGPoint(x: 298, y: 150))
    XCTAssertEqual(MouseGrid.edgePoint(of: region, .up), CGPoint(x: 200, y: 198))
    XCTAssertEqual(MouseGrid.edgePoint(of: region, .down), CGPoint(x: 200, y: 102))
  }

  func testPointerStepFollowsTheConfiguredSpeed() {
    XCTAssertEqual(
      PointerModeInterpreter.step(streak: 0, fine: false, base: 20, acceleration: 0, maximum: 40),
      20)
    XCTAssertEqual(
      PointerModeInterpreter.step(streak: 5, fine: false, base: 20, acceleration: 0, maximum: 40),
      20)
    XCTAssertEqual(
      PointerModeInterpreter.step(streak: 5, fine: false, base: 20, acceleration: 10, maximum: 40),
      40)
    XCTAssertEqual(
      PointerModeInterpreter.step(streak: 5, fine: true, base: 20, acceleration: 10, maximum: 40),
      2)
    XCTAssertEqual(
      PointerModeInterpreter.step(streak: 0, fine: false, base: 50, acceleration: 6, maximum: 10),
      50, "a ceiling below the base never shrinks the base step")
  }

  func testPointerMarkerColourFollowsTheHeldButton() {
    XCTAssertEqual(OverlayPanel.pointerMarkerColor(held: nil), OverlayPanel.nordFrost2CG)
    let colours = [MouseButtonKind.primary, .secondary, .middle].map {
      OverlayPanel.pointerMarkerColor(held: $0)
    }
    XCTAssertEqual(Set(colours.map { "\($0)" }).count, 3)
    XCTAssertFalse(colours.contains(OverlayPanel.nordFrost2CG))
  }
}
