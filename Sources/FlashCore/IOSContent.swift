import ApplicationServices

/// UIKit content inside a Mac window: Mac Catalyst and iPad apps (Messages,
/// WhatsApp) host it under one window group with this subrole. Its
/// Accessibility tree differs from AppKit's in two ways the walker and the
/// INSERT rule account for.
public enum IOSContent {
  public static let groupSubrole = "iOSContentGroup"

  /// UIKit exposes each accessibility element as one leaf: a conversation row
  /// or a message is a single `AXStaticText`. Every element carries a press
  /// action there, so the action says nothing; a control-sized leaf is the
  /// click target.
  public static let cellRole = "AXStaticText"

  /// UIKit also reports read-only text views, such as Messages' bubbles, with
  /// a text-input role. Only an element that can take keyboard focus is typed
  /// into, and only an explicit "not settable" answer rules one out.
  public static func canTakeKeyboardFocus(_ element: AXUIElement) -> Bool {
    var settable: DarwinBoolean = true
    guard
      AXUIElementIsAttributeSettable(element, kAXFocusedAttribute as CFString, &settable)
        == .success
    else { return true }
    return settable.boolValue
  }

  /// Whether `element` sits in a window hosting UIKit content. Several IPCs;
  /// callers ask only after an element has already failed the focus check.
  public static func contains(_ element: AXUIElement) -> Bool {
    var window: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &window)
        == .success, let window, CFGetTypeID(window) == AXUIElementGetTypeID()
    else { return false }
    var children: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        window as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
      let children = children as? [AXUIElement]
    else { return false }
    return children.contains { child in
      var subrole: CFTypeRef?
      AXUIElementCopyAttributeValue(child, kAXSubroleAttribute as CFString, &subrole)
      return subrole as? String == groupSubrole
    }
  }
}
