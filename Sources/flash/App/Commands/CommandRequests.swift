import AppKit
import FlashCore

/// `app hide|hide_others|show_all|raise`: the focused app hidden, every other
/// app hidden, every hidden app shown, or every window of the focused app
/// brought to the front (the Window menu's Bring All to Front).
enum AppVisibilityAction: String, CaseIterable, Hashable {
  case hide
  case hideOthers = "hide_others"
  case showAll = "show_all"
  case raise
}

enum WindowStateAction: Hashable {
  enum FullscreenState: String, Hashable {
    case on, off, toggle
  }

  case minimize
  case restore
  case fullscreen(FullscreenState)
}

struct AlertCommand: Hashable {
  let message: String
  let duration: TimeInterval?
  let style: StatusAlert.Style

  /// The alert the command shows: one line, for the style's default dwell
  /// unless the call passed `--duration`.
  var alert: StatusAlert {
    .message(message, duration: duration.map { .seconds($0) } ?? .standard, style: style)
  }

  var argTokens: [String] {
    var tokens = ["--message=\(message)"]
    if let duration {
      tokens.append("--duration=\(duration)")
    }
    if style != .standard {
      tokens.append("--style=\(style.rawValue)")
    }
    return tokens
  }
}

/// `alert confirm --prompt=<text> --command=<topic action [--arg=value ...]>`:
/// the question and the Flash command it gates. The wrapped command is any
/// command a mapping could name after `flash`, a plugin command included; a
/// confirmation cannot wrap another confirmation.
struct ConfirmCommand: Hashable {
  let prompt: String
  let command: URLCommand

  /// The `--command` value: the wrapped command and its arguments,
  /// space-joined.
  var commandText: String {
    command.argv.dropFirst().joined(separator: " ")
  }
}

/// `mouse grid`: the click the grid commits, plus how the grid starts.
struct MouseGridRequest: Hashable {
  var mouse: MouseCommand
  /// `--zoom-to-depth=N`: start N steps deep on the cell under the pointer.
  var zoomToDepth: Int?
  /// `--bisect`: halves and quadrants instead of the keyboard-shaped grid.
  var bisect: Bool

  init(_ mouse: MouseCommand, zoomToDepth: Int? = nil, bisect: Bool = false) {
    self.mouse = mouse
    self.zoomToDepth = zoomToDepth
    self.bisect = bisect
  }

  /// Arg tokens in diagnostic form: the mouse tokens, then the grid's own.
  var argTokens: [String] {
    var tokens = mouse.argTokens
    if bisect { tokens.append("--bisect") }
    if let zoomToDepth { tokens.append("--zoom-to-depth=\(zoomToDepth)") }
    return tokens
  }
}

/// `selection <action>`: what to do with the selected text. Copy and paste
/// go through `register yank` and `register paste`; nothing cuts, since
/// Flash never edits text. None of them changes the mode.
enum SelectionAction: String, CaseIterable, Hashable {
  case copy, paste
  /// VISUAL's `o`: the moving end goes to the other end.
  case swapEnds = "swap_ends"

  /// Copy and paste name a register; swapping the ends takes none.
  var takesRegister: Bool { self == .copy || self == .paste }
}

/// `mouse warp`: where the pointer jumps. `area` is the focused window or
/// the display it is on; `edge` the centre or one side, a few points inside
/// it so the pointer still sits on the area.
struct MouseWarpRequest: Hashable {
  enum Area: String, Hashable, CaseIterable {
    case window, screen
  }
  enum Edge: String, Hashable, CaseIterable {
    case center, top, bottom, left, right
  }
  var area: Area = .window
  var edge: Edge = .center

  var argTokens: [String] {
    ["--area=\(area.rawValue)", "--edge=\(edge.rawValue)"]
  }

  /// The point `edge` names inside `frame` (NSScreen coordinates), `inset`
  /// points in from a side.
  func point(in frame: CGRect, inset: CGFloat = 8) -> CGPoint {
    let dx = min(inset, frame.width / 2)
    let dy = min(inset, frame.height / 2)
    switch edge {
    case .center: return CGPoint(x: frame.midX, y: frame.midY)
    case .top: return CGPoint(x: frame.midX, y: frame.maxY - dy)
    case .bottom: return CGPoint(x: frame.midX, y: frame.minY + dy)
    case .left: return CGPoint(x: frame.minX + dx, y: frame.midY)
    case .right: return CGPoint(x: frame.maxX - dx, y: frame.midY)
    }
  }
}

/// `mouse position`: one action on the saved pointer positions.
enum MousePositionRequest: Hashable {
  /// Remember where the pointer is.
  case save
  /// Forget the saved position the pointer is on.
  case unsave
  /// Forget every saved position (of this app, when the history is per app).
  case clear
  /// Hint every saved position and act on the one you pick.
  case hints(MouseCommand)
  /// Jump to the saved position after / before the one the pointer is on.
  case next
  case previous

  var argTokens: [String] {
    switch self {
    case .save: return ["--action=save"]
    case .unsave: return ["--action=unsave"]
    case .clear: return ["--action=clear"]
    case .hints(let command): return ["--action=hints"] + command.argTokens
    case .next: return ["--action=next"]
    case .previous: return ["--action=previous"]
    }
  }
}

/// `window focus`: the nearest window in a direction, or the next one in
/// the z-order.
enum WindowFocusCycle: String, Hashable, CaseIterable {
  /// The window just below the focused one in the z-order (wrapping).
  case next
  /// The window just above it in the z-order (wrapping).
  case previous
  /// The frontmost window below the focused one that it overlaps.
  case behind
}

/// `window next` / `window previous`: the focused app's windows, in the order
/// the first press of a run found them.
enum WindowAppCycle: String, Hashable, CaseIterable {
  case next
  case previous
}

enum WindowFocusRequest: Hashable {
  case direction(WindowFocusDirection)
  case cycle(WindowFocusCycle)
  case app(WindowAppCycle)

  /// A `window focus --direction=` value.
  init?(direction rawValue: String) {
    if let direction = WindowFocusDirection(rawValue: rawValue) {
      self = .direction(direction)
    } else if let cycle = WindowFocusCycle(rawValue: rawValue) {
      self = .cycle(cycle)
    } else {
      return nil
    }
  }
}

/// `--gesture`: a trackpad gesture performed at the picked point instead of
/// a click. The pointer lands on the point first, as with `--move`.
enum TargetGesture: String, CaseIterable, Hashable {
  /// Look Up (three-finger tap): the app's look-up action on the word under
  /// the pointer.
  case lookUp = "look_up"
  /// Smart zoom (two-finger double tap) at the point.
  case smartZoom = "smart_zoom"
}

enum MouseCommand: Hashable {
  case click(JumpAction, modifiers: ClickModifiers)
  case move
  /// `mouse target --copy-url` (Vimium's `yf`): label only the targets that
  /// carry a URL, and copy the chosen one's instead of clicking it.
  case copyURL
  /// `mouse target --copy-text` (Wooshy's ⌘C): label only the targets with
  /// text, and copy the chosen one's (its label as Flash read it).
  case copyText
  /// The pointer lands on the point, then the trackpad gesture runs there.
  case gesture(TargetGesture)
  /// Two-phase drag: the first commit picks the grab point, the second picks
  /// the drop point, then the dispatcher synthesizes one continuous
  /// down→dragged…→up gesture. Modifiers are held for the whole gesture
  /// (option-drag copy, cmd-drag move, …).
  case drag(modifiers: ClickModifiers)
  /// Two-phase text selection: the first commit clicks to set the caret, the
  /// second shift-clicks to extend the selection to that point — the standard
  /// macOS gesture, so it works across line wraps and never turns into an
  /// accidental drag of an existing selection.
  case select(modifiers: ClickModifiers)
  /// Multi-click session (a click chain): each commit performs `action`,
  /// then the targets are discovered again (or the grid restarts) for the
  /// next pick; Escape ends the session (`ClickChain`). Never a secondary
  /// click: its menu would take the keyboard.
  case multi(JumpAction, modifiers: ClickModifiers)
  /// Precision session (`mouse target` only): the matched hint enters an
  /// adjustment sub-state — snap the click point to the target's bounding-box
  /// edges or interpolate across its width — before the commit key clicks.
  case adjust(JumpAction, modifiers: ClickModifiers)
  /// Seek & click (`mouse target` only): type visible label text to filter
  /// the targets, Tab cycles, Return commits the selection with `action`.
  case search(JumpAction, modifiers: ClickModifiers)
  /// Path session (`mouse target` only): the first commit picks one end,
  /// the second the other, and every target between them in reading order
  /// gets `action`, in that order.
  case path(JumpAction, modifiers: ClickModifiers)
  /// Sticky session (`mouse target` only): each commit performs `action`
  /// and the same labels stay up, with no new walk, until Escape ends it.
  /// Never a secondary click, as for `multi`.
  case sticky(JumpAction, modifiers: ClickModifiers)

  var action: JumpAction {
    switch self {
    case .click(let action, _): return action
    case .multi(let action, _): return action
    case .adjust(let action, _): return action
    case .search(let action, _): return action
    case .path(let action, _): return action
    case .sticky(let action, _): return action
    case .move, .gesture, .drag, .select, .copyURL, .copyText: return .leftClick
    }
  }

  var modifiers: ClickModifiers {
    switch self {
    case .click(_, let modifiers): return modifiers
    case .drag(let modifiers): return modifiers
    case .select(let modifiers): return modifiers
    case .multi(_, let modifiers): return modifiers
    case .adjust(_, let modifiers): return modifiers
    case .search(_, let modifiers): return modifiers
    case .path(_, let modifiers): return modifiers
    case .sticky(_, let modifiers): return modifiers
    case .move, .gesture, .copyURL, .copyText: return []
    }
  }

  var isSticky: Bool {
    if case .sticky = self { return true }
    return false
  }

  /// A session that keeps its labels up after a commit (`--multi`,
  /// `--sticky`).
  var repeats: Bool { isMulti || isSticky }

  /// This command as a plain click of its action and modifiers: what a
  /// surface that has no session shapes of its own (the grid, a switched
  /// surface) performs.
  var asClick: MouseCommand {
    switch self {
    case .move, .gesture, .copyURL, .copyText: return self
    case .drag(let modifiers): return .drag(modifiers: modifiers)
    case .select(let modifiers): return .select(modifiers: modifiers)
    case .multi: return self
    case .click, .adjust, .search, .path, .sticky:
      return .click(action, modifiers: modifiers)
    }
  }

  /// A count typed before a mouse finisher is a finger count, the way a
  /// trackpad reads it: two fingers turn a click into a secondary click and a
  /// double click into smart zoom; three fingers turn a click into Look Up.
  /// Every other count, and every other command, is unchanged.
  func withFingers(_ fingers: Int) -> MouseCommand {
    switch (fingers, self) {
    case (2, .click(.leftClick, let modifiers)): return .click(.rightClick, modifiers: modifiers)
    case (2, .click(.doubleClick, let modifiers)) where modifiers.isEmpty:
      return .gesture(.smartZoom)
    case (3, .click(.leftClick, let modifiers)) where modifiers.isEmpty: return .gesture(.lookUp)
    default: return self
    }
  }

  var isDrag: Bool {
    if case .drag = self { return true }
    return false
  }

  var isSelect: Bool {
    if case .select = self { return true }
    return false
  }

  var isMulti: Bool {
    if case .multi = self { return true }
    return false
  }

  var isSearch: Bool {
    if case .search = self { return true }
    return false
  }
}

/// A proportional frame for `flash window move`. Percentages are relative to
/// the target screen's Flash-usable frame. `x` grows from the left and `y`
/// grows from the top so the CLI stays independent of AppKit's Y-up space.
struct ProportionalWindowFrame: Hashable {
  let xPercent: Double
  let yPercent: Double
  let widthPercent: Double
  let heightPercent: Double
}

/// Semantic window geometry retained across explicit screen moves and display
/// topology changes. Named positions are shortcuts; proportional frames carry
/// the user's exact size and placement intent.
enum WindowLayout: Hashable {
  case position(WindowPosition)
  case proportional(ProportionalWindowFrame)
}

/// Geometry for `flash window move`. Named positions map the focused window to
/// a fixed slot of the target screen's Flash-usable frame: `visibleFrame` plus
/// Flash's own top status-bar reservation folded in so a slot's height is the
/// height the user actually sees. A proportional layout supplies all of
/// `x`, `y`, `width`, and `height` as percentages of that same usable frame.
///
/// Layout and monitor selection are orthogonal controls:
///
/// - `layout` (optional): named slot or complete proportional frame of the target screen's
///   Flash-usable frame. When omitted, the window keeps its shape and
///   is only translated (proportionally remapped) onto the target
///   screen.
/// - `screen` (optional): relative monitor offset. `0` (or omitted)
///   stays on the window's current screen. `+N` / `-N` cycle forward
///   / backward through `NSScreen.screens` with modulo wrap.
///
/// The parser rejects the empty form (`flash window move`) so a mapping
/// that forgot both keys fails at config load instead of firing a silent
/// no-op on every press.
struct MoveWindowParams: Hashable {
  let layout: WindowLayout?
  let screen: Int
}

/// `WindowPosition` is also referenced by `WindowMover`. Keep its
/// declaration beside `MoveWindowParams`.
enum WindowPosition: String, CaseIterable, Hashable {
  case topLeft = "topleft"
  case topRight = "topright"
  case bottomLeft = "bottomleft"
  case bottomRight = "bottomright"
  case leftHalf = "lefthalf"
  case rightHalf = "righthalf"
  case topHalf = "tophalf"
  case bottomHalf = "bottomhalf"
  case maximized = "maximized"
  case centered = "centered"
}
