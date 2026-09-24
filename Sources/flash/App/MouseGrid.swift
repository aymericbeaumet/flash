import AppKit
import FlashCore

/// The mouse grid's geometry: pure functions from a region and a key shape to
/// cells, plus the `Navigation` value a grid session steps through.
/// Coordinates are global NSScreen points (bottom-left origin, +y up), so row 0
/// is the top of a region.
enum MouseGrid {
  enum Shape: Equatable {
    /// Rows of keys, top row first. Every step of the grid tiles its region
    /// with this matrix, so a cell's position always matches its key's.
    case keyboard([[Character]])
    /// `--bisect`: y/u/b/n keep a quadrant; h/j/k/l keep a half.
    case bisect

    static let bisectKeys: [[Character]] = [["y", "u"], ["b", "n"]]

    var keys: [[Character]] {
      switch self {
      case .keyboard(let keys): return keys
      case .bisect: return Self.bisectKeys
      }
    }

    var rows: Int { keys.count }
    var columns: Int { keys.first?.count ?? 0 }
  }

  enum Direction: Equatable {
    case left, right, up, down
  }

  /// Cells at or below this edge are too small to subdivide usefully, so the
  /// selection that reaches them clicks.
  static let minimumTerminalSize: CGFloat = 18

  /// A cell whose selection drills into it: a gap-free tile with a translucent
  /// tint and a centred label chip.
  static let cellRole = "FlashMouseGridCell"
  /// A cell whose selection clicks its centre, drawn as a tile.
  static let finalCellRole = "FlashMouseGridFinalCell"
  /// A cell whose selection clicks, when cells are smaller than a chip: the
  /// chips form a glued cluster centred on (and covering) the region, and
  /// each click lands on its chip's centre. The renderer keys off this role.
  static let finalChipRole = "FlashMouseGridFinalChip"

  static func cellSize(of region: CGRect, shape: Shape) -> CGSize {
    guard shape.rows > 0, shape.columns > 0 else { return .zero }
    return CGSize(
      width: region.width / CGFloat(shape.columns),
      height: region.height / CGFloat(shape.rows))
  }

  /// The cell at `row` (0 = top) and `column` (0 = left) of `region`.
  static func cellFrame(in region: CGRect, row: Int, column: Int, shape: Shape) -> CGRect {
    let size = cellSize(of: region, shape: shape)
    return CGRect(
      x: region.minX + CGFloat(column) * size.width,
      y: region.maxY - CGFloat(row + 1) * size.height,
      width: size.width,
      height: size.height)
  }

  /// Every cell of `region`, row-major from the top-left.
  static func cellFrames(of region: CGRect, shape: Shape) -> [CGRect] {
    var frames: [CGRect] = []
    frames.reserveCapacity(shape.rows * shape.columns)
    for row in 0..<shape.rows {
      for column in 0..<shape.columns {
        frames.append(cellFrame(in: region, row: row, column: column, shape: shape))
      }
    }
    return frames
  }

  /// The cell containing `point`, which is first clamped into `region`.
  static func cellFrame(containing point: CGPoint, in region: CGRect, shape: Shape) -> CGRect {
    let size = cellSize(of: region, shape: shape)
    guard size.width > 0, size.height > 0 else { return region }
    let column = Int(((point.x - region.minX) / size.width).rounded(.down))
    let row = Int(((region.maxY - point.y) / size.height).rounded(.down))
    return cellFrame(
      in: region,
      row: min(max(row, 0), shape.rows - 1),
      column: min(max(column, 0), shape.columns - 1),
      shape: shape)
  }

  /// A pseudo-cell of one cell's size centred on the region. Selecting it
  /// (Space) keeps the region centre fixed, so repeating it converges on the
  /// dead centre whatever key the layout puts there.
  static func centreCell(of region: CGRect, shape: Shape) -> CGRect {
    let size = cellSize(of: region, shape: shape)
    return CGRect(
      x: region.midX - size.width / 2,
      y: region.midY - size.height / 2,
      width: size.width,
      height: size.height)
  }

  /// Bisect's h/j/k/l: the half of `region` on the `direction` side.
  static func half(of region: CGRect, _ direction: Direction) -> CGRect {
    switch direction {
    case .left:
      return CGRect(x: region.minX, y: region.minY, width: region.width / 2, height: region.height)
    case .right:
      return CGRect(
        x: region.midX, y: region.minY, width: region.width / 2, height: region.height)
    case .up:
      return CGRect(
        x: region.minX, y: region.midY, width: region.width, height: region.height / 2)
    case .down:
      return CGRect(x: region.minX, y: region.minY, width: region.width, height: region.height / 2)
    }
  }

  /// Whether selecting a cell of `region`, shown at `depth`, clicks instead of
  /// drilling: on the last configured step, or once cells reach the size
  /// floor. Bisect ignores the step count (see `keepCommits`).
  static func selectionCommits(region: CGRect, depth: Int, steps: Int, shape: Shape) -> Bool {
    let cell = cellSize(of: region, shape: shape)
    switch shape {
    case .keyboard:
      return depth + 1 >= steps || min(cell.width, cell.height) <= minimumTerminalSize
    case .bisect:
      return keepCommits(CGRect(origin: .zero, size: cell))
    }
  }

  /// Bisect clicks once the region it keeps is at the size floor on both
  /// sides, so a run of halves along one axis never clicks early.
  static func keepCommits(_ kept: CGRect) -> Bool {
    max(kept.width, kept.height) <= minimumTerminalSize
  }

  /// The hints for one grid step. Cells are tiles, row-major and labelled from
  /// the shape's keys. When the selection clicks and cells are smaller than a
  /// chip, the chips form a glued cluster instead, each slot at least one chip
  /// and one cell in size, so it covers the region without overlapping.
  static func hints(
    region: CGRect,
    depth: Int,
    shape: Shape,
    steps: Int,
    chipSize: CGSize
  ) -> [AssignedHint] {
    let keys = shape.keys
    guard shape.rows > 0, shape.columns > 0, keys.allSatisfy({ $0.count == shape.columns })
    else { return [] }
    let cell = cellSize(of: region, shape: shape)
    let commits = selectionCommits(region: region, depth: depth, steps: steps, shape: shape)
    let cluster = commits && (cell.width < chipSize.width || cell.height < chipSize.height)
    let slotRegion: CGRect
    if cluster {
      let slot = CGSize(
        width: max(chipSize.width, cell.width), height: max(chipSize.height, cell.height))
      let width = slot.width * CGFloat(shape.columns)
      let height = slot.height * CGFloat(shape.rows)
      slotRegion = CGRect(
        x: region.midX - width / 2, y: region.midY - height / 2, width: width, height: height)
    } else {
      slotRegion = region
    }
    let role = cluster ? finalChipRole : commits ? finalCellRole : cellRole
    var out: [AssignedHint] = []
    out.reserveCapacity(shape.rows * shape.columns)
    for (row, rowKeys) in keys.enumerated() {
      for (column, key) in rowKeys.enumerated() {
        let target = JumpTarget(
          id: "mouse_grid:\(depth):\(row * shape.columns + column)",
          frame: cellFrame(in: slotRegion, row: row, column: column, shape: shape),
          role: role,
          providerID: "mouse_grid")
        out.append(AssignedHint(target: target, label: String(key)))
      }
    }
    return out
  }

  /// The grid's starting area: the usable frame (below Flash's status bar) of
  /// the front window's screen, else the pointer's, else the primary's.
  static func initialRegion(
    context: AppContext?,
    layouts: [WindowScreenLayout],
    pointer: CGPoint?
  ) -> (root: CGRect, screenIndex: Int)? {
    guard !layouts.isEmpty else { return nil }
    let index: Int
    if let window = context?.frontWindowFrame, !window.isNull, !window.isEmpty,
      layouts.contains(where: { $0.frame.intersects(window) })
    {
      index = WindowMover.screenIndex(forFrame: window, screens: layouts)
    } else if let pointer,
      let pointerIndex = layouts.firstIndex(where: { $0.frame.contains(pointer) })
    {
      index = pointerIndex
    } else {
      index = layouts.firstIndex { $0.frame.origin == .zero } ?? 0
    }
    return (layouts[index].usableFrame, index)
  }

  /// Where a grid session is, and every earlier position so Backspace can undo
  /// any grid keystroke. Pure: the coordinator applies it to the overlay.
  struct Navigation: Equatable {
    struct Step: Equatable {
      var region: CGRect
      var depth: Int
    }

    /// One undoable position: the display and the step on it.
    struct Position: Equatable {
      var root: CGRect
      var screenIndex: Int
      var current: Step
    }

    /// The usable frame of the display the grid is on.
    private(set) var root: CGRect
    /// Index of that display in `NSScreen.screens` order.
    private(set) var screenIndex: Int
    private(set) var current: Step
    /// Earlier positions, oldest first.
    private(set) var history: [Position] = []
    /// Where the pointer was before cursor-follow first moved it, so a cancel
    /// can put it back. Nil while the pointer has not been moved.
    var pointerOrigin: CGPoint?

    init(root: CGRect, screenIndex: Int, pointerOrigin: CGPoint? = nil) {
      self.root = root
      self.screenIndex = screenIndex
      self.current = Step(region: root, depth: 0)
      self.pointerOrigin = pointerOrigin
    }

    /// The same display from its full extent with no history: the second
    /// phase of a drag or selection.
    var restarted: Navigation {
      Navigation(root: root, screenIndex: screenIndex, pointerOrigin: pointerOrigin)
    }

    private var position: Position {
      Position(root: root, screenIndex: screenIndex, current: current)
    }

    private mutating func push() {
      history.append(position)
    }

    /// Zoom into `region` (a cell, a centre pseudo-cell, a bisect half).
    mutating func drill(into region: CGRect) {
      push()
      current = Step(region: region, depth: current.depth + 1)
    }

    /// Space: zoom into the centre pseudo-cell.
    mutating func centre(shape: Shape) {
      drill(into: MouseGrid.centreCell(of: current.region, shape: shape))
    }

    /// Slide the region by its own size, clamped inside the display. False,
    /// with nothing recorded, when it is already at that edge.
    @discardableResult
    mutating func move(_ direction: Direction) -> Bool {
      var region = current.region
      switch direction {
      case .left: region.origin.x -= region.width
      case .right: region.origin.x += region.width
      case .up: region.origin.y += region.height
      case .down: region.origin.y -= region.height
      }
      region.origin.x = min(
        max(region.origin.x, root.minX), max(root.minX, root.maxX - region.width))
      region.origin.y = min(
        max(region.origin.y, root.minY), max(root.minY, root.maxY - region.height))
      guard region != current.region else { return false }
      push()
      current.region = region
      return true
    }

    /// Tab / Shift-Tab: the whole of the next / previous display. `roots` are
    /// the displays' usable frames in `NSScreen.screens` order. False with a
    /// single display.
    @discardableResult
    mutating func switchScreen(_ delta: Int, roots: [CGRect]) -> Bool {
      guard roots.count > 1 else { return false }
      let index = ((screenIndex + delta) % roots.count + roots.count) % roots.count
      push()
      root = roots[index]
      screenIndex = index
      current = Step(region: root, depth: 0)
      return true
    }

    /// Undo the last grid keystroke of any kind. False when nothing is left.
    @discardableResult
    mutating func back() -> Bool {
      guard let previous = history.popLast() else { return false }
      root = previous.root
      screenIndex = previous.screenIndex
      current = previous.current
      return true
    }

    /// Back to the whole display, forgetting every step.
    mutating func reset() {
      current = Step(region: root, depth: 0)
      history = []
    }

    /// `--zoom-to-depth`: drill up to `depth` times into the cell under
    /// `point`, stopping while one selection still remains to be made.
    mutating func zoom(toward point: CGPoint, depth: Int, shape: Shape, steps: Int) {
      for _ in 0..<max(0, depth) {
        let region = current.region
        guard
          !MouseGrid.selectionCommits(
            region: region, depth: current.depth, steps: steps, shape: shape)
        else { return }
        drill(into: MouseGrid.cellFrame(containing: point, in: region, shape: shape))
      }
    }
  }
}
