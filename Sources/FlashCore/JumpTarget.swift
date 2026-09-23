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

  /// Generic elements admitted only because the app makes them clickable (a
  /// web app's cards and rows, an iOS app's conversation rows and messages);
  /// dedup ranks them below every semantic control. A typing surface is never
  /// generic, whatever its role (WhatsApp's search field is an `AXStaticText`).
  public var isGenericContainer: Bool {
    !entersInsertMode
      && (role == "AXGroup" || role == "AXListItem" || role == IOSContent.cellRole)
  }

  /// AX roles that represent a typing surface. Committing a click on a
  /// target with one of these roles puts the user in insert mode.
  public static let textInputRoles: Set<String> = [
    "AXTextField", "AXSearchField", "AXTextArea", "AXComboBox",
  ]

  /// A search field is a typing surface whatever role carries it: WhatsApp's
  /// chat search is an `AXStaticText`, Finder's collapsed toolbar search an
  /// `AXButton` that opens and focuses its field.
  public static func isTextInput(role: String?, subrole: String?) -> Bool {
    (role.map(textInputRoles.contains) ?? false) || subrole == "AXSearchField"
  }

  /// This target with its INSERT decision replaced, for a provider that
  /// settles the decision after capture.
  public func enteringInsertMode(_ entersInsertMode: Bool) -> JumpTarget {
    JumpTarget(
      id: id, frame: frame, role: role, accessibilityLabel: accessibilityLabel, url: url,
      contextID: contextID, pid: pid, resolveClickPoint: resolveClickPoint,
      entersInsertMode: entersInsertMode, priority: priority, providerID: providerID)
  }

  /// Semantic role for links discovered inside terminal content. Terminal
  /// emulators use Shift-click to bypass application mouse reporting and
  /// activate their own link handling, so the host adds Shift when committing
  /// one of these targets. Native accessibility links continue to use AXLink.
  public static let terminalLinkRole = "FlashTerminalLink"

  public func resolvedClickPoint(preferred point: CGPoint) -> CGPoint? {
    guard let resolveClickPoint else { return point }
    return resolveClickPoint(point)
  }

  /// Plugin target IDs may be walk ordinals, so match the captured semantics.
  /// The same link text is often visible more than once — a path repeated in
  /// a terminal pane — and then the copy nearest the captured position is the
  /// one the user picked; only two copies at the same distance are ambiguous.
  public func matchingClickPoint(preferred point: CGPoint, among targets: [JumpTarget]) -> CGPoint?
  {
    guard accessibilityLabel?.isEmpty == false || url?.isEmpty == false else { return nil }
    let ranked =
      targets
      .filter {
        $0.providerID == providerID && $0.pid == pid && $0.role == role
          && $0.accessibilityLabel == accessibilityLabel && $0.url == url
          && $0.contextID == contextID
          && $0.entersInsertMode == entersInsertMode
      }
      .map { candidate -> (target: JumpTarget, distance: CGFloat) in
        let dx = candidate.frame.midX - frame.midX
        let dy = candidate.frame.midY - frame.midY
        let distance = dx * dx + dy * dy
        return (candidate, distance.isFinite ? distance : .infinity)
      }
      .sorted { $0.distance < $1.distance }
    guard let nearest = ranked.first,
      ranked.dropFirst().first.map({ $0.distance > nearest.distance }) ?? true
    else { return nil }
    return Self.relocatedClickPoint(point, from: frame, to: nearest.target.frame)
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
