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

  /// Screen rect of a character range within a text-bearing element, via the
  /// parameterized `kAXBoundsForRangeParameterizedAttribute`. Returned in
  /// NSScreen bottom-left coordinates (flipped by `screenH`, matching
  /// `frameFromAX`). nil if the element doesn't support it or the range is
  /// empty. Used to find a point guaranteed to sit on a multi-line link/text
  /// element (e.g. its first character) so a synthesized click never lands in
  /// the empty inter-line gap of the element's union bounding box.
  public static func boundsForRange(
    _ element: AXUIElement, location: Int, length: Int, screenH: CGFloat
  ) -> CGRect? {
    var range = CFRange(location: location, length: length)
    guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
    var raw: CFTypeRef?
    guard
      AXUIElementCopyParameterizedAttributeValue(
        element,
        kAXBoundsForRangeParameterizedAttribute as CFString,
        rangeValue,
        &raw) == .success,
      let value = raw,
      CFGetTypeID(value) == AXValueGetTypeID()
    else { return nil }
    let axValue = value as! AXValue
    guard AXValueGetType(axValue) == .cgRect else { return nil }
    var rect = CGRect.zero
    guard AXValueGetValue(axValue, .cgRect, &rect), rect.width > 0, rect.height > 0
    else { return nil }
    return CGRect(
      x: rect.minX, y: screenH - rect.minY - rect.height,
      width: rect.width, height: rect.height)
  }

  /// The on-screen character range, when the element publishes one. A range
  /// that covers the whole value is the document, not the window.
  public static func visibleCharacterRange(_ element: AXUIElement) -> CFRange? {
    storedRange(element, kAXVisibleCharacterRangeAttribute as String)
  }

  /// The UTF-16 range of visual line `line`. Nil when the element has no
  /// line layout, or `line` is past the last line.
  public static func rangeForLine(_ element: AXUIElement, line: Int) -> CFRange? {
    guard line >= 0 else { return nil }
    let parameter = NSNumber(value: line)
    var raw: CFTypeRef?
    guard
      AXUIElementCopyParameterizedAttributeValue(
        element, kAXRangeForLineParameterizedAttribute as CFString, parameter, &raw) == .success,
      let raw
    else { return nil }
    return range(from: raw)
  }

  /// The visual line that contains UTF-16 index `index`.
  public static func lineForIndex(_ element: AXUIElement, index: Int) -> Int? {
    guard index >= 0 else { return nil }
    let parameter = NSNumber(value: index)
    var raw: CFTypeRef?
    guard
      AXUIElementCopyParameterizedAttributeValue(
        element, kAXLineForIndexParameterizedAttribute as CFString, parameter, &raw) == .success,
      let raw
    else { return nil }
    if let number = raw as? NSNumber { return number.intValue }
    guard CFGetTypeID(raw) == CFNumberGetTypeID() else { return nil }
    return (raw as! NSNumber).intValue
  }

  private static func storedRange(_ element: AXUIElement, _ name: String) -> CFRange? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success, let raw
    else { return nil }
    return range(from: raw)
  }

  private static func range(from raw: CFTypeRef) -> CFRange? {
    guard CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    let value = raw as! AXValue
    guard AXValueGetType(value) == .cfRange else { return nil }
    var range = CFRange()
    guard AXValueGetValue(value, .cfRange, &range), range.location >= 0, range.length > 0
    else { return nil }
    return range
  }
}
