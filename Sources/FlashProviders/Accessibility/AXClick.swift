import AppKit
import ApplicationServices
import FlashCore

/// AX-level click utilities shared between providers and the dispatcher.
///
/// Why prefer AX clicks over `CGEvent` mouse synthesis:
///   - The cursor stays put — no warp + hide-cursor dance.
///   - Bypasses screen hit-test ambiguity (transparent overlays, custom
///     hit regions, fractional-scale rounding).
///   - In web browsers, sometimes the only path that delivers a click the
///     page's JS handler actually sees. The browser may decline
///     `el.click()` for security reasons (navigation outside a user
///     gesture) yet accept `AXPress` because the OS routes that through
///     the same accessibility focus path VoiceOver uses.
///
/// All entry points are AX-bound and require Accessibility permission.
public enum AXClick {
  /// Press-style action names tried in order for a left-click.
  /// `AXOpen` covers Finder items; `AXConfirm` covers default-button
  /// confirmations that don't expose `AXPress`.
  private static let pressActions: [String] = [
    kAXPressAction, "AXOpen", "AXConfirm",
  ]

  /// Try the press-style action(s) for `action` on `element`. Returns
  /// true if any of them succeeds. Does *not* touch focus — that's a
  /// provider-side decision because setting focus on a non-text element
  /// is a surprising substitute for "click".
  public static func tryActions(_ element: AXUIElement, action: JumpAction) -> Bool {
    switch action {
    case .leftClick:
      for name in pressActions {
        if AXUIElementPerformAction(element, name as CFString) == .success {
          return true
        }
      }
    case .rightClick:
      if AXUIElementPerformAction(element, kAXShowMenuAction as CFString) == .success {
        return true
      }
    case .doubleClick:
      return false
    }
    return false
  }

  /// Move keyboard focus to `element`. The unambiguous AX-level "click"
  /// for text fields, where AXPress is a no-op.
  public static func setFocus(_ element: AXUIElement) -> Bool {
    AXUIElementSetAttributeValue(
      element,
      kAXFocusedAttribute as CFString,
      kCFBooleanTrue
    ) == .success
  }

  /// True if `element` advertises any of the press-style actions
  /// (`AXPress`/`AXOpen`/`AXConfirm`). Used by AccessibilityProvider to
  /// confirm tentative `<div onclick>`-style targets discovered inside
  /// `AXWebArea` subtrees and to filter standalone images that have no
  /// real click handler.
  public static func hasPressAction(_ element: AXUIElement) -> Bool {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success,
      let arr = names as? [String]
    else { return false }
    for name in pressActions where arr.contains(name) {
      return true
    }
    return false
  }

  /// Click at `nsScreenPoint` (NSScreen coords, Y-up from primary
  /// bottom-left) via the AX hit-test of process `pid`.
  ///
  /// Strategy:
  ///   1. `AXUIElementCopyElementAtPosition` to resolve the AX element
  ///      under the point.
  ///   2. Try press actions on that hit.
  ///   3. Walk up via `kAXParentAttribute` up to `maxAncestors` levels,
  ///      retrying actions at each step. Real-world hit targets are
  ///      often inner text/span nodes that have no press action; their
  ///      handler lives one or two levels up.
  ///
  /// Returns false when no element along the chain accepts a press —
  /// the caller is expected to fall back to a synthesized mouse click.
  public static func clickAtPoint(
    pid: pid_t,
    nsScreenPoint: CGPoint,
    action: JumpAction,
    maxAncestors: Int = 6
  ) -> Bool {
    let screenH = primaryScreenHeight()
    // AX hit-test takes top-left primary-origin Y-down coords.
    let axX = Float(nsScreenPoint.x)
    let axY = Float(screenH - nsScreenPoint.y)
    let app = AXUIElementCreateApplication(pid)
    var hit: AXUIElement?
    guard AXUIElementCopyElementAtPosition(app, axX, axY, &hit) == .success,
      let initial = hit
    else { return false }

    var current = initial
    var depth = 0
    while true {
      if tryActions(current, action: action) { return true }
      if depth >= maxAncestors { return false }
      var parentRaw: CFTypeRef?
      guard
        AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentRaw)
          == .success,
        let parentCF = parentRaw,
        CFGetTypeID(parentCF) == AXUIElementGetTypeID()
      else { return false }
      current = parentCF as! AXUIElement
      depth += 1
    }
  }

  private static func primaryScreenHeight() -> CGFloat {
    if let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) {
      return primary.frame.height
    }
    return NSScreen.main?.frame.height ?? 1080
  }
}
