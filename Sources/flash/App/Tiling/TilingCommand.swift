import FlashCore

/// `tile layout --type=`: the focused window's container.
enum TilingLayoutRequest: String, CaseIterable, Hashable, Sendable {
  case tiles, accordion, horizontal, vertical
  /// tiles ↔ accordion.
  case toggle
}

/// `tile resize --dimension=`: `smart` is the axis of the focused window's
/// container.
enum TilingResizeDimension: String, CaseIterable, Hashable, Sendable {
  case width, height, smart
}

/// The `tile` topic: the focused window's place in its workspace's tree.
enum TilingCommand: Hashable, Sendable {
  case move(WindowFocusDirection)
  case swap(WindowFocusDirection)
  case join(WindowFocusDirection)
  case layout(TilingLayoutRequest)
  /// Points; positive grows the window.
  case resize(TilingResizeDimension, amount: Int)
  case balance
  case flatten
  /// Float a tiled window, or tile a floating one.
  case float
  /// Fill the workspace, or end it.
  case fullscreen

  var explanation: String {
    switch self {
    case .move(let direction):
      return "Moves the focused window \(direction.rawValue) in the tiling tree."
    case .swap(let direction):
      return "Swaps the focused window with its \(direction.rawValue) neighbor."
    case .join(let direction):
      return "Puts the focused window and its \(direction.rawValue) neighbor in a new container."
    case .layout(let request):
      return "Sets the focused window's container layout: \(request.rawValue)."
    case .resize(let dimension, let amount):
      return "Resizes the focused tiled window's \(dimension.rawValue) by \(amount) points."
    case .balance: return "Gives every tiled window of the workspace an equal share."
    case .flatten: return "Puts every tiled window of the workspace in one container."
    case .float: return "Floats the focused window, or tiles it again."
    case .fullscreen: return "Makes the focused tiled window fill its workspace, or ends it."
    }
  }
}

/// The `workspace` topic: emulated workspaces over the displays.
enum WorkspaceCommand: Hashable, Sendable {
  case switchTo(String)
  case next
  case previous
  case backAndForth
  /// Move the focused window to a workspace.
  case moveWindow(String)
  /// Show the focused workspace on the next (1) or previous (-1) display.
  case moveToMonitor(Int)
  /// Print the workspaces, the focused one marked.
  case list

  var explanation: String {
    switch self {
    case .switchTo(let name): return "Shows workspace \(name) and focuses it."
    case .next: return "Shows the next workspace on the focused display."
    case .previous: return "Shows the previous workspace on the focused display."
    case .backAndForth: return "Shows the workspace focused before this one."
    case .moveWindow(let name): return "Moves the focused window to workspace \(name)."
    case .moveToMonitor(let step):
      return "Shows the focused workspace on the \(step > 0 ? "next" : "previous") display."
    case .list: return "Lists the workspaces, the focused one marked."
    }
  }
}

/// What a tiling or workspace command did, for the CLI and the command line.
enum TilingOutcome: Equatable, Sendable {
  case done
  case output(String)
  case failed(String)

  static let disabled = TilingOutcome.failed(
    "tiling is off: set [tiling] enabled = true (docs/tiling.md)")
}
