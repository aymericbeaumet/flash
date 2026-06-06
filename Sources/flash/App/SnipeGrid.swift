import AppKit
import FlashCore

enum SnipeGrid {
  struct Region: Equatable {
    var frame: CGRect
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

  static func hints(
    in region: Region,
    depth: Int,
    alphabet: [Character]
  ) -> [AssignedHint] {
    let labels = alphabet.map(String.init)
    guard labels.count >= 4 else { return [] }
    let finalStep = isFinalDisplayDepth(depth)
    let maxColumns: Int
    let maxRows: Int
    let maxCells: Int
    if finalStep {
      maxColumns = max(2, Int(region.frame.width / finalMinimumCellWidth))
      maxRows = max(2, Int(region.frame.height / finalMinimumCellHeight))
      maxCells = min(labels.count, maxColumns * maxRows, 12)
    } else {
      maxColumns = 8
      maxRows = 4
      maxCells = min(labels.count, 16)
    }
    let grid = gridShape(
      maxCells: maxCells,
      aspect: region.frame.width / max(1, region.frame.height),
      maxColumns: maxColumns,
      maxRows: maxRows)
    let cellWidth = region.frame.width / CGFloat(grid.columns)
    let cellHeight = region.frame.height / CGFloat(grid.rows)
    var out: [AssignedHint] = []
    out.reserveCapacity(grid.columns * grid.rows)

    var index = 0
    for row in 0..<grid.rows {
      for column in 0..<grid.columns {
        let x = region.frame.minX + CGFloat(column) * cellWidth
        let y = region.frame.maxY - CGFloat(row + 1) * cellHeight
        let frame = CGRect(x: x, y: y, width: cellWidth, height: cellHeight)
        let target = JumpTarget(
          id: "snipe:\(depth):\(index)",
          frame: frame,
          role: "FlashSnipeCell",
          providerID: "snipe")
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

  private static func gridShape(
    maxCells: Int,
    aspect: CGFloat,
    maxColumns: Int,
    maxRows: Int
  ) -> (columns: Int, rows: Int) {
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
    return (best.columns, best.rows)
  }
}
