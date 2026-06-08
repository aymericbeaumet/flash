import AppKit
import FlashCore

enum MouseGrid {
  struct Grid: Equatable {
    var columns: Int
    var rows: Int

    var cellCount: Int { columns * rows }
  }

  struct Region: Equatable {
    var frame: CGRect
    var grid: Grid?

    init(frame: CGRect, grid: Grid? = nil) {
      self.frame = frame
      self.grid = grid
    }
  }

  /// Region edge below which we commit instead of subdividing further —
  /// even a perfectly aspect-matched grid can't shrink past this without
  /// producing unhittably-small chips.
  static let minimumTerminalSize: CGFloat = 18
  /// Floor on each side of a single cell at the precision step. The
  /// grid algorithm picks the densest cols/rows that keeps every final
  /// cell at least this wide / tall.
  static let finalMinimumCell: CGFloat = 18
  /// Compile-time fallback when no config object is available (tests,
  /// fixtures). Production callers thread `Config.hints.mouseGridSteps`.
  static let defaultSteps = 3

  static func initialRegion(
    context: AppContext?,
    screens: [NSScreen],
    fallback: CGRect
  ) -> Region {
    if let context, !context.frontWindowFrame.isNull,
      context.frontWindowFrame.width > 0,
      context.frontWindowFrame.height > 0
    {
      return Region(frame: context.frontWindowFrame)
    }
    var union: CGRect = .null
    for screen in screens {
      union = union.union(screen.visibleFrame)
    }
    return Region(frame: union.isNull ? fallback : union)
  }

  static func preparedRegion(
    _ region: Region,
    alphabet: [Character],
    steps: Int = defaultSteps
  ) -> Region {
    guard alphabet.count >= 4 else { return region }
    if let grid = region.grid, grid.cellCount <= alphabet.count {
      return region
    }
    return Region(
      frame: region.frame,
      grid: fixedGrid(for: region.frame, alphabet: alphabet, steps: steps))
  }

  static func hints(
    in region: Region,
    depth: Int,
    alphabet: [Character],
    steps: Int = defaultSteps
  ) -> [AssignedHint] {
    let labels = alphabet.map(String.init)
    guard labels.count >= 4 else { return [] }
    let prepared = preparedRegion(region, alphabet: alphabet, steps: steps)
    guard let grid = prepared.grid, grid.cellCount <= labels.count else { return [] }
    let frame = prepared.frame
    let cellWidth = frame.width / CGFloat(grid.columns)
    let cellHeight = frame.height / CGFloat(grid.rows)
    var out: [AssignedHint] = []
    out.reserveCapacity(grid.cellCount)

    var index = 0
    for row in 0..<grid.rows {
      for column in 0..<grid.columns {
        let x = frame.minX + CGFloat(column) * cellWidth
        let y = frame.maxY - CGFloat(row + 1) * cellHeight
        let frame = CGRect(x: x, y: y, width: cellWidth, height: cellHeight)
        let target = JumpTarget(
          id: "mouse_grid:\(depth):\(index)",
          frame: frame,
          role: "FlashMouseGridCell",
          providerID: "mouse_grid")
        out.append(AssignedHint(target: target, label: labels[index]))
        index += 1
      }
    }
    return out
  }

  static func shouldCommit(region: Region, depth: Int, steps: Int = defaultSteps) -> Bool {
    depth >= steps
      || min(region.frame.width, region.frame.height) <= minimumTerminalSize
      || (isFinalDisplayDepth(depth, steps: steps)
        && (region.frame.width < finalMinimumCell * 2
          || region.frame.height < finalMinimumCell * 2))
  }

  static func isFinalDisplayDepth(_ depth: Int, steps: Int = defaultSteps) -> Bool {
    depth >= steps - 1
  }

  /// Compute the per-step grid shape by **starting from the final step**:
  ///
  ///   - Imagine the precision grid: the densest aspect-matched grid
  ///     of `alphabet` cells, sized to ≥ `finalMinimumCell` on each side,
  ///     that fits inside `frame` after `steps - 1` subdivisions.
  ///   - The same shape is then used at every earlier step (recursive
  ///     subdivision). After `steps` selections the cell size collapses
  ///     to roughly the precision target.
  ///
  /// Concretely: with `steps = N`, region width `W`, and minimum cell
  /// `M`, the algorithm picks the largest integer `cols` such that
  /// `cols^N · M ≤ W` (and likewise for `rows`), then maximises
  /// `cols · rows` under the alphabet cap. Aspect ratio of the resulting
  /// grid follows the region's aspect, which handles vertical monitors.
  static func fixedGrid(for frame: CGRect, alphabet: [Character], steps: Int) -> Grid {
    let labelCount = max(4, alphabet.count)
    let stepCount = max(1, steps)
    let maxColumns = max(
      2,
      Int(floor(pow(max(1, Double(frame.width / finalMinimumCell)), 1.0 / Double(stepCount)))))
    let maxRows = max(
      2,
      Int(floor(pow(max(1, Double(frame.height / finalMinimumCell)), 1.0 / Double(stepCount)))))
    return gridShape(
      maxCells: labelCount,
      aspect: frame.width / max(1, frame.height),
      maxColumns: maxColumns,
      maxRows: maxRows)
  }

  private static func gridShape(
    maxCells: Int,
    aspect: CGFloat,
    maxColumns: Int,
    maxRows: Int
  ) -> Grid {
    let capped = max(4, maxCells)
    // Odd-axis pass first. Odd cols/rows produce a true centre cell the
    // user can aim at; an even axis puts the visual centre on a chip
    // seam. We only fall back to even shapes when no odd shape fits
    // under the precision-floor caps (`maxColumns/maxRows`), which is
    // the case for very small regions where 2 is the only valid axis.
    let oddColMax = maxColumns.isMultiple(of: 2) ? maxColumns - 1 : maxColumns
    let oddRowMax = maxRows.isMultiple(of: 2) ? maxRows - 1 : maxRows
    if let oddBest = bestShape(
      capped: capped, aspect: aspect,
      colRange: stride(from: 3, through: oddColMax, by: 2),
      rowRange: stride(from: 3, through: oddRowMax, by: 2))
    {
      return Grid(columns: oddBest.columns, rows: oddBest.rows)
    }
    let evenBest = bestShape(
      capped: capped, aspect: aspect,
      colRange: stride(from: 2, through: max(2, maxColumns), by: 1),
      rowRange: stride(from: 2, through: max(2, maxRows), by: 1))
    return Grid(
      columns: evenBest?.columns ?? 2,
      rows: evenBest?.rows ?? 2)
  }

  private static func bestShape<C, R>(
    capped: Int,
    aspect: CGFloat,
    colRange: C,
    rowRange: R
  ) -> (columns: Int, rows: Int)?
  where C: Sequence, C.Element == Int, R: Sequence, R.Element == Int {
    var best: (columns: Int, rows: Int, cells: Int, score: CGFloat)?
    for rows in rowRange {
      for columns in colRange {
        let cells = rows * columns
        guard cells <= capped else { continue }
        let shapeAspect = CGFloat(columns) / CGFloat(rows)
        let score = abs(log(max(0.01, shapeAspect) / max(0.01, aspect)))
        if let current = best {
          if cells > current.cells || (cells == current.cells && score < current.score) {
            best = (columns, rows, cells, score)
          }
        } else {
          best = (columns, rows, cells, score)
        }
      }
    }
    return best.map { ($0.columns, $0.rows) }
  }
}
