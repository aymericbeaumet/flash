import ApplicationServices
import Foundation

/// Typed AX attribute accessors shared across the codebase.
///
/// Before extraction this set of helpers was duplicated between
/// `AccessibilityProvider` (FlashProviders) and `NormalModeDispatcher`
/// (the app target), with subtle differences in the URL handler. The
/// duplicates have been collapsed onto this namespace; both modules
/// call into here.
public enum AXAttribute {
  public static func role(_ element: AXUIElement) -> String? {
    string(element, kAXRoleAttribute as String)
  }

  public static func children(_ element: AXUIElement) -> [AXUIElement] {
    var raw: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw)
        == .success,
      let children = raw as? [AXUIElement]
    else { return [] }
    return children
  }

  public static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
      let value = raw,
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    return (value as! AXUIElement)
  }

  public static func string(_ element: AXUIElement, _ name: String) -> String? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
      let value = raw
    else { return nil }
    return value as? String
  }

  public static func bool(_ element: AXUIElement, _ name: String) -> Bool? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
      let value = raw
    else { return nil }
    return value as? Bool
  }

  public static func url(_ element: AXUIElement, _ name: String) -> String? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
      let value = raw
    else { return nil }
    if let url = value as? URL { return url.absoluteString }
    if CFGetTypeID(value) == CFURLGetTypeID() {
      return (value as! URL).absoluteString
    }
    return value as? String
  }

  public static func number(_ element: AXUIElement, _ name: String) -> Double? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
      let value = raw
    else { return nil }
    if CFGetTypeID(value) == CFNumberGetTypeID() {
      return (value as! NSNumber).doubleValue
    }
    if let number = value as? NSNumber {
      return number.doubleValue
    }
    return nil
  }

  public static func point(_ element: AXUIElement, _ name: String) -> CGPoint? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
      let value = raw,
      CFGetTypeID(value) == AXValueGetTypeID()
    else { return nil }
    let axValue = value as! AXValue
    guard AXValueGetType(axValue) == .cgPoint else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
    return point
  }

  public static func size(_ element: AXUIElement, _ name: String) -> CGSize? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
      let value = raw,
      CFGetTypeID(value) == AXValueGetTypeID()
    else { return nil }
    let axValue = value as! AXValue
    guard AXValueGetType(axValue) == .cgSize else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
    return size
  }
}
