import AppKit
import ApplicationServices
import FlashCore

extension NormalModeDispatcher {
  /// The focused element of `pid` as `FocusRegion`, with the frame of the
  /// scroll area around it. A declared terminal emulator answers without a
  /// read; otherwise the focused-text read decides text and terminals, and
  /// the roles of the element and its first ancestors decide a collection.
  /// Blocking AX IPC, each element bounded by `focusedTextMessagingTimeout`:
  /// run it on `AppDelegate.normalModeAXActionQueue`, never on main.
  static func focusRegion(pid: pid_t) -> FocusRegionTracker.Reading {
    let (text, element) = focusedTextElement(pid: pid, detail: .kind)
    let identity = element?.elementID
    guard text.kind == .uneditable, let element else {
      return FocusRegionTracker.Reading(
        region: FocusRegion.classify(text: text, roles: []), element: identity)
    }
    var roles: [(role: String?, subrole: String?)] = []
    var scrollFrame: CGRect?
    let primaryH = ScreenSpace.primaryHeight
    var current: AXUIElement? = element.element
    // The element, then its ancestors; the walk goes one further than the
    // collection check for the scroll area a page's web area sits in.
    for depth in 0...(FocusRegion.ancestorDepth + 1) {
      guard let node = current else { break }
      let (role, subrole, parent) = roleSubroleAndParent(of: node)
      if depth <= FocusRegion.ancestorDepth { roles.append((role, subrole)) }
      if scrollFrame == nil, role == kAXScrollAreaRole as String {
        scrollFrame = frame(of: node, primaryScreenHeight: primaryH)
      }
      current = parent
    }
    return FocusRegionTracker.Reading(
      region: FocusRegion.classify(text: text, roles: roles), scrollFrame: scrollFrame,
      element: identity)
  }

  /// Role, subrole and parent in one round trip.
  private static func roleSubroleAndParent(of element: AXUIElement)
    -> (String?, String?, AXUIElement?)
  {
    let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXParentAttribute] as CFArray
    var raw: CFArray?
    guard
      AXUIElementCopyMultipleAttributeValues(
        element, names, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
      let values = raw as? [Any], values.count == 3
    else { return (nil, nil, nil) }
    var parent: AXUIElement?
    if let value = values[2] as CFTypeRef?, CFGetTypeID(value) == AXUIElementGetTypeID() {
      let element = value as! AXUIElement
      AXUIElementSetMessagingTimeout(element, focusedTextMessagingTimeout)
      parent = element
    }
    return (values[0] as? String, values[1] as? String, parent)
  }
}
