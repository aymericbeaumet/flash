import AppKit
import FlashCore
import QuartzCore

/// Transient banner toast — multi-line text centered on the focused
/// screen, auto-dismissed after `durationMs`. The only banner the user
/// is expected to ever see in practice is the Accessibility-permission
/// walkthrough; everything else is silent.
extension OverlayPanel {
  /// Show a transient banner centered on the focused screen. Multi-line strings (with
  /// `\n`) are rendered as wrapped text. Used to signal edge cases (no targets,
  /// Accessibility denied) — staying within the "transparent hint overlay only" UI rule.
  /// `outlivesTeardown` keeps it up across app switches, for instructions the
  /// user follows in another app.
  func displayBanner(_ text: String, durationMs: Int? = nil, outlivesTeardown: Bool = false) {
    let durationMs = durationMs ?? FlashTunables.bannerDurationMs
    let snapshot = OverlayPanel.currentScreenSnapshot()
    let frame = snapshot.unionFrame
    applyPanelFrame(frame)

    let fontSize = max(CGFloat(overlayConfig.fontSize), 16)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let longestLine = lines.map(\.count).max() ?? text.count

    let label = makeLabelLayer()
    label.string = text
    label.fontSize = fontSize
    label.foregroundColor = (nsColor(fromHex: overlayConfig.hintFG) ?? .black).cgColor
    label.alignmentMode = .center
    label.isWrapped = true
    label.contentsScale = snapshot.mainScale
    label.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)

    let lineHeight = fontSize + 6
    let approxWidth = CGFloat(longestLine) * fontSize * 0.62 + 40
    let chipHeight = lineHeight * CGFloat(lines.count) + 16
    let centerX: CGFloat
    let centerY: CGFloat
    if let main = snapshot.mainFrame {
      centerX = main.midX - frame.minX
      centerY = main.midY - frame.minY
    } else {
      centerX = (contentView?.bounds.midX ?? 0)
      centerY = (contentView?.bounds.midY ?? 0)
    }

    let chip = makeChipLayer()
    chip.frame = CGRect(
      x: centerX - approxWidth / 2, y: centerY - chipHeight / 2, width: approxWidth,
      height: chipHeight)
    let bannerTop = nsColor(fromHex: overlayConfig.hintBGTop) ?? .systemYellow
    let bannerBottom = nsColor(fromHex: overlayConfig.hintBGBottom) ?? bannerTop
    chip.colors = [bannerBottom.cgColor, bannerTop.cgColor]
    chip.cornerRadius = 6
    chip.borderColor =
      nsColor(fromHex: overlayConfig.hintBorder)?.cgColor ?? OverlayPanel.fallbackBorderCGColor
    let textHeight = lineHeight * CGFloat(lines.count)
    label.frame = CGRect(
      x: 8, y: (chipHeight - textHeight) / 2, width: approxWidth - 16, height: textHeight)
    chip.sublayers = [label]
    presentToast(chip, durationMs: durationMs, outlivesTeardown: outlivesTeardown)
  }
}

extension OverlayPanel {
  /// Show `layer` as the toast, above every other overlay layer, replacing
  /// only a previous toast. `durationMs` of zero or nil keeps it until
  /// `dismissToast` or a teardown.
  func presentToast(_ layer: CALayer, durationMs: Int?, outlivesTeardown: Bool) {
    toastToken &+= 1
    let token = toastToken
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    toast?.layer.removeFromSuperlayer()
    toast = Toast(layer: layer, token: token, outlivesTeardown: outlivesTeardown)
    var sublayers = contentLayer.sublayers ?? []
    appendToastLayerIfNeeded(to: &sublayers)
    contentLayer.sublayers = sublayers
    CATransaction.commit()
    refreshWindowLevelForCurrentContent()
    orderFrontRegardless()
    if let durationMs, durationMs > 0 {
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(durationMs)) {
        [weak self] in self?.dismissToast(token: token)
      }
    }
  }

  /// Remove the toast — only the one with `token` when given, so an expiry
  /// never removes a newer toast.
  func dismissToast(token: UInt64? = nil) {
    guard let current = toast, token == nil || current.token == token else { return }
    toast = nil
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    current.layer.removeFromSuperlayer()
    CATransaction.commit()
    refreshWindowLevelForCurrentContent()
    orderOutIfNoPersistentContent()
  }

  /// Every rebuild of `contentLayer.sublayers` keeps the toast, on top.
  func appendToastLayerIfNeeded(to sublayers: inout [CALayer]) {
    guard let layer = toast?.layer else { return }
    sublayers.removeAll { $0 === layer }
    sublayers.append(layer)
  }
}
