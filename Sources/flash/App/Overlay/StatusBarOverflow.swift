/// How a status bar that does not fit gives way, as pure cell arithmetic:
/// lane widths in, the width each truncatable span keeps out.
///
/// The constraints: an absolute centre owns a reservation centred on the bar —
/// its content plus gutters, never narrower than the housing the recess
/// mimics — and each side lane ends `marginColumns` short of it; a physical
/// notch bounds the left lane; the three tmux lanes together fit the bar.
/// Because the reservation is centred, narrowing the centre frees a column
/// for both side lanes at once, while narrowing a lane frees only that lane.
///
/// `budgets` water-fills: it repeatedly narrows the widest span whose
/// narrowing relieves a violated constraint (ties in template order), never
/// below its minimum, until nothing is violated or no span can help.
enum StatusBarOverflow {
  enum Lane: Int, CaseIterable {
    case left, centre, right, absoluteCentre
  }

  /// A truncatable stretch of one lane: an explicit `#[shrink]` group, or a
  /// whole section once those are exhausted. It ranks by its full `width`
  /// and never narrows below `minimum` — one cell for the ellipsis, plus any
  /// part of it that cannot be cut (a section's mode pill).
  struct Span: Equatable {
    var lane: Lane
    var width: Int
    var minimum = 1
  }

  struct Geometry: Equatable {
    var columns: Int
    /// Columns left of a physical notch, less its margin; nil without one.
    var leftColumns: Int? = nil
    /// The drawn recess's minimum width: the camera housing's. Zero lets the
    /// reservation hug the centred content.
    var housingColumns = 0
    /// Blank columns inside the recess on each side of the centred content.
    var gutterColumns = 0
    /// Clearance between each side lane and the reservation.
    var marginColumns = 0
    /// The reservation never leaves a side lane fewer columns than this; a
    /// bar too narrow for that drops the reservation instead.
    var minimumLaneColumns = 0
  }

  /// The columns a centre `centre` cells wide reserves, centred on the bar.
  /// Empty without a centre or on a bar too narrow to reserve anything.
  static func reserve(centre: Int, in geometry: Geometry) -> Range<Int> {
    let width = footprint(centre: centre, in: geometry)
    guard width > 0 else { return 0..<0 }
    let start = (geometry.columns - width) / 2
    return start..<(start + width)
  }

  /// The width each span keeps, in `spans` order. `fixed` is the width per
  /// lane that no span in this pass can narrow.
  static func budgets(_ spans: [Span], fixed: [Lane: Int], in geometry: Geometry) -> [Int] {
    var widths = spans.map(\.width)
    var lanes = Lane.allCases.map { fixed[$0, default: 0] }
    for span in spans { lanes[span.lane.rawValue] += span.width }
    while true {
      let pressure = Pressure(lanes: lanes, geometry: geometry)
      var chosen: Int?
      var cells = 0
      var runnerUp = 0
      for index in spans.indices where widths[index] > spans[index].minimum {
        let relief = pressure.cells(relievedBy: spans[index].lane)
        guard relief > 0 else { continue }
        if let current = chosen, widths[index] <= widths[current] {
          runnerUp = max(runnerUp, widths[index])
          continue
        }
        if let current = chosen { runnerUp = widths[current] }
        chosen = index
        cells = relief
      }
      guard let index = chosen else { return widths }
      // Narrow in one step as far as narrowing cell by cell would: until the
      // span's own constraints are met, or it is level with the next widest.
      let step = max(
        1, min(cells, widths[index] - spans[index].minimum, widths[index] - runnerUp))
      widths[index] -= step
      lanes[spans[index].lane.rawValue] -= step
    }
  }

  private static func footprint(centre: Int, in geometry: Geometry) -> Int {
    let cap = geometry.columns - 2 * geometry.minimumLaneColumns
    guard centre > 0, cap > 0 else { return 0 }
    return min(cap, max(geometry.housingColumns, centre + 2 * geometry.gutterColumns))
  }

  /// How far each constraint is exceeded; positive means violated.
  private struct Pressure {
    /// Side lanes against the reservation, in half cells: a centred
    /// reservation hands each lane half of every column it gives up.
    var left = 0
    var right = 0
    /// The centre's content beyond the widest reservation the bar allows.
    var centre = 0
    var total = 0
    var notch = 0
    /// Columns the reservation still sheds as the centre narrows; zero when
    /// the housing or the cap, not the content, sets its width.
    var centreSlack = 0

    init(lanes: [Int], geometry: Geometry) {
      let left = lanes[Lane.left.rawValue]
      let right = lanes[Lane.right.rawValue]
      total = left + lanes[Lane.centre.rawValue] + right - geometry.columns
      if let leftColumns = geometry.leftColumns { notch = left - leftColumns }
      let content = lanes[Lane.absoluteCentre.rawValue] + 2 * geometry.gutterColumns
      let footprint = StatusBarOverflow.footprint(
        centre: lanes[Lane.absoluteCentre.rawValue], in: geometry)
      guard footprint > 0 else { return }
      // left + margin <= floor((columns - footprint) / 2)
      self.left = 2 * (left + geometry.marginColumns) + footprint - geometry.columns
      // right + margin <= ceil((columns - footprint) / 2)
      self.right = 2 * (right + geometry.marginColumns) - 1 + footprint - geometry.columns
      centre = content - footprint
      centreSlack = footprint == content ? max(0, content - geometry.housingColumns) : 0
    }

    /// Cells a span in `lane` gives up before every constraint it relieves
    /// is met; zero when it relieves none.
    func cells(relievedBy lane: Lane) -> Int {
      switch lane {
      case .left: return max(0, (left + 1) / 2, total, notch)
      case .right: return max(0, (right + 1) / 2, total)
      case .centre: return max(0, total)
      case .absoluteCentre:
        return centre > 0 ? centre : min(max(0, left, right), centreSlack)
      }
    }
  }
}
