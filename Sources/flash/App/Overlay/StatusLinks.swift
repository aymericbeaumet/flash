import AppKit
import CoreGraphics
import FlashCore

enum StatusBarHoverGate: Equatable {
  case ready
  case dismissed(String)

  func hovering(_ name: String?) -> Self {
    guard case .dismissed(let blocked) = self, name == blocked else { return .ready }
    return self
  }

  func permits(_ name: String) -> Bool { self != .dismissed(name) }
}

struct StatusBarPopupRegion: Equatable {
  var rect: CGRect
  var name: String
  var content: String
  var document: [FlashStatusTextSegment]? = nil
}

enum StatusBarHintAction: Equatable {
  case click(URL)
  case hover(StatusBarPopupRegion)
}

struct StatusBarHintRegion: Equatable {
  var rect: CGRect
  var action: StatusBarHintAction
}

struct StatusBarScreenInteractions {
  var screenFrame: CGRect
  var links: [(rect: CGRect, url: URL)]
  var popups: [StatusBarPopupRegion]
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
/// It sits at `OverlayPanel.statusBarClickWindowLevel` (above the system
/// menu-bar level and the bar window) because macOS only delivers menu-bar-band
/// clicks to windows at or above that level. To avoid stealing the native menu
/// bar's own clicks, the window flips to click-through
/// (`ignoresMouseEvents = true`) and the bar window drops below the menu bar
/// whenever the auto-hidden menu bar is actually revealed under the pointer
/// (`OverlayPanel.menuBarRevealTimer`), so native wins then; when the menu bar
/// is folded away, the band is Flash's and the window swallows the click.
final class StatusBarClickView: NSView {
  /// Link sub-rects in this view's coordinate space, with their targets.
  var links: [(rect: CGRect, url: URL)] = [] {
    didSet { window?.invalidateCursorRects(for: self) }
  }
  var popups: [StatusBarPopupRegion] = [] {
    didSet {
      let signature = popups.enumerated().map { index, popup in
        "\(index):\(StatusFormatDocument.stableID(popup.name)):\(NSStringFromRect(popup.rect))"
      }.joined(separator: ";")
      guard signature != popupDiagnosticSignature else { return }
      popupDiagnosticSignature = signature
      let regions = popups.enumerated().map { index, popup in
        "\(index):\(StatusFormatDocument.stableID(popup.name)):\(NSStringFromRect(popup.rect)):\(popup.content.utf8.count)"
      }.joined(separator: ";")
      FlashLog.debug(
        "Status hover regions changed",
        fields: [
          "window": String(window?.windowNumber ?? 0),
          "popup_count": String(popups.count), "regions": regions,
        ],
        source: "core:StatusBarClickView.regions")
    }
  }
  private var popupDiagnosticSignature = ""
  private var hoverDiagnosticSignature: String?
  private var trackingDiagnosticBounds: CGRect?

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
  var onPopupClick: ((StatusBarPopupRegion, NSPoint) -> Void)?
  /// A committed left-click found a handler (a link or a named range
  /// action). The hovered popup has served its purpose, so it closes.
  var onLinkActivated: (() -> Void)?
  /// Reports the hovered link or popup run (view coordinates, nil when the
  /// pointer is over plain text or has left) so the bar can wash it.
  var onHoverHighlight: ((CGRect?) -> Void)?

  static func focusesPopup(overLink: Bool, modifiers: NSEvent.ModifierFlags) -> Bool {
    !overLink || modifiers.contains(.option)
  }

  /// The wash follows the narrowest interactive span under the pointer. A
  /// whole-row popup — a feed row wraps its label, title, domain and arrow in
  /// one region so they share one preview — must not wash the entire row when
  /// the pointer sits on one of its links. The popup that opens is unaffected.
  static func hoverWashRect(link: CGRect?, popup: CGRect?) -> CGRect? {
    guard let popup else { return link }
    guard let link, link.width < popup.width else { return popup }
    return link
  }

  /// Window-space location of the in-flight `mouseDown`, used to tell a click
  /// from a drag: a link opens only if the pointer comes back up within
  /// `dragSlop` of where it went down. A drag (window-drag, selection sweep,
  /// a slip toward a menu) opens nothing — but is still swallowed.
  private var mouseDownLocation: NSPoint?
  private var rightMouseDownLocation: NSPoint?
  private var mouseDownURL: URL?
  private var mouseDownPopup: StatusBarPopupRegion?
  private var rightMouseDownPopup: StatusBarPopupRegion?

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
    let local = convert(event.locationInWindow, from: nil)
    // Only physical clicks reach here now. A hinted status-bar link is opened
    // straight from the hint's own URL (`activateStatusBarLink`) instead of
    // being replayed as a synthetic click into this window, so there is no
    // pending gesture to reconcile against whatever the bar published since.
    mouseDownURL = links.first(where: { $0.rect.contains(local) })?.url
    mouseDownPopup = popups.first(where: { $0.rect.contains(local) })
    FlashLog.trace(
      "[statusbar] click_down at=\(local) links=\(links.count) popups=\(popups.count) "
        + "url=\(mouseDownURL?.absoluteString ?? "nil") "
        + "popup=\(mouseDownPopup?.name ?? "nil")")
  }

  override func mouseUp(with event: NSEvent) {
    defer {
      mouseDownLocation = nil
      mouseDownURL = nil
      mouseDownPopup = nil
    }
    guard let start = mouseDownLocation,
      Self.isClick(from: start, to: event.locationInWindow)
    else {
      FlashLog.trace(
        "[statusbar] click_up dropped had_down=\(mouseDownLocation != nil) treated_as=drag")
      return
    }
    let url = mouseDownURL
    FlashLog.trace(
      "[statusbar] click_up url=\(url?.absoluteString ?? "nil") "
        + "popup=\(mouseDownPopup?.name ?? "nil")")
    if let popup = mouseDownPopup,
      Self.focusesPopup(overLink: url != nil, modifiers: event.modifierFlags)
    {
      let point = window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
      onPopupClick?(popup, point)
      return
    }
    if let url {
      onLinkActivated?()
      activate(url: url)
    }
    // Non-link clicks are intentionally not forwarded (no super call): the band
    // is Flash's while the menu bar is folded, so the click stops here instead
    // of leaking to the wallpaper or the window underneath.
  }

  /// Follow a status-bar link: a `#[range=…]` action goes back to Flash, and
  /// anything else opens in the handling app.
  func activate(url: URL) {
    if let action = FlashStatusBarRenderer.rangeActionName(from: url) {
      onStatusBarAction?(action)
      return
    }
    Self.openExternally(url)
  }

  /// Hand a status-bar link to whichever app handles it.
  ///
  /// `activates = true` brings the handling browser to the front and gives it
  /// keyboard focus. A plain `open(url)` opens the tab in the background — the
  /// click panel is non-activating, so the previously focused app keeps focus
  /// and typing lands in the old app.
  static func openExternally(_ url: URL) {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.open(url, configuration: configuration) { app, error in
      if let error {
        FlashLog.warn("[statusbar] link_open_failed url=\(url.absoluteString) error=\(error)")
      } else {
        FlashLog.trace(
          "[statusbar] link_opened url=\(url.absoluteString) "
            + "app=\(app?.bundleIdentifier ?? "nil")")
      }
    }
  }

  override func rightMouseDown(with event: NSEvent) {
    rightMouseDownLocation = event.locationInWindow
    let local = convert(event.locationInWindow, from: nil)
    rightMouseDownPopup = popups.first(where: { $0.rect.contains(local) })
  }

  override func rightMouseUp(with event: NSEvent) {
    defer {
      rightMouseDownLocation = nil
      rightMouseDownPopup = nil
    }
    guard let start = rightMouseDownLocation,
      Self.isClick(from: start, to: event.locationInWindow)
    else { return }
    guard let popup = rightMouseDownPopup else { return }
    let point = window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
    onPopupClick?(popup, point)
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
    if trackingDiagnosticBounds != bounds {
      trackingDiagnosticBounds = bounds
      FlashLog.debug(
        "Status hover tracking updated",
        fields: ["window": String(window?.windowNumber ?? 0), "bounds": NSStringFromRect(bounds)],
        source: "core:StatusBarClickView.tracking")
    }
  }

  override func mouseMoved(with event: NSEvent) { updatePointer(at: event) }
  override func mouseEntered(with event: NSEvent) {
    onPointerEntered?()
    updatePointer(at: event)
  }
  override func mouseExited(with event: NSEvent) {
    NSCursor.arrow.set()
    let point = window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
    logHover(event: "exited", popup: nil, overLink: false, point: point)
    onPopupHover?(nil, point)
    onHoverHighlight?(nil)
  }

  /// Pointing hand over a link run, the default arrow over the rest of the bar.
  private func updatePointer(at event: NSEvent) {
    let local = convert(event.locationInWindow, from: nil)
    let link = links.first(where: { $0.rect.contains(local) })
    let overLink = link != nil
    let popup = popups.first(where: { $0.rect.contains(local) })
    if overLink || popup != nil {
      NSCursor.pointingHand.set()
    } else {
      NSCursor.arrow.set()
    }
    let point = window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
    logHover(
      event: event.type == .mouseEntered ? "entered" : "moved",
      popup: popup, overLink: overLink, point: point)
    onPopupHover?(popup, point)
    onHoverHighlight?(Self.hoverWashRect(link: link?.rect, popup: popup?.rect))
  }

  private func logHover(event: String, popup: StatusBarPopupRegion?, overLink: Bool, point: CGPoint)
  {
    let popupID = popup.map { StatusFormatDocument.stableID($0.name) } ?? "none"
    let signature = "\(popupID):\(overLink):\(window?.ignoresMouseEvents ?? false)"
    guard event != "moved" || signature != hoverDiagnosticSignature else { return }
    hoverDiagnosticSignature = event == "exited" ? nil : signature
    FlashLog.debug(
      "Status hover target changed",
      fields: [
        "event": event, "popup_id": popupID, "over_link": String(overLink),
        "window": String(window?.windowNumber ?? 0),
        "ignores_mouse": String(window?.ignoresMouseEvents ?? false),
        "popup_count": String(popups.count),
        "content_bytes": String(popup?.content.utf8.count ?? 0),
        "pointer": NSStringFromPoint(point),
      ],
      source: "core:StatusBarClickView.hover")
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
  func statusLinkRects(
    raw: String, font: NSFont, labelFrame: CGRect, alignment: CATextLayerAlignmentMode,
    barFrame: CGRect, panelFrame: CGRect
  ) -> [(rect: CGRect, url: URL)] {
    statusLinkRects(
      raw: FlashStatusBarRenderer.segments(from: raw), font: font,
      labelFrame: labelFrame, alignment: alignment, barFrame: barFrame, panelFrame: panelFrame)
  }

  func statusPopupRects(
    raw: String, popupTexts: [String: String], font: NSFont, labelFrame: CGRect,
    alignment: CATextLayerAlignmentMode, barFrame: CGRect, panelFrame: CGRect
  ) -> [StatusBarPopupRegion] {
    statusPopupRects(
      raw: FlashStatusBarRenderer.segments(from: raw), popupTexts: popupTexts,
      font: font, labelFrame: labelFrame, alignment: alignment, barFrame: barFrame,
      panelFrame: panelFrame)
  }

  /// Hintable status spans ordered from left to right. Popup-only spans move
  /// the pointer so their hover surface opens; a popup covering the same glyph
  /// span as a link reuses the link's click hint instead of drawing a duplicate.
  static func statusBarHintRegions(
    links: [(rect: CGRect, url: URL)],
    popups: [StatusBarPopupRegion]
  ) -> [StatusBarHintRegion] {
    func sameSpan(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
      abs(lhs.minX - rhs.minX) < 0.5
        && abs(lhs.maxX - rhs.maxX) < 0.5
        && abs(lhs.minY - rhs.minY) < 0.5
        && abs(lhs.maxY - rhs.maxY) < 0.5
    }

    let clickRegions = links.map { StatusBarHintRegion(rect: $0.rect, action: .click($0.url)) }
    let hoverRegions = popups.compactMap { popup -> StatusBarHintRegion? in
      guard !links.contains(where: { sameSpan($0.rect, popup.rect) }) else { return nil }
      return StatusBarHintRegion(rect: popup.rect, action: .hover(popup))
    }
    return (clickRegions + hoverRegions).sorted {
      if abs($0.rect.minX - $1.rect.minX) >= 0.5 { return $0.rect.minX < $1.rect.minX }
      return $0.rect.minY < $1.rect.minY
    }
  }

  /// Screen-space rects + targets for the `#[link=…]` runs in one rendered
  /// region. `labelFrame` is the text layer's frame relative to the bar
  /// layer; `barFrame` is the bar layer's frame relative to the panel;
  /// `panelFrame` is the panel's frame in screen coordinates.
  func statusLinkRects(
    raw: [FlashStatusTextSegment],
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
    raw: [FlashStatusTextSegment],
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
        content: run.content,
        document: run.document ?? statusBarPopupDocuments[run.name])
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

  func showStatusBarPopup(
    _ popup: StatusBarPopupRegion,
    at pointer: CGPoint,
    screenSnapshot snapshot: ScreenSnapshot = OverlayPanel.currentScreenSnapshot(),
    preservingContent: Bool = false
  ) {
    guard !statusPopupController.presentation.isFocused else { return }
    if statusPopupController.isContentSnapshot, !preservingContent {
      if statusPopupController.containsSnapshotAnchor(pointer) { return }
      statusPopupController.leaveAnchor()
    }
    // A terminal popup with no running session forks a PTY child on first
    // hover. Sweeping the pointer across the bar must not spawn one child per
    // span, so such a popup waits for a short dwell with the pointer still on
    // it before it is prepared; document popups and running sessions show
    // immediately as before.
    if statusBarTerminalNeedsSpawnHandler?(popup.name) == true,
      statusBarHoverDwellName != popup.name
    {
      statusBarHoverDwellWork?.cancel()
      statusBarHoverDwellName = popup.name
      let work = DispatchWorkItem { [weak self] in
        guard let self, self.statusBarHoverDwellName == popup.name,
          popup.rect.contains(NSEvent.mouseLocation)
        else {
          self?.statusBarHoverDwellName = nil
          return
        }
        self.showStatusBarPopup(
          popup, at: pointer, screenSnapshot: snapshot, preservingContent: preservingContent)
      }
      statusBarHoverDwellWork = work
      DispatchQueue.main.asyncAfter(
        deadline: .now() + .milliseconds(Self.statusBarHoverDwellMs), execute: work)
      return
    }
    statusBarHoverDwellName = nil
    statusBarHoverGate = statusBarHoverGate.hovering(popup.name)
    guard statusBarHoverGate.permits(popup.name) else { return }
    guard
      let screen = snapshot.screens.first(where: { $0.frame.contains(pointer) })
        ?? snapshot.screens.first(where: { $0.frame.intersects(popup.rect) })
    else {
      hideStatusBarPopup(reason: "screen_missing")
      return
    }
    if let current = statusPopupController.presentation.identity?.name, current != popup.name {
      hideStatusBarPopup(reason: "anchor_changed")
    }
    guard statusBarTerminalPrepareHandler?(popup.name) ?? true else {
      hideStatusBarPopup(reason: "terminal_missing")
      return
    }
    statusPopupController.preview(
      popup, pointer: pointer,
      visibleFrame: screen.visibleFrame, style: statusBarPopupStyle,
      font: NSFont.monospacedSystemFont(
        ofSize: Self.statusBarFontSize(overlayFontSize: CGFloat(overlayConfig.fontSize)),
        weight: .medium), preservingContent: preservingContent)
    activeStatusBarPopupName = statusPopupController.presentation.identity?.name
    activeStatusBarPopupContent = statusPopupController.content
    activeStatusBarPopupVisibleFrame = screen.visibleFrame
  }

  /// Follow a hinted status-bar link directly.
  ///
  /// This used to arm the click view with the URL and then synthesize a click
  /// into the menu-bar band, hoping the event came back to Flash's own click
  /// window. That chain has several ways to break — the pointer warp wakes the
  /// native menu-bar reveal, the arming is matched by timestamp and proximity,
  /// and the click has to be delivered to a window in the menu-bar band — and
  /// when any link broke, the hint silently did nothing. The hint already
  /// carries the URL the user picked, so follow it. Re-publication of the bar
  /// in the meantime cannot change it either, which is what the arming was
  /// protecting in the first place.
  func activateStatusBarLink(_ url: URL) {
    FlashLog.trace("[statusbar] hint_link url=\(url.absoluteString)")
    if let action = FlashStatusBarRenderer.rangeActionName(from: url) {
      statusBarActionHandler?(action)
      return
    }
    StatusBarClickView.openExternally(url)
  }

  func activateStatusBarPopup(_ popup: StatusBarPopupRegion, at pointer: CGPoint) {
    let wasFocused = statusPopupController.focusedName
    guard wasFocused != popup.name else { return }
    if wasFocused != nil {
      if let statusBarPopupDismissHandler {
        statusBarPopupDismissHandler(false)
      } else {
        hideStatusBarPopup(reason: "anchor_clicked")
      }
    }
    statusBarHoverGate = .ready
    showStatusBarPopup(popup, at: pointer)
    statusPopupController.focus()
  }

  /// Close the hovered popup because a left-click just ran a handler. The
  /// pointer stays where it is, so the gate keeps that popup shut until the
  /// pointer leaves its region; a pinned popup is left alone because it is no
  /// longer tied to hover.
  func dismissStatusBarPopupForClick() {
    guard let name = statusPopupController.presentation.identity?.name,
      !statusPopupController.presentation.isStandalone
    else { return }
    statusBarHoverGate = .dismissed(name)
    hideStatusBarPopup(reason: "link_click")
  }

  func hideStatusBarPopup(reason: String = "overlay_hidden") {
    statusBarHoverDwellWork?.cancel()
    statusBarHoverDwellWork = nil
    statusBarHoverDwellName = nil
    statusPopupController.dismiss(reason: reason)
    activeStatusBarPopupName = nil
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

  /// Route a hovered segment (screen coordinates) to the surface drawing it;
  /// every other surface hides its wash.
  func setStatusBarHoverHighlight(_ screenRect: CGRect?) {
    for surface in [primaryStatusBarSurface] + secondaryStatusBars {
      let bar = surface.backgroundLayer.frame.offsetBy(dx: frame.minX, dy: frame.minY)
      if let screenRect, bar.intersects(screenRect) {
        surface.setHoverHighlight(screenRect.offsetBy(dx: -bar.minX, dy: -bar.minY))
      } else {
        surface.setHoverHighlight(nil)
      }
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
          content: popup.content,
          document: popup.document)
      }
      view.onPointerEntered = { [weak self] in self?.startMenuBarRevealTracking() }
      view.onStatusBarAction = statusBarActionHandler
      view.onLinkActivated = { [weak self] in self?.dismissStatusBarPopupForClick() }
      view.onPopupClick = { [weak self] popup, point in
        var screenPopup = popup
        screenPopup.rect = popup.rect.offsetBy(dx: band.minX, dy: band.minY)
        self?.activateStatusBarPopup(screenPopup, at: point)
      }
      view.onPopupHover = { [weak self] popup, point in
        guard let self else { return }
        if let popup {
          var screenPopup = popup
          screenPopup.rect = popup.rect.offsetBy(dx: band.minX, dy: band.minY)
          self.showStatusBarPopup(screenPopup, at: point)
        } else {
          if self.statusPopupController.containsSnapshotAnchor(point) { return }
          self.statusBarHoverGate = .ready
          self.statusPopupController.leaveAnchor()
          self.activeStatusBarPopupName = self.statusPopupController.presentation.identity?.name
        }
      }
      view.onHoverHighlight = { [weak self] rect in
        self?.setStatusBarHoverHighlight(rect?.offsetBy(dx: band.minX, dy: band.minY))
      }
      window.orderFrontRegardless()
    }
    // A content/config refresh does not generate mouseMoved for a stationary
    // pointer. Re-hit-test now so an open popup updates immediately.
    refreshStatusBarPopup(popups: popups, links: links, at: NSEvent.mouseLocation)
    // The probe normally arms on hover, but if the pointer is already parked
    // in the band when the windows (re)appear no `mouseEntered` will fire —
    // catch that case here.
    if Self.pointerIsInMenuBarBand() { startMenuBarRevealTracking() }
  }

  /// Re-hit-test live status content, including the wash under a stationary
  /// pointer. An open popup updates in place and keeps its latest anchor.
  func refreshStatusBarPopup(
    popups: [StatusBarPopupRegion],
    links: [(rect: CGRect, url: URL)] = [],
    at pointer: CGPoint,
    screenSnapshot: ScreenSnapshot = OverlayPanel.currentScreenSnapshot()
  ) {
    statusPopupController.refresh(popups)
    activeStatusBarPopupName = statusPopupController.presentation.identity?.name
    activeStatusBarPopupContent = statusPopupController.content
    if statusPopupController.containsSnapshotAnchor(pointer) { return }
    let acceptsPointer = !statusBarClickWindows.contains(where: \.ignoresMouseEvents)
    let popup = acceptsPointer ? popups.first(where: { $0.rect.contains(pointer) }) : nil
    let link = acceptsPointer ? links.first(where: { $0.rect.contains(pointer) }) : nil
    setStatusBarHoverHighlight(
      StatusBarClickView.hoverWashRect(link: link?.rect, popup: popup?.rect))
    guard !statusPopupController.presentation.isFocused else { return }
    if let popup {
      showStatusBarPopup(popup, at: pointer, screenSnapshot: screenSnapshot)
    } else {
      statusBarHoverGate = .ready
      statusPopupController.leaveAnchor()
      activeStatusBarPopupName = nil
    }
  }

  /// Tear down every click window (bar hidden).
  func hideStatusBarClickWindows() {
    lastModeBadgeLayoutStamp = nil
    stopMenuBarRevealTracking()
    if !statusPopupController.presentation.isStandalone { hideStatusBarPopup() }
    guard !statusBarClickWindows.isEmpty || lastStatusBarClickSignature != nil else { return }
    for window in statusBarClickWindows { window.orderOut(nil) }
    statusBarClickWindows.removeAll()
    lastStatusBarClickSignature = nil
  }

  // MARK: Reveal-aware yielding

  /// Serial utility queue the reveal probe runs on. The pointer checks are
  /// thread-safe C calls (`CGEvent(source:)`, `CGDisplayBounds`) and stay off
  /// the main run loop; the window-list read hops to main through
  /// `WindowSnapshot.windowList`, and only while the pointer is in the band.
  private static let menuBarRevealProbeQueue = DispatchQueue(
    label: "flash.status_bar.reveal", qos: .utility)
  static let menuBarRevealClientID = "core:menu_bar_reveal"
  static let menuBarRevealIntervalMs = 80

  /// The bar window and its click windows both outrank the native menu bar, so
  /// they must step aside while it is actually revealed under the pointer —
  /// otherwise reaching for the top edge would show nothing. Poll on a short
  /// cadence and flip `ignoresMouseEvents` plus the bar's window level:
  /// revealed → click-through and bar lowered (native wins); folded → bar back
  /// on top and the windows catching. The probe runs only while the pointer is
  /// near the band (armed by `mouseEntered`, self-stopping otherwise), and hops
  /// to main only when the state flips. Call on the main thread.
  func startMenuBarRevealTracking() {
    guard !menuBarRevealProbeArmed else { return }
    FlashLog.debug("Status menu reveal tracking started", source: "core:StatusLinks.menuReveal")
    menuBarRevealProbeArmed = true
    menuBarRevealedShadow = false
    PollScheduler.shared.register(
      Self.menuBarRevealClientID, everyMs: Self.menuBarRevealIntervalMs, priority: .system,
      on: Self.menuBarRevealProbeQueue
    ) { [weak self] in self?.probeMenuBarReveal() }
  }

  func stopMenuBarRevealTracking() {
    if menuBarRevealProbeArmed {
      FlashLog.debug("Status menu reveal tracking stopped", source: "core:StatusLinks.menuReveal")
    }
    menuBarRevealProbeArmed = false
    PollScheduler.shared.unregister(Self.menuBarRevealClientID)
    menuBarRevealedShadow = false
    // Leave the windows catching and the bar on top (the defaults) so a stale
    // click-through or yielded state can't survive a hide/show.
    for window in statusBarClickWindows where window.ignoresMouseEvents {
      window.ignoresMouseEvents = false
    }
    setStatusBarYieldsToNativeMenuBar(false)
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
        self.setStatusBarYieldsToNativeMenuBar(revealed)
        FlashLog.debug(
          "Status menu reveal changed",
          fields: [
            "revealed": String(revealed),
            "click_windows": String(self.statusBarClickWindows.count),
          ],
          source: "core:StatusLinks.menuReveal")
        if revealed { self.statusBarNativeMenuDidReveal() }
      }
    }
    if !pointerNearBand && !revealed {
      // Pointer left the band with the menu bar folded: nothing to watch.
      // `mouseEntered` re-arms on the next hover.
      DispatchQueue.main.async { [weak self] in self?.stopMenuBarRevealTracking() }
    }
  }

  func statusBarNativeMenuDidReveal() {
    guard !statusPopupController.presentation.isStandalone else { return }
    hideStatusBarPopup(reason: "native_menu_revealed")
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
      let infos = WindowSnapshot.windowList([.optionOnScreenOnly])
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
