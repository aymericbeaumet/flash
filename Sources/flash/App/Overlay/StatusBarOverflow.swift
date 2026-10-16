import CoreGraphics

/// How a status bar divides the screen, and how a segment that does not fit
/// is cut. `#[align=centre]` and `#[align=notch]` are one lane: the camera
/// housing, reserved at the middle of the bar. It does not grow or move
/// with its label, and the two side segments split what remains, so the
/// gaps beside the housing match. A wider side cannot shift it.
/// Padding — the outer edge inset, the notch margin, the gutter inside the
/// notch — is already excluded from the centred lane's budget.
///
/// A segment wider than its budget loses its own edge: the left and the centre
/// end with `…`, the right begins with `…`. The last `#[shrink]` span in that
/// segment is cut first, and the segment edge is used only for the overflow
/// that span cannot absorb.
enum StatusBarOverflow {
  enum Lane: Int, CaseIterable {
    case left, centre, right, notch
  }

  /// Which end of a segment the ellipsis occupies when nothing else is marked.
  enum Edge: Equatable {
    case trailing
    case leading
  }

  struct Geometry: Equatable {
    var columns: Int
    /// Columns left of a physical notch, less its margin; nil without one.
    var leftColumns: Int? = nil
    /// Columns right of a physical notch, less its margin; nil without one.
    var rightColumns: Int? = nil
    /// The centre segment's width: the camera housing, in columns. Zero means
    /// there is no housing, so a centre label's own width (plus gutters)
    /// sizes the slot.
    var housingColumns = 0
    /// Blank columns inside the notch on each side of the centred label.
    var gutterColumns = 0
    /// Clearance between each side segment and the notch, in columns.
    var marginColumns = 0
    /// A notch is dropped rather than leaving a side segment fewer columns
    /// than this.
    var minimumLaneColumns = 0
  }

  struct Budgets: Equatable {
    var left: Int
    var centre: Int
    var right: Int
    var notch: Int
    /// The notch in the column grid. Empty when the centre segment is absent
    /// or the bar is too narrow to reserve it.
    var reserve: Range<Int>

    func columns(for lane: Lane) -> Int {
      switch lane {
      case .left: return left
      case .centre: return centre
      case .right: return right
      case .notch: return notch
      }
    }

    func edge(for lane: Lane) -> Edge {
      lane == .right ? .leading : .trailing
    }
  }

  /// Column budgets for a centred label `notchContent` cells wide (zero when
  /// that lane is absent). The housing is reserved at the middle of the bar.
  /// Side budgets are equal; neither is given the odd column left over by
  /// the split. `centre` stays zero: the label is budgeted on `notch`.
  static func plan(notchContent: Int, in geometry: Geometry) -> Budgets {
    let hasNotch = notchContent > 0
    let cap = geometry.columns - 2 * geometry.minimumLaneColumns
    let wanted: Int
    if !hasNotch {
      wanted = 0
    } else if geometry.housingColumns > 0 {
      wanted = geometry.housingColumns
    } else {
      wanted = notchContent + 2 * geometry.gutterColumns
    }
    let reserved = wanted > 0 && cap >= wanted
    let reserve: Range<Int>
    if reserved {
      let start = (geometry.columns - wanted) / 2
      reserve = start..<(start + wanted)
    } else {
      reserve = 0..<0
    }
    let notchBudget: Int
    let side: Int
    if reserved {
      side = max(0, (geometry.columns - wanted) / 2 - geometry.marginColumns)
      notchBudget =
        geometry.housingColumns > 0
        ? max(0, wanted - 2 * geometry.gutterColumns) : notchContent
    } else {
      side = geometry.columns / 2
      notchBudget = hasNotch ? geometry.columns : 0
    }
    return Budgets(
      left: geometry.leftColumns ?? side,
      centre: 0,
      right: geometry.rightColumns ?? side,
      notch: notchBudget,
      reserve: reserve)
  }

  /// The columns a centred label `centre` cells wide reserves. With a housing,
  /// that is the housing itself — a longer label is cut, and the notch does
  /// not grow. Empty without a notch label or on a bar too narrow to reserve it.
  static func reserve(centre: Int, in geometry: Geometry) -> Range<Int> {
    plan(notchContent: centre, in: geometry).reserve
  }
}

/// Point boxes for the status-bar segments. The centre box is the centred
/// lane's housing, always at the middle of the bar. Padding is outside the
/// content boxes: edge padding at the screen edges, `notchMargin` on each
/// side of the notch, and `gutterColumns` inside the notch.
struct StatusBarSegments: Equatable {
  var barWidth: CGFloat = 0
  var left = CGRect.zero
  var centre = CGRect.zero
  var right = CGRect.zero
  /// The notch outline. Empty when no centre slot is reserved.
  var notch = CGRect.zero
  var leftColumns = 0
  var centreColumns = 0
  var rightColumns = 0
  /// A notch label draws the recessed housing. A physical notch
  /// does not: the hardware is already there.
  var drawsRecess = false

  static func make(
    barWidth: CGFloat,
    cellWidth: CGFloat,
    edgePadding: CGFloat,
    notchMargin: CGFloat,
    notchWidth: CGFloat,
    gutterColumns: Int,
    hasLeft: Bool,
    hasRight: Bool,
    hasNotch: Bool,
    centreContentColumns: Int,
    physicalNotch: CGRect?,
    minimumLaneColumns: Int
  ) -> StatusBarSegments {
    guard cellWidth > 0, barWidth > 0 else { return StatusBarSegments() }
    func columns(in width: CGFloat) -> Int {
      guard width > 0 else { return 0 }
      return max(0, Int(floor(width / cellWidth)))
    }
    let full = CGRect(
      x: edgePadding, y: 0, width: max(0, barWidth - 2 * edgePadding), height: 0)

    if let physical = physicalNotch, physical.width > 0 {
      let left = CGRect(
        x: edgePadding, y: 0,
        width: max(0, physical.minX - notchMargin - edgePadding), height: 0)
      let rightX = physical.maxX + notchMargin
      let right = CGRect(
        x: rightX, y: 0, width: max(0, barWidth - edgePadding - rightX), height: 0)
      return StatusBarSegments(
        barWidth: barWidth, left: left, centre: .zero, right: right, notch: physical,
        leftColumns: columns(in: left.width), centreColumns: 0,
        rightColumns: columns(in: right.width), drawsRecess: false)
    }

    let gutter = CGFloat(max(0, gutterColumns)) * cellWidth
    // `#[align=centre]` and `#[align=notch]` reserve one housing at the
    // middle of the bar. A longer label is cut; the housing does not move.
    let hasCentreSlot = hasNotch
    var notchPoints: CGFloat = 0
    if hasCentreSlot {
      if notchWidth > 0 {
        notchPoints = notchWidth
      } else if centreContentColumns > 0 {
        notchPoints = CGFloat(centreContentColumns) * cellWidth + 2 * gutter
      }
    }
    let minimumSide = CGFloat(max(0, minimumLaneColumns)) * cellWidth
    if notchPoints > 0,
      barWidth < notchPoints + 2 * (notchMargin + edgePadding + minimumSide)
    {
      notchPoints = 0
    }

    if notchPoints > 0 {
      let notch = CGRect(x: (barWidth - notchPoints) / 2, y: 0, width: notchPoints, height: 0)
      let interior = max(0, notchPoints - 2 * gutter)
      let centre = CGRect(x: notch.minX + gutter, y: 0, width: interior, height: 0)
      let left = CGRect(
        x: edgePadding, y: 0,
        width: max(0, notch.minX - notchMargin - edgePadding), height: 0)
      let rightX = notch.maxX + notchMargin
      let right = CGRect(
        x: rightX, y: 0, width: max(0, barWidth - edgePadding - rightX), height: 0)
      let centreBudget =
        notchWidth > 0 ? columns(in: interior) : max(0, centreContentColumns)
      return StatusBarSegments(
        barWidth: barWidth, left: left, centre: centre, right: right, notch: notch,
        leftColumns: columns(in: left.width), centreColumns: centreBudget,
        rightColumns: columns(in: right.width), drawsRecess: hasNotch)
    }

    if hasLeft && hasRight {
      let half = barWidth / 2
      let left = CGRect(x: edgePadding, y: 0, width: max(0, half - edgePadding), height: 0)
      let right = CGRect(
        x: half, y: 0, width: max(0, barWidth - half - edgePadding), height: 0)
      return StatusBarSegments(
        barWidth: barWidth, left: left, centre: hasCentreSlot ? full : .zero, right: right,
        notch: .zero, leftColumns: columns(in: left.width),
        centreColumns: hasCentreSlot ? columns(in: full.width) : 0,
        rightColumns: columns(in: right.width), drawsRecess: false)
    }
    if hasRight {
      return StatusBarSegments(
        barWidth: barWidth, left: .zero, centre: hasCentreSlot ? full : .zero, right: full,
        notch: .zero, leftColumns: 0,
        centreColumns: hasCentreSlot ? columns(in: full.width) : 0,
        rightColumns: columns(in: full.width), drawsRecess: false)
    }
    return StatusBarSegments(
      barWidth: barWidth, left: full, centre: hasCentreSlot ? full : .zero, right: .zero,
      notch: .zero, leftColumns: columns(in: full.width),
      centreColumns: hasCentreSlot ? columns(in: full.width) : 0, rightColumns: 0,
      drawsRecess: false)
  }

  /// Column limits for `fitted`. Each segment is capped at the columns that
  /// fit in its content box, and at the bar, so layout does not cut again.
  func budgets(columns available: Int) -> StatusBarOverflow.Budgets {
    func cap(_ value: Int) -> Int { min(max(0, value), max(0, available)) }
    return StatusBarOverflow.Budgets(
      left: cap(leftColumns), centre: cap(centreColumns), right: cap(rightColumns),
      notch: cap(centreColumns), reserve: 0..<0)
  }
}
