import CoreGraphics
import XCTest

@testable import flash

final class MouseGridPreviewTests: XCTestCase {
  private let shape = MouseGrid.Shape.keyboard([
    ["1", "2", "3", "4", "5"], ["q", "w", "e", "r", "t"], ["a", "s", "d", "f", "g"],
    ["z", "x", "c", "v", "b"],
  ])
  private let region = CGRect(x: 0, y: 0, width: 2000, height: 1200)
  private let chip = CGSize(width: 18, height: 16)
  private let bigram = CGSize(width: 28, height: 16)

  /// A drilling step previews the step after each of its cells: the previews
  /// come first so the step's own cells render over them, each tiles its
  /// parent cell, and each is labelled with the parent's key then its own.
  func testADrillingStepPreviewsTheNextStepUnderItsOwnCells() throws {
    let hints = MouseGrid.hints(
      region: region, depth: 0, shape: shape, steps: 3, chipSize: chip, previewChipSize: bigram)
    XCTAssertEqual(hints.count, 20 + 20 * 20)
    let previews = hints.prefix(400)
    let cells = hints.suffix(20)
    XCTAssertTrue(previews.allSatisfy { $0.target.role == MouseGrid.previewCellRole })
    XCTAssertTrue(cells.allSatisfy { $0.target.role == MouseGrid.cellRole })
    let q = try XCTUnwrap(cells.first { $0.label == "q" })
    let under = previews.filter { $0.label.hasPrefix("q") }
    XCTAssertEqual(under.map(\.label), shape.keys.flatMap { $0 }.map { "q" + String($0) })
    XCTAssertEqual(
      under.map(\.target.frame), MouseGrid.cellFrames(of: q.target.frame, shape: shape))
    let again = MouseGrid.hints(
      region: region, depth: 0, shape: shape, steps: 3, chipSize: chip, previewChipSize: bigram)
    XCTAssertEqual(hints.map(\.label), again.map(\.label), "deterministic")
    XCTAssertEqual(hints.map(\.target.frame), again.map(\.target.frame))
    XCTAssertEqual(
      MouseGrid.hints(region: region, depth: 0, shape: shape, steps: 3, chipSize: chip).count, 20,
      "no preview unless asked")
  }

  /// The clicking step previews nothing, and neither does a step whose next
  /// cells could not hold a two-letter chip.
  func testNoPreviewOnTheClickingStepOrWhenTheNextCellsAreTooSmall() {
    XCTAssertEqual(
      MouseGrid.hints(
        region: region, depth: 2, shape: shape, steps: 3, chipSize: chip, previewChipSize: bigram
      ).count, 20)
    let small = CGRect(x: 0, y: 0, width: 400, height: 240)
    XCTAssertEqual(
      MouseGrid.hints(
        region: small, depth: 0, shape: shape, steps: 6, chipSize: chip, previewChipSize: bigram
      ).count, 20, "80x60 cells split into 16x15: too small for a bigram chip")
  }

  func testThePreviewIsAConfiguredDefaultThatCanBeTurnedOff() {
    XCTAssertTrue(Config().hints.mouseGridPreview)
    XCTAssertFalse(
      ConfigLoader.parse("[hints]\nmouse_grid_preview = false").hints.mouseGridPreview)
    XCTAssertTrue(
      ConfigLoader.parse("[hints]\nmouse_grid_preview = \"no\"").loadingDiagnostics.contains {
        $0.message.contains("hints.mouse_grid_preview")
      })
  }

  /// The step's own cells hold the eye; the preview is a faint hint under
  /// them; the clicking step lets the point it clicks show through its label.
  func testThePreviewIsFaintAndTheClickingStepIsSeeThrough() {
    let cell = MouseGrid.Appearance.of(role: MouseGrid.cellRole)
    let preview = MouseGrid.Appearance.of(role: MouseGrid.previewCellRole)
    let commit = MouseGrid.Appearance.of(role: MouseGrid.finalCellRole)
    let chip = MouseGrid.Appearance.of(role: MouseGrid.finalChipRole)
    XCTAssertEqual(cell.tint, 1)
    XCTAssertEqual(cell.label, 1)
    XCTAssertLessThanOrEqual(preview.tint, 0.2)
    XCTAssertLessThanOrEqual(preview.label, 0.35)
    XCTAssertLessThan(preview.border, cell.border)
    XCTAssertLessThan(commit.label, 1)
    XCTAssertGreaterThan(commit.label, preview.label)
    XCTAssertLessThan(chip.label, 1)
  }
}
