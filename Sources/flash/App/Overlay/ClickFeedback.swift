import AppKit
import QuartzCore

/// `[overlay] click_feedback`: a short ring where a committed click lands, for
/// demos and screencasts. The overlay's one deliberate animation: explicit,
/// on its own layer outside the rebuilt drawing subtree, started after the
/// click is queued, so it never delays the click or the next key. Each ring
/// removes itself once its animation has run.
extension OverlayPanel {
  static let clickFeedbackDuration: CFTimeInterval = 0.22
  static let clickFeedbackRadius: CGFloat = 16

  /// The ring grows out of the click point and fades.
  static func clickFeedbackAnimation() -> CAAnimationGroup {
    let grow = CABasicAnimation(keyPath: "transform.scale")
    grow.fromValue = 0.35
    grow.toValue = 1.0
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0.95
    fade.toValue = 0.0
    let group = CAAnimationGroup()
    group.animations = [grow, fade]
    group.duration = clickFeedbackDuration
    group.timingFunction = CAMediaTimingFunction(name: .easeOut)
    // Hold the faded end until the ring is removed, so it cannot flash back.
    group.fillMode = .forwards
    group.isRemovedOnCompletion = false
    return group
  }

  /// Draw one ring at `point` (NSScreen coordinates).
  func showClickFeedback(at point: CGPoint) {
    let panelFrame = ensurePanelFrame()
    let snapshot = Self.currentScreenSnapshot()
    let scale = snapshot.screens.first { $0.frame.contains(point) }?.scale ?? snapshot.mainScale
    let radius = Self.clickFeedbackRadius
    let ring = CAShapeLayer()
    ring.actions = Self.noActions
    ring.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
    ring.position = CGPoint(x: point.x - panelFrame.minX, y: point.y - panelFrame.minY)
    ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 2, dy: 2), transform: nil)
    ring.fillColor = NSColor.clear.cgColor
    ring.strokeColor = (nsColor(fromHex: hintColors.border) ?? .systemYellow).cgColor
    ring.lineWidth = 3
    ring.contentsScale = scale
    // The model value is the animation's end: invisible.
    ring.opacity = 0

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    clickFeedbackLayer.frame = contentView?.bounds ?? .zero
    clickFeedbackLayer.addSublayer(ring)
    ring.add(Self.clickFeedbackAnimation(), forKey: "click_feedback")
    CATransaction.commit()

    clickFeedbackRingsInFlight += 1
    refreshWindowLevelForCurrentContent()
    if !isVisible { orderFrontRegardless() }
    DispatchQueue.main.asyncAfter(
      deadline: .now() + .milliseconds(Int(Self.clickFeedbackDuration * 1000))
    ) { [weak self, weak ring] in
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      ring?.removeFromSuperlayer()
      CATransaction.commit()
      self?.clickFeedbackRingDidFinish()
    }
  }

  private func clickFeedbackRingDidFinish() {
    clickFeedbackRingsInFlight = max(0, clickFeedbackRingsInFlight - 1)
    guard clickFeedbackRingsInFlight == 0 else { return }
    refreshWindowLevelForCurrentContent()
    orderOutIfNoPersistentContent()
  }
}
