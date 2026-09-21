import AppKit
import QuartzCore

/// The persistent status bar's own window. It shares the `OverlayPanel`'s
/// union-of-screens frame, so bar layout stays in overlay coordinates, is
/// transparent and click-through, and is ordered above the native menu bar and
/// its extras, so a reveal of the auto-hidden menu bar (the pointer grazing the
/// top edge while hovering the bar, a menu key equivalent flashing its title,
/// Flash itself becoming active, a wake) slides those windows down *behind* the
/// bar instead of painting over it.
final class StatusBarWindow: NSPanel {
  let contentLayer = CALayer()

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  init(frame: NSRect) {
    super.init(
      contentRect: frame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    level = OverlayPanel.statusBarWindowLevel
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    animationBehavior = .none
    ignoresMouseEvents = true
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
    view.wantsLayer = true
    view.layer = contentLayer
    contentLayer.frame = view.bounds
    contentLayer.actions = OverlayPanel.noActions
    contentView = view
  }
}

extension OverlayPanel {
  /// Host the bar layers in the status-bar window and order it with the bar's
  /// visibility. The layers are parented nowhere else, so transient overlay
  /// renders that rebuild `contentLayer.sublayers` can never detach the bar.
  func syncStatusBarWindow() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    guard modeBadgeVisible else {
      statusBarWindow.contentLayer.sublayers = nil
      statusBarWindow.orderOut(nil)
      return
    }
    let layers: [CALayer] = [modeBadgeLayer] + secondaryStatusBars.map(\.backgroundLayer)
    let hosted = statusBarWindow.contentLayer.sublayers ?? []
    if hosted.count != layers.count || !zip(hosted, layers).allSatisfy({ $0 === $1 }) {
      statusBarWindow.contentLayer.sublayers = layers
    }
    statusBarWindow.orderFrontRegardless()
  }
}
