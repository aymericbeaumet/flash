import AppKit
import QuartzCore

extension OverlayPanel {
  struct AlertStyle {
    let fillColor: NSColor
    let strokeColor: NSColor
    let textColor: NSColor

    static let standard = AlertStyle(
      fillColor: NSColor.black.withAlphaComponent(0.75),
      strokeColor: .white,
      textColor: .white)
    static let error = AlertStyle(
      fillColor: NSColor.systemRed.withAlphaComponent(0.92),
      strokeColor: NSColor.white.withAlphaComponent(0.95),
      textColor: .white)

    static func from(_ style: AlertCommand.Style) -> AlertStyle {
      switch style {
      case .standard: return .standard
      case .error: return .error
      }
    }
  }

  private static let alertTextSize: CGFloat = 27
  private static let alertRadius: CGFloat = 27
  private static let alertStrokeWidth: CGFloat = 2
  private static var alertDisplayDuration: TimeInterval { FlashTunables.alertDuration }
  private static let alertTextGutter: CGFloat = 10

  /// Hammerspoon-style transient centered alert for the `alert_show` verb.
  /// Drawn in the existing overlay window so normal-mode capture cannot hide
  /// a separate panel behind the resident overlay.
  func displayAlert(
    _ message: String,
    duration: TimeInterval? = nil,
    style: AlertStyle = .standard
  ) {
    let duration = duration ?? Self.alertDisplayDuration
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
    let screenFrame = snapshot.mainFrame ?? frame
    applyPanelFrame(frame)
    recycleAll()

    let padding = Self.alertTextSize / 2
    let maxTextWidth = max(
      120,
      screenFrame.width * 0.8 - padding * 2 - Self.alertStrokeWidth)
    let textSize = Self.alertTextSize(for: message, maxWidth: maxTextWidth)
    let boxSize = CGSize(
      width: ceil(textSize.width + padding * 2 + Self.alertStrokeWidth + Self.alertTextGutter),
      height: ceil(textSize.height + padding * 2 + Self.alertStrokeWidth))
    let boxFrame = CGRect(
      x: screenFrame.midX - frame.minX - boxSize.width / 2,
      y: screenFrame.midY - frame.minY - boxSize.height / 2,
      width: boxSize.width,
      height: boxSize.height)

    let label = dequeueLabelLayer()
    label.string = message
    label.font = NSFont.systemFont(ofSize: Self.alertTextSize)
    label.fontSize = Self.alertTextSize
    label.foregroundColor = style.textColor.cgColor
    label.alignmentMode = .center
    label.isWrapped = true
    label.contentsScale = snapshot.mainScale
    label.frame = CGRect(
      x: padding + Self.alertStrokeWidth / 2,
      y: (boxSize.height - textSize.height) / 2,
      width: textSize.width + Self.alertTextGutter,
      height: textSize.height)

    let box = dequeueHintLayer()
    box.frame = boxFrame
    box.colors = nil
    box.backgroundColor = style.fillColor.cgColor
    box.borderColor = style.strokeColor.cgColor
    box.borderWidth = Self.alertStrokeWidth
    box.cornerRadius = Self.alertRadius
    box.masksToBounds = true
    box.contentsScale = snapshot.mainScale
    box.sublayers = [label]

    var sublayers: [CALayer] = [box]
    appendModeBadgeLayerIfNeeded(to: &sublayers, panelFrame: frame)
    appendActiveWindowBorderLayerIfNeeded(to: &sublayers)
    contentLayer.sublayers = sublayers
    transientContentVisible = true
    hintLayers.append(box)
    labelLayers.append(label)

    DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
      guard let self, self.transientDisplayToken == myToken else { return }
      self.hide()
    }
  }

  func dismissAlert() {
    transientDisplayToken &+= 1
    hide()
  }

  private static func alertTextSize(for message: String, maxWidth: CGFloat) -> CGSize {
    let text = message as NSString
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: Self.alertTextSize)
    ]
    let size = text.boundingRect(
      with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: attrs)
    return CGSize(width: ceil(size.width), height: ceil(size.height))
  }
}
