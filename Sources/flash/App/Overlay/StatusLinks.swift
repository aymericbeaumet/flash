import AppKit
import FlashCore

/// Transparent overlay that turns a `#[link=…]` run in the status bar into a
/// clickable target. The status-bar panel is click-through
/// (`ignoresMouseEvents = true`) so it never steals clicks from the menu bar
/// underneath; these catchers re-add interactivity only over the exact link
/// rects.
final class StatusLinkCatcherView: NSView {
  var onClick: (() -> Void)?

  override func mouseDown(with event: NSEvent) {
    onClick?()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas { removeTrackingArea(area) }
    addTrackingArea(
      NSTrackingArea(
        rect: bounds,
        options: [.activeAlways, .cursorUpdate, .mouseEnteredAndExited],
        owner: self,
        userInfo: nil))
  }

  override func cursorUpdate(with event: NSEvent) { cursor.set() }
  override func mouseEntered(with event: NSEvent) { cursor.set() }
  override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

  /// Pointing hand for real links; the default arrow for the swallow-only
  /// shield (which has no `onClick`).
  private var cursor: NSCursor { onClick == nil ? .arrow : .pointingHand }
}

final class StatusLinkCatcherPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  init() {
    super.init(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: true)
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    // One step above the bar so the click lands here, not on the bar (or
    // the native menu bar) beneath it.
    level = NSWindow.Level(rawValue: OverlayPanel.persistentStatusWindowLevel.rawValue + 1)
    ignoresMouseEvents = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    contentView = StatusLinkCatcherView(frame: .zero)
  }

  var clickView: StatusLinkCatcherView { contentView as! StatusLinkCatcherView }
}

extension OverlayPanel {
  /// Screen-space rects + targets for the `#[link=…]` runs in one rendered
  /// region. `labelFrame` is the text layer's frame relative to the bar
  /// layer; `barFrame` is the bar layer's frame relative to the panel;
  /// `panelFrame` is the panel's frame in screen coordinates.
  func statusLinkRects(
    raw: String,
    font: NSFont,
    labelFrame: CGRect,
    alignment: CATextLayerAlignmentMode,
    barFrame: CGRect,
    panelFrame: CGRect
  ) -> [(rect: CGRect, url: URL)] {
    let (runs, totalWidth) = FlashStatusBarRenderer.linkRuns(from: raw, font: font)
    guard !runs.isEmpty else { return [] }
    let pad: CGFloat
    switch alignment {
    case .right:
      pad = max(0, labelFrame.width - totalWidth)
    case .center, .justified:
      pad = max(0, (labelFrame.width - totalWidth) / 2)
    default:
      pad = 0
    }
    var result: [(rect: CGRect, url: URL)] = []
    for run in runs {
      guard let url = URL(string: run.url) else { continue }
      let screenX =
        panelFrame.minX + barFrame.minX + labelFrame.minX + pad + run.xOffset
      // Span the bar's full height so the whole vertical band over the run
      // is clickable, not just the text's exact box.
      let screenY = panelFrame.minY + barFrame.minY
      result.append(
        (
          rect: CGRect(x: screenX, y: screenY, width: run.width, height: barFrame.height),
          url: url
        ))
    }
    return result
  }

  /// Pool, position, and show one catcher window per link rect. Skips all
  /// work when the rect/target set is unchanged so a re-render that doesn't
  /// move a link doesn't churn the windows.
  func syncStatusLinkCatchers(_ links: [(rect: CGRect, url: URL)]) {
    let signature = links
      .map { "\($0.rect.origin.x),\($0.rect.origin.y),\($0.rect.width)|\($0.url.absoluteString)" }
      .joined(separator: ";")
    if signature == lastStatusLinkSignature { return }
    lastStatusLinkSignature = signature

    while statusLinkCatchers.count > links.count {
      statusLinkCatchers.removeLast().orderOut(nil)
    }
    while statusLinkCatchers.count < links.count {
      statusLinkCatchers.append(StatusLinkCatcherPanel())
    }
    for (catcher, link) in zip(statusLinkCatchers, links) {
      // One step above the shields so a click on a link opens it rather
      // than being swallowed by the bar-wide shield beneath. Still below the
      // native status bar; links only sit over Flash's own content (left /
      // centre), never over the system menu-bar extras on the right.
      catcher.level = NSWindow.Level(rawValue: OverlayPanel.persistentStatusWindowLevel.rawValue + 1)
      catcher.setFrame(link.rect, display: false)
      catcher.clickView.frame = NSRect(origin: .zero, size: link.rect.size)
      let url = link.url
      catcher.clickView.onClick = { NSWorkspace.shared.open(url) }
      catcher.orderFrontRegardless()
    }
  }

  /// Status-bar rects (one per screen), in screen coordinates, matching the
  /// bar layout `configureModeBadge` / `configureSecondaryStatusBars` use.
  func statusBarScreenRects(panelFrame: CGRect, fontSize: CGFloat) -> [CGRect] {
    OverlayPanel.currentScreenSnapshot().screens.map { screen in
      let barFrame = OverlayPanel.statusBarFrame(
        screenFrame: screen.frame,
        visibleFrame: screen.visibleFrame,
        panelFrame: panelFrame,
        fontSize: fontSize)
      return CGRect(
        x: panelFrame.minX + barFrame.minX,
        y: panelFrame.minY + barFrame.minY,
        width: barFrame.width,
        height: barFrame.height)
    }
  }

  /// Place one transparent shield per status-bar rect to swallow stray
  /// clicks. Skips work when the rects are unchanged.
  func syncStatusBarShields(_ rects: [CGRect]) {
    let signature = rects
      .map { "\($0.origin.x),\($0.origin.y),\($0.width),\($0.height)" }
      .joined(separator: ";")
    if signature == lastStatusShieldSignature { return }
    lastStatusShieldSignature = signature

    while statusBarClickShields.count > rects.count {
      statusBarClickShields.removeLast().orderOut(nil)
    }
    while statusBarClickShields.count < rects.count {
      statusBarClickShields.append(StatusLinkCatcherPanel())
    }
    for (shield, rect) in zip(statusBarClickShields, rects) {
      // Sit at the bar's own level — below the native status bar (`.statusBar`,
      // where the system menu-bar extras live), so those still receive their
      // clicks. The shield only catches clicks that would otherwise fall
      // through Flash's content to the wallpaper (onClick == nil → swallowed).
      shield.level = OverlayPanel.persistentStatusWindowLevel
      shield.setFrame(rect, display: false)
      shield.clickView.frame = NSRect(origin: .zero, size: rect.size)
      shield.clickView.onClick = nil
      shield.orderFrontRegardless()
    }
  }

  func hideStatusBarShields() {
    guard !statusBarClickShields.isEmpty || lastStatusShieldSignature != nil else { return }
    for shield in statusBarClickShields { shield.orderOut(nil) }
    statusBarClickShields.removeAll()
    lastStatusShieldSignature = nil
  }

  /// Tear down every catcher window (bar hidden / no links).
  func hideStatusLinkCatchers() {
    guard !statusLinkCatchers.isEmpty || lastStatusLinkSignature != nil else { return }
    for catcher in statusLinkCatchers { catcher.orderOut(nil) }
    statusLinkCatchers.removeAll()
    lastStatusLinkSignature = nil
  }
}
