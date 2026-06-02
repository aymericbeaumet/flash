import CoreGraphics
import Darwin

public struct JumpTarget: @unchecked Sendable {
  public let id: String
  public let frame: CGRect
  public let role: String?
  public let accessibilityLabel: String?
  /// pid of the app that owns this target. Required when the discovery
  /// `scope` extends beyond the focused app — without it, `commit` doesn't
  /// know which app to bring forward before dispatching the click. Nil is
  /// fine for legacy single-app contexts.
  public let pid: pid_t?
  public let activate: ((JumpAction) -> Bool)?
  public let providerID: String

  public init(
    id: String,
    frame: CGRect,
    role: String? = nil,
    accessibilityLabel: String? = nil,
    pid: pid_t? = nil,
    activate: ((JumpAction) -> Bool)? = nil,
    providerID: String
  ) {
    self.id = id
    self.frame = frame
    self.role = role
    self.accessibilityLabel = accessibilityLabel
    self.pid = pid
    self.activate = activate
    self.providerID = providerID
  }
}
