import AppKit
import FlashCore
import XCTest

@testable import flash

final class WindowSwitcherTests: XCTestCase {
  private func window(
    _ id: String, pid: pid_t, minimized: Bool = false, onActiveSpace: Bool = true
  ) -> WindowSwitcherWindow<String> {
    WindowSwitcherWindow(
      id: id, pid: pid, title: id.uppercased(), minimized: minimized,
      onActiveSpace: onActiveSpace)
  }

  func testFocusInTheFrontmostAppMakesThatWindowTheMostRecent() {
    var recency = WindowRecency<String>()
    recency.appActivated(1)
    recency.focusResolved("a1", pid: 1)
    recency.focusResolved("a2", pid: 1)
    recency.appActivated(2)
    recency.focusResolved("b1", pid: 2)
    XCTAssertEqual(recency.windows, ["b1", "a2", "a1"])
    XCTAssertEqual(recency.current, "b1")
    XCTAssertEqual(recency.apps, [2, 1])
  }

  func testBackgroundFocusIsRememberedButNotPromoted() {
    var recency = WindowRecency<String>()
    recency.appActivated(1)
    recency.focusResolved("a1", pid: 1)
    recency.appActivated(2)
    recency.focusResolved("b1", pid: 2)
    // App 1 closed a1 in the background; its focus moved to a2 on its own.
    recency.focusResolved("a2", pid: 1)
    XCTAssertEqual(recency.windows, ["b1", "a1"], "the user did not choose a2")
    // Coming back to app 1 lands in a2: an activation that resolves no new
    // focused window still promotes the app's focused one.
    recency.appActivated(1)
    XCTAssertEqual(recency.windows, ["a2", "b1", "a1"])
    XCTAssertEqual(recency.current, "a2")
  }

  func testActivationBeforeItsFocusResolvesStillOrdersByTheUsersChoice() {
    var recency = WindowRecency<String>()
    recency.appActivated(1)
    recency.focusResolved("a1", pid: 1)
    recency.appActivated(2)  // a new app: no focused window known yet
    XCTAssertEqual(recency.windows, ["a1"])
    recency.focusResolved("b1", pid: 2)
    XCTAssertEqual(recency.windows, ["b1", "a1"])
  }

  func testRemovingAWindowOrAnAppForgetsThem() {
    var recency = WindowRecency<String>()
    recency.appActivated(1)
    recency.focusResolved("a1", pid: 1)
    recency.appActivated(2)
    recency.focusResolved("b1", pid: 2)
    recency.focusResolved("b2", pid: 2)
    recency.remove("b2")
    XCTAssertEqual(recency.windows, ["b1", "a1"])
    XCTAssertNil(recency.current, "the focused window closed")
    recency.removeApp(2, windows: ["b1"])
    XCTAssertEqual(recency.windows, ["a1"])
    XCTAssertEqual(recency.apps, [1])
    XCTAssertNil(recency.frontmost)
  }

  func testRecencyKeepsABoundedHistory() {
    var recency = WindowRecency<Int>()
    recency.appActivated(1)
    for id in 0..<(WindowRecency<Int>.capacity + 10) {
      recency.focusResolved(id, pid: 1)
    }
    XCTAssertEqual(recency.windows.count, WindowRecency<Int>.capacity)
    XCTAssertEqual(recency.windows.first, WindowRecency<Int>.capacity + 9)
  }

  func testRowsListFocusedWindowsFirstThenTheRestByAppRecency() {
    var recency = WindowRecency<String>()
    recency.appActivated(1)
    recency.focusResolved("a2", pid: 1)
    recency.appActivated(2)
    recency.focusResolved("b1", pid: 2)
    let catalog: [pid_t: [WindowSwitcherWindow<String>]] = [
      1: [window("a1", pid: 1), window("a2", pid: 1), window("a3", pid: 1, minimized: true)],
      2: [window("b1", pid: 2), window("b2", pid: 2, onActiveSpace: false)],
      3: [window("c1", pid: 3)],
      4: [window("d1", pid: 4)],
    ]
    let rows = WindowSwitcherPlanner.rows(
      recency: recency, catalog: catalog, catalogOrder: [4, 3, 2, 1])
    XCTAssertEqual(
      rows.map(\.id), ["b1", "a2", "b2", "a1", "a3", "d1", "c1"],
      "focused windows, then app 2's and app 1's others, then never-active apps in catalog order")
  }

  func testRowsDropRememberedWindowsTheCatalogNoLongerHas() {
    var recency = WindowRecency<String>()
    recency.appActivated(1)
    recency.focusResolved("a1", pid: 1)
    recency.focusResolved("gone", pid: 1)
    let rows = WindowSwitcherPlanner.rows(
      recency: recency, catalog: [1: [window("a1", pid: 1)]], catalogOrder: [1])
    XCTAssertEqual(rows.map(\.id), ["a1"])
  }

  func testSelectionStartsOnThePreviousWindowLikeCommandTab() {
    let rows = [window("a", pid: 1), window("b", pid: 2), window("c", pid: 3)]
    XCTAssertEqual(WindowSwitcherPlanner.initialSelection(rows: rows, current: "a"), 1)
    XCTAssertEqual(
      WindowSwitcherPlanner.initialSelection(rows: rows, current: "z"), 0,
      "the user is in none of the rows: the most recent one is the way back")
    XCTAssertEqual(WindowSwitcherPlanner.initialSelection(rows: rows, current: nil), 0)
    XCTAssertEqual(
      WindowSwitcherPlanner.initialSelection(rows: [window("a", pid: 1)], current: "a"), 0)
  }

  func testSelectionWrapsBothWays() {
    XCTAssertEqual(WindowSwitcherPlanner.step(2, by: 1, count: 3), 0)
    XCTAssertEqual(WindowSwitcherPlanner.step(0, by: -1, count: 3), 2)
    XCTAssertEqual(WindowSwitcherPlanner.step(1, by: 1, count: 3), 2)
    XCTAssertEqual(WindowSwitcherPlanner.step(0, by: 1, count: 0), 0)
  }

  // MARK: Labels and order

  func testTheEasiestLabelGoesToTheRowTheSelectionStartsOn() {
    XCTAssertEqual(WindowSwitcherPlanner.labelOrder(count: 4, first: 1), [1, 2, 3, 0])
    XCTAssertEqual(WindowSwitcherPlanner.labelOrder(count: 3, first: 0), [0, 1, 2])
    XCTAssertEqual(WindowSwitcherPlanner.labelOrder(count: 2, first: 5), [1, 0])
    XCTAssertEqual(WindowSwitcherPlanner.labelOrder(count: 0, first: 0), [])
  }

  func testAppsNeverActivatedFollowTheStackingOrderThenLaunchOrder() {
    XCTAssertEqual(
      WindowSwitcherPlanner.appOrder(stacked: [3, 9, 3, 1], running: [1, 2, 3, 4]),
      [3, 1, 2, 4], "stacked apps first, front first; 9 is no listed app")
  }

  func testOneBadgeSaysWhereTheWindowIs() {
    func row(_ window: WindowSwitcherWindow<String>, hidden: Bool = false)
      -> WindowSwitcherRow<String>
    {
      WindowSwitcherRow(window: window, label: "a", app: "App", appHidden: hidden)
    }
    XCTAssertNil(row(window("a", pid: 1)).badge)
    XCTAssertEqual(
      row(window("a", pid: 1, minimized: true, onActiveSpace: false), hidden: true).badge,
      .minimized)
    XCTAssertEqual(row(window("a", pid: 1, onActiveSpace: false), hidden: true).badge, .hidden)
    XCTAssertEqual(row(window("a", pid: 1, onActiveSpace: false)).badge, .otherSpace)
  }

  // MARK: Keys

  private func command(
    _ keyCode: UInt16, _ typed: String? = nil, _ flags: NSEvent.ModifierFlags = []
  ) -> WindowSwitcherKeyCommand? {
    WindowSwitcherInterpreter.command(keyCode: keyCode, typed: typed, modifierFlags: flags)
  }

  func testNavigationKeysAreTheOnesAltTabUsersExpect() {
    XCTAssertEqual(command(48, "\t"), .move(1))
    XCTAssertEqual(command(48, "\t", [.shift]), .move(-1))
    XCTAssertEqual(command(125), .move(1))
    XCTAssertEqual(command(124), .move(1))
    XCTAssertEqual(command(126), .move(-1))
    XCTAssertEqual(command(123), .move(-1))
    XCTAssertEqual(command(36, "\r"), .choose)
    XCTAssertEqual(command(76), .choose)
    XCTAssertEqual(command(53, "\u{1b}", [.option]), .cancel)
    XCTAssertEqual(command(51), .backspace)
  }

  func testEveryOtherKeyTypesALabelWhateverModifierIsHeld() {
    XCTAssertEqual(command(2, "d"), .type("d"))
    XCTAssertEqual(command(2, "D", [.shift]), .type("d"))
    XCTAssertEqual(command(2, "d", [.option]), .type("d"))
    XCTAssertEqual(command(41, ";"), .type(";"))
    XCTAssertNil(command(122, nil), "a key with no character does nothing")
  }

  // MARK: Session

  private func state(selection: Int = 1, labels: [String] = ["d", "s", "fa", "fs"])
    -> WindowSwitcherState<String>
  {
    let rows = labels.enumerated().map { index, label in
      WindowSwitcherRow(
        window: window("w\(index)", pid: pid_t(index)), label: label, app: "App",
        appHidden: false)
    }
    return WindowSwitcherState(rows: rows, selection: selection)
  }

  func testMovingWrapsAndForgetsATypedPrefix() {
    var switcher = state(selection: 3)
    XCTAssertEqual(switcher.apply(.type("f")), .redraw)
    XCTAssertEqual(switcher.typed, "f")
    XCTAssertEqual(switcher.apply(.move(1)), .redraw)
    XCTAssertEqual(switcher.selection, 0)
    XCTAssertEqual(switcher.typed, "")
    XCTAssertEqual(switcher.apply(.move(-1)), .redraw)
    XCTAssertEqual(switcher.selection, 3)
  }

  func testALabelChoosesItsWindowInOneKeyOrTwo() {
    var switcher = state()
    XCTAssertEqual(switcher.apply(.type("s")), .choose(switcher.rows[1]))
    XCTAssertEqual(switcher.apply(.type("f")), .redraw)
    XCTAssertEqual(switcher.apply(.type("s")), .choose(switcher.rows[3]))
  }

  func testAKeyNoLabelStartsWithIsIgnoredAndBackspaceEdits() {
    var switcher = state()
    XCTAssertEqual(switcher.apply(.type("z")), .ignore, "a stray key keeps the list up")
    XCTAssertEqual(switcher.apply(.backspace), .ignore)
    XCTAssertEqual(switcher.apply(.type("f")), .redraw)
    XCTAssertEqual(switcher.apply(.type("z")), .ignore)
    XCTAssertEqual(switcher.typed, "f")
    XCTAssertEqual(switcher.apply(.backspace), .redraw)
    XCTAssertEqual(switcher.typed, "")
  }

  func testReturnChoosesTheSelectionAndEscapeCancels() {
    var switcher = state(selection: 2)
    XCTAssertEqual(switcher.apply(.choose), .choose(switcher.rows[2]))
    XCTAssertEqual(switcher.apply(.move(1)), .redraw)
    XCTAssertEqual(switcher.apply(.choose), .choose(switcher.rows[3]))
    XCTAssertEqual(switcher.apply(.cancel), .cancel)
  }

  func testAnEmptyListChoosesNothing() {
    var switcher = WindowSwitcherState<String>(rows: [], selection: 3)
    XCTAssertEqual(switcher.selection, 0)
    XCTAssertEqual(switcher.apply(.move(1)), .ignore)
    XCTAssertEqual(switcher.apply(.choose), .cancel)
  }

  // MARK: Layout

  func testTheBoxIsCentredAndItsRowsFollowTheSelection() {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let layout = WindowSwitcherLayout.make(
      screen: screen, rowCount: 100, selection: 50, rowHeight: 28, chipWidth: 16,
      appWidth: 80, titleWidth: 200, badgeWidth: 0)
    XCTAssertEqual(layout.visible, 41..<60, "19 rows fit in 70% of the height")
    XCTAssertEqual(layout.box.height, 20 + 19 * 28)
    XCTAssertEqual(layout.box.midX, screen.midX, accuracy: 1)
    XCTAssertEqual(layout.box.midY, screen.midY, accuracy: 1)
    XCTAssertEqual(layout.rowFrame(41).maxY, layout.box.height - 10, "the first row is on top")
    XCTAssertEqual(layout.rowFrame(42).maxY, layout.rowFrame(41).minY)
  }

  func testTheBoxIsAsWideAsItsLongestRowWithinBounds() {
    let screen = CGRect(x: 100, y: 50, width: 1000, height: 800)
    func width(title: CGFloat, app: CGFloat = 80, badge: CGFloat = 0) -> CGFloat {
      WindowSwitcherLayout.make(
        screen: screen, rowCount: 3, selection: 0, rowHeight: 28, chipWidth: 16,
        appWidth: app, titleWidth: title, badgeWidth: badge
      ).box.width
    }
    XCTAssertEqual(width(title: 10), WindowSwitcherLayout.minimumWidth)
    XCTAssertEqual(width(title: 5_000), 600, "at most 60% of the display")
    XCTAssertEqual(width(title: 300), 20 + 16 + 8 + 20 + 8 + 80 + 8 + 300)
    XCTAssertEqual(width(title: 300, app: 900), 20 + 16 + 8 + 20 + 8 + 200 + 8 + 300 - 0)
    XCTAssertEqual(
      WindowSwitcherLayout.make(
        screen: screen, rowCount: 3, selection: 0, rowHeight: 28, chipWidth: 16,
        appWidth: 80, titleWidth: 300, badgeWidth: 60
      ).titleColumn, 300)
  }

  func testWhichKeyShowsEverySelectorInBoundedColumns() {
    for size in [CGSize(width: 1440, height: 900), CGSize(width: 800, height: 600)] {
      let screen = CGRect(origin: .zero, size: size)
      let layout = WindowSwitcherLayout.make(
        screen: screen, rowCount: 66, selection: 0, rowHeight: 28, chipWidth: 40,
        appWidth: 0, titleWidth: 5000, badgeWidth: 0, showsAllRows: true)
      XCTAssertEqual(layout.visible, 0..<66)
      XCTAssertTrue(screen.contains(layout.box))
      let bounds = CGRect(origin: .zero, size: layout.box.size)
      for index in layout.visible {
        XCTAssertTrue(bounds.contains(layout.rowFrame(index)), "row \(index), \(size)")
        XCTAssertGreaterThanOrEqual(layout.rowFrame(index).width, 40)
        for earlier in layout.visible where earlier < index {
          XCTAssertFalse(layout.rowFrame(earlier).intersects(layout.rowFrame(index)))
        }
      }
    }
  }

  func testAnExtremePaletteHasBoundedChipsAndExplicitOverflow() {
    let screen = CGRect(x: 0, y: 0, width: 800, height: 600)
    let layout = WindowSwitcherLayout.make(
      screen: screen, rowCount: 1000, selection: 0, rowHeight: 28, chipWidth: 5000,
      appWidth: 0, titleWidth: 5000, badgeWidth: 0, showsAllRows: true)
    XCTAssertTrue(screen.contains(layout.box))
    XCTAssertGreaterThan(layout.hiddenRowCount, 0)
    XCTAssertEqual(layout.visible.count + layout.hiddenRowCount, 1000)
    for index in layout.visible {
      XCTAssertGreaterThan(layout.rowFrame(index).width, layout.chipWidth)
      XCTAssertGreaterThanOrEqual(layout.rowFrame(index).minY, 10 + layout.rowHeight)
    }
  }

  func testModifiedNextKeysFitWithoutLosingTheirModifiers() {
    let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .bold)
    let nextKeys = ["cmd+<down>", "ctrl+<down>"]
    let requiredWidth = nextKeys.map {
      ceil(($0 as NSString).size(withAttributes: [.font: font]).width) + 20
    }.max()!
    let layout = WindowSwitcherLayout.make(
      screen: CGRect(x: 0, y: 0, width: 800, height: 600),
      rowCount: 79, selection: 0, rowHeight: 28, chipWidth: 5000,
      appWidth: 0, titleWidth: 5000, badgeWidth: 0, showsAllRows: true,
      minimumChipWidth: requiredWidth)
    XCTAssertGreaterThanOrEqual(layout.chipWidth, requiredWidth)
    XCTAssertGreaterThan(
      layout.hiddenRowCount, 0,
      "fewer columns and explicit overflow preserve the complete next key")
  }

  func testRealRegisterPaletteFitsEveryLiteralSelectorAtDefaultFontSizes() {
    let palette = WhichKey.rows(after: "\"", in: CompiledMappings([]))
    XCTAssertEqual(palette.entries.count, 66)
    for fontSize: CGFloat in [12, 14] {
      let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
      let requiredWidth = palette.entries.map {
        let next = String($0.label.dropFirst(palette.typed.count))
        return ceil(((next + "…") as NSString).size(withAttributes: [.font: font]).width) + 6
      }.max()!
      let fullWidth = palette.entries.map {
        ceil(($0.label as NSString).size(withAttributes: [.font: font]).width) + 6
      }.max()!
      for size in [CGSize(width: 1440, height: 900), CGSize(width: 800, height: 600)] {
        let layout = WindowSwitcherLayout.make(
          screen: CGRect(origin: .zero, size: size), rowCount: palette.entries.count,
          selection: 0, rowHeight: 28, chipWidth: fullWidth,
          appWidth: 0, titleWidth: 200, badgeWidth: 0, showsAllRows: true,
          minimumChipWidth: requiredWidth)
        XCTAssertEqual(layout.visible.count, 66, "font \(fontSize), \(size)")
        XCTAssertEqual(layout.hiddenRowCount, 0)
        XCTAssertGreaterThanOrEqual(layout.chipWidth, requiredWidth)
      }
    }
  }

  // MARK: Reading an app's windows

  private func element(_ index: Int32) -> AXUIElement { AXApp.make(pid: 70_000 + index) }

  func testListedWindowsAreOnTheActiveSpaceAndLiveRememberedOnesElsewhere() throws {
    let reads: [AXUIElement: WindowSwitcherCatalog.WindowRead] = [
      element(1): .init(title: "one", minimized: false, switchable: true),
      element(2): .init(title: "two", minimized: true, switchable: true),
      element(3): .init(title: "palette", minimized: false, switchable: false),
      element(4): .init(title: "elsewhere", minimized: false, switchable: true),
      element(6): .init(title: "docked", minimized: true, switchable: true),
    ]
    let windows = try XCTUnwrap(
      WindowSwitcherCatalog.windows(
        pid: 7, listed: [element(1), element(2), element(3)],
        remembered: [element(1), element(4), element(5), element(6)],
        read: { reads[$0].map { .window($0) } ?? .gone }))
    XCTAssertEqual(windows.map(\.title), ["one", "two", "elsewhere", "docked"])
    XCTAssertEqual(windows.map(\.onActiveSpace), [true, true, false, true])
    XCTAssertEqual(windows.map(\.minimized), [false, true, false, true])
    XCTAssertTrue(windows.allSatisfy { $0.pid == 7 && $0.id.pid == 7 })
  }

  func testAnAppThatStopsAnsweringKeepsItsLastGoodWindows() {
    var asked = 0
    let windows = WindowSwitcherCatalog.windows(
      pid: 7, listed: [element(1), element(2), element(3)], remembered: [],
      read: { element in
        asked += 1
        return element == self.element(2)
          ? .unresponsive : .window(.init(title: "w", minimized: false, switchable: true))
      })
    XCTAssertNil(windows)
    XCTAssertEqual(asked, 2, "no timeout per remaining window")
  }

  // MARK: Session phase and drawing

  func testTheListIsAHintSessionPhaseThatOwnsTheKeys() {
    var session = HintSession()
    let switcher = WindowSwitcherState<WindowSwitcherKey>(rows: [], selection: 0)
    session.phase = .switching(switcher)
    XCTAssertEqual(session.keyRoute, .switcher)
    XCTAssertTrue(session.isActive, "the list owns the keyboard without hint chips")
    XCTAssertEqual(session.windowSwitcher, switcher)
    XCTAssertNil(session.confirmation)
    XCTAssertEqual(
      FlashStatusReport.hintSessionPhase(route: .switcher, active: true, discovering: false),
      "window_switcher")
  }

  func testTheOverlayDrawsOneLabeledRowPerVisibleWindow() throws {
    _ = NSApplication.shared
    let panel = OverlayPanel()
    defer {
      panel.hide()
      panel.orderOut(nil)
    }
    let rows = ["D", "S", "F"].enumerated().map { index, label in
      WindowSwitcherDisplay.Row(
        label: label, app: "App \(index)", title: "Title \(index)",
        badge: index == 2 ? "minimized" : nil, icon: nil)
    }
    panel.displayWindowSwitcher(.init(rows: rows, selection: 1, typed: "", anchor: nil))
    XCTAssertTrue(panel.transientContentVisible)
    let box = try XCTUnwrap(panel.contentLayer.sublayers?.first { $0.cornerRadius == 10 })
    let layers = box.sublayers ?? []
    XCTAssertEqual(layers.filter { $0 is CAGradientLayer }.count, 3, "one label chip per row")
    let texts = layers.compactMap { ($0 as? CATextLayer)?.string as? String }
    XCTAssertEqual(
      texts, ["App 0", "Title 0", "App 1", "Title 1", "App 2", "Title 2", "minimized"])
    XCTAssertEqual(
      layers.filter { !($0 is CAGradientLayer) && !($0 is CATextLayer) }.count, 1,
      "the selected row's highlight")

    panel.hide()
    XCTAssertFalse(panel.transientContentVisible)
    XCTAssertFalse(panel.contentLayer.sublayers?.contains { $0 === box } ?? false)
  }

  // MARK: The resident

  func testWithNoWindowsTheSwitcherStaysSilent() {
    let delegate = AppDelegate()
    delegate.overlay = OverlayPanel()
    delegate.performWindowSwitch()
    XCTAssertNil(delegate.hintSession.windowSwitcher)
    XCTAssertFalse(delegate.hintSession.isActive, "no session, no banner")
  }
}
