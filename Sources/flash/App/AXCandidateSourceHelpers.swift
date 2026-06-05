import AppKit
import ApplicationServices
import FlashCore
import Foundation

enum AXCandidateSourceHelpers {
  static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
      let value = raw
    else { return nil }
    return value as? String
  }

  static func urlAttribute(_ element: AXUIElement, _ name: String) -> String? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
      let value = raw
    else { return nil }
    if let url = value as? URL {
      return url.absoluteString
    }
    return value as? String
  }

  static func elementArrayAttribute(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
      let values = raw as? [AXUIElement]
    else { return [] }
    return values
  }

  static func resolveAXItem(
    _ item: Candidate,
    completion: @escaping (CandidateResolution) -> Void
  ) {
    if let pid = item.pid,
      let app = NSRunningApplication(processIdentifier: pid)
    {
      app.activate(options: [.activateAllWindows])
    }
    if let element = item.targetElement {
      if AXUIElementPerformAction(element, kAXPressAction as CFString) != .success {
        _ = AXUIElementSetAttributeValue(element, kAXSelectedAttribute as CFString, kCFBooleanTrue)
      }
    }
    DispatchQueue.main.async {
      completion(.resolved(pid: item.pid))
    }
  }
}
