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
  func displayBanner(_ text: String, durationMs: Int? = 700) {
    transientDisplayToken &+= 1
    let myToken = transientDisplayToken

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer {
      CATransaction.commit()
      refreshWindowLevelForCurrentContent()
      orderFrontRegardless()
    }

    let snapshot = OverlayPanel.currentScreenSnapshot()
    let frame = snapshot.unionFrame
    applyPanelFrame(frame)
    recycleAll()

    let fontSize = max(CGFloat(overlayConfig.fontSize), 16)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let longestLine = lines.map(\.count).max() ?? text.count

    let label = dequeueLabelLayer()
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

    let chip = dequeueHintLayer()
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
    var sublayers: [CALayer] = [chip]
    appendModeBadgeLayerIfNeeded(to: &sublayers, panelFrame: frame)
    appendActiveWindowBorderLayerIfNeeded(to: &sublayers)
    contentLayer.sublayers = sublayers
    transientContentVisible = true
    hintLayers.append(chip)
    labelLayers.append(label)

    if let durationMs {
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(durationMs)) { [weak self] in
        // Only hide if a newer banner hasn't replaced us — otherwise we'd hide it early.
        guard let self, self.transientDisplayToken == myToken else { return }
        self.hide()
      }
    }
  }
}
