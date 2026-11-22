import CoreGraphics
import FlashCore
import XCTest

@testable import flash

/// A click chain — `mouse target --multi` (NORMAL's `alt+f`), `--sticky` and
/// the grid's `--multi` — keeps its session up after every click. What one
/// click leads to, what refreshes the labels between picks, and which
/// sessions can chain at all are pure decisions, tested here.
final class ClickChainTests: XCTestCase {
  private func click(
    _ action: JumpAction = .leftClick, modifiers: ClickModifiers = [], menuBar: Bool = false,
    leaves: Bool = false
  ) -> ClickChain.Click {
    ClickChain.Click(
      action: action, modifiers: modifiers, inMenuBar: menuBar, leavesSurface: leaves)
  }

  // MARK: - After a click

  /// `--multi` discovers again after each click, `--sticky` shows the same
  /// labels again.
  func testAChainKeepsGoingAfterAnOrdinaryClick() {
    XCTAssertEqual(ClickChain.step(after: click(), sticky: false), .rediscover)
    XCTAssertEqual(ClickChain.step(after: click(), sticky: true), .relabel)
    XCTAssertEqual(
      ClickChain.step(after: click(.doubleClick, modifiers: [.command]), sticky: false),
      .rediscover, "held Command rides the click and the chain goes on")
    XCTAssertEqual(ClickChain.step(after: click(.middleClick), sticky: false), .rediscover)
  }

  /// No click enters INSERT, so a click on an input is no exception: every
  /// click that opens no menu keeps the chain going, whatever it lands on,
  /// until Escape.
  func testEveryClickThatOpensNoMenuKeepsTheChainGoing() {
    for action in [JumpAction.leftClick, .doubleClick, .tripleClick, .middleClick] {
      for modifiers: ClickModifiers in [[], [.command], [.shift], [.option]] {
        let click = click(action, modifiers: modifiers)
        XCTAssertEqual(ClickChain.step(after: click, sticky: false), .rediscover, "\(action)")
        XCTAssertEqual(ClickChain.step(after: click, sticky: true), .relabel, "\(action)")
      }
    }
  }

  /// A secondary click and a Control-click (macOS's secondary click) open a
  /// context menu, and a click into the menu bar opens a menu: the menu takes
  /// the keyboard, as after `cf`, so the chain ends there.
  func testAClickThatOpensAMenuHandsItTheKeyboard() {
    for sticky in [false, true] {
      XCTAssertEqual(ClickChain.step(after: click(.rightClick), sticky: sticky), .nativeMenu)
      XCTAssertEqual(
        ClickChain.step(after: click(modifiers: [.control]), sticky: sticky), .nativeMenu)
      XCTAssertEqual(ClickChain.step(after: click(menuBar: true), sticky: sticky), .nativeMenu)
    }
    XCTAssertTrue(ClickChain.opensMenu(action: .rightClick, modifiers: []))
    XCTAssertTrue(ClickChain.opensMenu(action: .leftClick, modifiers: [.control, .shift]))
    XCTAssertFalse(ClickChain.opensMenu(action: .leftClick, modifiers: [.command, .option]))
  }

  /// A Mission Control window or desktop leaves Mission Control: nothing the
  /// labels described is on screen any more, so the chain ends.
  func testAClickThatLeavesTheSurfaceEndsTheChain() {
    XCTAssertEqual(ClickChain.step(after: click(leaves: true), sticky: false), .end)
    XCTAssertEqual(ClickChain.step(after: click(leaves: true), sticky: true), .end)
  }

  // MARK: - Between picks

  private func chain(
    _ command: MouseCommand = .multi(.leftClick, modifiers: []), pid: pid_t = 7,
    prefix: String = "", missionControl: DockView? = nil
  ) -> HintSession {
    var session = HintSession()
    session.command = command
    session.sourceAppPID = pid
    session.prefix = prefix
    session.missionControl = missionControl
    session.hints = [
      AssignedHint(
        target: JumpTarget(
          id: "a", frame: CGRect(x: 0, y: 0, width: 20, height: 20), providerID: "ax"),
        label: "a")
    ]
    return session
  }

  /// Controls that load after the click's own walk — a page still arriving,
  /// a list filling in — get labels: the chain's app reporting a change while
  /// the chain waits for its next pick discovers again.
  func testAChangeInTheChainsAppRefreshesItsLabels() {
    XCTAssertTrue(ClickChain.refreshes(chain(), reportedPID: 7, committing: false))
  }

  func testOnlyAWaitingMultiChainOverItsOwnAppRefreshes() {
    XCTAssertFalse(
      ClickChain.refreshes(chain(), reportedPID: 8, committing: false), "another app's change")
    XCTAssertFalse(
      ClickChain.refreshes(chain(), reportedPID: 7, committing: true), "a click is going out")
    XCTAssertFalse(
      ClickChain.refreshes(chain(prefix: "a"), reportedPID: 7, committing: false),
      "a label is half typed")
    XCTAssertFalse(
      ClickChain.refreshes(
        chain(.sticky(.leftClick, modifiers: [])), reportedPID: 7, committing: false),
      "sticky labels never walk again")
    XCTAssertFalse(
      ClickChain.refreshes(
        chain(.click(.leftClick, modifiers: [])), reportedPID: 7, committing: false),
      "a single click is no chain")
    XCTAssertFalse(
      ClickChain.refreshes(
        chain(missionControl: .missionControl), reportedPID: 7, committing: false),
      "Mission Control's labels come from the Dock, not from the app")
    var grid = chain()
    grid.surface = .grid
    XCTAssertFalse(ClickChain.refreshes(grid, reportedPID: 7, committing: false))
    var anchored = chain()
    anchored.phase = .labels(
      anchor: .init(point: .zero, hint: nil))
    XCTAssertFalse(ClickChain.refreshes(anchored, reportedPID: 7, committing: false))
    var empty = chain()
    empty.hints = []
    XCTAssertFalse(ClickChain.refreshes(empty, reportedPID: 7, committing: false))
  }

  /// A pick whose target changed or went away clicks nothing. A `--multi`
  /// chain then discovers again instead of ending; every other session ends.
  func testAChainSurvivesAPickWhoseTargetIsGone() {
    XCTAssertTrue(ClickChain.survivesUnavailableTarget(chain()))
    XCTAssertFalse(ClickChain.survivesUnavailableTarget(chain(.sticky(.leftClick, modifiers: []))))
    XCTAssertFalse(ClickChain.survivesUnavailableTarget(chain(.click(.leftClick, modifiers: []))))
    var grid = chain()
    grid.surface = .grid
    XCTAssertFalse(ClickChain.survivesUnavailableTarget(grid))
  }

  // MARK: - Which sessions chain

  private func parse(_ argv: [String]) -> URLCommand? {
    parseMappingCommand(argv: ["flash", "mouse"] + argv)?.command
  }

  /// A chain repeats a click whose menu would take the keyboard after the
  /// first one, so a repeating session never carries a secondary click.
  func testARepeatingSessionRejectsASecondaryClick() {
    XCTAssertNil(parse(["target", "--multi", "--secondary"]))
    XCTAssertNil(parse(["target", "--sticky", "--secondary"]))
    XCTAssertNil(parse(["target", "--multi", "--modifiers=ctrl"]))
    XCTAssertNil(parse(["target", "--sticky", "--modifiers=cmd+ctrl"]))
    XCTAssertNil(parse(["grid", "--multi", "--secondary"]))
    XCTAssertNil(parse(["grid", "--multi", "--modifiers=ctrl"]))
    XCTAssertEqual(
      parse(["target", "--multi", "--modifiers=cmd"]),
      .mouseTarget(.multi(.leftClick, modifiers: .command)))
    XCTAssertEqual(
      parse(["target", "--multi", "--double"]), .mouseTarget(.multi(.doubleClick, modifiers: [])))
    XCTAssertEqual(
      parse(["target", "--sticky", "--middle"]),
      .mouseTarget(.sticky(.middleClick, modifiers: [])))
    XCTAssertEqual(
      parse(["target", "--secondary", "--modifiers=ctrl"]),
      .mouseTarget(.click(.rightClick, modifiers: .control)), "one secondary click still parses")
  }

  /// Vimium's `<a-f>` opens several links in a row: NORMAL's `alt+f` is the
  /// click chain. Command held on each label opens a link in a background
  /// tab, as Vimium's does.
  func testAltFIsNormalsClickChain() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let bundled = ConfigLoader.parse(
      try String(contentsOf: root.appendingPathComponent("config.default.toml"), encoding: .utf8))
    let key = try XCTUnwrap(NormalModeInterpreter.canonicalizeMappingKey("alt+f"))
    for config in [Config.default, ConfigLoader.parse(""), bundled] {
      XCTAssertEqual(
        config.mode.normal.first { $0.key == key }?.action.command,
        .mouseTarget(.multi(.leftClick, modifiers: [])))
    }
  }
}
