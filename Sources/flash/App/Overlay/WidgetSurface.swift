import AppKit
import QuartzCore

/// A widget's font: `[widgets.<name>] font` when it names an installed
/// fixed-pitch font, else the system monospaced font. Widgets lay text out on
/// a cell grid, so a proportional face would misplace every aligned column.
enum StatusWidgetFont {
  /// nil when a nonempty `name` is not an installed monospaced font.
  static func resolve(name: String, size: CGFloat) -> NSFont? {
    guard !name.isEmpty else { return .monospacedSystemFont(ofSize: size, weight: .regular) }
    guard let font = NSFont(name: name, size: size), font.isFixedPitch else { return nil }
    return font
  }

  static func font(name: String, size: CGFloat) -> NSFont {
    resolve(name: name, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
  }
}

/// One widget window's drawing: the rounded background and border, and each
/// stacked line laid out as its own tmux status line at the widget's column
/// count, drawn through the shared run renderer.
final class WidgetSurface {
  let backgroundLayer = CALayer()
  private let renderer = StatusRunRenderer()
  var runLayers: [StatusRunRenderer.RunLayer] { renderer.runLayers }

  /// The cell geometry of a set of lines in a widget's style.
  struct Metrics: Equatable {
    var cellWidth: CGFloat
    var lineHeight: CGFloat
    var columns: Int
    var size: CGSize
  }

  init() {
    backgroundLayer.actions = OverlayPanel.noActions
    backgroundLayer.masksToBounds = true
  }

  static func metrics(lines: [StatusFormatDocument], widget: Config.Widget, font: NSFont)
    -> Metrics
  {
    let cellWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
    let lineHeight = max(
      font.pointSize + 4, ceil(font.ascender - font.descender + font.leading))
    let columns =
      widget.columns > 0
      ? widget.columns
      : min(widget.maxColumns, max(1, lines.map(\.naturalColumns).max() ?? 0))
    let rows = CGFloat(lines.count)
    let padding = CGFloat(widget.padding)
    return Metrics(
      cellWidth: cellWidth, lineHeight: lineHeight, columns: columns,
      size: CGSize(
        width: ceil(CGFloat(columns) * cellWidth + padding * 2),
        height: ceil(
          rows * lineHeight + max(0, rows - 1) * CGFloat(widget.lineSpacing) + padding * 2)))
  }

  /// `#RRGGBB` or `#RRGGBBAA` as 0xRRGGBBAA.
  static func rgba(_ hex: String) -> UInt32? {
    let digits = hex.hasPrefix("#") ? hex.dropFirst() : hex[...]
    guard digits.count == 6 || digits.count == 8, let value = UInt32(digits, radix: 16) else {
      return nil
    }
    return digits.count == 6 ? value << 8 | 0xFF : value
  }

  /// `#RRGGBB` or `#RRGGBBAA`, in the colour space status text uses.
  static func color(_ hex: String) -> NSColor? {
    rgba(hex).map { rgba in
      FlashStatusTextColor.nsColor(.rgb(rgba >> 8)).withAlphaComponent(
        CGFloat(rgba & 0xFF) / 255)
    }
  }

  /// Draw `lines` in `widget`'s style at `scale`; returns the widget's size.
  @discardableResult
  func render(lines: [StatusFormatDocument], widget: Config.Widget, scale: CGFloat) -> CGSize {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    let font = StatusWidgetFont.font(name: widget.font, size: CGFloat(widget.fontSize))
    let metrics = Self.metrics(lines: lines, widget: widget, font: font)
    let padding = CGFloat(widget.padding)
    let foreground = Self.rgba(widget.foreground).map { FlashStatusTextColor.rgb($0 >> 8) }
    backgroundLayer.frame = CGRect(origin: .zero, size: metrics.size)
    backgroundLayer.contentsScale = scale
    backgroundLayer.backgroundColor = Self.color(widget.background)?.cgColor
    backgroundLayer.borderColor = Self.color(widget.border)?.cgColor
    backgroundLayer.borderWidth = CGFloat(widget.borderSize)
    backgroundLayer.cornerRadius = CGFloat(widget.cornerRadius)
    var items: [StatusRunRenderer.Item] = []
    for (row, line) in lines.enumerated() {
      let layout = StatusFormatLayout.layout(line, columns: metrics.columns)
      let y =
        metrics.size.height - padding - CGFloat(row + 1) * metrics.lineHeight
        - CGFloat(row) * CGFloat(widget.lineSpacing)
      for run in NativeStatusBarSurface.visibleRuns(
        layout, cellWidth: metrics.cellWidth, excluded: nil)
      where !Self.isBlank(run.segment) {
        var run = run
        if let foreground, run.segment.foreground == .defaultForeground {
          run.segment.foreground = foreground
        }
        let frame = CGRect(
          x: padding + CGFloat(run.column) * metrics.cellWidth, y: y,
          width: CGFloat(run.columns) * metrics.cellWidth, height: metrics.lineHeight)
        items.append(
          .init(
            run: run, frame: frame,
            textRect: CGRect(origin: .zero, size: frame.size)))
      }
    }
    renderer.render(items, in: backgroundLayer, font: font, scale: scale)
    return metrics.size
  }

  /// Padding cells with nothing to paint: no layer is spent on them.
  private static func isBlank(_ segment: FlashStatusTextSegment) -> Bool {
    segment.text.allSatisfy(\.isWhitespace) && segment.background == .defaultBackground
      && !segment.reverse && !segment.underline && !segment.strikethrough && !segment.overline
  }
}
