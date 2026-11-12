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
    let source = SyntheticEventSources.session
    guard
      let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
    else { return false }
    let modifiers =
      flags.isEmpty || !UIKitApps.hostsUIKit(pid: pid) ? [] : UIKitApps.modifierKeys(in: flags)
    var held: CGEventFlags = []
    for modifier in modifiers {
      held.insert(modifier.flag)
      postModifierKey(modifier.key, down: true, flags: held, source: source, to: pid)
    }
    down.flags = flags
    up.flags = flags
    down.setIntegerValueField(.eventSourceUserData, value: syntheticKeyEventTag)
    up.setIntegerValueField(.eventSourceUserData, value: syntheticKeyEventTag)
    down.postToPid(pid)
    up.postToPid(pid)
    for modifier in modifiers.reversed() {
      held.remove(modifier.flag)
      postModifierKey(modifier.key, down: false, flags: held, source: source, to: pid)
    }
    return true
  }

  /// A modifier key's own press or release (see `UIKitApps`); `flags` is the
  /// modifier state after it.
  private static func postModifierKey(
    _ key: CGKeyCode, down: Bool, flags: CGEventFlags, source: CGEventSource?, to pid: pid_t
  ) {
    guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
    else { return }
    event.flags = flags
    event.setIntegerValueField(.eventSourceUserData, value: syntheticKeyEventTag)
    event.postToPid(pid)
  }

  /// Post one modifier chord to the session event stream so macOS can handle
  /// system shortcuts that do not belong to a target application.
  @discardableResult
  static func sendGlobalKey(
    virtualKey: CGKeyCode,
    flags: CGEventFlags
  ) -> Bool {
    guard let events = focusedKeyEvents(virtualKey: virtualKey, flags: flags) else { return false }
    events.down.post(tap: .cghidEventTap)
    events.up.post(tap: .cghidEventTap)
    return true
  }

  /// Test seam. Production posts at the annotated session tap: downstream of
  /// `KeyboardCaptureTap`, so the stroke is not swallowed as another hyper
  /// key, and the window server attaches it to the key window. `postToPid`
  /// has no window, so Alacritty drops it while the hyper key is still
  /// physically down. Volume is an auxiliary system event and does not take
  /// this path.
  static var focusedKeyPoster: (CGEvent) -> Void = { event in
    event.post(tap: .cgAnnotatedSessionEventTap)
  }

  /// One key down/up for the focused app. A private source keeps the held
  /// hyper key out of the event; the session keyboard type still fills the
  /// function-key unicode arrows and F-keys need.
  static func focusedKeyEvents(
    virtualKey: CGKeyCode,
    flags: CGEventFlags
  ) -> (down: CGEvent, up: CGEvent)? {
    let source = SyntheticEventSources.focusedKeyboardSource()
    guard
      let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
    else { return nil }
    down.flags = flags
    up.flags = flags
    down.setIntegerValueField(.eventSourceUserData, value: syntheticKeyEventTag)
    up.setIntegerValueField(.eventSourceUserData, value: syntheticKeyEventTag)
    return (down, up)
  }

  /// Posts one key into the focused app's key window. See `focusedKeyPoster`.
  @discardableResult
  static func sendFocusedKey(
    virtualKey: CGKeyCode,
    flags: CGEventFlags = []
  ) -> Bool {
    guard let events = focusedKeyEvents(virtualKey: virtualKey, flags: flags) else { return false }
    focusedKeyPoster(events.down)
    focusedKeyPoster(events.up)
    return true
  }

  @discardableResult
  static func typeText(_ text: String, to pid: pid_t) -> Bool {
    let source = SyntheticEventSources.session
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
    let source = SyntheticEventSources.session
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

  struct TextSelectionSnapshot {
    let element: AXUIElement?
    let identity: TextSelectionIdentity
  }

  enum SelectionCollapseResult { case collapsed, unsupported, changed }

  /// Capture both the bytes and the AX identity: later steps must not follow a
  /// newly focused field or collapse a selection the user changed meanwhile.
  static func captureTextSelection(pid: pid_t) -> TextSelectionSnapshot {
    let app = AXApp.make(pid: pid)
    let focused = elementAttribute(app, kAXFocusedUIElementAttribute as String)
    let text = focused.flatMap { stringAttribute($0, kAXSelectedTextAttribute as String) }
    return TextSelectionSnapshot(
      element: focused,
      identity: TextSelectionIdentity(
        text: text.flatMap { $0.isEmpty ? nil : $0 },
        range: focused.flatMap(selectedTextRange)))
  }

  static func textSelectionState(
    _ captured: TextSelectionSnapshot, pid: pid_t
  ) -> TextSelectionIdentity.State {
    let current = captureTextSelection(pid: pid)
    switch (captured.element, current.element) {
    case (nil, nil): break
    case (let original?, let focused?) where CFEqual(original, focused): break
    default: return .changed
    }
    return captured.identity.state(comparedTo: current.identity)
  }

  /// Mutate only the element and range captured by the yank, never a fresh
  /// lookup's replacement. A copy action may have already collapsed it.
  static func collapseSelectedText(
    _ captured: TextSelectionSnapshot, pid: pid_t, shouldContinue: () -> Bool = { true }
  ) -> SelectionCollapseResult {
    switch textSelectionState(captured, pid: pid) {
    case .changed: return .changed
    case .collapsed: return .collapsed
    case .unchanged: break
    }
    guard let focused = captured.element, let range = captured.identity.range else {
      return .unsupported
    }
    if range.length == 0 { return .collapsed }
    var collapsed = CFRange(location: range.location + range.length, length: 0)
    guard let value = AXValueCreate(.cfRange, &collapsed) else { return .unsupported }
    guard shouldContinue() else { return .changed }
    return AXUIElementSetAttributeValue(
      focused, kAXSelectedTextRangeAttribute as CFString, value) == .success
      ? .collapsed : .unsupported
  }

  private static func selectedTextRange(_ element: AXUIElement) -> NSRange? {
    var raw: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element, kAXSelectedTextRangeAttribute as CFString, &raw) == .success,
      let raw, CFGetTypeID(raw) == AXValueGetTypeID()
    else { return nil }
    let value = raw as! AXValue
    var range = CFRange(location: 0, length: 0)
    guard AXValueGetType(value) == .cfRange, AXValueGetValue(value, .cfRange, &range),
      range.location >= 0, range.length >= 0, range.location <= Int.max - range.length
    else { return nil }
    return NSRange(location: range.location, length: range.length)
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
  /// distinct from `tab close`/⌘W, which close a tab in tabbed apps. Returns
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

  /// How many standard windows `pid` has (`AXStandardWindow`: documents,
  /// conversations, browser windows; not dialogs, sheets or floating
  /// panels), on every Space and minimized ones included; nil when its
  /// windows cannot be read. `app close` quits an app at its last one.
  static func standardWindowCount(pid: pid_t) -> Int? {
    var raw: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(AXApp.make(pid: pid), kAXWindowsAttribute as CFString, &raw)
        == .success, let windows = raw as? [AXUIElement]
    else { return nil }
    return windows.filter {
      stringAttribute($0, kAXSubroleAttribute as String) == kAXStandardWindowSubrole as String
    }.count
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

  /// `input focus`: focus the `index`-th (1-based) editable
  /// text input of the focused window, in reading order (top-to-bottom, then
  /// left-to-right — AX frames are top-left-origin, so ascending y is
  /// downwards). Returns false when no input exists in the walk budget.
  static func focusTextInput(pid: pid_t, index: Int, maxNodes: Int = 2000) -> Bool {
    let app = AXApp.make(pid: pid)
    guard
      let window = elementAttribute(app, kAXFocusedWindowAttribute as String)
        ?? elementAttribute(app, kAXMainWindowAttribute as String)
    else { return false }
    var queue = [window]
    var cursor = 0
    var inputs: [(element: AXUIElement, frame: CGRect)] = []
    while cursor < queue.count, cursor < maxNodes {
      let element = queue[cursor]
      cursor += 1
      if let role = role(of: element), focusableInputRoles.contains(role),
        let frame = frame(of: element), frame.width >= 10, frame.height >= 8
      {
        inputs.append((element, frame))
      }
      var raw: CFTypeRef?
      if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw)
        == .success,
        let children = raw as? [AXUIElement]
      {
        queue.append(contentsOf: children)
      }
    }
    guard !inputs.isEmpty else { return false }
    inputs.sort { lhs, rhs in
      if abs(lhs.frame.minY - rhs.frame.minY) > 8 { return lhs.frame.minY < rhs.frame.minY }
      return lhs.frame.minX < rhs.frame.minX
    }
    let target = inputs[min(max(index, 1), inputs.count) - 1]
    return AXUIElementSetAttributeValue(
      target.element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
  }

  private static func frame(of element: AXUIElement) -> CGRect? {
    var raw: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &raw) == .success,
      let value = raw,
      CFGetTypeID(value) == AXValueGetTypeID()
    else { return nil }
    var rect = CGRect.zero
    guard AXValueGetValue((value as! AXValue), .cgRect, &rect) else { return nil }
    return rect
  }

  private static let focusableInputRoles: Set<String> = [
    "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox",
  ]

  /// Retained scroll areas in BFS order, including nested containers.
  static func scrollAreaTargets(
    pid: pid_t, screenH: CGFloat, bundleIdentifier: String, maxNodes: Int = 2000
  ) -> [JumpTarget] {
    let app = AXApp.make(pid: pid)
    guard
      let window = elementAttribute(app, kAXFocusedWindowAttribute as String)
        ?? elementAttribute(app, kAXMainWindowAttribute as String)
    else { return [] }
    var queue = [window]
    var cursor = 0
    var targets: [JumpTarget] = []
    while cursor < queue.count, cursor < maxNodes {
      let element = queue[cursor]
      cursor += 1
      if role(of: element) == "AXScrollArea",
        let target = AccessibilityProvider.captureTarget(
          element: element, id: "scroll_area_\(targets.count)", pid: pid, screenH: screenH,
          providerID: "scroll_target", bundleIdentifier: bundleIdentifier,
          allowsInteractiveDescendants: true),
        target.frame.width >= 40, target.frame.height >= 40
      {
        targets.append(target)
      }
      var raw: CFTypeRef?
      if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw)
        == .success,
        let children = raw as? [AXUIElement]
      {
        queue.append(contentsOf: children)
      }
    }
    return targets
  }
}
