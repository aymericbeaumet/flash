import CoreGraphics
import FlashCore
import XCTest

@testable import FlashProviders

final class AccessibilityTraversalTests: XCTestCase {
  func testWorklistHandlesDeepSingleChildTreesWithoutRecursion() {
    let maximumDepth = 100_000
    var visited = 0
    var worklist = AXTraversalWorklist(root: 0)

    while let depth = worklist.pop() {
      visited += 1
      if depth < maximumDepth {
        worklist.appendForDepthFirstVisit([depth + 1]) { $0 }
      }
    }

    XCTAssertEqual(visited, maximumDepth + 1)
  }

  func testWorklistPreservesRecursiveDepthFirstSiblingOrder() {
    let children = [
      0: [1, 2, 3],
      1: [4, 5],
      2: [6],
    ]
    var visited: [Int] = []
    var worklist = AXTraversalWorklist(root: 0)

    while let node = worklist.pop() {
      visited.append(node)
      worklist.appendForDepthFirstVisit(children[node] ?? []) { $0 }
    }

    XCTAssertEqual(visited, [0, 1, 4, 5, 2, 6, 3])
  }

  /// A native table walks only its visible rows: every other child (columns,
  /// header, rows AX already dropped from `AXRows`) keeps its place, and the
  /// scrolled-off rows cost no batched read at all.
  func testTableWalksVisibleRowsInsteadOfEveryRow() {
    let rows = (0..<5_000).map { "row\($0)" }
    let children = ["header"] + rows + ["column"]
    let visible = Array(rows[40..<60])
    XCTAssertEqual(
      AccessibilityProvider.tableChildren(children: children, rows: rows, visibleRows: visible),
      ["header"] + visible + ["column"])
  }

  func testVirtualisedTableAppendsVisibleRowsItsChildrenLack() {
    // Some outlines expose their rows only through `AXVisibleRows`.
    XCTAssertEqual(
      AccessibilityProvider.tableChildren(
        children: ["column"], rows: ["a", "b", "c"], visibleRows: ["b", "c"]),
      ["column", "b", "c"])
    XCTAssertEqual(
      AccessibilityProvider.tableChildren(
        children: ["column", "b"], rows: nil, visibleRows: ["b", "c"]),
      ["column", "b", "c"], "unreadable AXRows keeps every child and adds the missing rows")
  }

  func testTableWithoutAVisibleRowListKeepsItsChildren() {
    // An empty or unreadable visible-row list is no evidence that a row is
    // off screen, so nothing is dropped.
    let children = ["header", "a", "b"]
    XCTAssertEqual(
      AccessibilityProvider.tableChildren(children: children, rows: ["a", "b"], visibleRows: nil),
      children)
    XCTAssertEqual(
      AccessibilityProvider.tableChildren(children: children, rows: ["a", "b"], visibleRows: []),
      children)
  }
}

final class OffscreenPruneTests: XCTestCase {
  private let clip = CGRect(x: 0, y: 0, width: 1000, height: 800)

  private func skips(_ frame: CGRect?, depth: Int = 3, insideWebArea: Bool = false) -> Bool {
    AccessibilityProvider.skipsOffscreenSubtree(
      frame: frame, visible: clip, depth: depth, insideWebArea: insideWebArea)
  }

  func testANativeContainerWhollyOutsideTheClipIsSkipped() {
    XCTAssertTrue(skips(CGRect(x: 0, y: -400, width: 1000, height: 300)))
    XCTAssertTrue(skips(CGRect(x: 1200, y: 0, width: 200, height: 800)))
    XCTAssertFalse(skips(CGRect(x: 0, y: -400, width: 1000, height: 401)))
    XCTAssertFalse(skips(CGRect(x: 100, y: 100, width: 50, height: 50)))
  }

  func testTheRootAndFramelessContainersAreAlwaysWalked() {
    let away = CGRect(x: 0, y: -4000, width: 1000, height: 300)
    XCTAssertFalse(skips(away, depth: 0))
    XCTAssertFalse(skips(nil))
    XCTAssertFalse(skips(CGRect(x: 0, y: -4000, width: 0, height: 300)))
  }

  /// A web container can hold a `position: fixed` control that renders on
  /// screen however far away the container's own box lies (a page footer's
  /// "Back to top" link), so no web container is ever skipped.
  func testWebContainersAreAlwaysWalkedHoweverFarOffscreen() {
    XCTAssertFalse(skips(CGRect(x: 60, y: -9_000, width: 1000, height: 109), insideWebArea: true))
    XCTAssertFalse(skips(CGRect(x: 5_000, y: 0, width: 300, height: 800), insideWebArea: true))
  }
}

final class HintPointCandidateTests: XCTestCase {
  func testThePreferredPointIsAlwaysProbedFirst() {
    let frame = CGRect(x: 100, y: 200, width: 400, height: 40)
    let preferred = CGPoint(x: 300, y: 220)
    let candidates = AccessibilityProvider.hintPointCandidates(preferred: preferred, in: frame)
    XCTAssertEqual(candidates.first, preferred)
  }

  func testAWideRowOffersEdgeProbesAwayFromItsMidpoint() {
    // The failure this covers: a list row whose centre is covered by a button
    // or a link. One probe vetoed the whole gesture and the click vanished.
    let frame = CGRect(x: 0, y: 0, width: 600, height: 40)
    let candidates = AccessibilityProvider.hintPointCandidates(
      preferred: CGPoint(x: 300, y: 20), in: frame)
    XCTAssertGreaterThan(candidates.count, 1)
    for candidate in candidates {
      XCTAssertTrue(frame.contains(candidate), "probe \(candidate) escaped \(frame)")
    }
    XCTAssertTrue(candidates.contains { $0.x < 100 }, "no probe near the leading edge")
    XCTAssertTrue(candidates.contains { $0.x > 500 }, "no probe near the trailing edge")
  }

  func testProbesStayInsideATinyTarget() {
    let frame = CGRect(x: 10, y: 10, width: 4, height: 4)
    let candidates = AccessibilityProvider.hintPointCandidates(
      preferred: CGPoint(x: 12, y: 12), in: frame)
    for candidate in candidates {
      XCTAssertTrue(frame.contains(candidate), "probe \(candidate) escaped \(frame)")
    }
  }

  func testADegeneratedFrameFallsBackToThePreferredPointAlone() {
    let preferred = CGPoint(x: 5, y: 6)
    XCTAssertEqual(
      AccessibilityProvider.hintPointCandidates(preferred: preferred, in: .zero), [preferred])
  }

  func testDuplicateProbesAreDropped() {
    let frame = CGRect(x: 0, y: 0, width: 8, height: 8)
    let candidates = AccessibilityProvider.hintPointCandidates(
      preferred: CGPoint(x: 2, y: 4), in: frame)
    for (index, candidate) in candidates.enumerated() {
      for other in candidates[(index + 1)...] {
        XCTAssertFalse(
          abs(other.x - candidate.x) < 1 && abs(other.y - candidate.y) < 1,
          "duplicate probe \(candidate)")
      }
    }
  }

  /// A terminal emulator's window is one typing surface: a primary hint click
  /// anywhere in it hands the keyboard to the terminal, so every target the
  /// walk finds there enters INSERT. Which apps are terminals is plugin data
  /// (manifest `terminal_emulators`); other apps keep the per-role judgement.
  func testTerminalEmulatorTargetsEnterInsertAndOtherAppsKeepTheirRoleJudgement() {
    let targets = [
      JumpTarget(
        id: "content", frame: CGRect(x: 0, y: 0, width: 400, height: 300),
        role: "AXTextArea", entersInsertMode: true, providerID: "ax"),
      JumpTarget(
        id: "tab", frame: CGRect(x: 0, y: 300, width: 80, height: 20),
        role: "AXButton", providerID: "ax"),
    ]
    let isTerminal: (String) -> Bool = { $0 == "com.mitchellh.ghostty" }

    let terminal = AccessibilityProvider.settlingInsertIntent(
      targets, bundleIdentifier: "com.mitchellh.ghostty", isTerminalEmulator: isTerminal)
    XCTAssertEqual(terminal.map(\.id), ["content", "tab"])
    XCTAssertEqual(terminal.map(\.entersInsertMode), [true, true])

    let editor = AccessibilityProvider.settlingInsertIntent(
      targets, bundleIdentifier: "com.apple.TextEdit", isTerminalEmulator: isTerminal)
    XCTAssertEqual(editor.map(\.entersInsertMode), [true, false])
  }
}
