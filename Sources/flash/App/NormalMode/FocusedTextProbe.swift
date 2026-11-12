import AppKit
import ApplicationServices
import FlashCore
import FlashProviders

extension NormalModeDispatcher {
  /// Each element the probe reads waits at most this long: a wedged app
  /// costs the move a short pause, then counts as having nothing editable
  /// focused.
  static let focusedTextMessagingTimeout: Float = 0.25

  /// The focused element of `pid` as `FocusedText` (`FocusedText.read`). A
  /// declared terminal emulator is answered without any AX read. Blocking AX
  /// IPC otherwise, a few calls bounded per element: run it on
  /// `AppDelegate.normalModeAXActionQueue`, never on main.
  static func focusedText(pid: pid_t, detail: FocusedText.Detail) -> FocusedText {
    focusedTextElement(pid: pid, detail: detail).text
  }

  /// `focusedText`, with the element it read, so a motion or VISUAL can
  /// select a range of that same element (`AXFocusedTextElement.select`).
  static func focusedTextElement(
    pid: pid_t, detail: FocusedText.Detail
  ) -> (text: FocusedText, element: AXFocusedTextElement?) {
    let inTerminal = TerminalEmulators.contains(
      NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
    guard !inTerminal else {
      return (
        FocusedText.read(AXFocusedTextElement?.none, inTerminalEmulator: true, detail: detail),
        nil
      )
    }
    let focused = focusedElement(pid: pid)
    return (FocusedText.read(focused, inTerminalEmulator: false, detail: detail), focused)
  }

  /// The app's focused element, each read bounded by
  /// `focusedTextMessagingTimeout`.
  static func focusedElement(pid: pid_t) -> AXFocusedTextElement? {
    let timeout = focusedTextMessagingTimeout
    let app = AXApp.make(pid: pid, messagingTimeout: timeout)
    return elementAttribute(app, kAXFocusedUIElementAttribute as String).map {
      AXUIElementSetMessagingTimeout($0, timeout)
      return AXFocusedTextElement(element: $0)
    }
  }
}

/// The focused element, read through Accessibility.
struct AXFocusedTextElement: FocusedTextElement {
  let element: AXUIElement

  /// The element's identity (`CFHash`), which `TextScope` and VISUAL compare
  /// across reads: another value means the focus moved.
  var elementID: Int { Int(bitPattern: CFHash(element)) }

  /// `kAXDOMClassListAttribute` (`AXWebConstants.h`): an array of the
  /// element's class names, which Chromium and WebKit expose on every web
  /// element.
  static let domClassListAttribute = "AXDOMClassList"

  func identity() -> FocusedTextIdentity? {
    let names =
      [
        kAXRoleAttribute, kAXSubroleAttribute, Self.domClassListAttribute,
        kAXDescriptionAttribute,
      ] as CFArray
    var raw: CFArray?
    // An attribute the element lacks comes back as an error value, which
    // none of the casts below accept.
    guard
      AXUIElementCopyMultipleAttributeValues(
        element, names, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
      let values = raw as? [Any], values.count == 4
    else { return nil }
    return FocusedTextIdentity(
      role: values[0] as? String, subrole: values[1] as? String,
      domClasses: values[2] as? [String], description: values[3] as? String)
  }

  func valueIsSettable() -> Bool? {
    var settable: DarwinBoolean = false
    guard
      AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        == .success
    else { return nil }
    return settable.boolValue
  }

  func selectedRange() -> CFRange? {
    var raw: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &raw)
        == .success, let raw, CFGetTypeID(raw) == AXValueGetTypeID()
    else { return nil }
    var range = CFRange()
    guard AXValueGetValue(raw as! AXValue, .cfRange, &range) else { return nil }
    return range
  }

  func characterCount() -> Int? {
    NormalModeDispatcher.numberAttribute(element, kAXNumberOfCharactersAttribute as String)
      .map(Int.init)
  }

  func value() -> String? {
    NormalModeDispatcher.stringAttribute(element, kAXValueAttribute as String)
  }

  /// Selects `range` of this element, if it still has the app's keyboard
  /// focus, and reads the selection back: true only when the app now
  /// selects exactly `range`. A deletion trusts nothing else.
  func select(_ range: Range<Int>, pid: pid_t) -> Bool {
    guard let focused = NormalModeDispatcher.focusedElement(pid: pid),
      CFEqual(focused.element, element)
    else { return false }
    var wanted = CFRange(location: range.lowerBound, length: range.count)
    guard let value = AXValueCreate(.cfRange, &wanted),
      AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
        == .success,
      let selected = selectedRange()
    else { return false }
    return selected.location == wanted.location && selected.length == wanted.length
  }

  func character(at location: Int) -> String? {
    var range = CFRange(location: location, length: 1)
    guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
    var raw: CFTypeRef?
    guard
      AXUIElementCopyParameterizedAttributeValue(
        element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &raw)
        == .success
    else { return nil }
    return raw as? String
  }
}
