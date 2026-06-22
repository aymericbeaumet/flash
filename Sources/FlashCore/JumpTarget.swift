import CoreGraphics
import Darwin

// @unchecked Sendable: `activate` is a non-`@Sendable` closure provided by the
// owning source. Providers wire up activation on the AX queue and the host
// invokes the closure on the main thread once committed; the target itself is
// treated as immutable in between. Other fields are all value types.
public struct JumpTarget: @unchecked Sendable {
  public let id: String
  public let frame: CGRect
  public let role: String?
  public let accessibilityLabel: String?
  /// URL associated with this target when AX exposes one. Primarily
  /// useful for link-like targets; nil for controls without URL
  /// metadata.
  public let url: String?
  /// pid of the app that owns this target. Always the focused app
  /// (Flash only walks the active window) but kept on the target so the
  /// commit path can re-activate by pid without re-querying NSWorkspace.
  public let pid: pid_t?
  public let activate: ((JumpAction) -> Bool)?
  /// Resolves a point — in NSScreen bottom-left coords — that is guaranteed to
  /// sit on the target, computed lazily at commit so it costs nothing during
  /// the hint walk. Providers set this for surfaces whose `frame` is a union
  /// bounding box that may have empty interior (a multi-line web link whose
  /// box centre falls in the gap between lines). nil means "use the frame
  /// centre". Returning nil from the closure also means "use the centre".
  public let resolveClickPoint: (() -> CGPoint?)?
  public let providerID: String
  /// Whether committing a click on this target should switch Flash into
  /// insert mode. The owning provider decides: a typing surface (text
  /// field, a tmux pane) sets this true so the user lands ready to type;
  /// a link or button leaves it false so keyboard navigation continues.
  public let entersInsertMode: Bool
  /// When true, `ActionDispatcher.perform` skips provider AX activation
  /// and AX hit-test fallback, then goes straight to a synthesized
  /// `CGEvent` click. Set by providers whose targets sit on top of a
  /// surface that exposes an AX press action which does *not* mean
  /// "click here" — e.g. a tmux pane chip over an alacritty terminal,
  /// or a browser web link whose AXPress reports success while the DOM
  /// click handler never runs. Without this flag the dispatcher would
  /// treat the spurious AXPress as a successful click and never deliver
  /// the real one.
  public let preferHostClick: Bool
  /// Mark a target as structurally important inside its source so the
  /// renderer can give it a stronger visual treatment than the rest.
  /// Used by the tmux plugin for pane chips (vs. link chips) and by
  /// the firefox plugin for tab chips (vs. element chips) — the user
  /// can scan a screen full of mixed hints and pick out the
  /// "top-level" entry at a glance. Purely a styling signal; the
  /// commit path is unchanged.
  public let important: Bool

  public init(
    id: String,
    frame: CGRect,
    role: String? = nil,
    accessibilityLabel: String? = nil,
    url: String? = nil,
    pid: pid_t? = nil,
    activate: ((JumpAction) -> Bool)? = nil,
    resolveClickPoint: (() -> CGPoint?)? = nil,
    entersInsertMode: Bool = false,
    preferHostClick: Bool = false,
    important: Bool = false,
    providerID: String
  ) {
    self.id = id
    self.frame = frame
    self.role = role
    self.accessibilityLabel = accessibilityLabel
    self.url = url
    self.pid = pid
    self.activate = activate
    self.resolveClickPoint = resolveClickPoint
    self.entersInsertMode = entersInsertMode
    self.preferHostClick = preferHostClick
    self.important = important
    self.providerID = providerID
  }

  /// AX roles that represent a typing surface. Committing a click on a
  /// target with one of these roles puts the user in insert mode.
  public static let textInputRoles: Set<String> = [
    "AXTextField", "AXSearchField", "AXTextArea", "AXComboBox",
  ]
}
