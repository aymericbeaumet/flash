import AppKit
import QuartzCore

/// A desktop widget's own window, the only place widgets draw: borderless,
/// transparent and click-through, one level above the desktop picture — so
/// below Finder's desktop icons and every app window — and on every Space
/// without moving in Mission Control. It never becomes key or main, takes no
/// mouse input and has no chrome; it is not a full-screen auxiliary, so a
/// full-screen app covers it.
final class WidgetWindow: NSPanel {
  static let desktopLevel = NSWindow.Level(
    rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)

  let contentLayer = CALayer()

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  init(frame: NSRect, sharingType: NSWindow.SharingType) {
    super.init(
      contentRect: frame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    level = Self.desktopLevel
    collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    ignoresMouseEvents = true
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    animationBehavior = .none
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    isExcludedFromWindowsMenu = true
    self.sharingType = sharingType
    let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
    view.wantsLayer = true
    view.layer = contentLayer
    contentLayer.frame = view.bounds
    contentLayer.actions = OverlayPanel.noActions
    contentView = view
  }
}
