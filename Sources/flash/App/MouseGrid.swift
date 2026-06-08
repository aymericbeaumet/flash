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

  /// Region edge below which we commit instead of subdividing further.
  /// At very small regions a further subdivision would produce
  /// sub-pixel cells the user can't realistically aim at; bail with
  /// the most recent click point instead.
  static let minimumTerminalSize: CGFloat = 18
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
  }

  static func isFinalDisplayDepth(_ depth: Int, steps: Int = defaultSteps) -> Bool {
    depth >= steps - 1
  }

  /// Compute the per-step grid shape: always a square NxN with N odd.
  /// N is the largest odd integer satisfying `N*N <= alphabet.count`,
  /// so 25-letter alphabets (qwerty homerow + toprow) get 5x5 (= 25
  /// cells), 49-letter alphabets get 7x7, etc. Aspect-matching the
  /// grid to the screen is intentionally dropped: square cells let
  /// the user predict the centre cell on each axis (always present
  /// because N is odd), and the same shape works on vertical monitors.
  ///
  /// `frame` and `steps` are kept in the signature for API stability
  /// (and so the configured step count still controls precision via
  /// recursion depth), but they no longer feed the grid shape.
  static func fixedGrid(for frame: CGRect, alphabet: [Character], steps: Int) -> Grid {
    let target = alphabet.count
    guard target >= 9 else { return Grid(columns: 2, rows: 2) }
    var n = 3
    while (n + 2) * (n + 2) <= target {
      n += 2
    }
    return Grid(columns: n, rows: n)
  }
}
