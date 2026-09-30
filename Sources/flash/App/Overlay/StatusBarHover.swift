import AppKit

/// Whether the status bar answers the pointer with hover feedback: the segment
/// wash, hover popup previews (and their spawn dwell) and the pointing-hand
/// cursor. The band belongs to the native menu bar while the reveal probe sees
/// it revealed under the pointer, and on the menu-bar display's top point row,
/// whose touch is what reveals it; the probe confirms a reveal only once the
/// bar is on screen, on its next tick.
///
/// Click routing is not decided here: the probe alone flips the click windows
/// to click-through and lowers the bar (`nativeMenuBarRevealDidChange`).
struct StatusBarHoverState: Equatable {
  private(set) var nativeMenuBarRevealed = false
  private(set) var pointerOnRevealEdge = false

  var permitsHover: Bool { !nativeMenuBarRevealed && !pointerOnRevealEdge }

  enum Event: Equatable {
    /// The pointer of a hover event or of a stationary re-hit-test.
    case pointer(onRevealEdge: Bool)
    /// A reveal probe verdict; the probe stopping reads as folded.
    case nativeMenuBar(revealed: Bool)
  }

  enum Effect: Equatable {
    case none
    /// Hover just lost the band: clear the wash, the preview and its pending
    /// dwell, and the pointing hand.
    case suppress
    /// Hover just got the band back: re-hit-test the pointer where it rests.
    case resume
  }

  func applying(_ event: Event) -> (state: Self, effect: Effect) {
    var next = self
    switch event {
    case .pointer(let onEdge): next.pointerOnRevealEdge = onEdge
    case .nativeMenuBar(let revealed): next.nativeMenuBarRevealed = revealed
    }
    switch (permitsHover, next.permitsHover) {
    case (true, false): return (next, .suppress)
    case (false, true): return (next, .resume)
    default: return (next, .none)
    }
  }

  /// True on the top point row of the menu-bar display (`frame` in AppKit
  /// screen coordinates, so that row sits at `maxY`).
  static func pointerIsOnRevealEdge(_ pointer: CGPoint, menuBarScreenFrame frame: CGRect?) -> Bool {
    guard let frame else { return false }
    return pointer.y > frame.maxY - 1 && pointer.x >= frame.minX && pointer.x <= frame.maxX
  }
}

extension OverlayPanel {
  /// Feed one observation through `statusBarHover` and clear hover feedback
  /// the moment the band is lost. A `.resume` is returned for the caller: a
  /// pointer event hit-tests right after anyway, a probe verdict does not.
  @discardableResult
  func updateStatusBarHover(_ event: StatusBarHoverState.Event) -> StatusBarHoverState.Effect {
    let (next, effect) = statusBarHover.applying(event)
    statusBarHover = next
    if effect != .none {
      FlashLog.debug(
        "Status hover eligibility changed",
        fields: [
          "permits": String(next.permitsHover),
          "native_menu_revealed": String(next.nativeMenuBarRevealed),
          "reveal_edge": String(next.pointerOnRevealEdge),
        ],
        source: "core:StatusBarHover.transition")
    }
    if effect == .suppress { clearStatusBarHoverFeedback() }
    return effect
  }

  /// Whether hover may answer `pointer` (screen coordinates), after feeding it
  /// through `statusBarHover`. Every hover path asks before responding.
  func statusBarHoverPermits(
    at pointer: CGPoint,
    menuBarScreenFrame: CGRect? = OverlayPanel.currentScreenSnapshot().mainFrame
  ) -> Bool {
    updateStatusBarHover(
      .pointer(
        onRevealEdge: StatusBarHoverState.pointerIsOnRevealEdge(
          pointer, menuBarScreenFrame: menuBarScreenFrame)))
    return statusBarHover.permitsHover
  }

  private func clearStatusBarHoverFeedback() {
    statusBarHoverDwellWork?.cancel()
    statusBarHoverDwellWork = nil
    statusBarHoverDwellName = nil
    setStatusBarHoverHighlight(nil)
    // Only a preview follows the pointer; the reveal itself dismisses a
    // pinned popup (`statusBarNativeMenuDidReveal`).
    statusPopupController.leaveAnchor()
    activeStatusBarPopupName = statusPopupController.presentation.identity?.name
    NSCursor.arrow.set()
  }
}
