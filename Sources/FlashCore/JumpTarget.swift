import CoreGraphics
import Darwin

// @unchecked Sendable: `resolveClickPoint` is a non-`@Sendable` closure provided
// by the owning source. The host invokes it on its resolution queue at commit;
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
  /// Opaque source context retained across fresh captures (for example one
  /// terminal pane in one server lifetime). Absent when the source has none.
  public let contextID: String?
  /// pid of the app that owns this target. Always the focused app
  /// (Flash only walks the active window) but kept on the target so the
  /// commit path can re-activate by pid without re-querying NSWorkspace.
  public let pid: pid_t?
  /// Validate the captured target and resolve its current click point, using
  /// the preferred point in the original frame. The host runs this off main.
  /// An absent resolver describes a coordinate target; a resolver returning
  /// nil cancels the commit because the original target can no longer be hit.
  public let resolveClickPoint: ((CGPoint) -> CGPoint?)?
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
    contextID: String? = nil,
    pid: pid_t? = nil,
    resolveClickPoint: ((CGPoint) -> CGPoint?)? = nil,
    entersInsertMode: Bool = false,
    priority: FlashPriority = .normal,
    providerID: String
  ) {
    self.id = id
    self.frame = frame
    self.role = role
    self.accessibilityLabel = accessibilityLabel
    self.url = url
    self.contextID = contextID
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

  public func resolvedClickPoint(preferred point: CGPoint) -> CGPoint? {
    guard let resolveClickPoint else { return point }
    return resolveClickPoint(point)
  }

  /// Plugin target IDs may be walk ordinals. Match the captured semantics,
  /// rejecting indistinguishable duplicates rather than choosing their order.
  public func matchingClickPoint(preferred point: CGPoint, among targets: [JumpTarget]) -> CGPoint?
  {
    guard accessibilityLabel?.isEmpty == false || url?.isEmpty == false else { return nil }
    let matches = targets.filter {
      $0.providerID == providerID && $0.pid == pid && $0.role == role
        && $0.accessibilityLabel == accessibilityLabel && $0.url == url
        && $0.contextID == contextID
        && $0.entersInsertMode == entersInsertMode
    }
    guard matches.count == 1, let current = matches.first else { return nil }
    return Self.relocatedClickPoint(point, from: frame, to: current.frame)
  }

  public static func relocatedClickPoint(
    _ point: CGPoint, from original: CGRect, to current: CGRect
  ) -> CGPoint? {
    guard point.x.isFinite, point.y.isFinite,
      [original, current].allSatisfy({
        !$0.isNull && !$0.isInfinite && $0.width > 0 && $0.height > 0
          && $0.minX.isFinite && $0.minY.isFinite && $0.maxX.isFinite && $0.maxY.isFinite
      })
    else { return nil }
    let x = min(1, max(0, (point.x - original.minX) / original.width))
    let y = min(1, max(0, (point.y - original.minY) / original.height))
    let insetX = min(0.5, current.width / 2)
    let insetY = min(0.5, current.height / 2)
    return CGPoint(
      x: min(current.maxX - insetX, max(current.minX + insetX, current.minX + x * current.width)),
      y: min(current.maxY - insetY, max(current.minY + insetY, current.minY + y * current.height)))
  }
}
