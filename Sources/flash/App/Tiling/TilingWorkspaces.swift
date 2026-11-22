import CoreGraphics

/// One workspace: its tiled windows, the floating ones, and the one zoomed
/// to fill it (`tile fullscreen`).
struct TilingWorkspace<ID: Hashable>: Equatable {
  let name: String
  var tree: TilingTree<ID>
  var floating: [ID] = []
  var fullscreen: ID?

  var windows: [ID] { tree.windows + floating }
  var isEmpty: Bool { tree.isEmpty && floating.isEmpty }
}

/// A display as workspaces see it: its stable identity (the UUID that
/// survives a reconnect), whether it is the main display, and whether it is
/// wider than tall (an `auto` orientation lays out along its long side).
struct TilingDisplay: Equatable, Sendable {
  var identity: String
  var isMain: Bool
  var isWide: Bool
}

/// Which display a workspace is pinned to: `main`, `secondary` (the first
/// display that is not main), or the Nth display from the left.
enum TilingMonitorPattern: Equatable, Sendable {
  case main
  case secondary
  case index(Int)

  init?(_ raw: String) {
    switch raw.lowercased() {
    case "main": self = .main
    case "secondary": self = .secondary
    default:
      guard let index = Int(raw), index >= 1 else { return nil }
      self = .index(index)
    }
  }

  /// The display it names among `displays`, left to right; nil when not
  /// connected.
  func resolve(_ displays: [TilingDisplay]) -> String? {
    switch self {
    case .main: return displays.first(where: \.isMain)?.identity
    case .secondary: return displays.first(where: { !$0.isMain })?.identity
    case .index(let index):
      return displays.indices.contains(index - 1) ? displays[index - 1].identity : nil
    }
  }
}

/// AeroSpace-style workspaces emulated over the displays, without macOS
/// Spaces: every display shows one workspace, the others' windows are
/// parked off screen. Pure value state; the window layout queue turns each
/// change into frames and parking moves.
///
/// - A workspace remembers the display it was last shown on (`home`) by
///   identity; when that display returns after being unplugged, the
///   workspace shows there again.
/// - `persistent` names are always listed (the bar's workspace row);
///   any other workspace is created on demand and dropped once empty and
///   hidden.
/// - `pinned` workspaces show only on their display.
struct TilingWorkspaces<ID: Hashable>: Equatable {
  var layout: TilingLayoutKind = .tiles
  /// nil: horizontal on a wide display, vertical on a tall one.
  var orientation: TilingOrientation?
  private(set) var persistent: [String]
  private(set) var pinned: [String: TilingMonitorPattern]

  private(set) var workspaces: [String: TilingWorkspace<ID>] = [:]
  /// Displays left to right.
  private(set) var displays: [TilingDisplay] = []
  /// Display identity → the workspace it shows.
  private(set) var visible: [String: String] = [:]
  /// Workspace → the display it was last shown on.
  private(set) var home: [String: String] = [:]
  private(set) var focusedDisplay: String?
  /// The workspace focused before the current one, for `back_and_forth`.
  private(set) var previous: String?

  init(
    persistent: [String] = [], pinned: [String: TilingMonitorPattern] = [:],
    layout: TilingLayoutKind = .tiles, orientation: TilingOrientation? = nil
  ) {
    self.persistent = persistent
    self.pinned = pinned
    self.layout = layout
    self.orientation = orientation
  }

  /// A configuration reload: names and pins for what is created or shown
  /// next; existing workspaces keep their trees.
  mutating func configure(
    persistent: [String], pinned: [String: TilingMonitorPattern], layout: TilingLayoutKind,
    orientation: TilingOrientation?
  ) {
    self.persistent = persistent
    self.pinned = pinned
    self.layout = layout
    self.orientation = orientation
  }

  /// Restore display assignments before the first connected-display update.
  mutating func restore(_ state: TilingPersistedState) {
    for workspace in state.workspaces {
      ensure(workspace.name)
      home[workspace.name] = workspace.display
    }
    visible = state.displays
    focusedDisplay = state.focusedDisplay
  }

  /// Keep windows not present in the saved layout after its restored slots.
  mutating func restoreWorkspace(
    _ name: String, tree: TilingTree<ID>, floating: [ID], fullscreen: ID?
  ) {
    ensure(name)
    let existing = workspaces[name]!
    let restored = Set(tree.windows + floating)
    var merged = tree
    for id in existing.tree.windows where !restored.contains(id) { merged.insert(id) }
    workspaces[name]!.tree = merged
    workspaces[name]!.floating = floating + existing.floating.filter { !restored.contains($0) }
    workspaces[name]!.fullscreen = fullscreen
  }

  // MARK: Reading

  var focused: String? { focusedDisplay.flatMap { visible[$0] } }

  /// The workspace holding `id`.
  func workspace(of id: ID) -> String? {
    workspaces.values.first { $0.windows.contains(id) }?.name
  }

  /// The display showing `name`.
  func display(showing name: String) -> String? {
    visible.first { $0.value == name }?.key
  }

  /// Windows of workspaces no display shows: parked off screen.
  var hiddenWindows: Set<ID> {
    let shown = Set(visible.values)
    return Set(workspaces.values.filter { !shown.contains($0.name) }.flatMap(\.windows))
  }

  /// The workspaces a bar lists: the persistent ones in their order, then
  /// every other one in use, by name.
  var listed: [String] {
    let extra = workspaces.keys.filter { !persistent.contains($0) }.sorted(by: Self.nameOrder)
    return persistent + extra
  }

  /// Numbers in numeric order, then names.
  static func nameOrder(_ lhs: String, _ rhs: String) -> Bool {
    switch (Int(lhs), Int(rhs)) {
    case (let l?, let r?): return l < r
    case (.some, nil): return true
    case (nil, .some): return false
    case (nil, nil): return lhs < rhs
    }
  }

  // MARK: Displays

  /// The connected displays changed. A display that left hides its
  /// workspace (its windows are parked until the display or a switch shows
  /// them); a display that arrived shows the workspace whose home it is, or
  /// one pinned to it, or the first persistent workspace no display shows,
  /// or a new one.
  mutating func setDisplays(_ connected: [TilingDisplay]) {
    displays = connected
    let identities = Set(connected.map(\.identity))
    visible = visible.filter { identities.contains($0.key) }
    for display in connected where visible[display.identity] == nil {
      let shown = Set(visible.values)
      let returning = home.filter { $0.value == display.identity && !shown.contains($0.key) }
        .keys.sorted(by: Self.nameOrder).first
      let pinnedHere = pinned.filter {
        $0.value.resolve(connected) == display.identity && !shown.contains($0.key)
      }.keys.sorted(by: Self.nameOrder).first
      let free = persistent.first { name in
        !shown.contains(name)
          && (pinned[name]?.resolve(connected) ?? display.identity)
            == display.identity
      }
      let name = returning ?? pinnedHere ?? free ?? unusedName()
      show(name, on: display.identity)
    }
    if focusedDisplay.map({ !identities.contains($0) }) ?? true {
      focusedDisplay = connected.first(where: \.isMain)?.identity ?? connected.first?.identity
    }
    prune()
  }

  /// The display a window on it would join: focus follows the window.
  mutating func focusDisplay(_ identity: String) {
    guard visible[identity] != nil, focusedDisplay != identity else { return }
    let before = focused
    focusedDisplay = identity
    if before != focused { previous = before }
  }

  // MARK: Windows

  /// Add `id` to `workspace`, or to the workspace `display` (else the
  /// focused display) shows: tiled after `focused`, or floating.
  mutating func add(
    _ id: ID, display: String? = nil, workspace: String? = nil, floating: Bool = false,
    after focused: ID? = nil
  ) {
    guard self.workspace(of: id) == nil,
      let name = workspace ?? (display ?? focusedDisplay).flatMap({ visible[$0] })
        ?? self.focused
    else { return }
    ensure(name)
    if floating {
      workspaces[name]!.floating.append(id)
    } else {
      let anchor = focused.flatMap { self.workspace(of: $0) == name ? $0 : nil }
      workspaces[name]!.tree.insert(id, after: anchor)
    }
  }

  mutating func remove(_ id: ID) {
    guard let name = workspace(of: id) else { return }
    workspaces[name]!.tree.remove(id)
    workspaces[name]!.floating.removeAll { $0 == id }
    if workspaces[name]!.fullscreen == id { workspaces[name]!.fullscreen = nil }
    prune()
  }

  /// Tile a floating window, or float a tiled one.
  mutating func toggleFloating(_ id: ID, after focused: ID? = nil) {
    guard let name = workspace(of: id) else { return }
    if workspaces[name]!.floating.contains(id) {
      workspaces[name]!.floating.removeAll { $0 == id }
      workspaces[name]!.tree.insert(id, after: focused)
    } else {
      workspaces[name]!.tree.remove(id)
      workspaces[name]!.floating.append(id)
      if workspaces[name]!.fullscreen == id { workspaces[name]!.fullscreen = nil }
    }
  }

  /// Zoom a window to fill its workspace, or end the zoom.
  mutating func toggleFullscreen(_ id: ID) {
    guard let name = workspace(of: id), workspaces[name]!.tree.contains(id) else { return }
    workspaces[name]!.fullscreen = workspaces[name]!.fullscreen == id ? nil : id
  }

  /// Apply `change` to the tree of the workspace holding `id`.
  mutating func updateTree(holding id: ID, _ change: (inout TilingTree<ID>) -> Void) {
    guard let name = workspace(of: id) else { return }
    change(&workspaces[name]!.tree)
  }

  /// Apply `change` to the tree of `name`.
  mutating func updateTree(of name: String, _ change: (inout TilingTree<ID>) -> Void) {
    guard workspaces[name] != nil else { return }
    change(&workspaces[name]!.tree)
  }

  /// Move `id` to `name`, created on demand; it tiles at the end there.
  mutating func move(_ id: ID, to name: String) {
    guard let source = workspace(of: id), source != name else { return }
    let wasFloating = workspaces[source]!.floating.contains(id)
    workspaces[source]!.tree.remove(id)
    workspaces[source]!.floating.removeAll { $0 == id }
    if workspaces[source]!.fullscreen == id { workspaces[source]!.fullscreen = nil }
    ensure(name)
    if wasFloating {
      workspaces[name]!.floating.append(id)
    } else {
      workspaces[name]!.tree.insert(id)
    }
    prune()
  }

  // MARK: Switching

  /// Show `name` and focus it: on the display showing it already, else on
  /// its pinned display, else on the focused display in place of what that
  /// one showed. Created on demand.
  mutating func switchTo(_ name: String) {
    let before = focused
    if let shownOn = display(showing: name) {
      focusedDisplay = shownOn
    } else {
      guard
        let target = pinned[name]?.resolve(displays) ?? focusedDisplay
          ?? displays.first?.identity
      else { return }
      ensure(name)
      show(name, on: target)
      focusedDisplay = target
    }
    if before != focused, let before { previous = before }
    prune()
  }

  /// The workspace focused before this one.
  mutating func backAndForth() {
    guard let previous, workspaces[previous] != nil || persistent.contains(previous) else {
      return
    }
    switchTo(previous)
  }

  /// The next (`step` 1) or previous listed workspace, wrapping, skipping
  /// the ones other displays show.
  mutating func cycle(_ step: Int) {
    let names = listed
    guard let current = focused, let index = names.firstIndex(of: current), names.count > 1
    else { return }
    let others = Set(visible.filter { $0.key != focusedDisplay }.values)
    var next = index
    for _ in 0..<names.count {
      next = ((next + step) % names.count + names.count) % names.count
      if !others.contains(names[next]) { break }
    }
    guard names[next] != current else { return }
    switchTo(names[next])
  }

  /// Show the focused workspace on the next (`step` 1) or previous display;
  /// the display it leaves shows the one it displaced, the two swapping,
  /// unless that one is pinned there: then another workspace last shown on
  /// it, a free persistent one, or a new one. A pinned workspace stays where
  /// it is.
  mutating func moveFocusedWorkspace(_ step: Int) {
    guard let name = focused, pinned[name] == nil, let source = focusedDisplay,
      let index = displays.firstIndex(where: { $0.identity == source }), displays.count > 1
    else { return }
    let target = displays[((index + step) % displays.count + displays.count) % displays.count]
      .identity
    let displaced = visible[target].flatMap { pinned[$0] == nil ? $0 : nil }
    visible[source] = nil
    show(name, on: target)
    let shown = Set(visible.values)
    let fallback =
      displaced
      ?? home.filter { $0.value == source && !shown.contains($0.key) }.keys
      .sorted(by: Self.nameOrder).first
      ?? persistent.first { !shown.contains($0) && pinned[$0] == nil } ?? unusedName()
    show(fallback, on: source)
    focusedDisplay = target
    prune()
  }

  // MARK: Storage

  private mutating func ensure(_ name: String) {
    guard workspaces[name] == nil else { return }
    workspaces[name] = TilingWorkspace(
      name: name, tree: TilingTree(layout: layout, orientation: rootOrientation(for: name)))
  }

  private func rootOrientation(for name: String) -> TilingOrientation {
    if let orientation { return orientation }
    let identity = display(showing: name) ?? home[name] ?? focusedDisplay
    let wide = displays.first(where: { $0.identity == identity })?.isWide ?? true
    return wide ? .horizontal : .vertical
  }

  private mutating func show(_ name: String, on identity: String) {
    if let other = display(showing: name), other != identity { visible[other] = nil }
    visible[identity] = name
    home[name] = identity
    ensure(name)
  }

  /// The first numbered name no workspace uses.
  private func unusedName() -> String {
    var index = 1
    while workspaces[String(index)] != nil || persistent.contains(String(index))
      || visible.values.contains(String(index))
    {
      index += 1
    }
    return String(index)
  }

  /// Drop empty workspaces nobody shows unless they are persistent.
  private mutating func prune() {
    let shown = Set(visible.values)
    for (name, workspace) in workspaces
    where workspace.isEmpty && !shown.contains(name) && !persistent.contains(name) {
      workspaces[name] = nil
      home[name] = nil
    }
  }
}
