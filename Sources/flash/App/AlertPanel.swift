import AppKit
import QuartzCore

/// The one centred alert: a title, optionally over a monospaced value line,
/// in a rounded box. Every alert Flash shows — `alert_show`, a volume step,
/// a caffeinate toggle, a confirmation question — is one of these, so there
/// is a single layout to style and a single surface to test.
struct StatusAlert: Equatable {
  enum Style: String, Hashable {
    case standard
    case error
  }

  /// How long the alert stays up.
  enum Duration: Equatable {
    /// The style's default: `[overlay] alert_duration` for a standard alert,
    /// a fixed longer dwell for an error.
    case standard
    case seconds(TimeInterval)
    /// Until `alert_dismiss`, a replacing alert or a transient teardown.
    case untilDismissed
  }

  var title: String
  /// The monospaced second line; nil for a one-line message.
  var value: String?
  /// The widest value the alert can show, so the box stays put while the
  /// value changes (`6%` and `100%` share one box).
  var valueAnchor: String?
  var style: Style = .standard
  var duration: Duration = .standard

  static func message(_ text: String, duration: Duration = .standard, style: Style = .standard)
    -> Self
  {
    Self(title: text, style: style, duration: duration)
  }

  static func volume(_ percent: Int) -> Self {
    Self(title: "volume", value: "\(min(100, max(0, percent)))%", valueAnchor: "100%")
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

  /// The question a confirmation session asks. It stays up until the session
  /// answers it or is torn down.
  static let confirmationChoices = "[y]es  [n]o"

  static func confirmation(_ prompt: String) -> Self {
    Self(title: prompt, value: confirmationChoices, duration: .untilDismissed)
  }
}

extension OverlayPanel {
  /// The colours and teardown policy of one `StatusAlert.Style`.
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

    static func from(_ style: StatusAlert.Style) -> AlertStyle {
      switch style {
      case .standard: return .standard
      case .error: return .error
      }
    }
  }

  private static let alertTextSize: CGFloat = 27
  private static let alertRadius: CGFloat = 27
  private static let alertStrokeWidth: CGFloat = 2
  private static let alertLineGap: CGFloat = 2
  private static var alertDisplayDuration: TimeInterval { FlashTunables.alertDuration }
  /// Warnings and errors stay up long enough to read.
  private static let alertErrorDuration: TimeInterval = 10
  private static let alertTextGutter: CGFloat = 10

  /// The dwell in milliseconds `presentToast` understands: nil keeps the
  /// toast until it is dismissed.
  static func alertDurationMs(_ duration: StatusAlert.Duration, style: StatusAlert.Style) -> Int? {
    switch duration {
    case .standard:
      let seconds = style == .error ? alertErrorDuration : alertDisplayDuration
      return Int((seconds * 1000).rounded())
    case .seconds(let seconds):
      return Int((seconds * 1000).rounded())
    case .untilDismissed:
      return nil
    }
  }

  /// Draw `alert` centred on the focused screen, in the existing overlay
  /// window so normal-mode capture cannot hide a separate panel behind the
  /// resident overlay. The title wraps; the value is one monospaced line.
  /// Both are centred in a box as wide as the title or the widest value, so
  /// `on` and `6%` sit in the middle of their line.
  func displayAlert(_ alert: StatusAlert) {
    let style = AlertStyle.from(alert.style)
    let snapshot = OverlayPanel.currentScreenSnapshot()
    let frame = snapshot.unionFrame
    let screenFrame = snapshot.mainFrame ?? frame
    applyPanelFrame(frame)

    let padding = Self.alertTextSize / 2
    let maxTextWidth = max(
      120,
      screenFrame.width * 0.8 - padding * 2 - Self.alertStrokeWidth)
    let titleFont =
      alert.value == nil
      ? NSFont.systemFont(ofSize: Self.alertTextSize)
      : NSFont.systemFont(ofSize: Self.alertTextSize, weight: .semibold)
    let valueFont = NSFont.monospacedSystemFont(ofSize: Self.alertTextSize, weight: .regular)
    let titleSize = Self.alertTextSize(for: alert.title, maxWidth: maxTextWidth, font: titleFont)
    let valueSize =
      alert.value.map { Self.alertTextSize(for: $0, maxWidth: maxTextWidth, font: valueFont) }
      ?? .zero
    let anchorSize =
      alert.valueAnchor.map { Self.alertTextSize(for: $0, maxWidth: maxTextWidth, font: valueFont) }
      ?? .zero
    let contentWidth = max(titleSize.width, valueSize.width, anchorSize.width)
    let lineGap: CGFloat = alert.value == nil ? 0 : Self.alertLineGap
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
    let textBottom = (boxSize.height - contentHeight) / 2

    var lines: [CALayer] = []
    if let valueText = alert.value {
      let value = makeLabelLayer()
      value.string = valueText
      value.font = valueFont
      value.fontSize = Self.alertTextSize
      value.foregroundColor = style.textColor.cgColor
      value.alignmentMode = .center
      value.contentsScale = snapshot.mainScale
      value.frame = CGRect(
        x: textX, y: textBottom, width: textWidth, height: valueSize.height)
      lines.append(value)
    }

    let title = makeLabelLayer()
    title.string = alert.title
    title.font = titleFont
    title.fontSize = Self.alertTextSize
    title.foregroundColor = style.textColor.cgColor
    title.alignmentMode = .center
    title.isWrapped = true
    title.contentsScale = snapshot.mainScale
    title.frame = CGRect(
      x: textX, y: textBottom + valueSize.height + lineGap,
      width: textWidth, height: titleSize.height)
    lines.append(title)

    let box = makeChipLayer()
    box.frame = boxFrame
    box.colors = nil
    box.backgroundColor = style.fillColor.cgColor
    box.borderColor = style.strokeColor.cgColor
    box.borderWidth = Self.alertStrokeWidth
    box.cornerRadius = Self.alertRadius
    box.masksToBounds = true
    box.contentsScale = snapshot.mainScale
    box.sublayers = lines
    presentToast(
      box, durationMs: Self.alertDurationMs(alert.duration, style: alert.style),
      outlivesTeardown: style.outlivesTeardown)
  }

  func dismissAlert() {
    dismissToast()
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
