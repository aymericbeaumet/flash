import AppKit
import ApplicationServices
import Carbon.HIToolbox
import FlashCore
import FlashProviders

/// Normal-mode scrolling: page-instant, half-page wheel synthesis,
/// arrow-key fallback. Walks the focused-app AX tree to find scroll
/// bars / `kAXVerticalScrollBar` / scrolled page panes and uses
/// kAXValue setters where the AX surface allows it.
///
/// Split out of NormalMode.swift; same public surface, no behaviour
/// change.
extension NormalModeDispatcher {
  @discardableResult
  static func scroll(
    _ kind: ScrollKind,
    pid: pid_t,
    bundleID: String = "",
    windowFrame: CGRect? = nil
  ) -> Bool {
    // Hermetic policy: never emit a character keystroke as part of a
    // scroll command. The user's `h` / `j` / `k` / `l` mappings in
    // normal mode must not surface as typed text in the focused app —
    // not in vim, not in a shell prompt, nowhere. We try AX
    // scroll-bar value, then a synthesised scroll wheel (which is a
    // separate `CGEvent` type and never inserts a glyph), then AX
    // actions (`AXScroll*`). The earlier fallback to arrow / page /
    // letter keys was the leak path.
    let pageTarget = windowFrame.flatMap { pageScrollTarget(pid: pid, visibleIn: $0) }
    if let pageTarget {
      if scrollPageInstantly(kind, element: pageTarget.element) {
        FlashLog.debug("[normal_mode] scroll method=page_ax_edge kind=\(kind) bundle=\(bundleID)")
        return true
      }
      if synthesizeScrollWheel(kind, windowFrame: windowFrame, pageFrame: pageTarget.frame) {
        FlashLog.debug("[normal_mode] scroll method=page_wheel kind=\(kind) bundle=\(bundleID)")
        return true
      }
    }

    switch kind {
    case .top, .bottom:
      if scrollInstantly(kind, pid: pid) {
        FlashLog.debug("[normal_mode] scroll method=ax_value kind=\(kind) bundle=\(bundleID)")
        return true
      }
    default:
      if synthesizeScrollWheel(kind, windowFrame: windowFrame, pageFrame: nil) {
        FlashLog.debug("[normal_mode] scroll method=wheel kind=\(kind) bundle=\(bundleID)")
        return true
      }
      if scrollInstantly(kind, pid: pid) {
        FlashLog.debug("[normal_mode] scroll method=ax_value kind=\(kind) bundle=\(bundleID)")
        return true
      }
    }

    if performScrollAction(kind, pid: pid) {
      FlashLog.debug("[normal_mode] scroll method=ax_action kind=\(kind) bundle=\(bundleID)")
      return true
    }
    FlashLog.debug("[normal_mode] no hermetic scroller for \(kind) bundle=\(bundleID)")
    return false
  }

  static func adjustedScrollValue(
    current: Double,
    lower: Double,
    upper: Double,
    deltaFraction: Double
  ) -> Double {
    guard upper > lower else { return current }
    let adjusted = current + (upper - lower) * deltaFraction
    return min(max(adjusted, lower), upper)
  }

  static func edgeScrollValue(lower: Double, upper: Double, edge: ScrollEdge) -> Double {
    switch edge {
    case .minimum: return lower
    case .maximum: return upper
    }
  }

  private enum Axis: Equatable {
    case horizontal
    case vertical
  }

  enum ScrollEdge {
    case minimum
    case maximum
  }

  private struct ScrollIntent {
    var axis: Axis
    var deltaFraction: Double?
    var edge: ScrollEdge?
  }

  private struct PageScrollTarget {
    var element: AXUIElement
    var frame: CGRect
  }

  private static func scrollInstantly(_ kind: ScrollKind, pid: pid_t) -> Bool {
    guard let intent = intent(for: kind),
      let bar = scrollBar(axis: intent.axis, pid: pid),
      let current = numberAttribute(bar, kAXValueAttribute as String),
      let lower = numberAttribute(bar, kAXMinValueAttribute as String),
      let upper = numberAttribute(bar, kAXMaxValueAttribute as String)
    else { return false }

    let next: Double
    if let edge = intent.edge {
      next = edgeScrollValue(lower: lower, upper: upper, edge: edge)
    } else if let deltaFraction = intent.deltaFraction {
      next = adjustedScrollValue(
        current: current,
        lower: lower,
        upper: upper,
        deltaFraction: deltaFraction)
    } else {
      return false
    }

    guard abs(next - current) > .ulpOfOne else { return true }
    return AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: next))
      == .success
  }

  private static func scrollPageInstantly(_ kind: ScrollKind, element: AXUIElement) -> Bool {
    guard let intent = intent(for: kind),
      intent.axis == .vertical,
      let edge = intent.edge,
      let bar = directScrollBar(on: element, axis: .vertical)
        ?? scrollBarNear(element: element, axis: .vertical),
      let current = numberAttribute(bar, kAXValueAttribute as String),
      let lower = numberAttribute(bar, kAXMinValueAttribute as String),
      let upper = numberAttribute(bar, kAXMaxValueAttribute as String)
    else { return false }

    let next = edgeScrollValue(lower: lower, upper: upper, edge: edge)
    guard abs(next - current) > .ulpOfOne else { return true }
    return AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: next))
      == .success
  }

  private static func performScrollAction(_ kind: ScrollKind, pid: pid_t) -> Bool {
    let actions = scrollActionNames(for: kind)
    guard !actions.isEmpty else { return false }

    let app = AXUIElementCreateApplication(pid)
    if let focused = elementAttribute(app, kAXFocusedUIElementAttribute as String),
      performActionNear(element: focused, actions: actions)
    {
      return true
    }
    guard let window = elementAttribute(app, kAXFocusedWindowAttribute as String) else {
      return false
    }
    if performActionNear(element: window, actions: actions) {
      return true
    }
    return performFirstActionInTree(in: window, actions: actions, maxNodes: 2_000)
  }

  private static func scrollActionNames(for kind: ScrollKind) -> [String] {
    switch kind {
    case .left:
      return ["AXScrollLeftByPage", "AXScrollLeft"]
    case .right:
      return ["AXScrollRightByPage", "AXScrollRight"]
    case .up, .halfPageUp:
      return ["AXScrollUpByPage", "AXScrollUp"]
    case .down, .halfPageDown:
      return ["AXScrollDownByPage", "AXScrollDown"]
    case .top, .bottom:
      return []
    }
  }

  private static func performActionNear(element: AXUIElement, actions: [String]) -> Bool {
    var current = element
    for _ in 0..<10 {
      if performFirstSupportedAction(current, actions: actions) {
        return true
      }
      guard let parent = elementAttribute(current, kAXParentAttribute as String) else {
        return false
      }
      current = parent
    }
    return false
  }

  private static func performFirstActionInTree(
    in root: AXUIElement,
    actions: [String],
    maxNodes: Int
  ) -> Bool {
    var queue = [root]
    var index = 0
    while index < queue.count, index < maxNodes {
      let element = queue[index]
      index += 1
      if performFirstSupportedAction(element, actions: actions) {
        return true
      }
      var raw: CFTypeRef?
      if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw)
        == .success,
        let children = raw as? [AXUIElement]
      {
        queue.append(contentsOf: children)
      }
    }
    return false
  }

  private static func performFirstSupportedAction(
    _ element: AXUIElement,
    actions: [String]
  ) -> Bool {
    for action in actions {
      if AXUIElementPerformAction(element, action as CFString) == .success {
        return true
      }
    }
    return false
  }

  private static func intent(for kind: ScrollKind) -> ScrollIntent? {
    switch kind {
    case .left:
      return ScrollIntent(axis: .horizontal, deltaFraction: -0.08, edge: nil)
    case .right:
      return ScrollIntent(axis: .horizontal, deltaFraction: 0.08, edge: nil)
    case .up:
      return ScrollIntent(axis: .vertical, deltaFraction: -0.08, edge: nil)
    case .down:
      return ScrollIntent(axis: .vertical, deltaFraction: 0.08, edge: nil)
    case .halfPageUp:
      return ScrollIntent(axis: .vertical, deltaFraction: -0.5, edge: nil)
    case .halfPageDown:
      return ScrollIntent(axis: .vertical, deltaFraction: 0.5, edge: nil)
    case .top:
      return ScrollIntent(axis: .vertical, deltaFraction: nil, edge: .minimum)
    case .bottom:
      return ScrollIntent(axis: .vertical, deltaFraction: nil, edge: .maximum)
    }
  }

  private static func synthesizeScrollWheel(
    _ kind: ScrollKind,
    windowFrame: CGRect?,
    pageFrame: CGRect?
  ) -> Bool {
    guard let windowFrame, !windowFrame.isNull, windowFrame.width > 0, windowFrame.height > 0,
      let delta = scrollWheelDelta(
        for: kind,
        viewportSize: (pageFrame ?? windowFrame).size)
    else {
      return false
    }
    let source = CGEventSource(stateID: .combinedSessionState)
    guard
      let event = CGEvent(
        scrollWheelEvent2Source: source,
        units: .pixel,
        wheelCount: 2,
        wheel1: delta.vertical,
        wheel2: delta.horizontal,
        wheel3: 0)
    else {
      return false
    }
    let screenH = primaryScreenHeight()
    let point = scrollWheelPoint(windowFrame: windowFrame, pageFrame: pageFrame)
    event.location = CGPoint(x: point.x, y: screenH - point.y)
    event.setIntegerValueField(
      .eventSourceUserData, value: ActionDispatcher.syntheticMouseEventTag)
    event.post(tap: .cghidEventTap)
    return true
  }

  private static func scrollWheelPoint(windowFrame: CGRect, pageFrame: CGRect?) -> CGPoint {
    let frame = pageFrame ?? windowFrame
    let insetX = max(4, min(10, frame.width * 0.01))
    let x = min(max(frame.maxX - insetX, windowFrame.minX + 4), windowFrame.maxX - 4)
    let y = min(max(frame.midY, windowFrame.minY + 4), windowFrame.maxY - 4)
    return CGPoint(x: x, y: y)
  }

  static func scrollWheelDelta(
    for kind: ScrollKind,
    viewportSize: CGSize
  ) -> (vertical: Int32, horizontal: Int32)? {
    let verticalPage = Int32(max(1, (viewportSize.height / 2).rounded()))
    switch kind {
    case .left:
      return (vertical: 0, horizontal: scrollStepPixels)
    case .right:
      return (vertical: 0, horizontal: -scrollStepPixels)
    case .up:
      return (vertical: scrollStepPixels, horizontal: 0)
    case .down:
      return (vertical: -scrollStepPixels, horizontal: 0)
    case .halfPageUp:
      return (vertical: verticalPage, horizontal: 0)
    case .halfPageDown:
      return (vertical: -verticalPage, horizontal: 0)
    case .top, .bottom:
      return nil
    }
  }

  static func primaryScreenHeight() -> CGFloat {
    if let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) {
      return primary.frame.height
    }
    return NSScreen.main?.frame.height ?? 1080
  }
  private static func scrollBar(axis: Axis, pid: pid_t) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    if let focused = elementAttribute(app, kAXFocusedUIElementAttribute as String),
      let bar = scrollBarNear(element: focused, axis: axis)
    {
      return bar
    }
    guard let window = elementAttribute(app, kAXFocusedWindowAttribute as String) else {
      return nil
    }
    return firstScrollBar(in: window, axis: axis, maxNodes: 2_000)
  }

  private static func scrollBarNear(element: AXUIElement, axis: Axis) -> AXUIElement? {
    var current = element
    for _ in 0..<10 {
      if let bar = directScrollBar(on: current, axis: axis) {
        return bar
      }
      guard let parent = elementAttribute(current, kAXParentAttribute as String) else {
        return nil
      }
      current = parent
    }
    return nil
  }

  private static func firstScrollBar(
    in root: AXUIElement,
    axis: Axis,
    maxNodes: Int
  ) -> AXUIElement? {
    var queue = [root]
    var index = 0
    while index < queue.count, index < maxNodes {
      let element = queue[index]
      index += 1
      if let bar = directScrollBar(on: element, axis: axis) {
        return bar
      }
      if isScrollBar(element, axis: axis), canAdjustScrollBar(element) {
        return element
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

  private static func directScrollBar(on element: AXUIElement, axis: Axis) -> AXUIElement? {
    let name =
      axis == .vertical
      ? (kAXVerticalScrollBarAttribute as String)
      : (kAXHorizontalScrollBarAttribute as String)
    guard let bar = elementAttribute(element, name), canAdjustScrollBar(bar) else {
      return nil
    }
    return bar
  }

  private static func isScrollBar(_ element: AXUIElement, axis: Axis) -> Bool {
    guard role(of: element) == "AXScrollBar" else { return false }
    guard let orientation = stringAttribute(element, kAXOrientationAttribute as String) else {
      return true
    }
    switch axis {
    case .vertical:
      return orientation == (kAXVerticalOrientationValue as String)
    case .horizontal:
      return orientation == (kAXHorizontalOrientationValue as String)
    }
  }

  private static func canAdjustScrollBar(_ element: AXUIElement) -> Bool {
    numberAttribute(element, kAXValueAttribute as String) != nil
      && numberAttribute(element, kAXMinValueAttribute as String) != nil
      && numberAttribute(element, kAXMaxValueAttribute as String) != nil
  }

  static let editableRoles: Set<String> = [
    "AXTextField", "AXSearchField", "AXTextArea", "AXComboBox",
  ]
  static let documentRoles: Set<String> = ["AXWebArea", "AXDocument"]

  private static func pageScrollTarget(pid: pid_t, visibleIn windowFrame: CGRect) -> PageScrollTarget?
  {
    guard !windowFrame.isNull, windowFrame.width > 0, windowFrame.height > 0 else {
      return nil
    }
    let app = AXUIElementCreateApplication(pid)
    guard let window = elementAttribute(app, kAXFocusedWindowAttribute as String) else {
      return nil
    }

    let screenH = primaryScreenHeight()
    var best: PageScrollTarget?
    var bestArea: CGFloat = 0
    var queue = [window]
    var index = 0
    while index < queue.count, index < 600 {
      let element = queue[index]
      index += 1
      if role(of: element).map({ documentRoles.contains($0) }) == true,
        let frame = frame(of: element, primaryScreenHeight: screenH)
      {
        let clipped = frame.intersection(windowFrame)
        if !clipped.isNull, clipped.width > 40, clipped.height > 40 {
          let area = clipped.width * clipped.height
          if area > bestArea {
            bestArea = area
            best = PageScrollTarget(element: element, frame: clipped)
          }
        }
      }
      queue.append(contentsOf: children(of: element))
    }
    return best
  }
}
