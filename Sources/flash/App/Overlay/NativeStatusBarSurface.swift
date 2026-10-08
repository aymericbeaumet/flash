import AppKit
import QuartzCore

/// A screen's native tmux cell layout: the bar's lanes, notch and pill sizing,
/// drawn through the shared `StatusRunRenderer`.
final class NativeStatusBarSurface {
  let backgroundLayer: CAGradientLayer
  private(set) var layout = StatusFormatLayout.Result(
    cells: [], positionedRuns: [], ranges: [], fill: nil)
  private(set) var visibleRuns: [StatusFormatLayout.PositionedRun] = []
  private(set) var cellWidth: CGFloat = 1
  private(set) var runFrames: [CGRect] = []
  private(set) var availableColumns = 0
  private let renderer = StatusRunRenderer()
  var runLayers: [StatusRunRenderer.RunLayer] { renderer.runLayers }
  var lastRenderStats: StatusRunRenderer.RenderStats { renderer.lastRenderStats }

  /// Bottom-edge hairline, the centre notch, and the wash behind the hovered
  /// segment. All sit beneath the run containers, which stay transparent over
  /// the default background so the bar's gradient shows through.
  let hairline = CALayer()
  /// A recess mimicking the camera-housing notch, drawn behind the centred
  /// lane (`#[align=centre]` and `#[align=notch]`) at the middle of the bar.
  /// Hidden on a screen with a physical notch, where that lane is hidden,
  /// and when the lane is empty.
  let centreNotch = CAShapeLayer()
  let hoverHighlight = CALayer()
  private var hoverBand = CGRect.zero

  // The bar's run transitions are the shared renderer's.
  static let cycleAnimationKey = StatusRunRenderer.cycleAnimationKey
  static let crossfadeAnimationKey = StatusRunRenderer.crossfadeAnimationKey
  static let cycleTransitionDuration = StatusRunRenderer.cycleTransitionDuration
  static let crossfadeDuration = StatusRunRenderer.crossfadeDuration

  init(backgroundLayer: CAGradientLayer = CAGradientLayer()) {
    self.backgroundLayer = backgroundLayer
    backgroundLayer.actions = OverlayPanel.noActions
    backgroundLayer.masksToBounds = true
    for layer in [hairline, centreNotch, hoverHighlight] { layer.actions = OverlayPanel.noActions }
    hairline.backgroundColor = OverlayPanel.statusBarHairlineCG
    centreNotch.isHidden = true
    hoverHighlight.backgroundColor = OverlayPanel.statusBarHoverHighlightCG
    hoverHighlight.cornerRadius = 3
    hoverHighlight.opacity = 0
    backgroundLayer.insertSublayer(hairline, at: 0)
    backgroundLayer.insertSublayer(centreNotch, at: 1)
    backgroundLayer.insertSublayer(hoverHighlight, at: 2)
  }

  /// Forget what every run layer last drew, so the next `render` redraws each
  /// run's text instead of only the runs whose value changed.
  func invalidateDrawnRuns() { renderer.invalidateDrawnRuns() }

  /// `notchWidth` is the camera housing's width. The centred lane reserves
  /// that width at the middle of the bar and draws it as a recess. The
  /// housing does not grow or move for a longer label. Zero lets the
  /// reservation hug the label.
  func render(
    document: StatusFormatDocument, barFrame: CGRect, screenFrame: CGRect,
    scale: CGFloat, notch: CGRect?, font: NSFont, labels: Config.Mode.Labels,
    palette: OverlayPanel.ModeBadgePalette, modeStyle: OverlayModeBadgeStyle, modeText: String,
    notchWidth: CGFloat = 0
  ) {
    let modeText = modeText.trimmingCharacters(in: .whitespacesAndNewlines)
    let document = StatusFormatDocument(
      runs: document.runs.map { run in
        guard run.isModeLabel else { return run }
        var run = run
        run.text = modeText
        return run
      })
    cellWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
    availableColumns = max(
      0, Int((barFrame.width - OverlayPanel.statusBarEdgePadding * 2) / cellWidth))
    var sizingLabels = labels
    // Transient TERMINAL and HYPER labels must not widen the persistent
    // base-mode pill. Holding the leader should not resize the bar.
    sizingLabels.terminal = ""
    sizingLabels.hyper = ""
    let longestPill =
      document.runs.filter {
        $0.pill && !$0.isStyleBoundary && $0.text != labels.terminal && $0.text != labels.hyper
      }
      .map { $0.text.count }.max() ?? 0
    let pillWidth = max(
      OverlayPanel.modeBadgeWidth(labels: sizingLabels, currentText: "", fontSize: font.pointSize),
      CGFloat(longestPill) * font.pointSize * 0.66 + 16)
    let pillColumns = Int(ceil(pillWidth / cellWidth))
    let pillLabels = document.runs.filter { $0.pill && !$0.isStyleBoundary }.map {
      (padded: Self.paddedPillText($0.text, columns: pillColumns), label: $0.text)
    }
    let prepared = Self.preparedDocument(
      document, pillColumns: pillColumns, hideNotch: notch != nil)
    let notchLocal = notch.map {
      let start = $0.minX - screenFrame.minX - OverlayPanel.statusBarNotchMargin
      let end = $0.maxX - screenFrame.minX + OverlayPanel.statusBarNotchMargin
      return start..<end
    }
    let physicalNotch = notch.map {
      CGRect(
        x: $0.minX - screenFrame.minX, y: 0, width: $0.width,
        height: barFrame.height)
    }
    let segments = Self.segments(
      of: prepared, barWidth: barFrame.width, cellWidth: cellWidth, notchWidth: notchWidth,
      physicalNotch: physicalNotch)
    let fitted = Self.fitted(prepared, budgets: segments.budgets(columns: availableColumns))
    layout = StatusFormatLayout.layout(fitted, columns: availableColumns)
    visibleRuns = Self.visibleRuns(layout, cellWidth: cellWidth, excluded: notchLocal)
    runFrames = Self.frames(
      for: visibleRuns, segments: segments, cellWidth: cellWidth, pillWidth: pillWidth,
      height: barFrame.height, edgePadding: OverlayPanel.statusBarEdgePadding)
    backgroundLayer.frame = OverlayPanel.snap(barFrame, scale: scale)
    backgroundLayer.contentsScale = scale
    backgroundLayer.opacity = 1
    backgroundLayer.isHidden = false
    backgroundLayer.cornerRadius = 0
    backgroundLayer.borderWidth = 0
    let fillColor = layout.fill.map(FlashStatusTextColor.nsColor) ?? OverlayPanel.nordPolarNight0
    let fill = fillColor.cgColor
    backgroundLayer.backgroundColor = fill
    // Layer coordinates run bottom-up: the lifted tint sits at the top edge.
    backgroundLayer.colors = [fill, OverlayPanel.lifted(fillColor, by: 0.045).cgColor]
    hairline.frame = CGRect(x: 0, y: 0, width: barFrame.width, height: 1 / max(1, scale))
    hairline.contentsScale = scale
    let textHeight = font.pointSize + 4
    let textY = max(0, (barFrame.height - textHeight) / 2)
    // The wash is a chip hugging the glyphs, not a full-height block; it
    // never moves the text it sits under.
    hoverBand = CGRect(
      x: 0, y: max(0, textY - Self.hoverWashVerticalPadding), width: barFrame.width,
      height: min(barFrame.height, textHeight + Self.hoverWashVerticalPadding * 2))
    hoverHighlight.contentsScale = scale
    renderCentreNotch(
      notch: segments.notch, barFrame: barFrame, scale: scale, fill: fillColor,
      hidden: notch != nil || !segments.drawsRecess)
    renderer.render(
      zip(visibleRuns, runFrames).map { run, frame in
        StatusRunRenderer.Item(
          run: run, frame: frame,
          textRect: CGRect(x: 0, y: textY, width: frame.width, height: textHeight))
      }, in: backgroundLayer, font: font, scale: scale,
      pill: .init(palette: palette, modeStyle: modeStyle, labels: pillLabels))
  }

  /// Physical notch proportions scaled to the bar: the housing's bottom corners
  /// are rounded and its top corners fillet outward into the bar's edge.
  /// The housing's bottom corners, rounded into the display.
  ///
  /// macOS publishes the notch's rect (`auxiliaryTopLeftArea` /
  /// `auxiliaryTopRightArea`) but neither of its radii, so both are constants
  /// matched to the hardware rather than measured.
  static let notchCornerRadius: CGFloat = 9

  /// The housing's top corners, where it meets the bezel. These curve the
  /// other way: the black flares *outward* into the top edge instead of
  /// meeting it at a hard right angle, which is why the notch is at its
  /// widest flush with the top and narrower along its straight sides. The
  /// published rect is that widest width.
  static let notchTopFilletRadius: CGFloat = 5

  /// The housing's outline. Layer coordinates are y-up, so the bar's top edge
  /// is `height`: the path leaves the top edge at full width, curves inward
  /// through the fillets, runs straight down the sides, and rounds the two
  /// bottom corners.
  static func centreNotchPath(in rect: CGRect, height: CGFloat) -> CGPath {
    let fillet = max(0, min(notchTopFilletRadius, min(rect.width / 4, height / 2)))
    let radius = max(
      0, min(notchCornerRadius, min(rect.width / 2 - fillet, height - fillet)))
    let left = rect.minX + fillet
    let right = rect.maxX - fillet
    let path = CGMutablePath()
    path.move(to: CGPoint(x: rect.minX, y: height))
    path.addArc(
      center: CGPoint(x: rect.minX, y: height - fillet), radius: fillet,
      startAngle: .pi / 2, endAngle: 0, clockwise: true)
    path.addLine(to: CGPoint(x: left, y: radius))
    path.addArc(
      center: CGPoint(x: left + radius, y: radius), radius: radius,
      startAngle: .pi, endAngle: .pi * 1.5, clockwise: false)
    path.addLine(to: CGPoint(x: right - radius, y: 0))
    path.addArc(
      center: CGPoint(x: right - radius, y: radius), radius: radius,
      startAngle: .pi * 1.5, endAngle: .pi * 2, clockwise: false)
    path.addLine(to: CGPoint(x: right, y: height - fillet))
    path.addArc(
      center: CGPoint(x: rect.maxX, y: height - fillet), radius: fillet,
      startAngle: .pi, endAngle: .pi / 2, clockwise: true)
    path.closeSubpath()
    return path
  }

  /// The centred lane's housing, at the middle of the bar. A label wider
  /// than the interior is cut; the recess does not grow or move.
  private func renderCentreNotch(
    notch: CGRect, barFrame: CGRect, scale: CGFloat, fill: NSColor, hidden: Bool
  ) {
    guard !hidden, notch.width > 0 else {
      centreNotch.isHidden = true
      centreNotch.path = nil
      return
    }
    let rect = OverlayPanel.snap(
      CGRect(x: notch.minX, y: 0, width: notch.width, height: barFrame.height),
      scale: scale)
    centreNotch.frame = CGRect(x: 0, y: 0, width: barFrame.width, height: barFrame.height)
    centreNotch.contentsScale = scale
    centreNotch.fillColor = OverlayPanel.sunken(fill, by: OverlayPanel.statusBarNotchSink).cgColor
    centreNotch.path = Self.centreNotchPath(in: rect, height: barFrame.height)
    centreNotch.isHidden = false
  }

  /// Hover feedback follows the visible text immediately. A link can include
  /// its following separator space without widening the wash by a whole cell.
  func setHoverHighlight(_ rect: CGRect?) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    let bounds = rect.flatMap(hoverTextBounds)
    if let rect = bounds {
      hoverHighlight.frame = CGRect(
        x: rect.minX - Self.hoverWashHorizontalPadding, y: hoverBand.minY,
        width: rect.width + Self.hoverWashHorizontalPadding * 2, height: hoverBand.height)
    }
    hoverHighlight.opacity = Self.hoverOpacity(for: bounds, cellWidth: cellWidth)
  }

  private func hoverTextBounds(in rect: CGRect) -> CGRect? {
    var bounds = CGRect.null
    for (index, run) in visibleRuns.enumerated() {
      var frame = runFrames[index]
      guard !run.segment.hidden, frame.intersects(rect) else { continue }
      if !run.segment.pill {
        let text = run.segment.text
        guard let start = text.firstIndex(where: { !$0.isWhitespace }),
          let end = text.lastIndex(where: { !$0.isWhitespace })
        else { continue }
        let leading = StatusFormatCells.width(String(text[..<start]), styles: false)
        let columns = StatusFormatCells.width(String(text[start...end]), styles: false)
        frame.origin.x += CGFloat(leading) * cellWidth
        frame.size.width = CGFloat(columns) * cellWidth
      }
      let intersection = frame.intersection(rect)
      if !intersection.isEmpty { bounds = bounds.union(intersection) }
    }
    return bounds.isNull ? nil : bounds
  }

  /// Past this width a full-strength wash reads as a banner rather than a
  /// hover affordance — a feed row wraps its label, title, domain and arrow in
  /// one popup span, so it can cover most of a lane. Wide spans get a fainter
  /// wash rather than none, so the pin affordance survives.
  static let wideHoverCells = 24
  static let wideHoverOpacity: Float = 0.45
  /// Wash padding around the hovered glyphs. The wash is its own layer, so
  /// widening it never shifts a run.
  static let hoverWashHorizontalPadding: CGFloat = 5
  static let hoverWashVerticalPadding: CGFloat = 1

  /// Opacity for a hovered span: absent means hidden, a span wider than
  /// `wideHoverCells` is dimmed, anything else is full strength.
  static func hoverOpacity(for rect: CGRect?, cellWidth: CGFloat) -> Float {
    guard let rect else { return 0 }
    return rect.width > CGFloat(wideHoverCells) * cellWidth ? wideHoverOpacity : 1
  }

  static func truncationEquivalent(_ lhs: String, _ rhs: String) -> Bool {
    StatusRunRenderer.truncationEquivalent(lhs, rhs)
  }

  /// Native cells reserve enough room for Flash's pill, but the pill keeps its
  /// original point geometry. Remove only that reservation's rounding within
  /// its alignment lane, retaining the lane's anchor: the left segment starts
  /// at the edge padding, the right segment ends at the opposite padding, the
  /// Side lanes stay in their segment boxes. The centred lane is one strip
  /// on the housing's midpoint, so a wider side cannot shift the notch.
  private static func frames(
    for runs: [StatusFormatLayout.PositionedRun], segments: StatusBarSegments,
    cellWidth: CGFloat, pillWidth: CGFloat, height: CGFloat, edgePadding: CGFloat
  ) -> [CGRect] {
    struct LaneBox {
      var minColumn: Int
      var maxEnd: Int
      var excess: CGFloat
    }
    func visualWidth(_ run: StatusFormatLayout.PositionedRun) -> CGFloat {
      let reserved = CGFloat(run.columns) * cellWidth
      return run.segment.pill ? min(pillWidth, reserved) : reserved
    }
    var boxes: [StatusBarOverflow.Lane: LaneBox] = [:]
    for run in runs {
      let lane = Self.lane(run.segment.alignment)
      guard lane == .left || lane == .right else { continue }
      let end = run.column + run.columns
      var box = boxes[lane] ?? LaneBox(minColumn: run.column, maxEnd: end, excess: 0)
      box.minColumn = min(box.minColumn, run.column)
      box.maxEnd = max(box.maxEnd, end)
      if run.segment.pill {
        box.excess += max(0, CGFloat(run.columns) * cellWidth - pillWidth)
      }
      boxes[lane] = box
    }
    let full = CGRect(
      x: edgePadding, y: 0, width: max(0, segments.barWidth - 2 * edgePadding), height: 0)
    func contentRect(_ lane: StatusBarOverflow.Lane) -> CGRect {
      switch lane {
      case .right: return segments.right.width > 0 ? segments.right : full
      case .notch, .centre:
        return segments.centre.width > 0 ? segments.centre : full
      case .left: return segments.left.width > 0 ? segments.left : full
      }
    }
    // Layout parks this lane wherever the sides left a gap. Draw it as one
    // strip on the housing instead, so the notch stays at the middle.
    var centredX: [Int: CGFloat] = [:]
    let centred = runs.indices.filter { Self.lane(runs[$0].segment.alignment) == .notch }
    if !centred.isEmpty {
      let total = centred.reduce(CGFloat(0)) { $0 + visualWidth(runs[$1]) }
      var cursor = contentRect(.notch).midX - total / 2
      for index in centred {
        centredX[index] = cursor
        cursor += visualWidth(runs[index])
      }
    }
    var removed: [StatusBarOverflow.Lane: CGFloat] = [:]
    return runs.indices.map { index in
      let run = runs[index]
      if let x = centredX[index] {
        return CGRect(x: x, y: 0, width: visualWidth(run), height: height)
      }
      let lane = Self.lane(run.segment.alignment)
      let box = boxes[lane] ?? LaneBox(minColumn: 0, maxEnd: 0, excess: 0)
      let rect = contentRect(lane)
      let base: CGFloat
      let anchor: CGFloat
      switch lane {
      case .right:
        base = rect.maxX - CGFloat(box.maxEnd - run.column) * cellWidth
        anchor = box.excess
      case .left:
        base = rect.minX + CGFloat(run.column - box.minColumn) * cellWidth
        anchor = 0
      case .notch, .centre:
        base = 0
        anchor = 0
      }
      let reservedWidth = CGFloat(run.columns) * cellWidth
      let width = run.segment.pill ? min(pillWidth, reservedWidth) : reservedWidth
      let x = base + anchor - removed[lane, default: 0]
      removed[lane, default: 0] += reservedWidth - width
      return CGRect(x: x, y: 0, width: width, height: height)
    }
  }

  static func preparedDocument(_ document: StatusFormatDocument, pillColumns: Int, hideNotch: Bool)
    -> StatusFormatDocument
  {
    var result: [FlashStatusTextSegment] = []
    for var run in document.runs {
      if !run.isStyleBoundary {
        // A physical camera is the notch. Both centred alignments hide, and
        // no software recess is drawn over the hardware.
        if hideNotch && (run.alignment == .notch || run.alignment == .centre) {
          continue
        }
        if run.pill {
          run.text = paddedPillText(run.text, columns: pillColumns)
        }
      }
      result.append(run)
    }
    return StatusFormatDocument(runs: result)
  }

  private static func paddedPillText(_ value: String, columns: Int) -> String {
    var text = ""
    var width = 0
    for scalar in value.unicodeScalars {
      let next = StatusFormatCells.scalarWidth(scalar)
      guard width + next <= max(0, columns - 2) else { break }
      text.unicodeScalars.append(scalar)
      width += next
    }
    let left = max(0, (columns - width) / 2)
    return String(repeating: " ", count: left) + text
      + String(repeating: " ", count: max(0, columns - width - left))
  }

  /// Blank columns kept *inside* the reservation, between the recess edge and
  /// the centred label. This is a text inset rather than a margin around the
  /// notch — it clears the recess's rounded corners, which a real housing has
  /// no equivalent of because nothing is drawn inside it.
  static let centreGutterColumns = 2
  /// The column-budget form of `[statusbar] notch_margin`. Drawn segments use
  /// the point margin itself, so both gaps beside the notch are that many
  /// points and a glyph that clears the housing by less than a cell still
  /// draws. This rounds up for callers that only have a column grid, where a
  /// fractional cell cannot be reserved on its own.
  static func centreMarginColumns(cellWidth: CGFloat) -> Int {
    guard cellWidth > 0 else { return 0 }
    return Int(ceil(OverlayPanel.statusBarNotchMargin / cellWidth))
  }
  /// A reservation never starves a side lane below this; on a bar too narrow
  /// for all three the centre gives ground rather than erasing a lane.
  static let centreReservationMinimumLaneColumns = 8

  /// The bar's overflow constraints in columns of `cellWidth`.
  static func overflowGeometry(
    columns: Int, cellWidth: CGFloat, notchWidth: CGFloat, leftColumns: Int?
  ) -> StatusBarOverflow.Geometry {
    .init(
      columns: columns, leftColumns: leftColumns,
      housingColumns: notchWidth > 0 && cellWidth > 0 ? Int(ceil(notchWidth / cellWidth)) : 0,
      gutterColumns: centreGutterColumns,
      marginColumns: centreMarginColumns(cellWidth: cellWidth),
      minimumLaneColumns: centreReservationMinimumLaneColumns)
  }

  /// The segment boxes for one prepared document. `#[align=centre]` and
  /// `#[align=notch]` are the centred lane, so either one reserves the
  /// housing. Padding is outside the content boxes; the returned column
  /// counts are what fits inside them.
  static func segments(
    of document: StatusFormatDocument, barWidth: CGFloat, cellWidth: CGFloat, notchWidth: CGFloat,
    physicalNotch: CGRect?
  ) -> StatusBarSegments {
    func present(_ lane: StatusBarOverflow.Lane) -> Bool {
      document.runs.contains { !$0.isStyleBoundary && self.lane($0.alignment) == lane }
    }
    return StatusBarSegments.make(
      barWidth: barWidth, cellWidth: cellWidth,
      edgePadding: OverlayPanel.statusBarEdgePadding,
      notchMargin: OverlayPanel.statusBarNotchMargin, notchWidth: notchWidth,
      gutterColumns: centreGutterColumns, hasLeft: present(.left), hasRight: present(.right),
      hasNotch: present(.notch),
      centreContentColumns: contentColumns(document.runs, .notch),
      physicalNotch: physicalNotch,
      minimumLaneColumns: centreReservationMinimumLaneColumns)
  }

  /// Resolve overflow before native drawing. Each segment is cut to its own
  /// budget. The last `#[shrink]` span in a segment is cut first and ends in
  /// `…`; only the overflow it cannot absorb reaches the segment edge, which
  /// is the end of the left and centre segments and the start of the right.
  /// Pills and native list content are never cut. A document that fits is
  /// returned unchanged.
  static func fitted(_ document: StatusFormatDocument, budgets: StatusBarOverflow.Budgets)
    -> StatusFormatDocument
  {
    var runs = document.runs
    let ordinary = runs.indices.filter {
      !runs[$0].isStyleBoundary && runs[$0].list != .leftMarker
        && runs[$0].list != .rightMarker
    }
    var widths = Array(repeating: 0, count: runs.count)
    for index in ordinary {
      widths[index] = StatusFormatCells.width(runs[index].text, styles: false)
    }
    func lane(_ index: Int) -> StatusBarOverflow.Lane { self.lane(runs[index].alignment) }
    var groups: [[Int]] = []
    var open = false
    for index in ordinary {
      if runs[index].shrink, open, let last = groups.last?.last, lane(last) == lane(index) {
        groups[groups.count - 1].append(index)
      } else if runs[index].shrink {
        groups.append([index])
      }
      open = runs[index].shrink
    }
    func total(_ indices: [Int]) -> Int { indices.reduce(0) { $0 + widths[$1] } }
    for laneCase in StatusBarOverflow.Lane.allCases {
      let indices = ordinary.filter { lane($0) == laneCase }
      guard !indices.isEmpty else { continue }
      let budget = budgets.columns(for: laneCase)
      guard total(indices) > budget else { continue }
      if let last = groups.last(where: { lane($0[0]) == laneCase }) {
        let shrinkWidth = total(last)
        let keep = budget - (total(indices) - shrinkWidth)
        if keep < shrinkWidth {
          truncate(&runs, last, to: max(1, keep), edge: .trailing)
          for index in last {
            widths[index] = StatusFormatCells.width(runs[index].text, styles: false)
          }
        }
      }
      guard total(indices) > budget else { continue }
      let cut = indices.filter { !runs[$0].pill && runs[$0].list == .off }
      guard !cut.isEmpty else { continue }
      let fixed = total(indices) - total(cut)
      truncate(&runs, cut, to: max(0, budget - fixed), edge: budgets.edge(for: laneCase))
    }
    return StatusFormatDocument(runs: runs)
  }

  /// Column budgets from `geometry`, then `fitted(_:budgets:)`. A side that is
  /// the only segment keeps the whole bar; two sides with no centred lane
  /// split it. A centred lane reserves the housing at the middle.
  static func fitted(_ document: StatusFormatDocument, in geometry: StatusBarOverflow.Geometry)
    -> (document: StatusFormatDocument, reserve: Range<Int>)
  {
    let absolute = contentColumns(document.runs, .notch)
    var budgets = StatusBarOverflow.plan(notchContent: absolute, in: geometry)
    let hasLeft = document.runs.contains { !$0.isStyleBoundary && lane($0.alignment) == .left }
    let hasRight = document.runs.contains { !$0.isStyleBoundary && lane($0.alignment) == .right }
    if absolute == 0, geometry.leftColumns == nil, geometry.rightColumns == nil {
      if hasLeft, hasRight {
        let half = geometry.columns / 2
        budgets.left = half
        budgets.right = half
      } else if hasLeft {
        budgets.left = geometry.columns
      } else if hasRight {
        budgets.right = geometry.columns
      }
    }
    return (fitted(document, budgets: budgets), budgets.reserve)
  }

  /// `#[align=centre]` and `#[align=notch]` share the centred lane.
  static func lane(_ alignment: StatusFormatAlignment) -> StatusBarOverflow.Lane {
    switch alignment {
    case .default, .left: return .left
    case .right: return .right
    case .centre, .notch: return .notch
    }
  }

  private static func contentColumns(
    _ runs: [FlashStatusTextSegment], _ lane: StatusBarOverflow.Lane
  ) -> Int {
    runs.reduce(0) { total, run in
      guard !run.isStyleBoundary, self.lane(run.alignment) == lane else { return total }
      return total + StatusFormatCells.width(run.text, styles: false)
    }
  }

  /// Keep `width` cells of `span`. `.trailing` keeps the head and ends with
  /// `…`; `.leading` keeps the tail and starts with `…`. A non-positive width
  /// clears the span.
  private static func truncate(
    _ runs: inout [FlashStatusTextSegment], _ span: [Int], to width: Int,
    edge: StatusBarOverflow.Edge
  ) {
    guard width > 0 else {
      for index in span { runs[index].text = "" }
      return
    }
    switch edge {
    case .trailing:
      var remaining = width - 1
      var truncated = false
      for index in span {
        guard !truncated else {
          runs[index].text = ""
          continue
        }
        var kept = ""
        for character in runs[index].text {
          let cells = StatusFormatCells.width(String(character), styles: false)
          guard cells <= remaining else {
            kept.append("…")
            truncated = true
            break
          }
          kept.append(character)
          remaining -= cells
        }
        runs[index].text = kept
      }
    case .leading:
      var units: [(index: Int, character: Character, cells: Int)] = []
      for index in span {
        for character in runs[index].text {
          units.append(
            (index, character, StatusFormatCells.width(String(character), styles: false)))
        }
      }
      var remaining = width - 1
      var start = units.count
      var cursor = units.count - 1
      while cursor >= 0 {
        let cells = units[cursor].cells
        if cells > remaining { break }
        remaining -= cells
        start = cursor
        cursor -= 1
        if remaining == 0 { break }
      }
      var rebuilt = [Int: String]()
      for index in span { rebuilt[index] = "" }
      if start < units.count {
        rebuilt[units[start].index] = "…"
        for unit in units[start...] {
          var text = rebuilt[unit.index] ?? ""
          text.append(unit.character)
          rebuilt[unit.index] = text
        }
      } else if let first = span.first {
        rebuilt[first] = "…"
      }
      for index in span { runs[index].text = rebuilt[index] ?? "" }
    }
  }

  static func visibleRuns(
    _ result: StatusFormatLayout.Result, cellWidth: CGFloat,
    excluded: Range<CGFloat>?
  ) -> [StatusFormatLayout.PositionedRun] {
    var runs: [StatusFormatLayout.PositionedRun] = []
    for (index, cell) in result.cells.enumerated() where !cell.isContinuation {
      let x = OverlayPanel.statusBarEdgePadding + CGFloat(index) * cellWidth
      let end = x + CGFloat(cell.columns) * cellWidth
      if let excluded, x < excluded.upperBound && end > excluded.lowerBound { continue }
      if var last = runs.last {
        var appearance = last.segment
        var incoming = cell.segment
        // `#[shrink]` is a layout flag, not a paint style. A carousel title
        // and the ` (domain)` after `#[noshrink]` are one article and must
        // draw as one run, so they rise from the bottom together.
        if last.segment.cycle, incoming.cycle {
          incoming.shrink = last.segment.shrink
        }
        appearance.text = incoming.text
        if appearance == incoming, last.column + last.columns == index,
          last.segment.pill || last.segment.cycle
            || (last.segment.text.unicodeScalars.allSatisfy(\.isASCII)
              && cell.segment.text.unicodeScalars.allSatisfy(\.isASCII))
        {
          last.segment.text += cell.segment.text
          last.columns += cell.columns
          runs[runs.count - 1] = last
          continue
        }
      }
      runs.append(.init(column: index, columns: cell.columns, segment: cell.segment))
    }
    return runs
  }

  /// Drawn runs in screen coordinates, for a letter search of this bar.
  func letterRuns(panelFrame: CGRect) -> [StatusBarLetterRun] {
    let bar = backgroundLayer.frame
    let originX = panelFrame.minX + bar.minX
    let originY = panelFrame.minY + bar.minY
    return zip(visibleRuns, runFrames).compactMap { run, frame in
      guard !run.segment.hidden, cellWidth > 0 else { return nil }
      let screen = frame.offsetBy(dx: originX, dy: originY)
      if run.segment.pill {
        let label = run.segment.text.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return StatusBarLetterRun(
          text: label, frame: screen, cellWidth: cellWidth, centered: true)
      }
      guard !run.segment.text.isEmpty else { return nil }
      return StatusBarLetterRun(
        text: run.segment.text, frame: screen, cellWidth: cellWidth, centered: false)
    }
  }

  func interactionRects(
    panelFrame: CGRect, popupTexts: [String: String],
    popupDocuments: [String: [FlashStatusTextSegment]]
  )
    -> (
      links: [(rect: CGRect, url: URL)], popups: [StatusBarPopupRegion],
      hints: [StatusBarHintRegion]
    )
  {
    let bar = backgroundLayer.frame
    func rect(_ frame: CGRect) -> CGRect {
      frame.offsetBy(dx: panelFrame.minX + bar.minX, dy: panelFrame.minY + bar.minY)
    }
    func local(_ frame: CGRect) -> CGRect {
      frame.offsetBy(dx: -(panelFrame.minX + bar.minX), dy: -(panelFrame.minY + bar.minY))
    }
    var links: [(rect: CGRect, url: URL)] = []
    var popups: [StatusBarPopupRegion] = []
    func append(_ bounds: CGRect, _ url: URL, to targets: inout [(rect: CGRect, url: URL)]) {
      if let previous = targets.last, previous.url == url,
        abs(previous.rect.maxX - bounds.minX) < 0.01
      {
        targets[targets.count - 1].rect.size.width += bounds.width
      } else {
        targets.append((bounds, url))
      }
    }
    for (index, run) in visibleRuns.enumerated() {
      let bounds = rect(runFrames[index])
      if let target = run.segment.link, let url = URL(string: target) {
        append(bounds, url, to: &links)
      }
      if let name = run.segment.popup, let content = run.segment.popupContent ?? popupTexts[name] {
        if var previous = popups.last, previous.name == name, previous.content == content,
          abs(previous.rect.maxX - bounds.minX) < 0.01
        {
          previous.rect.size.width += bounds.width
          popups[popups.count - 1] = previous
        } else {
          popups.append(
            .init(rect: bounds, name: name, content: content, document: popupDocuments[name]))
        }
      }
    }
    // A popup hangs from the text its wash hugs, not from its outer spaces.
    for index in popups.indices {
      popups[index].textBounds = hoverTextBounds(in: local(popups[index].rect)).map(rect)
    }
    // Only ranges closed by the native layout are actionable; unclosed ranges
    // and cell metadata left behind by clipping cannot create an extra hit area.
    for range in layout.ranges where range.range.kind == .user {
      guard let url = FlashStatusBarRenderer.rangeActionURL(name: range.range.argument) else {
        continue
      }
      var fragments: [(rect: CGRect, url: URL)] = []
      for (index, run) in visibleRuns.enumerated() {
        let start = max(run.column, range.columns.lowerBound)
        let end = min(run.column + run.columns, range.columns.upperBound)
        if start < end {
          let frame = runFrames[index]
          let width = frame.width / CGFloat(run.columns)
          let bounds = CGRect(
            x: frame.minX + CGFloat(start - run.column) * width,
            y: frame.minY, width: CGFloat(end - start) * width, height: frame.height)
          append(rect(bounds), url, to: &fragments)
        }
      }
      links += fragments
    }
    let hints = OverlayPanel.statusBarHintRegions(links: links, popups: popups) {
      hoverTextBounds(in: local($0)).map(rect)
    }
    return (links, popups, hints)
  }
}
