import AppKit
import CoreGraphics
import FlashCore

/// The status bar's click surface: one window per screen spanning the menu-bar
/// band, routed by normal Cocoa hit-testing — no CGEvent tap. Two jobs:
///
///   1. Swallow every click that lands in the band so a click on the bar never
///      falls through to the wallpaper ("click to show desktop") or the app
///      beneath it. This is why the whole band is covered, not just the links.
///   2. Open a `#[link=…]` run when the click lands on one (a real click, not a
///      drag).
///
/// It sits at `OverlayPanel.statusBarClickWindowLevel` (the system menu-bar
/// level) because macOS only delivers menu-bar-band clicks to windows at that
/// level. To avoid stealing the native menu bar's own clicks, the window flips
/// to click-through (`ignoresMouseEvents = true`) whenever the auto-hidden menu
/// bar is revealed (`OverlayPanel.menuBarRevealTimer`), so native wins then;
/// when the menu bar is folded away, the band is Flash's and the window
/// swallows the click.
final class StatusBarClickView: NSView {
  /// Link sub-rects in this view's coordinate space, with their targets.
  var links: [(rect: CGRect, url: URL)] = [] {
    didSet { window?.invalidateCursorRects(for: self) }
  }

  /// Window-space location of the in-flight `mouseDown`, used to tell a click
  /// from a drag: a link opens only if the pointer comes back up within
  /// `dragSlop` of where it went down. A drag (window-drag, selection sweep,
  /// a slip toward a menu) opens nothing — but is still swallowed.
  private var mouseDownLocation: NSPoint?

  /// Movement past this (points) counts as a drag, not a click.
  static let dragSlop: CGFloat = 4

  /// Pure click-vs-drag test, exposed for unit testing.
  static func isClick(from down: NSPoint, to up: NSPoint) -> Bool {
    let dx = up.x - down.x
    let dy = up.y - down.y
    return (dx * dx + dy * dy) <= dragSlop * dragSlop
  }

  override func mouseDown(with event: NSEvent) {
    mouseDownLocation = event.locationInWindow
  }

  override func mouseUp(with event: NSEvent) {
    defer { mouseDownLocation = nil }
    guard let start = mouseDownLocation,
      Self.isClick(from: start, to: event.locationInWindow)
    else { return }
    let local = convert(event.locationInWindow, from: nil)
    if let url = links.first(where: { $0.rect.contains(local) })?.url {
      // `activates = true` brings the handling browser to the front and gives
      // it keyboard focus. The plain `open(url)` opens the tab in the
      // background (the click panel is non-activating, so the previously
      // focused app keeps focus) — typing then lands in the old app.
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = true
      NSWorkspace.shared.open(url, configuration: configuration, completionHandler: nil)
    }
    // Non-link clicks are intentionally not forwarded (no super call): the band
    // is Flash's while the menu bar is folded, so the click stops here instead
    // of leaking to the wallpaper or the window underneath.
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas { removeTrackingArea(area) }
    addTrackingArea(
      NSTrackingArea(
        rect: bounds,
        options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited],
        owner: self,
        userInfo: nil))
  }

  override func mouseMoved(with event: NSEvent) { updateCursor(at: event) }
  override func mouseEntered(with event: NSEvent) { updateCursor(at: event) }
  override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

  /// Pointing hand over a link run, the default arrow over the rest of the bar.
  private func updateCursor(at event: NSEvent) {
    let local = convert(event.locationInWindow, from: nil)
    if links.contains(where: { $0.rect.contains(local) }) {
      NSCursor.pointingHand.set()
    } else {
      NSCursor.arrow.set()
    }
  }
}

final class StatusBarClickPanel: NSPanel {
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
    level = OverlayPanel.statusBarClickWindowLevel
    ignoresMouseEvents = false
    acceptsMouseMovedEvents = true
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    contentView = StatusBarClickView(frame: .zero)
  }

  var clickView: StatusBarClickView { contentView as! StatusBarClickView }
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

  /// Per-screen status-bar band rects in screen coordinates, matching the bar
  /// layout `configureModeBadge` / `configureSecondaryStatusBars` render into.
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

  /// Pool, position, and show one full-band click window per screen, each
  /// carrying the link runs that fall inside its band (in window-local
  /// coordinates). Skips all work when nothing moved.
  func syncStatusBarClickWindows(
    bandRects: [CGRect],
    links: [(rect: CGRect, url: URL)]
  ) {
    let signature =
      (bandRects.map { "\($0.origin.x),\($0.origin.y),\($0.width),\($0.height)" }
      + links.map {
        "\($0.rect.origin.x),\($0.rect.origin.y),\($0.rect.width)|\($0.url.absoluteString)"
      })
      .joined(separator: ";")
    if signature == lastStatusBarClickSignature { return }
    lastStatusBarClickSignature = signature

    while statusBarClickWindows.count > bandRects.count {
      statusBarClickWindows.removeLast().orderOut(nil)
    }
    while statusBarClickWindows.count < bandRects.count {
      statusBarClickWindows.append(StatusBarClickPanel())
    }
    for (window, band) in zip(statusBarClickWindows, bandRects) {
      window.level = OverlayPanel.statusBarClickWindowLevel
      window.setFrame(band, display: false)
      let view = window.clickView
      view.frame = NSRect(origin: .zero, size: band.size)
      view.links = links.compactMap { link in
        guard band.intersects(link.rect) else { return nil }
        let local = CGRect(
          x: link.rect.minX - band.minX,
          y: link.rect.minY - band.minY,
          width: link.rect.width,
          height: link.rect.height)
        return (rect: local, url: link.url)
      }
      window.orderFrontRegardless()
    }
    startMenuBarRevealTracking()
  }

  /// Tear down every click window (bar hidden).
  func hideStatusBarClickWindows() {
    stopMenuBarRevealTracking()
    guard !statusBarClickWindows.isEmpty || lastStatusBarClickSignature != nil else { return }
    for window in statusBarClickWindows { window.orderOut(nil) }
    statusBarClickWindows.removeAll()
    lastStatusBarClickSignature = nil
  }

  // MARK: Reveal-aware yielding

  /// The click windows outrank the native menu bar (so the band delivers clicks
  /// to them at all), so they must step aside while the auto-hidden menu bar is
  /// actually revealed. Poll on a short cadence and flip `ignoresMouseEvents`:
  /// revealed → click-through (native wins); folded → catch.
  func startMenuBarRevealTracking() {
    guard menuBarRevealTimer == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(
      deadline: .now(), repeating: .milliseconds(80), leeway: .milliseconds(30))
    timer.setEventHandler { [weak self] in self?.updateClickWindowsForMenuBarReveal() }
    menuBarRevealTimer = timer
    timer.resume()
  }

  func stopMenuBarRevealTracking() {
    menuBarRevealTimer?.cancel()
    menuBarRevealTimer = nil
    // Leave the windows catching (the default) so a stale click-through state
    // can't survive a hide/show.
    for window in statusBarClickWindows where window.ignoresMouseEvents {
      window.ignoresMouseEvents = false
    }
  }

  private func updateClickWindowsForMenuBarReveal() {
    guard !statusBarClickWindows.isEmpty else { return }
    let revealed = Self.nativeMenuBarLikelyRevealed()
    for window in statusBarClickWindows where window.ignoresMouseEvents != revealed {
      window.ignoresMouseEvents = revealed
    }
  }

  /// Cheap gate + window scan. The auto-hidden menu bar only shows while the
  /// pointer is at the very top of the main display, so skip the scan entirely
  /// otherwise — the menu bar is folded and the band is Flash's.
  static func nativeMenuBarLikelyRevealed() -> Bool {
    guard
      let main = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
    else { return false }
    // `mouseLocation` is bottom-left global; the band is at the top (high y).
    let pointer = NSEvent.mouseLocation
    guard pointer.y >= main.frame.maxY - 40 else { return false }
    return nativeMenuBarIsRevealed(mainScreenWidth: main.frame.width)
  }

  /// True when the window server has an on-screen window at the main-menu level
  /// spanning the top of the main display — i.e. the menu bar is revealed.
  /// Matches by level + bounds only (no window-title read), so it needs no
  /// Screen Recording permission.
  static func nativeMenuBarIsRevealed(mainScreenWidth: CGFloat) -> Bool {
    guard
      let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        as? [[String: Any]]
    else { return false }
    let menuLayer = Int(CGWindowLevelForKey(.mainMenuWindow))
    for info in infos {
      guard
        let layer = info[kCGWindowLayer as String] as? Int, layer == menuLayer,
        let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
        let y = bounds["Y"], let width = bounds["Width"]
      else { continue }
      // CGWindow bounds use a top-left global origin: a revealed menu bar sits
      // flush at the top (y ~ 0) and spans most of the main display.
      if y <= 1, width >= mainScreenWidth * 0.6 { return true }
    }
    return false
  }
}
