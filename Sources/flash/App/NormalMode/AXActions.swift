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
  struct EditableFocusRepairCandidate: Equatable {
    var role: String?
    var subrole: String?
    var frame: CGRect?
    var enabled: Bool
    var hidden: Bool
    var isEditable: Bool
  }

  /// Stamped on every Flash-synthesized keyboard event (via `.eventSourceUserData`)
  /// so the normal-mode key tap never swallows our own output — `/`→⌘F, undo,
  /// tab chords, ⌘V paste, etc. Mirrors `ActionDispatcher.syntheticMouseEventTag`.
  static let syntheticKeyEventTag: Int64 = 0x46_4C_53_4B  // "FLSK"

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
    down.setIntegerValueField(.eventSourceUserData, value: syntheticKeyEventTag)
    up.setIntegerValueField(.eventSourceUserData, value: syntheticKeyEventTag)
    down.postToPid(pid)
    up.postToPid(pid)
    return true
  }

  @discardableResult
  static func typeText(_ text: String, to pid: pid_t) -> Bool {
    let source = CGEventSource(stateID: .combinedSessionState)
    var ok = true
    for unit in text.utf16 {
      guard
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
      else {
        ok = false
        continue
      }
      var character = UniChar(unit)
      down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &character)
      down.setIntegerValueField(.eventSourceUserData, value: syntheticKeyEventTag)
      up.setIntegerValueField(.eventSourceUserData, value: syntheticKeyEventTag)
      down.postToPid(pid)
      up.postToPid(pid)
    }
    return ok
  }

  /// Insert `text` as a single synthetic Unicode key event — the whole string
  /// typed at once, without touching the clipboard. Unlike `typeText` (one event
  /// per UTF-16 unit, which garbles surrogate pairs / multi-scalar clusters),
  /// this carries the full UTF-16 in one event, so emoji insert correctly.
  @discardableResult
  static func insertUnicode(_ text: String, to pid: pid_t) -> Bool {
    let source = CGEventSource(stateID: .combinedSessionState)
    guard
      let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
    else { return false }
    var utf16 = Array(text.utf16)
    down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
    up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
    down.setIntegerValueField(.eventSourceUserData, value: syntheticKeyEventTag)
    up.setIntegerValueField(.eventSourceUserData, value: syntheticKeyEventTag)
    down.postToPid(pid)
    up.postToPid(pid)
    return true
  }

  static func copy(_ value: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(value, forType: .string)
  }

  /// The text currently selected in the focused element of `pid`, read
  /// straight off the AX tree so a yank doesn't have to round-trip through the
  /// clipboard. Returns nil when nothing is selected or the app doesn't expose
  /// `AXSelectedText` (web content, terminals) — the caller then falls back to
  /// synthesizing ⌘C.
  static func selectedText(pid: pid_t) -> String? {
    let app = AXApp.make(pid: pid)
    guard let focused = elementAttribute(app, kAXFocusedUIElementAttribute as String),
      let text = stringAttribute(focused, kAXSelectedTextAttribute as String),
      !text.isEmpty
    else { return nil }
    return text
  }

  /// Forward argv to `/usr/bin/open` verbatim. Deliberately dumb: whatever
  /// the user typed after `:open` is handed straight to the system opener
  /// (URLs, files, `-a App`, …). All app-finding smartness lives in
  /// `:flashlight`.
  static func runOpen(_ args: [String]) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    proc.arguments = args
    FlashProcessEnvironment.shared.apply(to: proc)
    try? proc.run()
  }

  static func documentURL(pid: pid_t) -> String? {
    let app = AXApp.make(pid: pid)
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

  /// Close the focused window of `pid` by pressing its standard close button
  /// (the red traffic-light control). This shuts the OS window itself —
  /// distinct from `tab_close`/⌘W, which close a tab in tabbed apps. Returns
  /// false when the window exposes no AX close button (borderless/custom
  /// windows) so the caller can fall back to a keystroke.
  static func closeFocusedWindow(pid: pid_t) -> Bool {
    let app = AXApp.make(pid: pid)
    guard
      let window = elementAttribute(app, kAXFocusedWindowAttribute as String)
        ?? elementAttribute(app, kAXMainWindowAttribute as String)
    else {
      return false
    }
    guard let closeButton = elementAttribute(window, kAXCloseButtonAttribute as String) else {
      return false
    }
    return AXUIElementPerformAction(closeButton, kAXPressAction as CFString) == .success
  }

  static func strongEditableFocusCandidates(
    _ candidates: [EditableFocusRepairCandidate],
    windowFrame: CGRect?
  ) -> [EditableFocusRepairCandidate] {
    var strong: [EditableFocusRepairCandidate] = []
    for candidate in candidates
    where editableFocusCandidateIsStrong(candidate, windowFrame: windowFrame) {
      if !strong.contains(where: { editableFocusCandidatesRepresentSameElement($0, candidate) }) {
        strong.append(candidate)
      }
    }
    return strong
  }

  private static func editableFocusCandidateIsStrong(
    _ candidate: EditableFocusRepairCandidate,
    windowFrame: CGRect?
  ) -> Bool {
    guard candidate.isEditable, candidate.enabled, !candidate.hidden else { return false }
    guard let role = candidate.role, editableFocusRepairRoles.contains(role) else { return false }
    guard candidate.subrole != "AXSearchField" else { return false }
    guard let frame = candidate.frame, frame.width >= 20, frame.height >= 12 else {
      return false
    }
    guard let windowFrame else { return true }
    let intersection = frame.intersection(windowFrame)
    guard !intersection.isNull, !intersection.isEmpty else { return false }
    return area(intersection) / area(frame) >= 0.5
  }

  private static func editableFocusCandidatesRepresentSameElement(
    _ lhs: EditableFocusRepairCandidate,
    _ rhs: EditableFocusRepairCandidate
  ) -> Bool {
    guard lhs.role == rhs.role, let left = lhs.frame, let right = rhs.frame else {
      return false
    }
    let intersection = left.intersection(right)
    guard !intersection.isNull, !intersection.isEmpty else { return false }
    return area(intersection) / min(area(left), area(right)) >= 0.9
  }

  private static func area(_ rect: CGRect) -> CGFloat {
    max(0, rect.width) * max(0, rect.height)
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

  private static let editableFocusRepairRoles: Set<String> = [
    "AXTextField", "AXTextArea",
  ]
}
