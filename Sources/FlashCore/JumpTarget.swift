import CoreGraphics
import Darwin

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
  public let providerID: String
  /// Whether committing a click on this target should switch Flash into
  /// insert mode. The owning provider decides: a typing surface (text
  /// field, a tmux pane) sets this true so the user lands ready to type;
  /// a link or button leaves it false so keyboard navigation continues.
  public let entersInsertMode: Bool

  public init(
    id: String,
    frame: CGRect,
    role: String? = nil,
    accessibilityLabel: String? = nil,
    url: String? = nil,
    pid: pid_t? = nil,
    activate: ((JumpAction) -> Bool)? = nil,
    entersInsertMode: Bool = false,
    providerID: String
  ) {
    self.id = id
    self.frame = frame
    self.role = role
    self.accessibilityLabel = accessibilityLabel
    self.url = url
    self.pid = pid
    self.activate = activate
    self.entersInsertMode = entersInsertMode
    self.providerID = providerID
  }

  /// AX roles that represent a typing surface. Committing a click on a
  /// target with one of these roles puts the user in insert mode.
  public static let textInputRoles: Set<String> = [
    "AXTextField", "AXSearchField", "AXTextArea", "AXComboBox",
  ]
}
