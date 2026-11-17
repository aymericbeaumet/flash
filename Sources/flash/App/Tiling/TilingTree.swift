import CoreGraphics

/// How a container shows its children: side by side (`tiles`), or stacked
/// on the same area with a strip of each sibling left visible (`accordion`).
enum TilingLayoutKind: String, CaseIterable, Equatable, Sendable {
  case tiles
  case accordion

  var toggled: TilingLayoutKind { self == .tiles ? .accordion : .tiles }
}

/// The axis a container lays its children along.
enum TilingOrientation: String, CaseIterable, Equatable, Sendable {
  case horizontal
  case vertical

  var opposite: TilingOrientation { self == .horizontal ? .vertical : .horizontal }

  /// The axis a direction moves along: left and right are horizontal.
  init(_ direction: WindowFocusDirection) {
    switch direction {
    case .left, .right: self = .horizontal
    case .up, .down: self = .vertical
    }
  }
}

extension WindowFocusDirection {
  /// Left and up come first in a container's child order.
  var towardStart: Bool { self == .left || self == .up }
}

/// One workspace's tiling tree, i3/AeroSpace style: containers hold windows
/// and other containers, each with a layout and an orientation; windows are
/// the leaves. Pure value state with pure transitions; the solver turns it
/// into frames and the window layout queue applies them.
///
/// Normalization runs after every transition, as AeroSpace's defaults do:
/// an empty container goes, a container with one child is replaced by that
/// child (the root keeps a single window), and a container nested in another
/// takes the opposite orientation.
struct TilingTree<ID: Hashable>: Equatable {
  typealias Ref = Int

  enum Child: Equatable {
    case window(ID)
    case container(Ref)
  }

  struct Container: Equatable {
    var layout: TilingLayoutKind
    var orientation: TilingOrientation
    var children: [Child] = []
    /// Relative size of each child along `orientation`; positive.
    var weights: [Double] = []
  }

  private(set) var containers: [Ref: Container]
  private(set) var root: Ref
  private var nextRef: Ref = 1

  init(layout: TilingLayoutKind = .tiles, orientation: TilingOrientation = .horizontal) {
    containers = [0: Container(layout: layout, orientation: orientation)]
    root = 0
  }

  /// Rebuild the saved shape, allocating fresh internal references.
  init(_ node: TilingTreeNode<ID>) {
    self.init()
    func build(_ node: TilingTreeNode<ID>, tree: inout Self) -> Child {
      switch node {
      case .window(let id): return .window(id)
      case .container(let layout, let orientation, let children, let weights):
        let ref = tree.nextRef
        tree.nextRef += 1
        let mapped = children.map { build($0, tree: &tree) }
        tree.containers[ref] = Container(
          layout: layout, orientation: orientation, children: mapped, weights: weights)
        return .container(ref)
      }
    }
    switch build(node, tree: &self) {
    case .window(let id):
      containers[root]!.children = [.window(id)]
      containers[root]!.weights = [1]
    case .container(let ref):
      containers[0] = nil
      root = ref
    }
    normalize()
  }

  var node: TilingTreeNode<ID> {
    func stored(_ ref: Ref) -> TilingTreeNode<ID> {
      let container = containers[ref]!
      return .container(
        layout: container.layout, orientation: container.orientation,
        children: container.children.map {
          switch $0 {
          case .window(let id): return .window(id)
          case .container(let inner): return stored(inner)
          }
        }, weights: container.weights)
    }
    return stored(root)
  }

  // MARK: Reading

  /// Every window, depth first: the order `dfs` focus walks.
  var windows: [ID] {
    var result: [ID] = []
    func visit(_ ref: Ref) {
      for child in containers[ref]?.children ?? [] {
        switch child {
        case .window(let id): result.append(id)
        case .container(let inner): visit(inner)
        }
      }
    }
    visit(root)
    return result
  }

  var isEmpty: Bool { containers[root]?.children.isEmpty ?? true }

  func contains(_ id: ID) -> Bool { parent(of: id) != nil }

  /// The container holding `id`.
  func parent(of id: ID) -> Ref? {
    for (ref, container) in containers where container.children.contains(.window(id)) {
      return ref
    }
    return nil
  }

  private func parent(ofContainer ref: Ref) -> Ref? {
    for (candidate, container) in containers where container.children.contains(.container(ref)) {
      return candidate
    }
    return nil
  }

  /// The containers from `id`'s parent up to the root, each with the index of
  /// the child on the path.
  private func path(to id: ID) -> [(ref: Ref, index: Int)] {
    guard var ref = parent(of: id),
      var index = containers[ref]?.children.firstIndex(of: .window(id))
    else { return [] }
    var result = [(ref, index)]
    while let up = parent(ofContainer: ref),
      let at = containers[up]?.children.firstIndex(of: .container(ref))
    {
      ref = up
      index = at
      result.append((ref, index))
    }
    return result
  }

  /// The layout of the container holding `id`, or the root's.
  func layout(around id: ID?) -> (layout: TilingLayoutKind, orientation: TilingOrientation) {
    let ref = id.flatMap(parent(of:)) ?? root
    let container = containers[ref] ?? containers[root]!
    return (container.layout, container.orientation)
  }

  /// A readable form of the tree: `h_tiles[a, v_accordion[b, c]]`. Tests.
  var shape: String {
    func describe(_ ref: Ref) -> String {
      guard let container = containers[ref] else { return "?" }
      let prefix = container.orientation == .horizontal ? "h" : "v"
      let children = container.children.map { child -> String in
        switch child {
        case .window(let id): return "\(id)"
        case .container(let inner): return describe(inner)
        }
      }
      return "\(prefix)_\(container.layout.rawValue)[\(children.joined(separator: ", "))]"
    }
    return describe(root)
  }

  // MARK: Transitions

  /// Add `id` right after `focused` in `focused`'s container, or at the end
  /// of the root. A window already in the tree stays where it is.
  mutating func insert(_ id: ID, after focused: ID? = nil) {
    guard !contains(id) else { return }
    if let focused, let ref = parent(of: focused),
      let index = containers[ref]?.children.firstIndex(of: .window(focused))
    {
      insertChild(.window(id), into: ref, at: index + 1)
    } else {
      insertChild(.window(id), into: root, at: containers[root]!.children.count)
    }
    normalize()
  }

  mutating func remove(_ id: ID) {
    guard let ref = parent(of: id),
      let index = containers[ref]?.children.firstIndex(of: .window(id))
    else { return }
    removeChild(at: index, from: ref)
    normalize()
  }

  /// Exchange two windows' places.
  mutating func swap(_ a: ID, _ b: ID) {
    guard a != b, let refA = parent(of: a), let refB = parent(of: b),
      let indexA = containers[refA]?.children.firstIndex(of: .window(a)),
      let indexB = containers[refB]?.children.firstIndex(of: .window(b))
    else { return }
    containers[refA]!.children[indexA] = .window(b)
    containers[refB]!.children[indexB] = .window(a)
  }

  /// Move `id` one step toward `direction`, i3 style:
  /// - in a container along that axis with a sibling that way, it passes a
  ///   window sibling, or enters a container sibling at its near end;
  /// - nested in a container along that axis, it leaves its inner containers
  ///   and lands beside the branch it was in, on that side;
  /// - with no container along that axis, the root is wrapped in a new one
  ///   along it, with the window on that side (AeroSpace's implicit
  ///   container).
  /// False when it is already at that edge of the workspace.
  @discardableResult
  mutating func move(_ id: ID, _ direction: WindowFocusDirection) -> Bool {
    let axis = TilingOrientation(direction)
    let toStart = direction.towardStart
    let entries = path(to: id)
    guard let own = entries.first else { return false }
    for (level, entry) in entries.enumerated() {
      guard let container = containers[entry.ref], container.orientation == axis else {
        continue
      }
      let target = entry.index + (toStart ? -1 : 1)
      if level == 0 {
        guard container.children.indices.contains(target) else { continue }
        if case .container(let inner) = container.children[target] {
          removeChild(at: own.index, from: own.ref)
          let near = toStart ? (containers[inner]?.children.count ?? 0) : 0
          insertChild(.window(id), into: inner, at: near)
        } else {
          containers[entry.ref]!.children.swapAt(entry.index, target)
          containers[entry.ref]!.weights.swapAt(entry.index, target)
        }
      } else {
        // Removing the window deeper down leaves this level's indices alone.
        removeChild(at: own.index, from: own.ref)
        insertChild(.window(id), into: entry.ref, at: toStart ? entry.index : entry.index + 1)
      }
      normalize()
      return true
    }
    guard let rootContainer = containers[root], rootContainer.orientation != axis,
      windows.count > 1
    else { return false }
    removeChild(at: own.index, from: own.ref)
    let oldRoot = root
    let wrapper = allocate(Container(layout: rootContainer.layout, orientation: axis))
    root = wrapper
    insertChild(.container(oldRoot), into: wrapper, at: 0)
    insertChild(.window(id), into: wrapper, at: toStart ? 0 : 1)
    normalize()
    return true
  }

  /// Put `id` and its sibling toward `direction` in a new container of the
  /// opposite orientation, in the sibling's place. False when no sibling is
  /// there along the parent's axis.
  @discardableResult
  mutating func join(_ id: ID, _ direction: WindowFocusDirection) -> Bool {
    guard let ref = parent(of: id), let container = containers[ref],
      container.orientation == TilingOrientation(direction),
      let index = container.children.firstIndex(of: .window(id))
    else { return false }
    let target = index + (direction.towardStart ? -1 : 1)
    guard container.children.indices.contains(target) else { return false }
    let sibling = container.children[target]
    let weight = container.weights[target]
    let joined = allocate(
      Container(
        layout: container.layout, orientation: container.orientation.opposite,
        children: direction.towardStart ? [sibling, .window(id)] : [.window(id), sibling],
        weights: [1, 1]))
    containers[ref]!.children[target] = .container(joined)
    containers[ref]!.weights[target] = weight
    removeChild(at: index, from: ref)
    normalize()
    return true
  }

  /// The container a dragged edge of `id` changes: the nearest one along
  /// the edge's axis where the branch holding `id` has a neighbor across
  /// that edge, toward `direction`. nil at the edge of the workspace.
  func resizeEdgeTarget(_ id: ID, toward direction: WindowFocusDirection) -> Ref? {
    let axis = TilingOrientation(direction)
    return path(to: id).first { entry in
      guard let container = containers[entry.ref], container.orientation == axis else {
        return false
      }
      return container.children.indices.contains(entry.index + (direction.towardStart ? -1 : 1))
    }?.ref
  }

  /// Move the edge of `id` toward `direction` by `fraction` of its
  /// container's length (positive grows `id`'s branch): the branch and the
  /// neighbor across that edge trade that much weight, nobody else moves,
  /// and each keeps at least 5% of the container. False when no neighbor
  /// is across the edge, or the floor allows no change.
  @discardableResult
  mutating func resizeEdge(
    _ id: ID, toward direction: WindowFocusDirection, by fraction: Double
  ) -> Bool {
    guard let ref = resizeEdgeTarget(id, toward: direction), var container = containers[ref],
      let index = path(to: id).first(where: { $0.ref == ref })?.index
    else { return false }
    let neighbor = index + (direction.towardStart ? -1 : 1)
    let total = container.weights.reduce(0, +)
    let floor = total * 0.05
    let own = container.weights[index]
    let other = container.weights[neighbor]
    let delta = min(max(fraction * total, floor - own), other - floor)
    guard abs(delta) > 1e-9 else { return false }
    container.weights[index] = own + delta
    container.weights[neighbor] = other - delta
    containers[ref] = container
    return true
  }

  /// The container `resize` would change for `id` along `orientation`: the
  /// nearest one along that axis where `id`'s branch has a sibling.
  func resizeTarget(_ id: ID, along orientation: TilingOrientation) -> Ref? {
    path(to: id).first { entry in
      guard let container = containers[entry.ref] else { return false }
      return container.orientation == orientation && container.children.count > 1
    }?.ref
  }

  /// Grow (`fraction` > 0) or shrink the branch holding `id` along
  /// `orientation`, by that share of its container's length, taken from or
  /// given to its siblings in proportion. False when no container along that
  /// axis holds `id` with a sibling.
  @discardableResult
  mutating func resize(_ id: ID, along orientation: TilingOrientation, by fraction: Double)
    -> Bool
  {
    for entry in path(to: id) {
      guard var container = containers[entry.ref], container.orientation == orientation,
        container.children.count > 1
      else { continue }
      let total = container.weights.reduce(0, +)
      let floor = total * 0.05
      let current = container.weights[entry.index]
      let others = total - current
      let wanted = min(
        max(current + fraction * total, floor), total - floor * Double(container.children.count - 1)
      )
      let delta = wanted - current
      guard abs(delta) > 1e-9, others > 0 else { return false }
      for index in container.weights.indices where index != entry.index {
        let share = container.weights[index] / others
        container.weights[index] = max(container.weights[index] - delta * share, floor)
      }
      container.weights[entry.index] = wanted
      containers[entry.ref] = container
      return true
    }
    return false
  }

  /// Every child of every container the same size.
  mutating func balance() {
    for ref in containers.keys {
      containers[ref]!.weights = Array(repeating: 1, count: containers[ref]!.children.count)
    }
  }

  /// One root container holding every window in its current order.
  mutating func flatten() {
    let all = windows
    let rootContainer = containers[root]!
    containers = [
      0: Container(
        layout: rootContainer.layout, orientation: rootContainer.orientation,
        children: all.map(Child.window), weights: Array(repeating: 1, count: all.count))
    ]
    root = 0
    nextRef = 1
  }

  /// The layout of the container holding `id` (the root without one).
  mutating func setLayout(_ layout: TilingLayoutKind, around id: ID?) {
    let ref = id.flatMap(parent(of:)) ?? root
    containers[ref]?.layout = layout
  }

  /// The orientation of the container holding `id`; nested containers flip
  /// to stay opposite.
  mutating func setOrientation(_ orientation: TilingOrientation, around id: ID?) {
    var ref = id.flatMap(parent(of:)) ?? root
    containers[ref]?.orientation = orientation
    // Its parents flip to stay opposite, up to the root; its children follow
    // in `normalize`.
    while let up = parent(ofContainer: ref), let child = containers[ref],
      containers[up]?.orientation == child.orientation
    {
      containers[up]!.orientation = child.orientation.opposite
      ref = up
    }
    normalize()
  }

  // MARK: Storage

  private mutating func allocate(_ container: Container) -> Ref {
    let ref = nextRef
    nextRef += 1
    containers[ref] = container
    return ref
  }

  private mutating func insertChild(_ child: Child, into ref: Ref, at index: Int) {
    guard var container = containers[ref] else { return }
    let weight =
      container.weights.isEmpty
      ? 1 : container.weights.reduce(0, +) / Double(container.weights.count)
    let at = min(max(0, index), container.children.count)
    container.children.insert(child, at: at)
    container.weights.insert(weight, at: at)
    containers[ref] = container
  }

  private mutating func removeChild(at index: Int, from ref: Ref) {
    guard var container = containers[ref], container.children.indices.contains(index) else {
      return
    }
    container.children.remove(at: index)
    container.weights.remove(at: index)
    containers[ref] = container
  }

  /// Drop empty containers, replace single-child ones with their child (the
  /// root keeps a lone window, and takes over a lone container), and give
  /// every nested container the opposite orientation of its parent.
  private mutating func normalize() {
    var changed = true
    while changed {
      changed = false
      for (ref, container) in containers where ref != root {
        guard let up = parent(ofContainer: ref),
          let index = containers[up]?.children.firstIndex(of: .container(ref))
        else {
          containers[ref] = nil
          changed = true
          break
        }
        if container.children.isEmpty {
          removeChild(at: index, from: up)
          containers[ref] = nil
          changed = true
          break
        }
        if container.children.count == 1 {
          containers[up]!.children[index] = container.children[0]
          containers[ref] = nil
          changed = true
          break
        }
      }
      if !changed, let rootContainer = containers[root], rootContainer.children.count == 1,
        case .container(let only) = rootContainer.children[0]
      {
        containers[root] = nil
        root = only
        changed = true
      }
    }
    func orient(_ ref: Ref) {
      guard let container = containers[ref] else { return }
      for child in container.children {
        guard case .container(let inner) = child else { continue }
        if containers[inner]?.orientation == container.orientation {
          containers[inner]?.orientation = container.orientation.opposite
        }
        orient(inner)
      }
    }
    orient(root)
  }
}
