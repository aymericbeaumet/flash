import CoreGraphics
import Darwin

// @unchecked Sendable: `resolveClickPoint` is a non-`@Sendable` closure provided
// by the owning source. The host invokes it on the main thread once committed;
// the target itself is treated as immutable in between. Other fields are all
// value types.
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
  /// field) sets this true so the user lands ready to type; links, buttons,
  /// and tmux pane selectors leave it false so keyboard navigation continues.
  public let entersInsertMode: Bool
  /// Source-declared salience for this target. The renderer currently paints
  /// `.important` and `.urgent` targets in the accent style; the commit path
  /// is unchanged.
  public let priority: FlashPriority

  public init(
    id: String,
    frame: CGRect,
    role: String? = nil,
    accessibilityLabel: String? = nil,
    url: String? = nil,
    pid: pid_t? = nil,
    resolveClickPoint: (() -> CGPoint?)? = nil,
    entersInsertMode: Bool = false,
    priority: FlashPriority = .normal,
    providerID: String
  ) {
    self.id = id
    self.frame = frame
    self.role = role
    self.accessibilityLabel = accessibilityLabel
    self.url = url
    self.pid = pid
    self.resolveClickPoint = resolveClickPoint
    self.entersInsertMode = entersInsertMode
    self.priority = priority
    self.providerID = providerID
  }

  /// AX roles that represent a typing surface. Committing a click on a
  /// target with one of these roles puts the user in insert mode.
  public static let textInputRoles: Set<String> = [
    "AXTextField", "AXSearchField", "AXTextArea", "AXComboBox",
  ]

  /// Semantic role for links discovered inside terminal content. Terminal
  /// emulators use Shift-click to bypass application mouse reporting and
  /// activate their own link handling, so the host adds Shift when committing
  /// one of these targets. Native accessibility links continue to use AXLink.
  public static let terminalLinkRole = "FlashTerminalLink"
}
