import AppKit
import FlashCore
import QuartzCore

struct ActiveWindowBorderStyle: Equatable {
  var color: CGColor
  var lineWidth: CGFloat
  var glow: Bool
}

/// Active-window border ("we're focused here"). The frame is supplied by
/// `AppDelegate` from `AppMonitor`'s focused-window frame and re-painted
/// whenever AX fires a window-move/resize. The colour is not supplied: it is
/// derived from `modeSurface.style`, the same value the status-bar pill is painted
/// from, and re-derived whenever that changes, so the border and the pill can
/// never show different modes.
extension OverlayPanel {
  /// Border stroke style per badge style: a thin green stroke in normal, a thin
  /// purple one in command (the mode-badge accents), and a thicker,
  /// softly-glowing blue one in insert. Normal and command share insert's outer
  /// edge — only insert grows inward (see `activeWindowBorderLocalRect`).
  static func activeWindowBorderStyle(
    for badgeStyle: OverlayModeBadgeStyle,
    sizeOverride: Double = 0,
    colorOverride: CGColor? = nil
  ) -> ActiveWindowBorderStyle {
    var style: ActiveWindowBorderStyle
    switch badgeStyle {
    case .normal: style = .init(color: nordAuroraGreenCG, lineWidth: 1, glow: false)
    case .insert: style = .init(color: nordFrost2CG, lineWidth: 2, glow: true)
    case .command: style = .init(color: nordAuroraPurpleCG, lineWidth: 1, glow: false)
    }
    // `[overlay] window_border_size` / `window_border_color` apply across
    // every mode; the defaults (0 / nil) keep the per-mode identity above.
    if sizeOverride > 0 { style.lineWidth = sizeOverride }
    if let colorOverride { style.color = colorOverride }
    return style
  }

  /// The style for the badge currently shown, with `[overlay]` overrides.
  var activeWindowBorderStyle: ActiveWindowBorderStyle {
    let colorOverride =
      overlayConfig.windowBorderColor.isEmpty
      ? nil : nsColor(fromHex: overlayConfig.windowBorderColor)?.cgColor
    return Self.activeWindowBorderStyle(
      for: modeSurface.style, sizeOverride: overlayConfig.windowBorderSize,
      colorOverride: colorOverride)
  }

  /// Re-stroke a shown border after the badge style or border config changed.
  func restyleActiveWindowBorder() {
    guard let activeWindowBorderFrame else { return }
    setActiveWindowBorder(around: activeWindowBorderFrame)
  }

  func setActiveWindowBorder(around targetFrame: CGRect?) {
    activeWindowBorderToken &+= 1

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }

    guard let targetFrame, !targetFrame.isNull, targetFrame.width > 0, targetFrame.height > 0 else {
      activeWindowBorderFrame = nil
      activeWindowBorderLayer.path = nil
      var sublayers = contentLayer.sublayers ?? []
      sublayers.removeAll { $0 === activeWindowBorderLayer }
      contentLayer.sublayers = sublayers
      orderOutIfNoPersistentContent()
      return
    }

    activeWindowBorderFrame = targetFrame
    let style = activeWindowBorderStyle
    let color = style.color
    let lineWidth = style.lineWidth
    let panelFrame = ensurePanelFrame()
    let local = Self.activeWindowBorderLocalRect(
      targetFrame: targetFrame,
      panelFrame: panelFrame,
      lineWidth: lineWidth)
    // Snap to the pixel grid of the screen the window is actually on. Using the
    // main screen's scale mis-snaps a window on a secondary display with a
    // different backing scale, producing a blurry / half-pixel border.
    let scale = Self.scaleForScreen(containing: targetFrame)
    let snapped = Self.snap(local, scale: scale)
    let path = CGMutablePath()
    path.addRoundedRect(in: snapped, cornerWidth: 4, cornerHeight: 4)
    activeWindowBorderLayer.frame = contentLayer.bounds
    activeWindowBorderLayer.path = path
    activeWindowBorderLayer.strokeColor = color
    activeWindowBorderLayer.fillColor = NSColor.clear.cgColor
    activeWindowBorderLayer.lineWidth = lineWidth
    // Soft, static glow (insert mode): a zero-offset shadow tinted with the
    // stroke color makes the border read as gently lit, without animating.
    if style.glow {
      activeWindowBorderLayer.shadowColor = color
      activeWindowBorderLayer.shadowOffset = .zero
      activeWindowBorderLayer.shadowRadius = 2
      activeWindowBorderLayer.shadowOpacity = 0.3
    } else {
      activeWindowBorderLayer.shadowOpacity = 0
    }

    var sublayers = contentLayer.sublayers ?? []
    // The focus stroke is background chrome. Keep every transient Flash
    // surface (command prompt, candidates, alerts, status bar) above it so a
    // target-window edge that crosses one of those surfaces never paints
    // through the foreground UI.
    sublayers.removeAll { $0 === activeWindowBorderLayer }
    sublayers.insert(activeWindowBorderLayer, at: 0)
    contentLayer.sublayers = sublayers
    if !isVisible {
      orderFrontRegardless()
    }
  }

  /// Re-attach the active-window border behind a freshly rebuilt sublayer stack
  /// when it's currently shown (`path != nil`). Transient overlays (hints,
  /// `displayAlert`, `displayBanner`) rebuild `contentLayer.sublayers` from
  /// scratch, so without this a toast blanks the colored focus border until the
  /// next window move re-draws it. Inserting at index zero is the z-order
  /// contract: Flash's interactive/transient UI must always remain fully above
  /// the window-focus chrome.
  func appendActiveWindowBorderLayerIfNeeded(to sublayers: inout [CALayer]) {
    guard activeWindowBorderFrame != nil else { return }
    sublayers.removeAll { $0 === activeWindowBorderLayer }
    sublayers.insert(activeWindowBorderLayer, at: 0)
  }

  /// Position the stroke fully *inside* the target window so the border reads as
  /// painted ON the window rather than wrapped AROUND it.
  ///
  /// The stroke is centered on the path, so the OUTER edge sits at
  /// `pathInset − lineWidth/2`. To keep that outer edge at a fixed `outerInset`
  /// inside the window edge — identical in normal (1px) and insert (3px) — while
  /// only the INNER edge grows with `lineWidth`, the path inset is
  /// `outerInset + lineWidth/2`. (For the historical 2px width this equals the
  /// old `inset = lineWidth`.) The outer inset also keeps the border from
  /// spilling onto an adjacent display when the window is flush to a boundary.
  static func activeWindowBorderLocalRect(
    targetFrame: CGRect,
    panelFrame: CGRect,
    lineWidth: CGFloat,
    outerInset: CGFloat = 1
  ) -> CGRect {
    let inset = outerInset + lineWidth / 2
    return CGRect(
      x: targetFrame.minX - panelFrame.minX + inset,
      y: targetFrame.minY - panelFrame.minY + inset,
      width: max(0, targetFrame.width - inset * 2),
      height: max(0, targetFrame.height - inset * 2))
  }

  /// Backing scale of the screen the window sits on (by center, then by largest
  /// overlap), so the border snaps to the right pixel grid on multi-display
  /// setups with mixed backing scales. Falls back to the main screen's scale.
  static func scaleForScreen(containing frame: CGRect) -> CGFloat {
    let snapshot = currentScreenSnapshot()
    let center = CGPoint(x: frame.midX, y: frame.midY)
    if let screen = snapshot.screens.first(where: { $0.frame.contains(center) }) {
      return screen.scale
    }
    var bestScale = snapshot.mainScale
    var bestOverlap: CGFloat = 0
    for screen in snapshot.screens {
      let intersection = screen.frame.intersection(frame)
      let overlap = intersection.isNull ? 0 : intersection.width * intersection.height
      if overlap > bestOverlap {
        bestOverlap = overlap
        bestScale = screen.scale
      }
    }
    return bestScale
  }
}
