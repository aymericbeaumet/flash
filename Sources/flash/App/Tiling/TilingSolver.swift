import CoreGraphics

/// Space between tiled windows (`inner`) and between them and the usable
/// frame's edges (`outer`), in points.
struct TilingGaps: Equatable, Sendable {
  var innerHorizontal: CGFloat = 0
  var innerVertical: CGFloat = 0
  var outerLeft: CGFloat = 0
  var outerRight: CGFloat = 0
  var outerTop: CGFloat = 0
  var outerBottom: CGFloat = 0

  static let zero = TilingGaps()

  init(
    innerHorizontal: CGFloat = 0, innerVertical: CGFloat = 0, outerLeft: CGFloat = 0,
    outerRight: CGFloat = 0, outerTop: CGFloat = 0, outerBottom: CGFloat = 0
  ) {
    self.innerHorizontal = innerHorizontal
    self.innerVertical = innerVertical
    self.outerLeft = outerLeft
    self.outerRight = outerRight
    self.outerTop = outerTop
    self.outerBottom = outerBottom
  }

  init(inner: CGFloat, outer: CGFloat) {
    self.init(
      innerHorizontal: inner, innerVertical: inner, outerLeft: outer, outerRight: outer,
      outerTop: outer, outerBottom: outer)
  }
}

/// Turns a tiling tree into window frames, in NSScreen coordinates (origin
/// at the primary display's bottom-left, y up). Pure: the same tree, frame
/// and gaps always give the same frames, on whole points, so applying them
/// twice moves nothing.
enum TilingSolver {
  /// The smallest side a solved frame keeps, so a crowded container still
  /// gives every window a frame macOS accepts.
  static let minimumSide: CGFloat = 40

  static func frames<ID: Hashable>(
    _ tree: TilingTree<ID>, in usable: CGRect, gaps: TilingGaps = .zero,
    accordionPadding: CGFloat = 30
  ) -> [ID: CGRect] {
    solve(tree, in: usable, gaps: gaps, accordionPadding: accordionPadding).windows
  }

  /// Each container's area, by reference: what `tile resize` measures a
  /// step in points against.
  static func containerFrames<ID: Hashable>(
    _ tree: TilingTree<ID>, in usable: CGRect, gaps: TilingGaps = .zero,
    accordionPadding: CGFloat = 30
  ) -> [TilingTree<ID>.Ref: CGRect] {
    solve(tree, in: usable, gaps: gaps, accordionPadding: accordionPadding).containers
  }

  /// The tiled window a hand drag of `dragged` lands on when the button
  /// comes up at `point`: the window of its workspace whose last frame
  /// (`frames`, as the engine applied them) contains the point, the smallest
  /// when accordion tiles overlap. Never the dragged window itself, nor a
  /// sibling of its own accordion, whose area it already shares; nil then,
  /// in a gap, or off the tiles: the drop goes back.
  static func dropTarget<ID: Hashable>(
    for dragged: ID, at point: CGPoint, in tree: TilingTree<ID>, frames: [ID: CGRect]
  ) -> ID? {
    let parent = tree.parent(of: dragged)
    let stacked = parent.flatMap { tree.containers[$0]?.layout } == .accordion
    func area(_ id: ID) -> CGFloat {
      guard let frame = frames[id] else { return .infinity }
      return frame.width * frame.height
    }
    return tree.windows.filter { id in
      guard id != dragged, let frame = frames[id], frame.contains(point) else { return false }
      return !(stacked && tree.parent(of: id) == parent)
    }.min { area($0) < area($1) }
  }

  private static func solve<ID: Hashable>(
    _ tree: TilingTree<ID>, in usable: CGRect, gaps: TilingGaps, accordionPadding: CGFloat
  ) -> (windows: [ID: CGRect], containers: [TilingTree<ID>.Ref: CGRect]) {
    let area = CGRect(
      x: usable.minX + gaps.outerLeft, y: usable.minY + gaps.outerBottom,
      width: usable.width - gaps.outerLeft - gaps.outerRight,
      height: usable.height - gaps.outerTop - gaps.outerBottom)
    var frames: [ID: CGRect] = [:]
    var containers: [TilingTree<ID>.Ref: CGRect] = [:]
    func place(_ ref: TilingTree<ID>.Ref, in rect: CGRect) {
      containers[ref] = rect
      guard let container = tree.containers[ref], !container.children.isEmpty else { return }
      let rects: [CGRect]
      switch container.layout {
      case .tiles:
        rects = tiles(
          rect, weights: container.weights, orientation: container.orientation,
          gap: container.orientation == .horizontal ? gaps.innerHorizontal : gaps.innerVertical)
      case .accordion:
        rects = accordion(
          rect, count: container.children.count, orientation: container.orientation,
          padding: accordionPadding)
      }
      for (child, childRect) in zip(container.children, rects) {
        switch child {
        case .window(let id): frames[id] = childRect
        case .container(let inner): place(inner, in: childRect)
        }
      }
    }
    place(tree.root, in: area)
    return (frames, containers)
  }

  /// Side by side along `orientation`, sized by `weights`: left to right, or
  /// top to bottom. Edges are cumulative and rounded, so neighbors meet at
  /// the gap exactly and the last child ends at the container's edge.
  static func tiles(
    _ rect: CGRect, weights: [Double], orientation: TilingOrientation, gap: CGFloat
  ) -> [CGRect] {
    let count = weights.count
    guard count > 0 else { return [] }
    let total = max(weights.reduce(0, +), .ulpOfOne)
    let length = orientation == .horizontal ? rect.width : rect.height
    let available = max(length - gap * CGFloat(count - 1), 0)
    var result: [CGRect] = []
    var cumulative = 0.0
    var start = (0 as CGFloat)
    for (index, weight) in weights.enumerated() {
      cumulative += weight
      let end =
        index == count - 1
        ? available : (available * CGFloat(cumulative / total)).rounded()
      let size = max(end - start, minimumSide)
      let offset = start + gap * CGFloat(index)
      switch orientation {
      case .horizontal:
        result.append(
          CGRect(
            x: (rect.minX + offset).rounded(), y: rect.minY.rounded(), width: size.rounded(),
            height: rect.height.rounded()))
      case .vertical:
        // The first child is on top: NSScreen y grows upward.
        result.append(
          CGRect(
            x: rect.minX.rounded(), y: (rect.maxY - offset - size).rounded(),
            width: rect.width.rounded(), height: size.rounded()))
      }
      start = end
    }
    return result
  }

  /// Every child on the same area, each inset by `padding` on the sides it
  /// has siblings, as AeroSpace draws an accordion: the first is flush with
  /// the start, the last with the end, the rest inset on both.
  static func accordion(
    _ rect: CGRect, count: Int, orientation: TilingOrientation, padding: CGFloat
  ) -> [CGRect] {
    guard count > 0 else { return [] }
    guard count > 1 else { return [rect.integral] }
    let length = orientation == .horizontal ? rect.width : rect.height
    let inset = min(padding, max((length - minimumSide) / 2, 0))
    return (0..<count).map { index in
      let leading: CGFloat = index == 0 ? 0 : inset
      let trailing: CGFloat = index == count - 1 ? 0 : inset
      switch orientation {
      case .horizontal:
        return CGRect(
          x: (rect.minX + leading).rounded(), y: rect.minY.rounded(),
          width: (rect.width - leading - trailing).rounded(), height: rect.height.rounded())
      case .vertical:
        return CGRect(
          x: rect.minX.rounded(), y: (rect.minY + trailing).rounded(),
          width: rect.width.rounded(), height: (rect.height - leading - trailing).rounded())
      }
    }
  }
}
