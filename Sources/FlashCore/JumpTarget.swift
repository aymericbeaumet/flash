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
  /// True when committing this target is expected to leave the user in a
  /// text-entry surface, e.g. an AX text field or a terminal/tmux pane.
  public let acceptsTextInput: Bool
  /// pid of the app that owns this target. Always the focused app
  /// (Flash only walks the active window) but kept on the target so the
  /// commit path can re-activate by pid without re-querying NSWorkspace.
  public let pid: pid_t?
  public let activate: ((JumpAction) -> Bool)?
  public let providerID: String

  public init(
    id: String,
    frame: CGRect,
    role: String? = nil,
    accessibilityLabel: String? = nil,
    url: String? = nil,
    acceptsTextInput: Bool = false,
    pid: pid_t? = nil,
    activate: ((JumpAction) -> Bool)? = nil,
    providerID: String
  ) {
    self.id = id
    self.frame = frame
    self.role = role
    self.accessibilityLabel = accessibilityLabel
    self.url = url
    self.acceptsTextInput = acceptsTextInput
    self.pid = pid
    self.activate = activate
    self.providerID = providerID
  }
}
