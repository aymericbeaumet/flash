import AppKit
import ApplicationServices
import FlashCore
import FlashProviders

/// `mouse_notifications`: the pressable parts of what Notification Center
/// shows — banners and alerts, their close, options and action buttons, and
/// the panel's controls while it is open — read from its AX windows under the
/// existing Accessibility grant. Only windows are read: the process also
/// reports a hidden menu bar of its own, which is never on screen.
enum NotificationCenterSurface {
  static let bundleIdentifier = "com.apple.notificationcenterui"

  /// One element of Notification Center's windows, as read for hinting.
  /// Generic over the element so the target filter runs on a fake tree.
  struct Node<Element> {
    var element: Element
    var role: String?
    /// NSScreen coordinates; nil when unreadable or smaller than 3×3 points.
    var frame: CGRect?
    var hidden: Bool
    /// An `AXGroup` with a press action: a banner, an alert or a stack.
    /// Read only for groups.
    var pressable: Bool
    var children: [Node<Element>]
  }

  /// Controls hinted wherever they appear in Notification Center's windows.
  static let controlRoles: Set<String> = [
    "AXButton", "AXMenuButton", "AXPopUpButton", "AXLink", "AXCheckBox", "AXRadioButton",
  ]

  /// The elements to hint, depth-first in tree order: every visible control,
  /// and every pressable group except one that only repeats the frame of the
  /// pressable group around it (a wrapper that would stack a second chip on
  /// the same banner). Hidden subtrees are skipped whole.
  static func pressableElements<Element>(in windows: [Node<Element>]) -> [Element] {
    var picked: [Element] = []
    func visit(_ node: Node<Element>, pressableFrame: CGRect?) {
      guard !node.hidden else { return }
      var enclosing = pressableFrame
      if let frame = node.frame, !frame.isEmpty {
        if let role = node.role, controlRoles.contains(role) {
          picked.append(node.element)
        } else if node.role == "AXGroup", node.pressable {
          if frame != pressableFrame { picked.append(node.element) }
          enclosing = frame
        }
      }
      for child in node.children { visit(child, pressableFrame: enclosing) }
    }
    for window in windows { visit(window, pressableFrame: nil) }
    return picked
  }

  /// Deeper than any banner or panel layout; guards an AX cycle.
  static let maxDepth = 24

  /// Notification Center's windows as `Node`s; empty when it shows nothing.
  /// Runs off main: one batched read per element, plus an action-name read
  /// per group.
  static func readWindows(pid: pid_t, screenH: CGFloat) -> [Node<AXUIElement>] {
    let app = AXApp.make(pid: pid)
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success,
      let windows = raw as? [AXUIElement]
    else { return [] }
    return windows.map { readNode($0, depth: 0, screenH: screenH) }
  }

  private static let nodeAttributes: CFArray =
    [
      kAXRoleAttribute,  // 0
      kAXPositionAttribute,  // 1
      kAXSizeAttribute,  // 2
      kAXHiddenAttribute,  // 3
      kAXChildrenAttribute,  // 4
    ] as CFArray

  private static func readNode(
    _ element: AXUIElement, depth: Int, screenH: CGFloat
  ) -> Node<AXUIElement> {
    var raw: CFArray?
    guard
      AXUIElementCopyMultipleAttributeValues(
        element, nodeAttributes, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
      let values = raw as? [Any], values.count == 5
    else {
      return Node(
        element: element, role: nil, frame: nil, hidden: false, pressable: false, children: [])
    }
    let role = values[0] as? String
    let children = depth < maxDepth ? (values[4] as? [AXUIElement] ?? []) : []
    return Node(
      element: element,
      role: role,
      frame: frame(position: values[1], size: values[2], screenH: screenH),
      hidden: values[3] as? Bool ?? false,
      pressable: role == "AXGroup" && AXClick.hasPressAction(element),
      children: children.map { readNode($0, depth: depth + 1, screenH: screenH) })
  }

  private static func frame(position: Any, size: Any, screenH: CGFloat) -> CGRect? {
    let positionRef = position as CFTypeRef
    let sizeRef = size as CFTypeRef
    guard CFGetTypeID(positionRef) == AXValueGetTypeID(),
      CFGetTypeID(sizeRef) == AXValueGetTypeID()
    else { return nil }
    var origin = CGPoint.zero
    var extent = CGSize.zero
    guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin),
      AXValueGetValue(sizeRef as! AXValue, .cgSize, &extent),
      extent.width >= 3, extent.height >= 3
    else { return nil }
    return CGRect(
      x: origin.x, y: screenH - origin.y - extent.height, width: extent.width,
      height: extent.height)
  }
}
