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
  /// A recess mimicking the camera-housing notch, drawn behind the
  /// absolute-centre component and sized to its reservation (content plus
  /// gutters), so the side lanes stop at its edges. Hidden on a screen with a
  /// physical notch (the centre is hidden there) and when nothing is centred.
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

  /// `notchWidth` is the real camera housing's width: the centre reservation
  /// (and the recess drawn behind it) is never narrower, and widens to hold a
  /// longer centred label. Zero lets the reservation hug the centred content.
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
    // A transient TERMINAL label must not widen the persistent base-mode pill.
    sizingLabels.terminal = ""
    let longestPill =
      document.runs.filter { $0.pill && !$0.isStyleBoundary && $0.text != labels.terminal }
      .map { $0.text.count }.max() ?? 0
    let pillWidth = max(
      OverlayPanel.modeBadgeWidth(labels: sizingLabels, currentText: "", fontSize: font.pointSize),
      CGFloat(longestPill) * font.pointSize * 0.66 + 16)
    let pillColumns = Int(ceil(pillWidth / cellWidth))
    let pillLabels = document.runs.filter { $0.pill && !$0.isStyleBoundary }.map {
      (padded: Self.paddedPillText($0.text, columns: pillColumns), label: $0.text)
    }
    let prepared = Self.preparedDocument(
      document, pillColumns: pillColumns, hideCentre: notch != nil)
    let notchLocal = notch.map {
      let start = $0.minX - screenFrame.minX - OverlayPanel.statusBarNotchMargin
      let end = $0.maxX - screenFrame.minX + OverlayPanel.statusBarNotchMargin
      return start..<end
    }
    let leftColumns = notchLocal.map {
      max(0, Int(floor(($0.lowerBound - OverlayPanel.statusBarEdgePadding) / cellWidth)))
    }
    let fitted = Self.fitted(
      prepared,
      in: Self.overflowGeometry(
        columns: availableColumns, cellWidth: cellWidth, notchWidth: notchWidth,
        leftColumns: leftColumns))
    layout = StatusFormatLayout.layout(fitted.document, columns: availableColumns)
    visibleRuns = Self.visibleRuns(layout, cellWidth: cellWidth, excluded: notchLocal)
    runFrames = Self.frames(
      for: visibleRuns, cellWidth: cellWidth, pillWidth: pillWidth,
      height: barFrame.height)
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
      reserve: fitted.reserve, barFrame: barFrame, scale: scale, fill: fillColor,
      hidden: notch != nil)
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

  /// The notch spans the centre reservation exactly — the housing's width, or
  /// the centred label plus gutters when that is wider — so the side lanes
  /// (which stop the margin short of the reservation) clear the recess.
  private func renderCentreNotch(
    reserve: Range<Int>, barFrame: CGRect, scale: CGFloat, fill: NSColor, hidden: Bool
  ) {
    guard !hidden, !reserve.isEmpty else {
      centreNotch.isHidden = true
      centreNotch.path = nil
      return
    }
    let rect = OverlayPanel.snap(
      CGRect(
        x: OverlayPanel.statusBarEdgePadding + CGFloat(reserve.lowerBound) * cellWidth, y: 0,
        width: CGFloat(reserve.count) * cellWidth, height: barFrame.height),
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
  /// its alignment lane, retaining the native centre/right anchor.
  private static func frames(
    for runs: [StatusFormatLayout.PositionedRun], cellWidth: CGFloat,
    pillWidth: CGFloat, height: CGFloat
  ) -> [CGRect] {
    var excess: [StatusFormatAlignment: CGFloat] = [:]
    for run in runs where run.segment.pill {
      excess[run.segment.alignment, default: 0] += max(
        0, CGFloat(run.columns) * cellWidth - pillWidth)
    }
    var removed: [StatusFormatAlignment: CGFloat] = [:]
    return runs.map { run in
      let alignment = run.segment.alignment
      let total = excess[alignment, default: 0]
      let anchor: CGFloat
      switch alignment {
      case .right: anchor = total
      case .centre, .absoluteCentre: anchor = total / 2
      case .left, .default: anchor = 0
      }
      let reservedWidth = CGFloat(run.columns) * cellWidth
      let width = run.segment.pill ? min(pillWidth, reservedWidth) : reservedWidth
      let x =
        OverlayPanel.statusBarEdgePadding + CGFloat(run.column) * cellWidth
        + anchor - removed[alignment, default: 0]
      removed[alignment, default: 0] += reservedWidth - width
      return CGRect(x: x, y: 0, width: width, height: height)
    }
  }

  static func preparedDocument(_ document: StatusFormatDocument, pillColumns: Int, hideCentre: Bool)
    -> StatusFormatDocument
  {
    var result: [FlashStatusTextSegment] = []
    for var run in document.runs {
      if !run.isStyleBoundary {
        if hideCentre && (run.alignment == .centre || run.alignment == .absoluteCentre) { continue }
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
  /// Clearance between a side lane and the notch, as whole columns of the
  /// shared `[statusbar] notch_margin` — the very same points a real camera
  /// housing reserves above. A drawn recess is at least the real housing's
  /// width and keeps the same margin, so a notched Mac and an external display
  /// lay the bar out alike. Rounded up, so a lane never encroaches on the gap
  /// by a fraction of a cell.
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

  /// Resolve overflow before native drawing, and reserve the absolute
  /// centre's columns. Explicit `#[shrink]` groups give way first, in any
  /// section; only once they are exhausted does a section lose its own tail.
  /// Both passes narrow the widest span that relieves a violated constraint
  /// (`StatusBarOverflow.budgets`) and end the cut in "…", so a truncation is
  /// always a prefix of the full text. A document that fits is returned
  /// unchanged, and one without an absolute centre reserves nothing.
  static func fitted(_ document: StatusFormatDocument, in geometry: StatusBarOverflow.Geometry)
    -> (document: StatusFormatDocument, reserve: Range<Int>)
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
    func lane(_ index: Int) -> StatusBarOverflow.Lane {
      switch runs[index].alignment {
      case .default, .left: return .left
      case .centre: return .centre
      case .right: return .right
      case .absoluteCentre: return .absoluteCentre
      }
    }
    // Narrow each span to its budget, cutting only its `cut` runs; the rest
    // of a span (a section's pills) keeps its width.
    func contract(_ spans: [(runs: [Int], cut: [Int])]) {
      var fixed: [StatusBarOverflow.Lane: Int] = [:]
      let members = Set(spans.flatMap(\.runs))
      for index in ordinary where !members.contains(index) {
        fixed[lane(index), default: 0] += widths[index]
      }
      let full = spans.map { $0.runs.reduce(0) { $0 + widths[$1] } }
      let kept = spans.indices.map { full[$0] - spans[$0].cut.reduce(0) { $0 + widths[$1] } }
      let budgets = StatusBarOverflow.budgets(
        spans.indices.map {
          .init(lane: lane(spans[$0].runs[0]), width: full[$0], minimum: kept[$0] + 1)
        }, fixed: fixed, in: geometry)
      for (index, span) in spans.enumerated() where budgets[index] < full[index] {
        truncate(&runs, span.cut, to: budgets[index] - kept[index])
        for run in span.cut { widths[run] = StatusFormatCells.width(runs[run].text, styles: false) }
      }
    }
    // The explicit truncation points: consecutive `#[shrink]` runs of a lane.
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
    if !groups.isEmpty { contract(groups.map { ($0, $0) }) }
    // The default truncation point: each section's tail. A section ranks by
    // its whole width, but pills and native list content keep their own
    // geometry and are never cut.
    var sections: [(runs: [Int], cut: [Int])] = []
    for index in ordinary {
      let cut = !runs[index].pill && runs[index].list == .off
      if let section = sections.firstIndex(where: { lane($0.runs[0]) == lane(index) }) {
        sections[section].runs.append(index)
        if cut { sections[section].cut.append(index) }
      } else {
        sections.append(([index], cut ? [index] : []))
      }
    }
    contract(sections.filter { !$0.cut.isEmpty })
    let centre = ordinary.filter { lane($0) == .absoluteCentre }.reduce(0) { $0 + widths[$1] }
    return (
      StatusFormatDocument(runs: runs), StatusBarOverflow.reserve(centre: centre, in: geometry)
    )
  }

  /// Keep the head of the spanned runs within `width` cells, the last of them
  /// an ellipsis; runs past the cut are emptied.
  private static func truncate(
    _ runs: inout [FlashStatusTextSegment], _ span: [Int], to width: Int
  ) {
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
        appearance.text = cell.segment.text
        if appearance == cell.segment, last.column + last.columns == index,
          last.segment.pill
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

  func interactionRects(
    panelFrame: CGRect, popupTexts: [String: String],
    popupDocuments: [String: [FlashStatusTextSegment]]
  )
    -> (links: [(rect: CGRect, url: URL)], popups: [StatusBarPopupRegion])
  {
    let bar = backgroundLayer.frame
    func rect(_ frame: CGRect) -> CGRect {
      frame.offsetBy(dx: panelFrame.minX + bar.minX, dy: panelFrame.minY + bar.minY)
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
    return (links, popups)
  }
}
