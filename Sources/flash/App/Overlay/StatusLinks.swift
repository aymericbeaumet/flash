import AppKit
import CoreGraphics
import FlashCore

struct StatusBarPopupRegion: Equatable {
  var rect: CGRect
  var name: String
  var content: String
}

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
  var popups: [StatusBarPopupRegion] = []

  /// Fired on `mouseEntered`. The overlay uses it to arm the menu-bar
  /// reveal probe only while the pointer is actually in the band, so the
  /// probe costs nothing in the steady state.
  var onPointerEntered: (() -> Void)?

  /// Dispatches a named `#[range=user|<name>]` click (the `[statusbar.click]`
  /// action map). Set by the overlay from the AppDelegate's handler.
  var onStatusBarAction: ((String) -> Void)?
  /// Reports the popup under the pointer (or nil) and the pointer in screen
  /// coordinates. The overlay moves its popup layer on every event.
  var onPopupHover: ((StatusBarPopupRegion?, NSPoint) -> Void)?

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
      if let action = FlashStatusBarRenderer.rangeActionName(from: url) {
        onStatusBarAction?(action)
        return
      }
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

  override func mouseMoved(with event: NSEvent) { updatePointer(at: event) }
  override func mouseEntered(with event: NSEvent) {
    onPointerEntered?()
    updatePointer(at: event)
  }
  override func mouseExited(with event: NSEvent) {
    NSCursor.arrow.set()
    let point = window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
    onPopupHover?(nil, point)
  }

  /// Pointing hand over a link run, the default arrow over the rest of the bar.
  private func updatePointer(at event: NSEvent) {
    let local = convert(event.locationInWindow, from: nil)
    if links.contains(where: { $0.rect.contains(local) }) {
      NSCursor.pointingHand.set()
    } else {
      NSCursor.arrow.set()
    }
    let popup = popups.first(where: { $0.rect.contains(local) })
    let point = window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
    onPopupHover?(popup, point)
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

  /// Screen-space hit regions for `#[popup=<name>]` spans. Content is already
  /// resolved by the status controller; measurement uses the exact fitted
  /// string rendered by the label, keeping hover geometry pixel-aligned.
  func statusPopupRects(
    raw: String,
    popupTexts: [String: String],
    font: NSFont,
    labelFrame: CGRect,
    alignment: CATextLayerAlignmentMode,
    barFrame: CGRect,
    panelFrame: CGRect
  ) -> [StatusBarPopupRegion] {
    let (runs, totalWidth) = FlashStatusBarRenderer.popupRuns(
      from: raw, font: font, popupTexts: popupTexts)
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
    return runs.map { run in
      StatusBarPopupRegion(
        rect: CGRect(
          x: panelFrame.minX + barFrame.minX + labelFrame.minX + pad + run.xOffset,
          y: panelFrame.minY + barFrame.minY,
          width: run.width,
          height: barFrame.height),
        name: run.name,
        content: run.content)
    }
  }

  /// Popup placement oracle: horizontally centered under the pointer, then
  /// clamped to the hovered display's visible frame (including negative-origin
  /// secondary displays). Oversized content is clipped to that frame.
  static func statusBarPopupFrame(
    pointer: CGPoint,
    popupSize: CGSize,
    visibleFrame: CGRect,
    offset: CGFloat
  ) -> CGRect {
    let width = min(max(1, popupSize.width), visibleFrame.width)
    let height = min(max(1, popupSize.height), visibleFrame.height)
    let x = min(
      max(pointer.x - width / 2, visibleFrame.minX),
      visibleFrame.maxX - width)
    let top = min(pointer.y - max(0, offset), visibleFrame.maxY)
    let y = max(visibleFrame.minY, top - height)
    return CGRect(x: x, y: y, width: width, height: height)
  }

  /// Natural popup geometry. Keep the measured text rect intact instead of
  /// rounding it independently: independent rounding leaves the spare fraction
  /// on the trailing edge, making nominally uniform padding visibly uneven.
  static func statusBarPopupLayout(
    textSize: CGSize,
    padding: CGFloat,
    borderWidth: CGFloat
  ) -> (popupSize: CGSize, labelFrame: CGRect) {
    let border = max(0, borderWidth)
    let inset = max(0, padding) + border
    let labelSize = CGSize(width: max(1, textSize.width), height: max(1, textSize.height))
    return (
      popupSize: CGSize(
        width: labelSize.width + inset * 2,
        height: labelSize.height + inset * 2),
      labelFrame: CGRect(origin: CGPoint(x: inset, y: inset), size: labelSize)
    )
  }

  func showStatusBarPopup(_ popup: StatusBarPopupRegion, at pointer: CGPoint) {
    let nameChanged = activeStatusBarPopupName != popup.name
    let snapshot = Self.currentScreenSnapshot()
    guard
      let screen = snapshot.screens.first(where: { $0.frame.contains(pointer) })
        ?? snapshot.screens.first(where: { $0.frame.intersects(popup.rect) })
    else {
      hideStatusBarPopup()
      return
    }

    let style = statusBarPopupStyle
    let font = NSFont.monospacedSystemFont(
      ofSize: Self.statusBarFontSize(overlayFontSize: CGFloat(overlayConfig.fontSize)),
      weight: .medium)
    let padding = CGFloat(style.padding)
    let border = CGFloat(style.borderWidth)
    let needsLayout =
      statusPopupLayer.isHidden
      || activeStatusBarPopupName != popup.name
      || activeStatusBarPopupContent != popup.content
      || activeStatusBarPopupVisibleFrame != screen.visibleFrame
    let popupSize: CGSize
    if needsLayout {
      let inset = padding + border
      let maxTextWidth = max(
        1,
        min(
          CGFloat(style.maxWidth) - inset * 2,
          screen.visibleFrame.width - inset * 2))
      let maxTextHeight = max(1, screen.visibleFrame.height - inset * 2)
      let attributed = FlashStatusBarRenderer.attributedStatusString(
        from: popup.content,
        font: font,
        defaultForeground: FlashStatusTextColor.parse(style.foreground))
      let measured = attributed.boundingRect(
        with: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading])
      let textSize = CGSize(
        width: min(maxTextWidth, measured.width),
        height: min(maxTextHeight, measured.height))
      let layout = Self.statusBarPopupLayout(
        textSize: textSize,
        padding: padding,
        borderWidth: border)
      popupSize = layout.popupSize
      statusPopupLayer.backgroundColor = nsColor(fromHex: style.background)?.cgColor
      statusPopupLayer.borderColor = nsColor(fromHex: style.borderColor)?.cgColor
      statusPopupLayer.borderWidth = border
      statusPopupLayer.cornerRadius = CGFloat(style.cornerRadius)
      statusPopupLayer.contentsScale = screen.scale
      statusPopupLabel.font = font
      statusPopupLabel.fontSize = font.pointSize
      statusPopupLabel.contentsScale = screen.scale
      statusPopupLabel.string = attributed
      statusPopupLabel.frame = layout.labelFrame
      statusPopupLabel.isHidden = false
      activeStatusBarPopupContent = popup.content
      activeStatusBarPopupVisibleFrame = screen.visibleFrame
    } else {
      popupSize = statusPopupLayer.frame.size
    }
    let screenFrame = Self.statusBarPopupFrame(
      pointer: pointer,
      popupSize: popupSize,
      visibleFrame: screen.visibleFrame,
      offset: CGFloat(style.offset))
    let localFrame = screenFrame.offsetBy(dx: -frame.minX, dy: -frame.minY)

    statusPopupLayer.frame = localFrame
    statusPopupLayer.zPosition = 10_000
    statusPopupLayer.isHidden = false
    activeStatusBarPopupName = popup.name
    if nameChanged { FlashLog.trace("[statusbar] popup show name=\(popup.name)") }
    if statusPopupLayer.superlayer !== contentLayer {
      contentLayer.addSublayer(statusPopupLayer)
    }
  }

  func hideStatusBarPopup() {
    if let name = activeStatusBarPopupName {
      FlashLog.trace("[statusbar] popup hide name=\(name)")
    }
    activeStatusBarPopupName = nil
    statusPopupLayer.isHidden = true
  }

  /// Per-screen status-bar band rects in screen coordinates, matching the bar
  /// layout `configureModeBadge` / `configureSecondaryStatusBars` render into.
  /// Honors `[statusbar] monitor`: with `primary`, only the main display gets
  /// a click window — covering every screen used to swallow band clicks on
  /// displays where no bar was drawn at all.
  func statusBarScreenRects(panelFrame: CGRect, fontSize: CGFloat) -> [CGRect] {
    let snapshot = OverlayPanel.currentScreenSnapshot()
    let screens =
      statusBarMonitor == .primary
      ? snapshot.screens.filter { $0.frame == snapshot.mainFrame }
      : snapshot.screens
    return screens.map { screen in
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
    links: [(rect: CGRect, url: URL)],
    popups: [StatusBarPopupRegion] = []
  ) {
    let signature =
      (bandRects.map { "\($0.origin.x),\($0.origin.y),\($0.width),\($0.height)" }
      + links.map {
        "\($0.rect.origin.x),\($0.rect.origin.y),\($0.rect.width)|\($0.url.absoluteString)"
      }
      + popups.map {
        "\($0.rect.origin.x),\($0.rect.origin.y),\($0.rect.width)|\($0.name)|\($0.content)"
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
      view.popups = popups.compactMap { popup in
        guard band.intersects(popup.rect) else { return nil }
        return StatusBarPopupRegion(
          rect: popup.rect.offsetBy(dx: -band.minX, dy: -band.minY),
          name: popup.name,
          content: popup.content)
      }
      view.onPointerEntered = { [weak self] in self?.startMenuBarRevealTracking() }
      view.onStatusBarAction = statusBarActionHandler
      view.onPopupHover = { [weak self] popup, point in
        guard let self else { return }
        if let popup {
          self.showStatusBarPopup(popup, at: point)
        } else {
          self.hideStatusBarPopup()
        }
      }
      window.orderFrontRegardless()
    }
    // A content/config refresh does not generate mouseMoved for a stationary
    // pointer. Re-hit-test now so an open popup updates immediately.
    let pointer = NSEvent.mouseLocation
    if !statusBarClickWindows.contains(where: \.ignoresMouseEvents),
      let popup = popups.first(where: { $0.rect.contains(pointer) })
    {
      showStatusBarPopup(popup, at: pointer)
    } else {
      hideStatusBarPopup()
    }
    // The probe normally arms on hover, but if the pointer is already parked
    // in the band when the windows (re)appear no `mouseEntered` will fire —
    // catch that case here.
    if Self.pointerIsInMenuBarBand() { startMenuBarRevealTracking() }
  }

  /// Tear down every click window (bar hidden).
  func hideStatusBarClickWindows() {
    stopMenuBarRevealTracking()
    hideStatusBarPopup()
    guard !statusBarClickWindows.isEmpty || lastStatusBarClickSignature != nil else { return }
    for window in statusBarClickWindows { window.orderOut(nil) }
    statusBarClickWindows.removeAll()
    lastStatusBarClickSignature = nil
  }

  // MARK: Reveal-aware yielding

  /// Serial utility queue the reveal probe polls on. Everything the probe
  /// touches is a thread-safe C call (`CGEvent(source:)`, `CGDisplayBounds`,
  /// `CGWindowListCopyWindowInfo`), so none of its work belongs on the main
  /// run loop — which owns the keyboard event tap and must never share it
  /// with a 12.5 Hz window-server scan.
  private static let menuBarRevealProbeQueue = DispatchQueue(
    label: "flash.status_bar.reveal", qos: .utility)

  /// The click windows outrank the native menu bar (so the band delivers clicks
  /// to them at all), so they must step aside while the auto-hidden menu bar is
  /// actually revealed. Poll on a short cadence and flip `ignoresMouseEvents`:
  /// revealed → click-through (native wins); folded → catch. The probe runs
  /// only while the pointer is near the band (armed by `mouseEntered`,
  /// self-stopping otherwise), and hops to main only when the state flips.
  /// Call on the main thread.
  func startMenuBarRevealTracking() {
    guard menuBarRevealTimer == nil else { return }
    menuBarRevealedShadow = false
    let timer = DispatchSource.makeTimerSource(queue: Self.menuBarRevealProbeQueue)
    timer.schedule(
      deadline: .now(), repeating: .milliseconds(80), leeway: .milliseconds(30))
    timer.setEventHandler { [weak self] in self?.probeMenuBarReveal() }
    menuBarRevealTimer = timer
    timer.resume()
  }

  func stopMenuBarRevealTracking() {
    menuBarRevealTimer?.cancel()
    menuBarRevealTimer = nil
    menuBarRevealedShadow = false
    // Leave the windows catching (the default) so a stale click-through state
    // can't survive a hide/show.
    for window in statusBarClickWindows where window.ignoresMouseEvents {
      window.ignoresMouseEvents = false
    }
  }

  /// One probe tick, on the probe queue.
  private func probeMenuBarReveal() {
    let pointerNearBand = Self.pointerIsInMenuBarBand()
    let revealed =
      pointerNearBand
      && Self.nativeMenuBarIsRevealed(
        mainScreenWidth: CGDisplayBounds(CGMainDisplayID()).width)
    let changed = revealed != menuBarRevealedShadow
    menuBarRevealedShadow = revealed
    if changed {
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        for window in self.statusBarClickWindows where window.ignoresMouseEvents != revealed {
          window.ignoresMouseEvents = revealed
        }
        if revealed { self.hideStatusBarPopup() }
      }
    }
    if !pointerNearBand && !revealed {
      // Pointer left the band with the menu bar folded: nothing to watch.
      // `mouseEntered` re-arms on the next hover.
      DispatchQueue.main.async { [weak self] in self?.stopMenuBarRevealTracking() }
    }
  }

  /// True while the pointer sits in the top band of the main display — the
  /// only place the auto-hidden menu bar can reveal. Thread-safe (CG calls
  /// only; `CGEvent` locations use a top-left global origin, so the band is
  /// small y).
  static func pointerIsInMenuBarBand() -> Bool {
    guard let pointer = CGEvent(source: nil)?.location else { return false }
    let main = CGDisplayBounds(CGMainDisplayID())
    return pointer.y <= main.minY + 40
      && pointer.x >= main.minX && pointer.x <= main.maxX
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
