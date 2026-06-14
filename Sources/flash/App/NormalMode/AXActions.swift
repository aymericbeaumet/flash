import AppKit
import ApplicationServices
import Carbon.HIToolbox
import FlashCore
import FlashProviders

/// AX-level helpers normal-mode uses to drive the focused app
/// directly: synthesizing keystrokes, copying text to the clipboard,
/// resolving the current document URL, detecting/defocusing editable
/// elements.
///
/// Split out of NormalMode.swift; same public surface, no behaviour
/// change.
extension NormalModeDispatcher {
  @discardableResult
  static func sendKey(
    virtualKey: CGKeyCode,
    flags: CGEventFlags = [],
    to pid: pid_t
  ) -> Bool {
    let source = CGEventSource(stateID: .combinedSessionState)
    guard
      let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
    else { return false }
    down.flags = flags
    up.flags = flags
    down.postToPid(pid)
    up.postToPid(pid)
    return true
  }

  static func cgFlags(from modifierFlags: NSEvent.ModifierFlags) -> CGEventFlags {
    let independent = modifierFlags.intersection(.deviceIndependentFlagsMask)
    var flags = CGEventFlags()
    if independent.contains(.command) { flags.insert(.maskCommand) }
    if independent.contains(.shift) { flags.insert(.maskShift) }
    if independent.contains(.control) { flags.insert(.maskControl) }
    if independent.contains(.option) { flags.insert(.maskAlternate) }
    return flags
  }

  static func copy(_ value: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(value, forType: .string)
  }

  /// Forward argv to `/usr/bin/open` verbatim. Deliberately dumb: whatever
  /// the user typed after `:open` is handed straight to the system opener
  /// (URLs, files, `-a App`, …). All app-finding smartness lives in
  /// `:flashlight`.
  static func runOpen(_ args: [String]) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    proc.arguments = args
    try? proc.run()
  }

  static func documentURL(pid: pid_t) -> String? {
    let app = AXUIElementCreateApplication(pid)
    var focusedRaw: CFTypeRef?
    if AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedRaw)
      == .success,
      let element = focusedRaw,
      CFGetTypeID(element) == AXUIElementGetTypeID(),
      let url = documentURLNear(element as! AXUIElement)
    {
      return url
    }

    var windowRaw: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRaw)
        == .success,
      let window = windowRaw,
      CFGetTypeID(window) == AXUIElementGetTypeID()
    else { return nil }
    let focusedWindow = window as! AXUIElement
    if let url = urlAttribute(focusedWindow, kAXDocumentAttribute as String)
      ?? urlAttribute(focusedWindow, kAXURLAttribute as String)
    {
      return url
    }
    return firstDocumentURL(in: focusedWindow, maxNodes: 2_000)
  }

  static func isEditableFocusedElement(pid: pid_t) -> Bool {
    let app = AXUIElementCreateApplication(pid)
    guard let element = elementAttribute(app, kAXFocusedUIElementAttribute as String) else {
      return false
    }
    return isEditable(element)
  }

  static func focusedElementFrame(pid: pid_t) -> CGRect? {
    let app = AXUIElementCreateApplication(pid)
    let screenH = primaryScreenHeight()
    if let element = elementAttribute(app, kAXFocusedUIElementAttribute as String),
      let frame = frame(of: element, primaryScreenHeight: screenH)
    {
      return frame
    }
    if let window = elementAttribute(app, kAXFocusedWindowAttribute as String),
      let frame = frame(of: window, primaryScreenHeight: screenH)
    {
      return frame
    }
    return nil
  }

  private static func isEditable(_ element: AXUIElement) -> Bool {
    var current = element
    for _ in 0..<8 {
      if role(of: current).map({ editableRoles.contains($0) }) == true {
        return true
      }
      if boolAttribute(current, "AXIsEditable") == true {
        return true
      }
      if elementAttribute(current, "AXEditableAncestor") != nil
        || elementAttribute(current, "AXHighestEditableAncestor") != nil
      {
        return true
      }
      guard let parent = elementAttribute(current, kAXParentAttribute as String) else {
        return false
      }
      current = parent
    }
    return false
  }

  private static func documentURLNear(_ element: AXUIElement) -> String? {
    var current = element
    for _ in 0..<10 {
      if role(of: current).map({ documentRoles.contains($0) }) == true {
        if let url = urlAttribute(current, kAXURLAttribute as String)
          ?? urlAttribute(current, kAXDocumentAttribute as String)
        {
          return url
        }
      }
      guard let parent = elementAttribute(current, kAXParentAttribute as String) else {
        return nil
      }
      current = parent
    }
    return nil
  }

  private static func firstDocumentURL(in root: AXUIElement, maxNodes: Int) -> String? {
    var queue = [root]
    var index = 0
    while index < queue.count, index < maxNodes {
      let element = queue[index]
      index += 1
      if role(of: element).map({ documentRoles.contains($0) }) == true {
        if let url = urlAttribute(element, kAXURLAttribute as String)
          ?? urlAttribute(element, kAXDocumentAttribute as String)
        {
          return url
        }
      }
      var raw: CFTypeRef?
      if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw)
        == .success,
        let children = raw as? [AXUIElement]
      {
        queue.append(contentsOf: children)
      }
    }
    return nil
  }
}
