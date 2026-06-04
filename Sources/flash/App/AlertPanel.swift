import AppKit
import QuartzCore

/// Hammerspoon-style transient centered alert for `flash://show_alert`.
///
/// Mirrors `hs.alert.defaultStyle`: black 75% fill, white stroke/text,
/// 27pt system font, radius 27, 2s display, 0.15s fade out. Only one
/// alert is visible at a time; a new alert immediately replaces the old one.
final class AlertPanel: NSPanel {
  private let boxView = NSView(frame: .zero)
  private let label = NSTextField(labelWithString: "")
  private var hideTimer: Timer?
  private var token: UInt64 = 0

  private static let textSize: CGFloat = 27
  private static let radius: CGFloat = 27
  private static let strokeWidth: CGFloat = 2
  private static let fillColor = NSColor.black.withAlphaComponent(0.75)
  private static let strokeColor = NSColor.white
  private static let textColor = NSColor.white
  private static let displayDuration: TimeInterval = 2.0
  private static let fadeOutDuration: TimeInterval = 0.15
  private static let textGutter: CGFloat = 10

  init() {
    super.init(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    level = .screenSaver
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    ignoresMouseEvents = true
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    alphaValue = 0

    let content = NSView(frame: .zero)
    content.wantsLayer = true
    content.layer?.backgroundColor = NSColor.clear.cgColor
    content.addSubview(boxView)
    contentView = content

    boxView.wantsLayer = true
    boxView.layer?.backgroundColor = Self.fillColor.cgColor
    boxView.layer?.borderColor = Self.strokeColor.cgColor
    boxView.layer?.borderWidth = Self.strokeWidth
    boxView.layer?.cornerRadius = Self.radius
    boxView.layer?.masksToBounds = true
    boxView.layer?.actions = Self.noActions
    boxView.addSubview(label)

    label.font = NSFont.systemFont(ofSize: Self.textSize)
    label.textColor = Self.textColor
    label.alignment = .center
    label.backgroundColor = .clear
    label.lineBreakMode = .byWordWrapping
    label.usesSingleLineMode = false
    label.isSelectable = false
    label.isEditable = false
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  func show(_ message: String, duration: TimeInterval = 2.0) {
    token &+= 1
    let myToken = token
    hideTimer?.invalidate()
    hideTimer = nil

    let screen = Self.alertScreen()
    let padding = Self.textSize / 2
    let maxTextWidth = max(120, screen.frame.width * 0.8 - padding * 2 - Self.strokeWidth)
    let textSize = Self.textSize(for: message, maxWidth: maxTextWidth)
    let boxSize = CGSize(
      width: ceil(textSize.width + padding * 2 + Self.strokeWidth + Self.textGutter),
      height: ceil(textSize.height + padding * 2 + Self.strokeWidth)
    )
    let boxFrame = CGRect(origin: .zero, size: boxSize)
    let panelFrame = CGRect(
      x: screen.frame.midX - boxSize.width / 2,
      y: screen.frame.midY - boxSize.height / 2,
      width: boxSize.width,
      height: boxSize.height
    )

    setFrame(panelFrame, display: false)
    contentView?.frame = boxFrame
    boxView.frame = boxFrame
    label.stringValue = message
    label.frame = CGRect(
      x: padding + Self.strokeWidth / 2,
      y: (boxSize.height - textSize.height) / 2,
      width: textSize.width + Self.textGutter,
      height: textSize.height
    )

    // Replacements must be instant: no fade-in, no order-out/order-in cycle.
    alphaValue = 1
    if !isVisible {
      orderFrontRegardless()
    }

    hideTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) {
      [weak self] _ in
      guard let self, self.token == myToken else { return }
      self.hide(animated: true)
    }
  }

  func dismiss() {
    token &+= 1
    hide(animated: false)
  }

  private func hide(animated: Bool) {
    hideTimer?.invalidate()
    hideTimer = nil
    guard isVisible else {
      alphaValue = 0
      return
    }
    if !animated {
      orderOut(nil)
      alphaValue = 0
      return
    }

    let myToken = token
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Self.fadeOutDuration
      animator().alphaValue = 0
    } completionHandler: { [weak self] in
      guard let self, self.token == myToken else { return }
      self.orderOut(nil)
    }
  }

  private static func textSize(for message: String, maxWidth: CGFloat) -> CGSize {
    let text = message as NSString
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: Self.textSize)
    ]
    let size = text.boundingRect(
      with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: attrs)
    return CGSize(width: ceil(size.width), height: ceil(size.height))
  }

  private static func alertScreen() -> NSScreen {
    if let main = NSScreen.main { return main }
    if let screen = NSScreen.screens.first { return screen }
    fatalError("Flash alert requested with no NSScreen available")
  }

  private static let noActions: [String: CAAction] = [
    "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "hidden": NSNull(),
    "backgroundColor": NSNull(), "cornerRadius": NSNull(), "borderWidth": NSNull(),
    "borderColor": NSNull(),
  ]
}
