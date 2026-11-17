import CoreGraphics
import CryptoKit
import Foundation

/// A tiling tree as stored: nested containers with their layout,
/// orientation, children and weights, windows as the leaves.
indirect enum TilingTreeNode<ID: Hashable>: Equatable {
  case window(ID)
  case container(
    layout: TilingLayoutKind, orientation: TilingOrientation, children: [TilingTreeNode<ID>],
    weights: [Double])

  /// Every window, depth first.
  var windows: [ID] {
    switch self {
    case .window(let id): return [id]
    case .container(_, _, let children, _): return children.flatMap(\.windows)
    }
  }

  /// The same shape over `transform`'s results: a window it maps to nil
  /// leaves, with its weight; a container keeps its place even emptied (the
  /// tree normalizes it away). nil for a lone window that left.
  func compactMapWindows<T: Hashable>(_ transform: (ID) -> T?) -> TilingTreeNode<T>? {
    switch self {
    case .window(let id):
      return transform(id).map { .window($0) }
    case .container(let layout, let orientation, let children, let weights):
      var kept: [TilingTreeNode<T>] = []
      var keptWeights: [Double] = []
      for (child, weight) in zip(children, weights) {
        guard let mapped = child.compactMapWindows(transform) else { continue }
        kept.append(mapped)
        keptWeights.append(weight)
      }
      return .container(
        layout: layout, orientation: orientation, children: kept, weights: keptWeights)
    }
  }
}

extension TilingLayoutKind: Codable {}
extension TilingOrientation: Codable {}

/// `{"window": id}` for a leaf; `{"layout", "orientation", "children",
/// "weights"}` for a container, one positive weight per child.
extension TilingTreeNode: Codable where ID: Codable {
  private enum CodingKeys: String, CodingKey {
    case window, layout, orientation, children, weights
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if container.contains(.window) {
      self = .window(try container.decode(ID.self, forKey: .window))
      return
    }
    let children = try container.decode([TilingTreeNode<ID>].self, forKey: .children)
    let weights = try container.decode([Double].self, forKey: .weights)
    guard weights.count == children.count, weights.allSatisfy({ $0.isFinite && $0 > 0 }) else {
      throw DecodingError.dataCorruptedError(
        forKey: .weights, in: container, debugDescription: "one positive weight per child")
    }
    self = .container(
      layout: try container.decode(TilingLayoutKind.self, forKey: .layout),
      orientation: try container.decode(TilingOrientation.self, forKey: .orientation),
      children: children, weights: weights)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .window(let id):
      try container.encode(id, forKey: .window)
    case .container(let layout, let orientation, let children, let weights):
      try container.encode(layout, forKey: .layout)
      try container.encode(orientation, forKey: .orientation)
      try container.encode(children, forKey: .children)
      try container.encode(weights, forKey: .weights)
    }
  }
}

/// What the saved layout keeps of a window to find it again: its app; its
/// window number, which a window keeps while its app runs, so a Flash
/// restart finds it exactly; a hash of its title, which finds it after its
/// app restarted too; and the frame it last had, to tell equal titles
/// apart. Never the title itself, nor a pid.
struct TilingWindowIdentity: Equatable, Codable {
  var bundleID: String
  var windowNumber: UInt32?
  var titleHash: String?
  var frame: CGRect?

  private enum CodingKeys: String, CodingKey {
    case bundleID = "bundle_id"
    case windowNumber = "window_number"
    case titleHash = "title_hash"
    case frame
  }

  init(
    bundleID: String, windowNumber: UInt32? = nil, titleHash: String? = nil, frame: CGRect? = nil
  ) {
    self.bundleID = bundleID
    self.windowNumber = windowNumber
    self.titleHash = titleHash
    self.frame = frame
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    bundleID = try container.decode(String.self, forKey: .bundleID)
    windowNumber = try container.decodeIfPresent(UInt32.self, forKey: .windowNumber)
    titleHash = try container.decodeIfPresent(String.self, forKey: .titleHash)
    if let values = try container.decodeIfPresent([Double].self, forKey: .frame) {
      guard values.count == 4, values.allSatisfy(\.isFinite) else {
        throw DecodingError.dataCorruptedError(
          forKey: .frame, in: container, debugDescription: "x, y, width, height")
      }
      frame = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(bundleID, forKey: .bundleID)
    try container.encodeIfPresent(windowNumber, forKey: .windowNumber)
    try container.encodeIfPresent(titleHash, forKey: .titleHash)
    if let frame {
      try container.encode(
        [frame.minX, frame.minY, frame.width, frame.height].map(Double.init), forKey: .frame)
    }
  }

  /// The first sixteen hexadecimal characters of the title's SHA-256.
  /// No raw title is stored; predictable titles can still be guessed.
  static func titleHash(_ title: String) -> String {
    String(
      SHA256.hash(data: Data(title.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
  }
}

/// One workspace as stored: its tree over window slots (indices into the
/// state's `windows`), the floating slots, the zoomed one, and the display
/// it was last shown on.
struct TilingPersistedWorkspace: Equatable, Codable {
  var name: String
  var display: String?
  var tree: TilingTreeNode<Int>
  var floating: [Int]
  var fullscreen: Int?
}

/// The saved layout, `tiling.json`: version 1. Decoding rejects another
/// version and anything inconsistent, so a file Flash cannot trust is
/// ignored whole rather than half applied.
struct TilingPersistedState: Equatable, Codable {
  static let version = 1

  var focusedDisplay: String?
  /// Display identity → the workspace it showed.
  var displays: [String: String]
  var workspaces: [TilingPersistedWorkspace]
  var windows: [TilingWindowIdentity]

  private enum CodingKeys: String, CodingKey {
    case version
    case focusedDisplay = "focused_display"
    case displays, workspaces, windows
  }

  init(
    focusedDisplay: String?, displays: [String: String], workspaces: [TilingPersistedWorkspace],
    windows: [TilingWindowIdentity]
  ) {
    self.focusedDisplay = focusedDisplay
    self.displays = displays
    self.workspaces = workspaces
    self.windows = windows
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    guard version == Self.version else {
      throw DecodingError.dataCorruptedError(
        forKey: .version, in: container,
        debugDescription: "version \(version) is not \(Self.version)")
    }
    focusedDisplay = try container.decodeIfPresent(String.self, forKey: .focusedDisplay)
    displays = try container.decode([String: String].self, forKey: .displays)
    workspaces = try container.decode([TilingPersistedWorkspace].self, forKey: .workspaces)
    windows = try container.decode([TilingWindowIdentity].self, forKey: .windows)
    if let problem = malformation {
      throw DecodingError.dataCorruptedError(
        forKey: .workspaces, in: container, debugDescription: problem)
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.version, forKey: .version)
    try container.encodeIfPresent(focusedDisplay, forKey: .focusedDisplay)
    try container.encode(displays, forKey: .displays)
    try container.encode(workspaces, forKey: .workspaces)
    try container.encode(windows, forKey: .windows)
  }

  /// Why the state cannot be trusted: a window slot out of range or in two
  /// places, a zoomed window not tiled in its workspace, a workspace name
  /// no workspace may have. nil when well formed.
  var malformation: String? {
    let known = Set(workspaces.map(\.name))
    guard displays.values.allSatisfy({ known.contains($0) }),
      Set(displays.values).count == displays.count,
      focusedDisplay.map({ displays[$0] != nil }) ?? true
    else { return "display assignment" }
    var seen: Set<Int> = []
    var names: Set<String> = []
    for workspace in workspaces {
      guard TilingSettings.isValidWorkspaceName(workspace.name),
        names.insert(workspace.name).inserted
      else { return "workspace name \(workspace.name)" }
      for slot in workspace.tree.windows + workspace.floating {
        guard windows.indices.contains(slot), seen.insert(slot).inserted else {
          return "window \(slot)"
        }
      }
      if let full = workspace.fullscreen, !workspace.tree.windows.contains(full) {
        return "fullscreen window \(full)"
      }
    }
    return nil
  }

  static func decode(_ data: Data) throws -> TilingPersistedState {
    try JSONDecoder().decode(TilingPersistedState.self, from: data)
  }

  func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(self)
  }
}

/// Where a live window matched a stored one: the workspace it belongs to,
/// floating or tiled, and whether it was the zoomed window there.
struct TilingRestoreMatch: Equatable {
  var workspace: String
  var floating: Bool
  var fullscreen: Bool
}

/// A saved layout on its way back: stored windows claimed by live ones as
/// they are adopted, and each workspace's stored tree projected over the
/// claimed ones for as long as the workspace is open, until a command on
/// it makes the live tree the user's. Pure value state.
struct TilingRestore<ID: Hashable> {
  private let state: TilingPersistedState
  /// Slot → the workspace holding it.
  private var home: [Int: String] = [:]
  private var floating: Set<Int> = []
  private var fullscreen: [String: Int] = [:]
  private var unclaimed: Set<Int>
  private var claimed: [Int: ID] = [:]
  private var slots: [ID: Int] = [:]
  private var open: Set<String>

  init(_ state: TilingPersistedState) {
    self.state = state
    open = Set(state.workspaces.map(\.name))
    for workspace in state.workspaces {
      for slot in workspace.tree.windows { home[slot] = workspace.name }
      for slot in workspace.floating {
        home[slot] = workspace.name
        floating.insert(slot)
      }
      if let full = workspace.fullscreen { fullscreen[workspace.name] = full }
    }
    // An entry no workspace holds has nowhere to go.
    unclaimed = Set(home.keys)
  }

  /// Stored windows still waiting for theirs.
  var pending: Int { unclaimed.count }

  /// Whether the live tree of `name` still follows its stored one.
  func isOpen(_ name: String) -> Bool { open.contains(name) }

  /// Claim the stored window `id` is, among the unclaimed ones of the same
  /// app: the one with its window number, else one with its title's hash
  /// (the title is read only then), the nearest by stored frame to `frame`
  /// when several have it. nil: a window the file does not know.
  mutating func claim(
    _ id: ID, bundleID: String, windowNumber: () -> UInt32?, title: () -> String?, frame: CGRect
  ) -> TilingRestoreMatch? {
    guard slots[id] == nil else { return nil }
    let candidates = unclaimed.filter { state.windows[$0].bundleID == bundleID }.sorted()
    guard !candidates.isEmpty else { return nil }
    var slot: Int?
    if let number = windowNumber(),
      let byNumber = candidates.first(where: { state.windows[$0].windowNumber == number })
    {
      slot = byNumber
    } else if let title = title() {
      let hash = TilingWindowIdentity.titleHash(title)
      let center = CGPoint(x: frame.midX, y: frame.midY)
      func distance(_ slot: Int) -> CGFloat {
        guard let stored = state.windows[slot].frame else { return .infinity }
        return hypot(stored.midX - center.x, stored.midY - center.y)
      }
      slot = candidates.filter { state.windows[$0].titleHash == hash }.min {
        distance($0) != distance($1) ? distance($0) < distance($1) : $0 < $1
      }
    }
    guard let slot, let name = home[slot] else { return nil }
    unclaimed.remove(slot)
    claimed[slot] = id
    slots[id] = slot
    return TilingRestoreMatch(
      workspace: name, floating: floating.contains(slot), fullscreen: fullscreen[name] == slot)
  }

  /// The stored tree of `name` over the windows claimed so far, with its
  /// floating and zoomed windows, while it is open; nil once closed, or for
  /// a workspace the file does not have.
  func projection(of name: String) -> (tree: TilingTree<ID>, floating: [ID], fullscreen: ID?)? {
    guard open.contains(name), let workspace = state.workspaces.first(where: { $0.name == name })
    else { return nil }
    let tree =
      workspace.tree.compactMapWindows { claimed[$0] }.map { TilingTree($0) } ?? TilingTree()
    return (
      tree, workspace.floating.compactMap { claimed[$0] },
      workspace.fullscreen.flatMap { claimed[$0] }
    )
  }

  func identity(of id: ID) -> TilingWindowIdentity? {
    slots[id].map { state.windows[$0] }
  }

  /// The tree of `name` is the user's from now on.
  mutating func close(_ name: String) { open.remove(name) }

  /// `id` left tiling, or its workspace: its stored place is spent, so a
  /// later projection does not put it back.
  mutating func forget(_ id: ID) {
    guard let slot = slots.removeValue(forKey: id) else { return }
    claimed[slot] = nil
  }
}

/// `~/Library/Application Support/Flash/tiling.json`: the saved layout,
/// written whole and atomically, readable by its owner alone. Reads and
/// writes run on the caller's queue, the window layout queue.
final class TilingLayoutStore {
  let fileURL: URL

  static var defaultFileURL: URL {
    let appSupport =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
        "Library/Application Support")
    return appSupport.appendingPathComponent("Flash", isDirectory: true)
      .appendingPathComponent("tiling.json")
  }

  init(fileURL: URL = TilingLayoutStore.defaultFileURL) {
    self.fileURL = fileURL
  }

  /// The saved layout, nil when there is none or the file cannot be trusted.
  func load() -> TilingPersistedState? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    do {
      return try TilingPersistedState.decode(try Data(contentsOf: fileURL))
    } catch {
      FlashLog.warn("[tiling] layout_unreadable: \(error)", fields: ["path": fileURL.path])
      return nil
    }
  }

  func save(_ state: TilingPersistedState) {
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try PrivateFile.write(try state.encoded(), to: fileURL)
    } catch {
      FlashLog.error("[tiling] layout_save_failed: \(error)", fields: ["path": fileURL.path])
    }
  }

  func remove() {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    do {
      try FileManager.default.removeItem(at: fileURL)
    } catch {
      FlashLog.warn("[tiling] layout_remove_failed: \(error)", fields: ["path": fileURL.path])
    }
  }
}
