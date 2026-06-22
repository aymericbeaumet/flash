import CoreGraphics
import XCTest

@testable import flash

final class WindowSnapshotTests: XCTestCase {
  func testFocusedWindowVisibleRegionSubtractsHigherZWindows() {
    let focused = WindowSnapshot.Entry(
      pid: 42,
      layer: 0,
      nsBounds: CGRect(x: 0, y: 0, width: 100, height: 100))
    let occluder = WindowSnapshot.Entry(
      pid: 7,
      layer: 0,
      nsBounds: CGRect(x: 25, y: 25, width: 50, height: 50))

    let snapshot = WindowSnapshot.build(entries: [occluder, focused], focusedPid: 42)

    XCTAssertEqual(snapshot.activeWindowFrame, focused.nsBounds)
    let visible = snapshot.visibleRegions[42] ?? []
    XCTAssertEqual(visible.count, 4)
    let visibleArea = visible.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
    XCTAssertEqual(visibleArea, 7_500)
    XCTAssertFalse(visible.contains { $0.contains(CGPoint(x: 50, y: 50)) })
  }

  func testOnlyFrontMostFocusedWindowIsHintable() {
    let front = WindowSnapshot.Entry(
      pid: 42,
      layer: 0,
      nsBounds: CGRect(x: 0, y: 0, width: 80, height: 80))
    let backSamePid = WindowSnapshot.Entry(
      pid: 42,
      layer: 0,
      nsBounds: CGRect(x: 100, y: 100, width: 80, height: 80))

    let snapshot = WindowSnapshot.build(entries: [front, backSamePid], focusedPid: 42)

    XCTAssertEqual(snapshot.activeWindowFrame, front.nsBounds)
    XCTAssertEqual(snapshot.visibleRegions[42], [front.nsBounds])
  }

  func testFocusedHighLayerPopupBecomesActiveSurface() {
    let popup = WindowSnapshot.Entry(
      pid: 42,
      layer: Int(CGWindowLevelForKey(.floatingWindow)),
      nsBounds: CGRect(x: 20, y: 20, width: 40, height: 40))
    let main = WindowSnapshot.Entry(
      pid: 42,
      layer: 0,
      nsBounds: CGRect(x: 0, y: 0, width: 100, height: 100))

    let snapshot = WindowSnapshot.build(entries: [popup, main], focusedPid: 42)

    XCTAssertEqual(snapshot.activeWindowFrame, popup.nsBounds)
    XCTAssertEqual(snapshot.visibleRegions[42], [popup.nsBounds])
    XCTAssertEqual(
      WindowSnapshot.topApplicationWindowFrame(entries: [popup, main], focusedPid: 42),
      main.nsBounds)
  }

  func testOtherPidHighLayerWindowOnlyOccludesFocusedSurface() {
    let statusPopover = WindowSnapshot.Entry(
      pid: 7,
      layer: Int(CGWindowLevelForKey(.statusWindow)),
      nsBounds: CGRect(x: 25, y: 25, width: 50, height: 50))
    let focused = WindowSnapshot.Entry(
      pid: 42,
      layer: 0,
      nsBounds: CGRect(x: 0, y: 0, width: 100, height: 100))

    let snapshot = WindowSnapshot.build(entries: [statusPopover, focused], focusedPid: 42)

    XCTAssertEqual(snapshot.activeWindowFrame, focused.nsBounds)
    XCTAssertNil(snapshot.visibleRegions[7])
    let visibleArea = (snapshot.visibleRegions[42] ?? []).reduce(CGFloat(0)) {
      $0 + $1.width * $1.height
    }
    XCTAssertEqual(visibleArea, 7_500)
  }

  func testTopInteractionEntryAtPointUsesZOrderAndIgnoresFlashPID() {
    let frontFlashOverlay = WindowSnapshot.Entry(
      pid: 99,
      layer: Int(CGWindowLevelForKey(.statusWindow)),
      nsBounds: CGRect(x: 0, y: 0, width: 200, height: 200))
    let clickedTerminal = WindowSnapshot.Entry(
      pid: 42,
      layer: 0,
      nsBounds: CGRect(x: 10, y: 10, width: 100, height: 100))
    let oldFrontmostBrowser = WindowSnapshot.Entry(
      pid: 7,
      layer: 0,
      nsBounds: CGRect(x: 150, y: 10, width: 100, height: 100))

    XCTAssertEqual(
      WindowSnapshot.topInteractionEntry(
        at: CGPoint(x: 25, y: 25),
        entries: [frontFlashOverlay, clickedTerminal, oldFrontmostBrowser],
        ignoringPids: [99])?.pid,
      42)
    XCTAssertNil(
      WindowSnapshot.topInteractionEntry(
        at: CGPoint(x: 300, y: 25),
        entries: [frontFlashOverlay, clickedTerminal, oldFrontmostBrowser],
        ignoringPids: [99]))
  }

  func testCGWindowInfoEntriesConvertToNSScreenCoordinates() {
    let info: [[String: Any]] = [
      [
        kCGWindowOwnerPID as String: Int32(42),
        kCGWindowLayer as String: 0,
        kCGWindowBounds as String: [
          "X": 10,
          "Y": 20,
          "Width": 200,
          "Height": 100,
        ],
      ],
      [
        kCGWindowOwnerPID as String: Int32(99),
        kCGWindowLayer as String: 0,
        kCGWindowBounds as String: [
          "X": 0,
          "Y": 0,
          "Width": 0,
          "Height": 100,
        ],
      ],
    ]

    let entries = WindowSnapshot.entries(from: info, primaryH: 900)

    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries[0].pid, 42)
    XCTAssertEqual(entries[0].nsBounds, CGRect(x: 10, y: 780, width: 200, height: 100))
  }
}
