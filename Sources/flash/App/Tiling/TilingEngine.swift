import ApplicationServices
import CoreGraphics

/// What the tiling engine asks of the windows it manages. The window layout
/// manager implements it with Accessibility on its serial queue; tests use a
/// fake that records every call.
protocol TilingWindowDriver: AnyObject {
  associatedtype Key: Hashable
  /// The window number, when its AX element exposes one.
  func tilingWindowNumber(of key: Key) -> UInt32?
  /// One AX title read for a title rule or persisted window identity.
  func tilingTitle(of key: Key) -> String?
  /// The window's frame now, NSScreen coordinates.
  func tilingFrame(of key: Key) -> CGRect?
  /// Move and size the window, within `bounds` (its display's usable frame).
  func tilingApply(_ frame: CGRect, to key: Key, within bounds: CGRect)
  /// Park the window off screen with its size kept: its top-left corner at
  /// `topLeft`, beside a display's bottom corner, so all but a sliver hides.
  func tilingPark(_ key: Key, topLeft: CGPoint)
  /// Raise and focus the window, activating its app.
  func tilingRaise(_ key: Key)
}

/// The workspace state the bar and plugins read.
struct TilingStatus: Equatable, Sendable {
  var focused: String?
  var listed: [String]
  var previous: String?

  /// `core:workspace.changed`'s payload, when the focused workspace is not
  /// the one `before` had: `{workspace, previous?, workspaces}`.
  func workspaceChange(since before: TilingStatus?) -> [String: Any]? {
    guard let focused, focused != before?.focused else { return nil }
    var payload: [String: Any] = ["workspace": focused, "workspaces": listed]
    if let previous { payload["previous"] = previous }
    return payload
  }
}

/// AeroSpace-style tiling over the windows the window catalog knows: which
/// windows it manages, the frames it last set, the windows it parked for
/// hidden workspaces, and the commands. Confined to the window layout queue;
/// every decision is made from `TilingWorkspaces` and `TilingSolver`, and only
/// the frames that changed are written.
final class TilingEngine<Driver: TilingWindowDriver> {
  typealias Key = Driver.Key

  /// A window as the catalog first reported it.
  struct Candidate {
    var key: Key
    var pid: pid_t
    var bundleID: String?
    var frame: CGRect
    /// nil when unreadable; a window that is not `AXStandardWindow` floats.
    var subrole: String?
  }

  private unowned let driver: Driver
  private(set) var settings: TilingSettings
  private(set) var workspaces: TilingWorkspaces<Key>
  private var pids: [Key: pid_t] = [:]
  private var identities: [Key: TilingWindowIdentity] = [:]
  private var bundleIDs: [Key: String] = [:]
  private var restoring: TilingRestore<Key>?
  var layoutDidChange: (() -> Void)?
  private var screens: [WindowScreenLayout] = []
  /// The on-screen frame Flash last set for each window it shows.
  private var applied: [Key: CGRect] = [:]
  private(set) var parked: Set<Key> = []
  /// Parked windows their app pulled back on screen and Flash parked again,
  /// once each while hidden: an app that keeps doing it stays where it is.
  private var reparked: Set<Key> = []
  /// A floating window's frame from before it was parked.
  private var floatingFrames: [Key: CGRect] = [:]
  private(set) var focused: Key?
  private var lastFocused: [String: Key] = [:]
  private var lastStatus: TilingStatus?
  var statusDidChange: ((TilingStatus) -> Void)?

  init(driver: Driver, settings: TilingSettings) {
    self.driver = driver
    self.settings = settings
    workspaces = TilingWorkspaces(
      persistent: settings.workspaces, pinned: settings.pinned, layout: settings.layout,
      orientation: settings.orientation)
  }

  func manages(_ key: Key) -> Bool { pids[key] != nil }
  func isParked(_ key: Key) -> Bool { parked.contains(key) }
  var status: TilingStatus {
    TilingStatus(
      focused: workspaces.focused, listed: workspaces.listed, previous: workspaces.previous)
  }

  func restore(_ state: TilingPersistedState) {
    guard pids.isEmpty, state.malformation == nil else { return }
    restoring = TilingRestore(state)
    workspaces.restore(state)
  }

  func snapshot() -> TilingPersistedState {
    var windows: [TilingWindowIdentity] = []
    var slots: [Key: Int] = [:]
    for name in workspaces.listed {
      for key in workspaces.workspaces[name]?.windows ?? [] {
        guard var identity = identities[key] else { continue }
        identity.frame = floatingFrames[key] ?? applied[key] ?? identity.frame
        slots[key] = windows.count
        windows.append(identity)
      }
    }
    let stored = workspaces.listed.compactMap { name -> TilingPersistedWorkspace? in
      guard let workspace = workspaces.workspaces[name],
        let tree = workspace.tree.node.compactMapWindows({ slots[$0] })
      else { return nil }
      return TilingPersistedWorkspace(
        name: name, display: workspaces.home[name], tree: tree,
        floating: workspace.floating.compactMap { slots[$0] },
        fullscreen: workspace.fullscreen.flatMap { slots[$0] })
    }
    return TilingPersistedState(
      focusedDisplay: workspaces.focusedDisplay, displays: workspaces.visible,
      workspaces: stored, windows: windows)
  }

  // MARK: Inputs

  /// A configuration reload: gaps and padding apply at once; workspace names
  /// and pins to what is created or shown next.
  func update(_ settings: TilingSettings) {
    guard settings != self.settings else { return }
    let startsPersisting = settings.persist && !self.settings.persist
    self.settings = settings
    if startsPersisting {
      for key in pids.keys {
        guard let bundle = bundleIDs[key] else { continue }
        identities[key] = TilingWindowIdentity(
          bundleID: bundle, windowNumber: driver.tilingWindowNumber(of: key),
          titleHash: driver.tilingTitle(of: key).map(TilingWindowIdentity.titleHash),
          frame: floatingFrames[key] ?? applied[key])
      }
    }
    workspaces.configure(
      persistent: settings.workspaces, pinned: settings.pinned, layout: settings.layout,
      orientation: settings.orientation)
    workspaces.setDisplays(workspaces.displays)
    relayout()
    publish()
  }

  /// The displays as the layout queue last read them.
  func setScreens(_ screens: [WindowScreenLayout]) {
    guard !screens.isEmpty else { return }
    let displaysChanged = screens.map(\.identity) != self.screens.map(\.identity)
    self.screens = screens
    if displaysChanged { workspaces.setDisplays(Self.displays(screens)) }
    relayout()
    publish()
  }

  /// Windows the catalog read: the ones not managed yet join the workspace
  /// their display shows (or a rule's), tiled after the focused window, or
  /// floating.
  func adopt(_ candidates: [Candidate]) {
    var adopted = false
    for candidate in candidates where pids[candidate.key] == nil {
      var title: String??
      func readTitle() -> String? {
        if title == nil { title = .some(driver.tilingTitle(of: candidate.key)) }
        return title ?? nil
      }
      let rule = TilingRule.first(
        in: settings.rules, bundleID: candidate.bundleID, title: readTitle)
      let number = settings.persist ? driver.tilingWindowNumber(of: candidate.key) : nil
      let match = candidate.bundleID.flatMap { bundle in
        restoring?.claim(
          candidate.key, bundleID: bundle, windowNumber: { number },
          title: readTitle, frame: candidate.frame)
      }
      let floats =
        rule?.floats ?? match?.floating
        ?? candidate.subrole.map { $0 != kAXStandardWindowSubrole as String } ?? false
      let destination = rule?.workspace ?? match?.workspace
      workspaces.add(
        candidate.key, display: identity(containing: candidate.frame),
        workspace: destination, floating: floats, after: focused)
      pids[candidate.key] = candidate.pid
      bundleIDs[candidate.key] = candidate.bundleID
      if settings.persist, let bundle = candidate.bundleID {
        if match == nil { _ = readTitle() }
        identities[candidate.key] = TilingWindowIdentity(
          bundleID: bundle, windowNumber: number,
          titleHash: (title ?? nil).map(TilingWindowIdentity.titleHash)
            ?? restoring?.identity(of: candidate.key)?.titleHash,
          frame: candidate.frame)
      }
      if let match, let name = workspaces.workspace(of: candidate.key) {
        if rule?.workspace != nil || rule?.floats != nil {
          restoring?.forget(candidate.key)
          restoring?.close(name)
          restoring?.close(match.workspace)
        }
        if let projection = restoring?.projection(of: match.workspace) {
          workspaces.restoreWorkspace(
            match.workspace, tree: projection.tree, floating: projection.floating,
            fullscreen: projection.fullscreen)
        }
      }
      if floats { floatingFrames[candidate.key] = candidate.frame }
      adopted = true
    }
    guard adopted else { return }
    relayout()
    publish()
  }

  /// The window closed, was minimized, or its app quit.
  func forget(_ key: Key) {
    guard pids.removeValue(forKey: key) != nil else { return }
    workspaces.remove(key)
    restoring?.forget(key)
    identities[key] = nil
    bundleIDs[key] = nil
    applied[key] = nil
    parked.remove(key)
    reparked.remove(key)
    floatingFrames[key] = nil
    if focused == key { focused = nil }
    relayout()
    publish()
  }

  func forget(pid: pid_t) {
    for key in pids.filter({ $0.value == pid }).keys { forget(key) }
  }

  /// The user focused `key`: its workspace's display becomes the focused
  /// one, and a window parked on a hidden workspace brings that workspace
  /// back, as AeroSpace does when Command-Tab reaches it.
  func focus(_ key: Key) {
    guard pids[key] != nil, let name = workspaces.workspace(of: key) else { return }
    focused = key
    lastFocused[name] = key
    if let display = workspaces.display(showing: name) {
      workspaces.focusDisplay(display)
    } else {
      workspaces.switchTo(name)
      relayout()
    }
    publish()
  }

  /// The user moved `key` by hand and let go, the pointer `at` a point (the
  /// frame's center when unknown). A floating window keeps its frame. A
  /// tiled one dropped on another tile of its workspace swaps places with
  /// it; dropped on another display, it joins the workspace shown there;
  /// anywhere else it goes back to its tile. A parked window that came back
  /// on screen is its app's doing: it parks again, once.
  func userMoved(_ key: Key, to frame: CGRect, at point: CGPoint? = nil) {
    guard let name = handDrag(of: key, to: frame) else { return }
    restoring?.close(name)
    let drop = point ?? CGPoint(x: frame.midX, y: frame.midY)
    if let workspace = workspaces.workspaces[name], workspace.fullscreen != key,
      let other = TilingSolver.dropTarget(for: key, at: drop, in: workspace.tree, frames: applied)
    {
      workspaces.updateTree(holding: key) { $0.swap(key, other) }
      applied[other] = nil
    } else if let target = identity(at: drop) ?? identity(containing: frame),
      let shown = workspaces.visible[target], shown != name
    {
      workspaces.move(key, to: shown)
      workspaces.focusDisplay(target)
    }
    applied[key] = nil
    relayout()
    publish()
  }

  /// The user resized `key` by hand and let go: each edge that moved pulls
  /// the split it sits on, trading length with the window across it, so the
  /// window keeps the edge it was given; an edge of the workspace has nothing
  /// across it and snaps back. A floating window keeps its frame.
  func userResized(_ key: Key, to frame: CGRect) {
    guard let name = handDrag(of: key, to: frame) else { return }
    restoring?.close(name)
    if let before = applied[key], let workspace = workspaces.workspaces[name],
      workspace.fullscreen != key, let usable = usableFrame(showing: name)
    {
      var tree = workspace.tree
      let growth: [(WindowFocusDirection, CGFloat)] = [
        (.left, before.minX - frame.minX), (.right, frame.maxX - before.maxX),
        (.up, frame.maxY - before.maxY), (.down, before.minY - frame.minY),
      ]
      for (direction, points) in growth where abs(points) >= 1 {
        guard let ref = tree.resizeEdgeTarget(key, toward: direction),
          let container = tree.containers[ref],
          let rect = TilingSolver.containerFrames(
            tree, in: usable, gaps: settings.gaps, accordionPadding: settings.accordionPadding)[
              ref]
        else { continue }
        let axis = TilingOrientation(direction)
        let gap = axis == .horizontal ? settings.gaps.innerHorizontal : settings.gaps.innerVertical
        let length =
          (axis == .horizontal ? rect.width : rect.height)
          - gap * CGFloat(container.children.count - 1)
        guard length > 0 else { continue }
        tree.resizeEdge(key, toward: direction, by: Double(points / length))
      }
      workspaces.updateTree(of: name) { $0 = tree }
    }
    applied[key] = nil
    relayout()
    publish()
  }

  /// What every hand drag of `key` shares: the workspace of a tiled window
  /// to judge the drop in; nil once a parked or floating window was dealt
  /// with, or for a window tiling does not manage.
  private func handDrag(of key: Key, to frame: CGRect) -> String? {
    guard pids[key] != nil, let name = workspaces.workspace(of: key) else { return nil }
    if parked.contains(key) {
      guard reparked.insert(key).inserted else { return nil }
      parked.remove(key)
      relayout()
      return nil
    }
    if workspaces.workspaces[name]?.floating.contains(key) == true {
      restoring?.close(name)
      floatingFrames[key] = frame
      layoutDidChange?()
      applied[key] = nil
      return nil
    }
    return name
  }

  /// Show every parked window again where it was, so nothing stays off
  /// screen once tiling stops or Flash quits.
  func releaseAll() {
    let main = screens.first(where: { $0.frame.origin == .zero }) ?? screens.first
    for key in parked {
      guard let main else { break }
      let frame =
        floatingFrames[key] ?? applied[key]
        ?? main.usableFrame.insetBy(
          dx: main.usableFrame.width / 6, dy: main.usableFrame.height / 6)
      let bounds =
        screens.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }?
        .usableFrame ?? main.usableFrame
      driver.tilingApply(frame, to: key, within: bounds)
    }
    parked.removeAll()
    reparked.removeAll()
  }

  // MARK: Commands

  func perform(_ command: TilingCommand) -> TilingOutcome {
    guard let key = focused, let name = workspaces.workspace(of: key) else {
      return .failed("no focused window is tiled: focus a window Flash tiles first")
    }
    let floating = workspaces.workspaces[name]?.floating.contains(key) == true
    switch command {
    case .move, .swap, .join, .resize, .fullscreen:
      if floating { return .failed("the focused window floats: tile float tiles it again") }
    case .float, .layout, .balance, .flatten:
      break
    }
    restoring?.close(name)
    switch command {
    case .float:
      workspaces.toggleFloating(key)
      if !floating { floatingFrames[key] = applied[key] ?? driver.tilingFrame(of: key) }
    case .move(let direction):
      workspaces.updateTree(holding: key) { $0.move(key, direction) }
    case .swap(let direction):
      let candidates = (workspaces.workspaces[name]?.tree.windows ?? []).compactMap { id in
        applied[id].map { WindowFocusCandidate(id: id, frame: $0) }
      }
      guard let other = WindowFocusPlanner.nearest(direction, from: key, in: candidates) else {
        return .done
      }
      workspaces.updateTree(holding: key) { $0.swap(key, other) }
    case .join(let direction):
      workspaces.updateTree(holding: key) { $0.join(key, direction) }
    case .layout(let request):
      workspaces.updateTree(holding: key) { tree in
        switch request {
        case .tiles: tree.setLayout(.tiles, around: key)
        case .accordion: tree.setLayout(.accordion, around: key)
        case .horizontal: tree.setOrientation(.horizontal, around: key)
        case .vertical: tree.setOrientation(.vertical, around: key)
        case .toggle: tree.setLayout(tree.layout(around: key).layout.toggled, around: key)
        }
      }
    case .resize(let dimension, let amount):
      guard let tree = workspaces.workspaces[name]?.tree,
        let usable = usableFrame(showing: name)
      else { return .done }
      let axis: TilingOrientation
      switch dimension {
      case .width: axis = .horizontal
      case .height: axis = .vertical
      case .smart: axis = tree.layout(around: key).orientation
      }
      let lengths = TilingSolver.containerFrames(
        tree, in: usable, gaps: settings.gaps, accordionPadding: settings.accordionPadding)
      guard let ref = tree.resizeTarget(key, along: axis), let rect = lengths[ref] else {
        return .done
      }
      let length = axis == .horizontal ? rect.width : rect.height
      guard length > 0 else { return .done }
      workspaces.updateTree(holding: key) {
        $0.resize(key, along: axis, by: Double(CGFloat(amount) / length))
      }
    case .balance:
      workspaces.updateTree(of: name) { $0.balance() }
    case .flatten:
      workspaces.updateTree(of: name) { $0.flatten() }
    case .fullscreen:
      workspaces.toggleFullscreen(key)
    }
    relayout()
    if case .fullscreen = command { driver.tilingRaise(key) }
    publish()
    return .done
  }

  func perform(_ command: WorkspaceCommand) -> TilingOutcome {
    switch command {
    case .switchTo(let name):
      guard TilingSettings.isValidWorkspaceName(name) else {
        return .failed("a workspace name is one word, at most 32 characters")
      }
      workspaces.switchTo(name)
    case .next: workspaces.cycle(1)
    case .previous: workspaces.cycle(-1)
    case .backAndForth:
      guard workspaces.previous != nil else { return .failed("no previous workspace yet") }
      workspaces.backAndForth()
    case .moveWindow(let name):
      guard TilingSettings.isValidWorkspaceName(name) else {
        return .failed("a workspace name is one word, at most 32 characters")
      }
      guard let key = focused, pids[key] != nil else {
        return .failed("no focused window is tiled: focus a window Flash tiles first")
      }
      if let old = workspaces.workspace(of: key) { restoring?.close(old) }
      restoring?.close(name)
      workspaces.move(key, to: name)
    case .moveToMonitor(let step):
      guard workspaces.displays.count > 1 else { return .failed("only one display") }
      workspaces.moveFocusedWorkspace(step)
    case .list:
      return .output(listing())
    }
    relayout()
    focusFocusedWorkspace()
    publish()
    return .done
  }

  /// `workspace list`: one workspace a line, its window count, the display
  /// showing it, `*` on the focused one.
  func listing() -> String {
    workspaces.listed.map { name in
      let count = workspaces.workspaces[name]?.windows.count ?? 0
      var line = "\(name)\t\(count) window\(count == 1 ? "" : "s")"
      if let display = workspaces.display(showing: name),
        let index = workspaces.displays.firstIndex(where: { $0.identity == display })
      {
        line += "\tdisplay \(index + 1)"
      }
      if name == workspaces.focused { line += "\t*" }
      return line
    }.joined(separator: "\n")
  }

  // MARK: Layout

  /// Write what changed: tiled windows of shown workspaces to their tiles,
  /// floating ones back from their parking, the rest of every hidden
  /// workspace to its display's corner.
  func relayout() {
    var desired: [Key: (frame: CGRect, bounds: CGRect)] = [:]
    for (identity, name) in workspaces.visible {
      guard let screen = screens.first(where: { $0.identity == identity }),
        let workspace = workspaces.workspaces[name]
      else { continue }
      let usable = screen.usableFrame
      var frames = TilingSolver.frames(
        workspace.tree, in: usable, gaps: settings.gaps,
        accordionPadding: settings.accordionPadding)
      if let full = workspace.fullscreen { frames[full] = Self.outerArea(usable, settings.gaps) }
      for (key, frame) in frames { desired[key] = (frame, usable) }
      for key in workspace.floating where parked.contains(key) {
        let frame =
          floatingFrames[key]
          ?? usable.insetBy(dx: usable.width / 6, dy: usable.height / 6).integral
        desired[key] = (frame, usable)
      }
    }
    for (key, target) in desired where parked.contains(key) || applied[key] != target.frame {
      driver.tilingApply(target.frame, to: key, within: target.bounds)
      applied[key] = target.frame
      parked.remove(key)
      reparked.remove(key)
    }
    for key in workspaces.hiddenWindows where !parked.contains(key) {
      if let name = workspaces.workspace(of: key),
        workspaces.workspaces[name]?.floating.contains(key) == true
      {
        floatingFrames[key] = driver.tilingFrame(of: key) ?? floatingFrames[key]
      }
      guard let topLeft = parkingOrigin(for: key) else { continue }
      driver.tilingPark(key, topLeft: topLeft)
      parked.insert(key)
    }
  }

  private static func outerArea(_ usable: CGRect, _ gaps: TilingGaps) -> CGRect {
    CGRect(
      x: usable.minX + gaps.outerLeft, y: usable.minY + gaps.outerBottom,
      width: usable.width - gaps.outerLeft - gaps.outerRight,
      height: usable.height - gaps.outerTop - gaps.outerBottom
    ).integral
  }

  /// Where a hidden window parks, on the display its workspace was last
  /// shown on (else the main one): hanging off the bottom-right corner, its
  /// top-left point one point inside, or off the bottom-left corner when
  /// another display lies beyond the bottom-right, as AeroSpace does; the
  /// corner that covers the least of any other display otherwise.
  private func parkingOrigin(for key: Key) -> CGPoint? {
    let home = workspaces.workspace(of: key).flatMap { workspaces.home[$0] }
    guard
      let screen = screens.first(where: { $0.identity == home })
        ?? screens.first(where: { $0.frame.origin == .zero }) ?? screens.first
    else { return nil }
    let size =
      applied[key]?.size ?? floatingFrames[key]?.size ?? driver.tilingFrame(of: key)?.size
      ?? screen.frame.size
    let top = screen.frame.minY + 1
    let origins = [
      CGPoint(x: screen.frame.maxX - 1, y: top),
      CGPoint(x: screen.frame.minX + 1 - size.width, y: top),
    ]
    let others = screens.filter { $0.identity != screen.identity }.map(\.frame)
    func covered(_ origin: CGPoint) -> CGFloat {
      let rect = CGRect(
        x: origin.x, y: origin.y - size.height, width: size.width, height: size.height)
      return others.reduce(0) { sum, frame in
        let overlap = frame.intersection(rect)
        return overlap.isNull ? sum : sum + overlap.width * overlap.height
      }
    }
    return origins.min { covered($0) < covered($1) }
  }

  private func usableFrame(showing name: String) -> CGRect? {
    guard let identity = workspaces.display(showing: name) else { return nil }
    return screens.first(where: { $0.identity == identity })?.usableFrame
  }

  /// Raise the window last focused in the focused workspace, or its first:
  /// after a workspace command the keyboard goes where the user now looks.
  private func focusFocusedWorkspace() {
    guard let name = workspaces.focused, let workspace = workspaces.workspaces[name] else {
      return
    }
    let target =
      lastFocused[name].flatMap { workspace.windows.contains($0) ? $0 : nil }
      ?? workspace.windows.first
    guard let target else { return }
    driver.tilingRaise(target)
  }

  private func identity(at point: CGPoint) -> String? {
    screens.first(where: { $0.frame.contains(point) })?.identity
  }

  private func identity(containing frame: CGRect) -> String? {
    let center = CGPoint(x: frame.midX, y: frame.midY)
    if let screen = screens.first(where: { $0.frame.contains(center) }) { return screen.identity }
    return screens.max { lhs, rhs in
      lhs.frame.intersection(frame).width * lhs.frame.intersection(frame).height
        < rhs.frame.intersection(frame).width * rhs.frame.intersection(frame).height
    }?.identity
  }

  private func publish() {
    layoutDidChange?()
    let current = status
    guard current != lastStatus else { return }
    lastStatus = current
    statusDidChange?(current)
  }

  /// Displays left to right, then top to bottom.
  static func displays(_ screens: [WindowScreenLayout]) -> [TilingDisplay] {
    screens.sorted {
      $0.frame.minX != $1.frame.minX ? $0.frame.minX < $1.frame.minX : $0.frame.maxY > $1.frame.maxY
    }.map {
      TilingDisplay(
        identity: $0.identity, isMain: $0.frame.origin == .zero,
        isWide: $0.frame.width >= $0.frame.height)
    }
  }
}
