import XCTest

@testable import flash

/// Segment budgets and where an overflow cut falls. Column geometry, no AppKit.
final class StatusBarOverflowTests: XCTestCase {
  /// A 100-column bar with a 24-column housing, 2-column gutters, a 1-column
  /// notch margin, and 8 columns a lane always keeps.
  private let bar = StatusBarOverflow.Geometry(
    columns: 100, housingColumns: 24, gutterColumns: 2, marginColumns: 1,
    minimumLaneColumns: 8)

  private func texts(_ source: String, in geometry: StatusBarOverflow.Geometry) -> [String] {
    NativeStatusBarSurface.fitted(StatusFormatDocument.parse(source), in: geometry)
      .document.runs.filter { !$0.isStyleBoundary }.map(\.text)
  }

  /// The centre slot is the housing. A longer label does not widen it, and a
  /// bar too narrow for the housing drops the slot.
  func testTheCentreMatchesTheHousingInsteadOfItsLabel() {
    XCTAssertEqual(StatusBarOverflow.reserve(centre: 6, in: bar), 38..<62)
    XCTAssertEqual(StatusBarOverflow.reserve(centre: 45, in: bar), 38..<62)
    XCTAssertEqual(StatusBarOverflow.reserve(centre: 200, in: bar), 38..<62)
    XCTAssertTrue(StatusBarOverflow.reserve(centre: 0, in: bar).isEmpty)
    var narrow = bar
    narrow.columns = 16
    XCTAssertTrue(StatusBarOverflow.reserve(centre: 6, in: narrow).isEmpty)
    var hug = bar
    hug.housingColumns = 0
    XCTAssertEqual(StatusBarOverflow.reserve(centre: 6, in: hug).count, 10)
  }

  /// `#[align=centre]` reserves the same housing as `#[align=notch]`. A longer
  /// label is cut, and the housing does not move to fit it.
  func testCentreReservesTheHousingAndCutsALongerLabel() {
    let source = "LEFT#[align=centre]\(String(repeating: "C", count: 40))#[align=right]RIGHT"
    let centre = NativeStatusBarSurface.fitted(StatusFormatDocument.parse(source), in: bar)
    let notch = NativeStatusBarSurface.fitted(
      StatusFormatDocument.parse(
        source.replacingOccurrences(of: "align=centre", with: "align=notch")),
      in: bar)
    XCTAssertEqual(centre.reserve, 38..<62)
    XCTAssertEqual(centre.reserve, notch.reserve)
    let label = centre.document.runs.filter { $0.alignment == .centre }.map(\.text).joined()
    XCTAssertTrue(label.hasSuffix("…"), label)
    XCTAssertLessThan(label.count, 40)
  }

  /// Both side segments get the same column budget, including when the split
  /// leaves an odd column. That column stays unused.
  func testSideBudgetsAreEqual() {
    let plan = StatusBarOverflow.plan(notchContent: 45, in: bar)
    XCTAssertEqual(plan.left, 37)
    XCTAssertEqual(plan.right, 37)
    XCTAssertEqual(plan.notch, 20, "the housing interior, after both gutters")
    var odd = bar
    odd.columns = 101
    let oddPlan = StatusBarOverflow.plan(notchContent: 6, in: odd)
    XCTAssertEqual(oddPlan.left, oddPlan.right)
    XCTAssertEqual(oddPlan.left, 37)
  }

  func testAFittingSegmentIsUnchanged() {
    let geometry = StatusBarOverflow.Geometry(
      columns: 30, housingColumns: 8, gutterColumns: 2, marginColumns: 0, minimumLaneColumns: 0)
    XCTAssertEqual(
      texts("ABCDEFGHIJ#[align=notch]C#[align=right]abcdefghij", in: geometry),
      ["ABCDEFGHIJ", "C", "abcdefghij"])
  }

  func testUnmarkedLeftAndCentreEndWithEllipsisAndTheRightStartsWithIt() {
    let geometry = StatusBarOverflow.Geometry(
      columns: 20, housingColumns: 8, gutterColumns: 2, marginColumns: 0, minimumLaneColumns: 0)
    XCTAssertEqual(
      texts("ABCDEFGHIJ#[align=notch]C#[align=right]abcdefghij", in: geometry),
      ["ABCDE…", "C", "…fghij"])
    let wideCentre = StatusBarOverflow.Geometry(
      columns: 40, housingColumns: 10, gutterColumns: 2, marginColumns: 0, minimumLaneColumns: 0)
    XCTAssertEqual(
      texts(
        "L#[align=notch]\(String(repeating: "C", count: 20))#[align=right]R",
        in: wideCentre)[1],
      "CCCCC…")
  }

  /// The last shrink span takes the ellipsis. An earlier shrink, and the text
  /// after the cut, stay at full width.
  func testTheLastShrinkIsCutInsteadOfTheSegmentEdge() {
    let geometry = StatusBarOverflow.Geometry(columns: 24, minimumLaneColumns: 0)
    XCTAssertEqual(
      texts(
        "KEEP #[shrink]FIRST#[noshrink] #[shrink]SECONDSECOND#[noshrink] TAIL", in: geometry
      )
      .joined(),
      "KEEP FIRST SECONDS… TAIL")
  }

  /// A marked right segment cuts its last shrink, so the tail stays. The
  /// leading ellipsis is only the fallback once that span is down to one cell.
  func testARightShrinkKeepsTheTailUntilItIsExhausted() {
    let geometry = StatusBarOverflow.Geometry(columns: 20, minimumLaneColumns: 0)
    XCTAssertEqual(
      texts("#[align=right]HEAD #[shrink]CUTCUTCUTCUT#[noshrink] TAIL", in: geometry).joined(),
      "HEAD CUTCUTCUT… TAIL")
    let tight = StatusBarOverflow.Geometry(columns: 10, minimumLaneColumns: 0)
    XCTAssertEqual(
      texts("#[align=right]#[shrink]AB#[noshrink] 1234567890", in: tight).joined(),
      "…234567890")
  }

  /// Point boxes, not the column grid. Both outer edges and both notch gaps
  /// are the configured padding, and a wider screen widens the sides only.
  func testPointSegmentsKeepEqualPaddingAndAFixedNotch() {
    let cell: CGFloat = 8
    let edge: CGFloat = 13
    let margin: CGFloat = 4
    let notch: CGFloat = 185
    func segments(width: CGFloat, centre: Bool) -> StatusBarSegments {
      StatusBarSegments.make(
        barWidth: width, cellWidth: cell, edgePadding: edge, notchMargin: margin,
        notchWidth: notch, gutterColumns: 2, hasLeft: true, hasRight: true,
        hasNotch: centre, centreContentColumns: 40,
        physicalNotch: nil, minimumLaneColumns: 8)
    }
    var previous = segments(width: 800, centre: true)
    for width in [800, 1200, 1728, 1920] as [CGFloat] {
      let made = segments(width: width, centre: true)
      XCTAssertEqual(made.notch.width, notch)
      XCTAssertEqual(made.notch.midX, width / 2, accuracy: 0.001)
      XCTAssertEqual(made.left.minX, edge, accuracy: 0.001)
      XCTAssertEqual(made.left.maxX, made.notch.minX - margin, accuracy: 0.001)
      XCTAssertEqual(made.right.minX, made.notch.maxX + margin, accuracy: 0.001)
      XCTAssertEqual(made.right.maxX, width - edge, accuracy: 0.001)
      XCTAssertEqual(made.left.width, made.right.width, accuracy: 0.001)
      XCTAssertEqual(made.centre.minX - made.notch.minX, CGFloat(2) * cell, accuracy: 0.001)
      XCTAssertEqual(
        made.centre.minX - made.notch.minX, made.notch.maxX - made.centre.maxX, accuracy: 0.001)
      XCTAssertEqual(made.leftColumns, made.rightColumns)
      if width > previous.barWidth {
        XCTAssertGreaterThan(made.left.width, previous.left.width)
        XCTAssertEqual(made.notch.width, previous.notch.width)
      }
      previous = made
    }
    let split = segments(width: 1000, centre: false)
    XCTAssertTrue(split.notch.isEmpty)
    XCTAssertEqual(split.left.minX, edge, accuracy: 0.001)
    XCTAssertEqual(split.right.maxX, 1000 - edge, accuracy: 0.001)
    XCTAssertEqual(split.left.width, split.right.width, accuracy: 0.001)
    let onlyLeft = StatusBarSegments.make(
      barWidth: 1000, cellWidth: cell, edgePadding: edge, notchMargin: margin,
      notchWidth: notch, gutterColumns: 2, hasLeft: true, hasRight: false,
      hasNotch: false, centreContentColumns: 0,
      physicalNotch: nil, minimumLaneColumns: 8)
    XCTAssertEqual(onlyLeft.left.minX, edge, accuracy: 0.001)
    XCTAssertEqual(onlyLeft.left.maxX, 1000 - edge, accuracy: 0.001)
    XCTAssertEqual(onlyLeft.rightColumns, 0)
    let physical = CGRect(x: 771, y: 0, width: 185, height: 32)
    let notched = StatusBarSegments.make(
      barWidth: 1728, cellWidth: cell, edgePadding: edge, notchMargin: margin,
      notchWidth: notch, gutterColumns: 2, hasLeft: true, hasRight: true,
      hasNotch: true, centreContentColumns: 12,
      physicalNotch: physical, minimumLaneColumns: 8)
    XCTAssertEqual(notched.left.maxX, physical.minX - margin, accuracy: 0.001)
    XCTAssertEqual(notched.right.minX, physical.maxX + margin, accuracy: 0.001)
    XCTAssertEqual(notched.left.minX, edge, accuracy: 0.001)
    XCTAssertEqual(notched.right.maxX, 1728 - edge, accuracy: 0.001)
    XCTAssertEqual(notched.centreColumns, 0)
    XCTAssertFalse(notched.drawsRecess)
  }

  func testAModePillIsNeverCut() {
    let geometry = StatusBarOverflow.Geometry(columns: 8, minimumLaneColumns: 0)
    let fitted = texts("#[pill]NORMAL#[nopill] ABCDEFGHIJ", in: geometry).joined()
    XCTAssertTrue(fitted.contains("NORMAL"), fitted)
    XCTAssertTrue(fitted.hasSuffix("…"), fitted)
  }
}
