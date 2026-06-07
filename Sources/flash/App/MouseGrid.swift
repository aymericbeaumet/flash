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

  static let minimumTerminalSize: CGFloat = 18
  static let maximumDepth = 3
  private static let finalMinimumCellWidth: CGFloat = 18
  private static let finalMinimumCellHeight: CGFloat = 18

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

  static func preparedRegion(_ region: Region, alphabet: [Character]) -> Region {
    guard alphabet.count >= 4 else { return region }
    if let grid = region.grid, grid.cellCount <= alphabet.count {
      return region
    }
    return Region(frame: region.frame, grid: fixedGrid(for: region.frame, alphabet: alphabet))
  }

  static func hints(
    in region: Region,
    depth: Int,
    alphabet: [Character]
  ) -> [AssignedHint] {
    let labels = alphabet.map(String.init)
    guard labels.count >= 4 else { return [] }
    let prepared = preparedRegion(region, alphabet: alphabet)
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

  static func shouldCommit(region: Region, depth: Int) -> Bool {
    depth >= maximumDepth
      || min(region.frame.width, region.frame.height) <= minimumTerminalSize
      || (isFinalDisplayDepth(depth)
        && (region.frame.width < finalMinimumCellWidth * 2
          || region.frame.height < finalMinimumCellHeight * 2))
  }

  static func isFinalDisplayDepth(_ depth: Int) -> Bool {
    depth >= maximumDepth - 1
  }

  static func fixedGrid(for frame: CGRect, alphabet: [Character]) -> Grid {
    let labelCount = max(4, alphabet.count)
    let maxColumns = max(
      2,
      Int(floor(pow(max(1, Double(frame.width / finalMinimumCellWidth)), 1.0 / Double(maximumDepth)))))
    let maxRows = max(
      2,
      Int(floor(pow(max(1, Double(frame.height / finalMinimumCellHeight)), 1.0 / Double(maximumDepth)))))
    let maxCells = min(labelCount, maxColumns * maxRows)
    return gridShape(
      maxCells: maxCells,
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
    let capped = max(4, min(maxCells, 20))
    var best = (columns: 2, rows: 2, cells: 4, score: CGFloat.greatestFiniteMagnitude)
    for rows in 2...max(2, min(capped, maxRows)) {
      for columns in 2...max(2, min(capped, maxColumns)) {
        let cells = rows * columns
        guard cells <= capped else { continue }
        let shapeAspect = CGFloat(columns) / CGFloat(rows)
        let score = abs(log(max(0.01, shapeAspect) / max(0.01, aspect)))
        if cells > best.cells || (cells == best.cells && score < best.score) {
          best = (columns, rows, cells, score)
        }
      }
    }
    return Grid(columns: best.columns, rows: best.rows)
  }
}
