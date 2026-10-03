import CoreGraphics
import FlashCore
import FlashProviders
import XCTest

@testable import flash

final class TargetFinalizerTests: XCTestCase {
  func testExtremeFiniteGeometryCannotOverflowSpatialBuckets() {
    let outer = candidate(
      id: "outer", frame: CGRect(x: -1.1e200, y: -1.1e200, width: 2.2e200, height: 2.2e200))
    let inner = candidate(
      id: "inner", frame: CGRect(x: -1e200, y: -1e200, width: 2e200, height: 2e200))
    let visible = [CGRect(x: -10, y: -10, width: 20, height: 20)]
    XCTAssertEqual(
      TargetFinalizer.finalize([outer, inner], visibleRegions: visible).map(\.id), ["inner"])
  }

  func testVisualRowsHaveTheSameOrderForEveryInputPermutation() {
    let targets = [
      candidate(id: "a", frame: CGRect(x: 20, y: 18, width: 2, height: 2)),
      candidate(id: "b", frame: CGRect(x: 10, y: 12, width: 2, height: 2)),
      candidate(id: "c", frame: CGRect(x: 0, y: 6, width: 2, height: 2)),
    ]
    let visible = [CGRect(x: -100, y: -100, width: 300, height: 300)]
    for order in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
      XCTAssertEqual(
        TargetFinalizer.finalize(order.map { targets[$0] }, visibleRegions: visible)
          .map(\.id), ["b", "a", "c"], "input order: \(order)")
    }
  }

  func testFiltersInvisibleTargetsBeforeLabelsAreAssigned() {
    let visible = CGRect(x: 0, y: 0, width: 200, height: 200)
    let candidates = (0..<700).map { i in
      let frame: CGRect
      if i < 10 {
        frame = CGRect(x: CGFloat(i * 12), y: 20, width: 8, height: 8)
      } else {
        frame = CGRect(x: 1000 + CGFloat(i), y: 1000, width: 8, height: 8)
      }
      return candidate(id: "t\(i)", frame: frame)
    }

    let finalized = TargetFinalizer.finalize(candidates, visibleRegions: [visible])
    XCTAssertEqual(finalized.count, 10)

    let labels = HintAssigner.generateLabels(
      count: finalized.count,
      alphabet: Array("abcdefghijklmnopqrstuvwxyz"))
    XCTAssertEqual(labels.map(\.count).max(), 1)
  }

  func testDedupKeepsBothWhenSmallerIsMuchSmallerThanLarger() {
    let visible = CGRect(x: 0, y: 0, width: 300, height: 300)
    let large = candidate(
      id: "large",
      frame: CGRect(x: 20, y: 20, width: 120, height: 120),
      priority: 20)
    let small = candidate(
      id: "small",
      frame: CGRect(x: 30, y: 30, width: 30, height: 30),
      priority: 10)

    // A small inner control nested inside a much larger clickable
    // container is a legitimate, independent hint target (think
    // `<button><div role="button">…</div></button>` or an icon button
    // inside a wide row link). Both must survive dedup.
    let finalized = TargetFinalizer.finalize([large, small], visibleRegions: [visible])
    XCTAssertEqual(Set(finalized.map(\.id)), Set(["large", "small"]))
  }

  func testDedupCollapsesNearlyIdenticalRectsKeepingSmaller() {
    let visible = CGRect(x: 0, y: 0, width: 300, height: 300)
    let outer = candidate(
      id: "outer",
      frame: CGRect(x: 20, y: 20, width: 100, height: 40),
      priority: 10)
    let inner = candidate(
      id: "inner",
      frame: CGRect(x: 22, y: 22, width: 96, height: 36),
      priority: 10)

    // Same logical control surfaced twice (Firefox's `<a><img/></a>`
    // emitting AXLink and a near-identical AXImage). The smaller —
    // more precise — frame survives.
    let finalized = TargetFinalizer.finalize([outer, inner], visibleRegions: [visible])
    XCTAssertEqual(finalized.map(\.id), ["inner"])
  }

  func testDedupTieKeepsHigherPriorityProvider() {
    let visible = CGRect(x: 0, y: 0, width: 300, height: 300)
    let low = candidate(
      id: "low",
      frame: CGRect(x: 20, y: 20, width: 40, height: 40),
      priority: 10,
      providerOrder: 1)
    let high = candidate(
      id: "high",
      frame: CGRect(x: 20, y: 20, width: 40, height: 40),
      priority: 20,
      providerOrder: 0)

    let finalized = TargetFinalizer.finalize([low, high], visibleRegions: [visible])
    XCTAssertEqual(finalized.map(\.id), ["high"])
  }

  func testDedupCollapsesSubstantiallyOverlappingShiftedTargets() {
    let visible = CGRect(x: 0, y: 0, width: 300, height: 300)
    let first = candidate(
      id: "first",
      frame: CGRect(x: 8, y: 210, width: 100, height: 22))
    let shifted = candidate(
      id: "shifted",
      frame: CGRect(x: 28, y: 206, width: 100, height: 22))

    let finalized = TargetFinalizer.finalize([first, shifted], visibleRegions: [visible])
    XCTAssertEqual(finalized.count, 1)
  }

  func testAPressableContainerNeverDisplacesTheControlItWraps() {
    let visible = [CGRect(x: 0, y: 0, width: 1000, height: 1000)]
    // A wrapper a hair smaller than its link: area order alone keeps the wrapper.
    let link = candidate(
      id: "link", frame: CGRect(x: 10, y: 10, width: 100, height: 20), role: "AXLink")
    let wrapper = candidate(
      id: "wrapper", frame: CGRect(x: 11, y: 11, width: 98, height: 18), role: "AXGroup")
    XCTAssertEqual(
      TargetFinalizer.finalize([wrapper, link], visibleRegions: visible).map(\.id), ["link"])

    // A card around a small link adds its own target: both stay.
    let card = candidate(
      id: "card", frame: CGRect(x: 0, y: 0, width: 460, height: 92), role: "AXGroup")
    XCTAssertEqual(
      Set(TargetFinalizer.finalize([card, link], visibleRegions: visible).map(\.id)),
      ["card", "link"])
  }

  func testAUIKitTextCellNeverDisplacesTheLinkInsideIt() {
    let visible = [CGRect(x: 0, y: 0, width: 1000, height: 1000)]
    // A one-line message whose whole text is a link.
    let link = candidate(
      id: "link", frame: CGRect(x: 10, y: 10, width: 200, height: 20), role: "AXLink")
    let message = candidate(
      id: "message", frame: CGRect(x: 12, y: 12, width: 196, height: 16), role: "AXStaticText")
    XCTAssertEqual(
      TargetFinalizer.finalize([message, link], visibleRegions: visible).map(\.id), ["link"])
  }

  func testATypingSurfaceBeatsTheSameSizeControlLaidOverIt() {
    let visible = [CGRect(x: 0, y: 0, width: 1000, height: 1000)]
    let frame = CGRect(x: 297, y: 202, width: 355, height: 32)
    let overlay = candidate(id: "overlay", frame: frame, role: "AXButton")
    let search = TargetCandidate(
      target: JumpTarget(
        id: "search", frame: frame, role: "AXStaticText", entersInsertMode: true,
        providerID: "test"),
      priority: 10, providerOrder: 0, ordinal: 1)
    XCTAssertFalse(search.target.isGenericContainer)
    XCTAssertEqual(
      TargetFinalizer.finalize([overlay, search], visibleRegions: visible).map(\.id), ["search"])
  }

  func testPressContainersAreControlSizedNotPageRegions() {
    let window = CGRect(x: 0, y: 0, width: 1000, height: 800)
    XCTAssertTrue(
      AccessibilityProvider.pressContainerFits(
        CGRect(x: 0, y: 0, width: 460, height: 92), in: window))
    XCTAssertFalse(
      AccessibilityProvider.pressContainerFits(
        CGRect(x: 0, y: 0, width: 12, height: 40), in: window))
    XCTAssertFalse(
      AccessibilityProvider.pressContainerFits(
        CGRect(x: 0, y: 0, width: 900, height: 700), in: window),
      "a page-wide wrapper with a click listener is not a target")
  }

  private func candidate(
    id: String,
    frame: CGRect,
    role: String? = nil,
    priority: Int = 10,
    providerOrder: Int = 0
  ) -> TargetCandidate {
    TargetCandidate(
      target: JumpTarget(id: id, frame: frame, role: role, pid: 42, providerID: "test"),
      priority: priority,
      providerOrder: providerOrder,
      ordinal: 0)
  }
}
