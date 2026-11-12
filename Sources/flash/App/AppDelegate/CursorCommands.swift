import AppKit
import ApplicationServices
import FlashCore

// `cursor <motion>` (Vim's motions in the focused text), `scroll
// cursor_top|cursor_middle|cursor_bottom` (`zt` `zz` `zb`) and `register paste
// --after` (`p` in text). Flash reads through Accessibility and writes
// through the app: a motion's landing is computed from the text the app gives
// and set with `AXSelectedTextRange`, which every engine takes; where the app
// gives no text, the app's own binding for the motion runs. Only text NORMAL
// acts on (`TextScope`) moves, never a terminal.

extension AppDelegate {
  /// One `cursor` command in the focused text: read off the main loop, the
  /// engine's landing set as the selection, read back. Without the text, the
  /// motion's binding (`performSourceCommand`), else nothing.
  func performCursor(
    _ command: CursorCommand, repeatCount: Int,
    completion: @escaping (NormalModeCommandOutcome) -> Void
  ) {
    guard let context = normalModeDispatchContext() else {
      applyModeOverlay()
      return completion(.noTarget)
    }
    guard !TerminalEmulators.contains(context.bundleIdentifier) else {
      return completion(.unavailable)
    }
    let count = normalizedRepeatCount(repeatCount)
    if case .findCharacter(let kind, let character?) = command {
      lastCharacterSearch = kind.search(for: character)
    }
    guard
      let resolved = CursorResolution.motion(
        for: command, count: count, lastSearch: lastCharacterSearch)
    else {
      FlashLog.debug("[cursor] nothing_to_do", fields: ["command": "\(command)"])
      return completion(.unavailable)
    }
    // In VISUAL the motion moves the selection's moving end.
    if modeStore.mode.isVisual {
      return performVisualMotion(
        resolved.motion, count: resolved.count, isRepeat: resolved.isRepeat,
        readsVisible: command.readsVisibleRange, completion: completion)
    }
    let pid = context.processID
    let readsVisible = command.readsVisibleRange
    let scope = textScope
    Self.normalModeAXActionQueue.async { [weak self] in
      let read = NormalModeDispatcher.focusedTextElement(pid: pid, detail: .contents)
      let outcome: CursorOutcome
      if !scope.isActive(for: read.text, pid: pid, element: read.element?.elementID) {
        outcome = .notText
      } else if let contents = read.text.contents, contents.text != nil {
        let visible = readsVisible ? read.element?.visibleRange() : nil
        if let target = CursorResolution.target(
          resolved.motion, count: resolved.count, isRepeat: resolved.isRepeat, in: contents,
          visible: visible)
        {
          outcome = read.element?.select(target..<target, pid: pid) == true ? .moved : .refused
        } else {
          outcome = .stayed
        }
      } else {
        outcome = .noText
      }
      DispatchQueue.main.async {
        guard let self else { return completion(.noTarget) }
        FlashLog.debug(
          "[cursor] motion", fields: ["command": "\(command)", "outcome": "\(outcome)"])
        switch outcome {
        case .moved, .stayed: completion(.performed)
        case .refused: completion(.failed)
        case .notText: completion(.unavailable)
        case .noText:
          // The app gives no text to measure: its own binding for the
          // motion, the macOS chord where there is one.
          guard let source = URLCommand.cursor(command).sourceCommand else {
            return completion(.unavailable)
          }
          self.performSourceCommand(
            source, repeatCount: count, context: context, completion: completion)
        }
      }
    }
  }

  private enum CursorOutcome {
    case moved, stayed, refused, notText, noText
  }

  /// `zt` `zz` `zb`: scroll the focused text so the caret's line sits at the
  /// top, middle or bottom of its scroll area, by the pixels between them.
  func performScrollCursor(
    _ position: ScrollCursorPosition,
    completion: @escaping (NormalModeCommandOutcome) -> Void
  ) {
    guard let context = normalModeDispatchContext(),
      !TerminalEmulators.contains(context.bundleIdentifier)
    else { return completion(.unavailable) }
    let pid = context.processID
    let scope = textScope
    Self.normalModeAXActionQueue.async {
      let read = NormalModeDispatcher.focusedTextElement(pid: pid, detail: .contents)
      var scrolled = false
      if let element = read.element,
        scope.isActive(for: read.text, pid: pid, element: element.elementID),
        let contents = read.text.contents,
        let caret = element.caretBounds(at: contents.selection.lowerBound, length: contents.length),
        let area = element.scrollAreaFrame()
      {
        let delta = position.scrollDelta(caret: caret, area: area)
        if abs(delta) >= 1 {
          scrolled = NormalModeDispatcher.postPixelScroll(
            vertical: Int32((-delta).rounded()), at: CGPoint(x: area.midX, y: area.midY))
        }
      }
      DispatchQueue.main.async { completion(scrolled ? .performed : .unavailable) }
    }
  }

  /// Vim's `p`: one character right in the focused text NORMAL acts on,
  /// unless the line ends at the cursor, then `body`. Elsewhere `body` alone.
  func stepPastCursor(_ body: @escaping () -> Void) {
    guard let context = normalModeDispatchContext(),
      !TerminalEmulators.contains(context.bundleIdentifier)
    else { return body() }
    let pid = context.processID
    let scope = textScope
    Self.normalModeAXActionQueue.async { [weak self] in
      let read = NormalModeDispatcher.focusedTextElement(pid: pid, detail: .caret)
      let active = scope.isActive(for: read.text, pid: pid, element: read.element?.elementID)
      let text = read.text
      DispatchQueue.main.async {
        guard let self, active, text.caretAtLineEnd == false else {
          return body()
        }
        self.performSourceCommand(
          URLCommand.inputMotion(.charRight).requiredSourceCommand, context: context,
          completion: { _ in body() })
      }
    }
  }
}

extension AXFocusedTextElement {
  /// `AXVisibleCharacterRange`: the text on screen, which `H`, `M` and `L`
  /// count lines in.
  func visibleRange() -> Range<Int>? {
    var raw: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element, kAXVisibleCharacterRangeAttribute as CFString, &raw) == .success,
      let raw, CFGetTypeID(raw) == AXValueGetTypeID()
    else { return nil }
    var range = CFRange()
    guard AXValueGetValue(raw as! AXValue, .cfRange, &range), range.location >= 0,
      range.length >= 0
    else { return nil }
    return range.location..<(range.location + range.length)
  }

  /// Where the caret's character is drawn (`AXBoundsForRange`), in
  /// Accessibility's top-left coordinates; the character before it at the
  /// text's end.
  func caretBounds(at caret: Int, length: Int) -> CGRect? {
    var range = CFRange(location: caret < length ? caret : max(caret - 1, 0), length: 1)
    guard length > 0, let parameter = AXValueCreate(.cfRange, &range) else { return nil }
    var raw: CFTypeRef?
    guard
      AXUIElementCopyParameterizedAttributeValue(
        element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &raw)
        == .success, let raw, CFGetTypeID(raw) == AXValueGetTypeID()
    else { return nil }
    var rect = CGRect.zero
    guard AXValueGetValue(raw as! AXValue, .cgRect, &rect), rect.height > 0 else { return nil }
    return rect
  }

  /// The frame of the scroll area the text scrolls in: the nearest
  /// `AXScrollArea` among the element and its first ancestors, else the
  /// element's own frame. Top-left coordinates.
  func scrollAreaFrame() -> CGRect? {
    var current: AXUIElement? = element
    for _ in 0..<5 {
      guard let node = current else { break }
      if NormalModeDispatcher.role(of: node) == kAXScrollAreaRole as String {
        return Self.topLeftFrame(of: node)
      }
      current = NormalModeDispatcher.elementAttribute(node, kAXParentAttribute as String)
    }
    return Self.topLeftFrame(of: element)
  }

  private static func topLeftFrame(of element: AXUIElement) -> CGRect? {
    guard let origin = NormalModeDispatcher.pointAttribute(element, kAXPositionAttribute as String),
      let size = NormalModeDispatcher.sizeAttribute(element, kAXSizeAttribute as String),
      size.width > 0, size.height > 0
    else { return nil }
    return CGRect(origin: origin, size: size)
  }
}
