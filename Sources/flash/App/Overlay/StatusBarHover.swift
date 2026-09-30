import AppKit

/// Whether the status bar answers the pointer with hover feedback: the segment
/// wash, hover popup previews (and their spawn dwell) and the pointing-hand
/// cursor. Hover works anywhere in the band, its top point row included: a
/// pointer thrown at the bar comes to rest there. The band belongs to the
/// native menu bar only while the reveal probe sees it revealed under the
/// pointer.
///
/// Click routing is not decided here: the probe alone flips the click windows
/// to click-through and lowers the bar (`nativeMenuBarRevealDidChange`).
struct StatusBarHoverState: Equatable {
  private(set) var nativeMenuBarRevealed = false

  var permitsHover: Bool { !nativeMenuBarRevealed }

  enum Effect: Equatable {
    case none
    /// Hover just lost the band: clear the wash, the preview and its pending
    /// dwell, and the pointing hand.
    case suppress
    /// Hover just got the band back: re-hit-test the pointer where it rests.
    case resume
  }

  /// Apply a reveal probe verdict; the probe stopping reads as folded.
  func applying(nativeMenuBarRevealed revealed: Bool) -> (state: Self, effect: Effect) {
    var next = self
    next.nativeMenuBarRevealed = revealed
    switch (permitsHover, next.permitsHover) {
    case (true, false): return (next, .suppress)
    case (false, true): return (next, .resume)
    default: return (next, .none)
    }
  }
}

extension OverlayPanel {
  /// Feed one reveal probe verdict through `statusBarHover` and clear hover
  /// feedback the moment the band is lost. A `.resume` is returned for the
  /// caller, which re-hit-tests a parked pointer.
  @discardableResult
  func updateStatusBarHover(nativeMenuBarRevealed revealed: Bool) -> StatusBarHoverState.Effect {
    let (next, effect) = statusBarHover.applying(nativeMenuBarRevealed: revealed)
    statusBarHover = next
    if effect != .none {
      FlashLog.debug(
        "Status hover eligibility changed",
        fields: [
          "permits": String(next.permitsHover),
          "native_menu_revealed": String(next.nativeMenuBarRevealed),
        ],
        source: "core:StatusBarHover.transition")
    }
    if effect == .suppress { clearStatusBarHoverFeedback() }
    return effect
  }

  private func clearStatusBarHoverFeedback() {
    statusBarHoverDwellWork?.cancel()
    statusBarHoverDwellWork = nil
    statusBarHoverDwellName = nil
    setStatusBarHoverHighlight(nil)
    // Only a preview is tied to the pointer; the reveal itself dismisses a
    // pinned popup (`statusBarNativeMenuDidReveal`).
    statusPopupController.leaveAnchor()
    activeStatusBarPopupName = statusPopupController.presentation.name
    NSCursor.arrow.set()
  }
}
