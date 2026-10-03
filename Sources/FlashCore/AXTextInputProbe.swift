import AppKit
import ApplicationServices
import CoreGraphics

/// Whether a screen point lands in a text input, judged by the same rule that
/// marks a discovered hint target as one (`JumpTarget.isTextInput`, in UIKit
/// content `IOSContent.canTakeKeyboardFocus`, and anywhere in a declared
/// terminal emulator), so a grid click and a hint click enter INSERT under one
/// rule.
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
    if ownedByTerminalEmulator(element) { return true }
    AXUIElementSetMessagingTimeout(element, messagingTimeout)
    guard let input = textInput(fromElementUp: element, limit: ancestorLimit) else { return false }
    return IOSContent.canTakeKeyboardFocus(input) || !IOSContent.contains(input)
  }

  /// The decision on the roles from the hit element up through its ancestors.
  public static func isTextInput(roles: [String]) -> Bool {
    isTextInput(path: roles.map { (role: $0, subrole: nil) })
  }

  /// The decision on the roles and subroles from the hit element up through
  /// its ancestors.
  public static func isTextInput(path: [(role: String, subrole: String?)]) -> Bool {
    path.prefix(ancestorLimit + 1).contains {
      JumpTarget.isTextInput(role: $0.role, subrole: $0.subrole)
    }
  }

  /// A terminal emulator's window is one typing surface, whatever AX reports
  /// under the point (Alacritty reports nothing at all).
  private static func ownedByTerminalEmulator(_ element: AXUIElement) -> Bool {
    var pid: pid_t = 0
    guard AXUIElementGetPid(element, &pid) == .success else { return false }
    return TerminalEmulators.contains(
      NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
  }

  private static func textInput(fromElementUp start: AXUIElement, limit: Int) -> AXUIElement? {
    var current: AXUIElement? = start
    var visited = 0
    while let element = current, visited <= limit {
      visited += 1
      // One IPC per level: the role and subrole decide, the parent continues.
      var raw: CFArray?
      guard
        AXUIElementCopyMultipleAttributeValues(
          element, levelAttributes, AXCopyMultipleAttributeOptions(rawValue: 0), &raw)
          == .success, let values = raw as? [Any], values.count == 3
      else { return nil }
      if JumpTarget.isTextInput(role: values[0] as? String, subrole: values[1] as? String) {
        return element
      }
      let parent = values[2] as CFTypeRef
      guard CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
      current = (parent as! AXUIElement)
    }
    return nil
  }

  private static let levelAttributes =
    [kAXRoleAttribute, kAXSubroleAttribute, kAXParentAttribute] as CFArray
}
