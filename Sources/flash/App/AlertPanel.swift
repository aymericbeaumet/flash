import AppKit
import QuartzCore

/// A state alert drawn as a title over its value. Both lines are centred.
/// `valueAnchor` is the widest value, so the box stays put while the value
/// changes.
struct StatusAlert: Equatable {
  var title: String
  var value: String
  var valueAnchor: String

  static func volume(_ percent: Int) -> Self {
    Self(
      title: "volume", value: "\(min(100, max(0, percent)))%", valueAnchor: "100%")
  }

  static func caffeinate(on: Bool) -> Self {
    Self(title: "caffeinate", value: on ? "on" : "off", valueAnchor: "off")
  }

  /// The plugin reports `caffeinate on` or `caffeinate off`. Nil for anything else.
  static func caffeinate(reported: String) -> Self? {
    switch reported {
    case "caffeinate on": return caffeinate(on: true)
    case "caffeinate off": return caffeinate(on: false)
    default: return nil
    }
  }
}

extension OverlayPanel {
  struct AlertStyle: Equatable {
    let fillColor: NSColor
    let strokeColor: NSColor
    let textColor: NSColor
    /// Whether the toast survives a transient overlay teardown (an app switch,
    /// a mode change, a dismiss observer). An error has to stay long enough to
    /// be read; an informational toast gets out of the way.
    let outlivesTeardown: Bool

    static let standard = AlertStyle(
      fillColor: NSColor.black.withAlphaComponent(0.75),
      strokeColor: .white,
      textColor: .white,
      outlivesTeardown: false)
    static let error = AlertStyle(
      fillColor: NSColor.systemRed.withAlphaComponent(0.92),
      strokeColor: NSColor.white.withAlphaComponent(0.95),
      textColor: .white,
      outlivesTeardown: true)

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
  /// Warnings and errors stay up long enough to read.
  private static let alertErrorDuration: TimeInterval = 10
  private static let alertTextGutter: CGFloat = 10

  /// Hammerspoon-style transient centered alert for the `alert_show` verb.
  /// Drawn in the existing overlay window so normal-mode capture cannot hide
  /// a separate panel behind the resident overlay.
  func displayAlert(
    _ message: String,
    duration: TimeInterval? = nil,
    style: AlertStyle = .standard
  ) {
    let duration =
      duration ?? (style == .error ? Self.alertErrorDuration : Self.alertDisplayDuration)
    let snapshot = OverlayPanel.currentScreenSnapshot()
    let frame = snapshot.unionFrame
    let screenFrame = snapshot.mainFrame ?? frame
    applyPanelFrame(frame)

    let padding = Self.alertTextSize / 2
    let maxTextWidth = max(
      120,
      screenFrame.width * 0.8 - padding * 2 - Self.alertStrokeWidth)
    let font = Self.alertFont(monospaced: false)
    let textSize = Self.alertTextSize(for: message, maxWidth: maxTextWidth, font: font)
    let contentWidth = textSize.width
    let boxSize = CGSize(
      width: ceil(contentWidth + padding * 2 + Self.alertStrokeWidth + Self.alertTextGutter),
      height: ceil(textSize.height + padding * 2 + Self.alertStrokeWidth))
    let boxFrame = CGRect(
      x: screenFrame.midX - frame.minX - boxSize.width / 2,
      y: screenFrame.midY - frame.minY - boxSize.height / 2,
      width: boxSize.width,
      height: boxSize.height)

    let label = makeLabelLayer()
    label.string = message
    label.font = font
    label.fontSize = Self.alertTextSize
    label.foregroundColor = style.textColor.cgColor
    label.alignmentMode = .center
    label.isWrapped = true
    label.contentsScale = snapshot.mainScale
    label.frame = CGRect(
      x: padding + Self.alertStrokeWidth / 2,
      y: (boxSize.height - textSize.height) / 2,
      width: contentWidth + Self.alertTextGutter,
      height: textSize.height)

    let box = makeChipLayer()
    box.frame = boxFrame
    box.colors = nil
    box.backgroundColor = style.fillColor.cgColor
    box.borderColor = style.strokeColor.cgColor
    box.borderWidth = Self.alertStrokeWidth
    box.cornerRadius = Self.alertRadius
    box.masksToBounds = true
    box.contentsScale = snapshot.mainScale
    box.sublayers = [label]
    presentToast(
      box, durationMs: Int((duration * 1000).rounded()),
      outlivesTeardown: style.outlivesTeardown)
  }

  /// Title over value. Both lines are centred in a box as wide as the title
  /// or the widest value, so `on` and `6%` sit in the middle of their line.
  func displayAlert(
    _ alert: StatusAlert,
    duration: TimeInterval? = nil,
    style: AlertStyle = .standard
  ) {
    let duration =
      duration ?? (style == .error ? Self.alertErrorDuration : Self.alertDisplayDuration)
    let snapshot = OverlayPanel.currentScreenSnapshot()
    let frame = snapshot.unionFrame
    let screenFrame = snapshot.mainFrame ?? frame
    applyPanelFrame(frame)

    let padding = Self.alertTextSize / 2
    let maxTextWidth = max(
      120,
      screenFrame.width * 0.8 - padding * 2 - Self.alertStrokeWidth)
    let titleFont = NSFont.systemFont(ofSize: Self.alertTextSize, weight: .semibold)
    let valueFont = NSFont.monospacedSystemFont(ofSize: Self.alertTextSize, weight: .regular)
    let titleSize = Self.alertTextSize(for: alert.title, maxWidth: maxTextWidth, font: titleFont)
    let valueSize = Self.alertTextSize(for: alert.value, maxWidth: maxTextWidth, font: valueFont)
    let anchorSize = Self.alertTextSize(
      for: alert.valueAnchor, maxWidth: maxTextWidth, font: valueFont)
    let contentWidth = max(titleSize.width, valueSize.width, anchorSize.width)
    let lineGap: CGFloat = 2
    let contentHeight = titleSize.height + lineGap + valueSize.height
    let boxSize = CGSize(
      width: ceil(contentWidth + padding * 2 + Self.alertStrokeWidth + Self.alertTextGutter),
      height: ceil(contentHeight + padding * 2 + Self.alertStrokeWidth))
    let boxFrame = CGRect(
      x: screenFrame.midX - frame.minX - boxSize.width / 2,
      y: screenFrame.midY - frame.minY - boxSize.height / 2,
      width: boxSize.width,
      height: boxSize.height)
    let textX = padding + Self.alertStrokeWidth / 2
    let textWidth = contentWidth + Self.alertTextGutter

    let title = makeLabelLayer()
    title.string = alert.title
    title.font = titleFont
    title.fontSize = Self.alertTextSize
    title.foregroundColor = style.textColor.cgColor
    title.alignmentMode = .center
    title.contentsScale = snapshot.mainScale
    title.frame = CGRect(
      x: textX, y: padding + Self.alertStrokeWidth / 2 + valueSize.height + lineGap,
      width: textWidth, height: titleSize.height)

    let value = makeLabelLayer()
    value.string = alert.value
    value.font = valueFont
    value.fontSize = Self.alertTextSize
    value.foregroundColor = style.textColor.cgColor
    value.alignmentMode = .center
    value.contentsScale = snapshot.mainScale
    value.frame = CGRect(
      x: textX, y: padding + Self.alertStrokeWidth / 2,
      width: textWidth, height: valueSize.height)

    let box = makeChipLayer()
    box.frame = boxFrame
    box.colors = nil
    box.backgroundColor = style.fillColor.cgColor
    box.borderColor = style.strokeColor.cgColor
    box.borderWidth = Self.alertStrokeWidth
    box.cornerRadius = Self.alertRadius
    box.masksToBounds = true
    box.contentsScale = snapshot.mainScale
    box.sublayers = [value, title]
    presentToast(
      box, durationMs: Int((duration * 1000).rounded()),
      outlivesTeardown: style.outlivesTeardown)
  }

  func dismissAlert() {
    dismissToast()
  }

  private static func alertFont(monospaced: Bool) -> NSFont {
    monospaced
      ? NSFont.monospacedSystemFont(ofSize: alertTextSize, weight: .regular)
      : NSFont.systemFont(ofSize: alertTextSize)
  }

  private static func alertTextSize(
    for message: String, maxWidth: CGFloat, font: NSFont
  ) -> CGSize {
    let text = message as NSString
    let attrs: [NSAttributedString.Key: Any] = [.font: font]
    let size = text.boundingRect(
      with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: attrs)
    return CGSize(width: ceil(size.width), height: ceil(size.height))
  }
}
