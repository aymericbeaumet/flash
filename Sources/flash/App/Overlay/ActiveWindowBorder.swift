import AppKit
import FlashCore
import QuartzCore

/// Insert-mode active-window border ("we're focused here"). The frame
/// is supplied by `AppDelegate` from `AppMonitor`'s focused-window
/// frame and re-painted whenever AX fires a window-move/resize.
extension OverlayPanel {
  func setActiveWindowBorder(around targetFrame: CGRect?) {
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
    let lineWidth: CGFloat = 2
    let local = Self.activeWindowBorderLocalRect(
      targetFrame: targetFrame,
      panelFrame: panelFrame,
      lineWidth: lineWidth)
    let scale = OverlayPanel.currentScreenSnapshot().mainScale
    let snapped = Self.snap(local, scale: scale)
    let path = CGMutablePath()
    path.addRoundedRect(in: snapped, cornerWidth: 4, cornerHeight: 4)
    activeWindowBorderLayer.frame = contentLayer.bounds
    activeWindowBorderLayer.path = path
    activeWindowBorderLayer.strokeColor = Self.nordFrost2CG
    activeWindowBorderLayer.fillColor = NSColor.clear.cgColor
    activeWindowBorderLayer.lineWidth = lineWidth

    var sublayers = contentLayer.sublayers ?? []
    if !sublayers.contains(where: { $0 === activeWindowBorderLayer }) {
      sublayers.append(activeWindowBorderLayer)
    }
    contentLayer.sublayers = sublayers
    if !isVisible {
      orderFrontRegardless()
    }
  }

  /// Position the stroke fully *inside* the target window so the border
  /// reads as painted ON the window rather than wrapped AROUND it. The
  /// stroke is centered on the path, so we need to inset the path by
  /// `lineWidth/2` for the outer edge of the stroke to land *at* the
  /// window edge, plus another `lineWidth/2` so the entire stroke band
  /// sits one full width inside the chrome — this is what stops the
  /// border from spilling onto an adjacent display when the window is
  /// flush against a screen boundary.
  static func activeWindowBorderLocalRect(
    targetFrame: CGRect,
    panelFrame: CGRect,
    lineWidth: CGFloat
  ) -> CGRect {
    let inset = lineWidth
    return CGRect(
      x: targetFrame.minX - panelFrame.minX + inset,
      y: targetFrame.minY - panelFrame.minY + inset,
      width: max(0, targetFrame.width - inset * 2),
      height: max(0, targetFrame.height - inset * 2))
  }
}
