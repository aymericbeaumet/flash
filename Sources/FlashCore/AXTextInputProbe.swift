import ApplicationServices
import CoreGraphics

/// Whether a screen point lands in a text input, judged by the same roles that
/// mark a discovered hint target as one (`JumpTarget.textInputRoles`), so a
/// grid click and a hint click enter INSERT under one rule.
public enum AXTextInputProbe {
  /// The deepest element under a point is often a text run inside the field
  /// (web editors expose AXStaticText children), so a few ancestors are checked.
  public static let ancestorLimit = 4

  /// `point` is global, top-left origin. Blocking AX IPC bounded by a short
  /// messaging timeout: call off the main thread.
  public static func isTextInput(at point: CGPoint, messagingTimeout: Float = 0.25) -> Bool {
    let systemWide = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
    var hit: AXUIElement?
    guard
      AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit)
        == .success, let element = hit
    else { return false }
    AXUIElementSetMessagingTimeout(element, messagingTimeout)
    return isTextInput(roles: rolesFromElementUp(element, limit: ancestorLimit))
  }

  /// The decision on the roles from the hit element up through its ancestors.
  public static func isTextInput(roles: [String]) -> Bool {
    roles.prefix(ancestorLimit + 1).contains { JumpTarget.textInputRoles.contains($0) }
  }

  private static func rolesFromElementUp(_ start: AXUIElement, limit: Int) -> [String] {
    var roles: [String] = []
    var current: AXUIElement? = start
    while let element = current, roles.count <= limit {
      var role: CFTypeRef?
      AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
      roles.append(role as? String ?? "")
      if JumpTarget.textInputRoles.contains(roles.last ?? "") { break }
      var parent: CFTypeRef?
      guard
        AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent)
          == .success, let parent, CFGetTypeID(parent) == AXUIElementGetTypeID()
      else { break }
      current = (parent as! AXUIElement)
    }
    return roles
  }
}
