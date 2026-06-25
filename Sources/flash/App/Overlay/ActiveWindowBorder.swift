import AppKit
import FlashCore
import QuartzCore

/// Insert-mode active-window border ("we're focused here"). The frame
/// is supplied by `AppDelegate` from `AppMonitor`'s focused-window
/// frame and re-painted whenever AX fires a window-move/resize.
extension OverlayPanel {
  func setActiveWindowBorder(
    around targetFrame: CGRect?,
    color: CGColor = OverlayPanel.nordFrost2CG,
    lineWidth: CGFloat = 2,
    glow: Bool = false
  ) {
    activeWindowBorderToken &+= 1

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }

    guard let targetFrame, !targetFrame.isNull, targetFrame.width > 0, targetFrame.height > 0 else {
      activeWindowBorderLayer.path = nil
      var sublayers = contentLayer.sublayers ?? []
      sublayers.removeAll { $0 === activeWindowBorderLayer }
      contentLayer.sublayers = sublayers
      orderOutIfNoPersistentContent()
      return
    }

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
    if glow {
      activeWindowBorderLayer.shadowColor = color
      activeWindowBorderLayer.shadowOffset = .zero
      activeWindowBorderLayer.shadowRadius = 3
      activeWindowBorderLayer.shadowOpacity = 0.45
    } else {
      activeWindowBorderLayer.shadowOpacity = 0
    }

    var sublayers = contentLayer.sublayers ?? []
    if !sublayers.contains(where: { $0 === activeWindowBorderLayer }) {
      sublayers.append(activeWindowBorderLayer)
    }
    contentLayer.sublayers = sublayers
    if !isVisible {
      orderFrontRegardless()
    }
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
