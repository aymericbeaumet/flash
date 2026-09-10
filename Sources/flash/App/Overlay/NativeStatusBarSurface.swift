import AppKit
import QuartzCore

/// A screen's native tmux cell layout, with pooled layers for its visible styled runs.
final class NativeStatusBarSurface {
  let backgroundLayer: CAGradientLayer
  private(set) var layout = StatusFormatLayout.Result(
    cells: [], positionedRuns: [], ranges: [], fill: nil)
  private(set) var visibleRuns: [StatusFormatLayout.PositionedRun] = []
  private(set) var cellWidth: CGFloat = 1
  private(set) var runLayers: [RunLayer] = []
  private(set) var runFrames: [CGRect] = []
  private(set) var availableColumns = 0

  final class RunLayer {
    let container = CALayer()
    let pill = CAGradientLayer()
    let text = CATextLayer()
    let effect = CATextLayer()
    let overline = CALayer()
    let curlyUnderline = CAShapeLayer()
    var previous: FlashStatusTextSegment?
    var previousFont: NSFont?
    var previousPalette: OverlayModeBadgeStyle?
    init() {
      for layer in [container, pill, text, effect, overline, curlyUnderline] {
        layer.actions = OverlayPanel.noActions
      }
      container.masksToBounds = true
      pill.cornerRadius = 4
      text.alignmentMode = .left
      effect.alignmentMode = .left
      text.truncationMode = .none
      effect.truncationMode = .none
      container.sublayers = [pill, text, effect, overline, curlyUnderline]
    }
  }

  init(backgroundLayer: CAGradientLayer = CAGradientLayer()) {
    self.backgroundLayer = backgroundLayer
    backgroundLayer.actions = OverlayPanel.noActions
    backgroundLayer.masksToBounds = true
  }

  func render(
    document: StatusFormatDocument, barFrame: CGRect, screenFrame: CGRect,
    scale: CGFloat, notch: CGRect?, font: NSFont, labels: Config.Mode.Labels,
    palette: OverlayPanel.ModeBadgePalette, modeStyle: OverlayModeBadgeStyle
  ) {
    let previousRuns = visibleRuns
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
    layout = StatusFormatLayout.layout(
      Self.shrinkingDocument(prepared, columns: availableColumns), columns: availableColumns)
    let notchLocal = notch.map {
      let start = $0.minX - screenFrame.minX - OverlayPanel.statusBarNotchMargin
      let end = $0.maxX - screenFrame.minX + OverlayPanel.statusBarNotchMargin
      return start..<end
    }
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
    let fill =
      layout.fill.map(FlashStatusTextColor.nsColor)?.cgColor ?? OverlayPanel.nordPolarNight0CG
    backgroundLayer.backgroundColor = fill
    backgroundLayer.colors = [fill, fill]
    let textHeight = font.pointSize + 4
    let textY = max(0, (barFrame.height - textHeight) / 2)
    let cycling = Self.cycleTransitionIndices(previous: previousRuns, next: visibleRuns)
    let cycleStartedAt = CACurrentMediaTime()
    for (index, run) in visibleRuns.enumerated() {
      if index == runLayers.count {
        let layers = RunLayer()
        runLayers.append(layers)
        backgroundLayer.addSublayer(layers.container)
      }
      let layers = runLayers[index]
      let rect = runFrames[index]
      layers.container.frame = rect
      layers.container.isHidden = false
      layers.container.contentsScale = scale
      let cellBackground = run.segment.reverse ? run.segment.foreground : run.segment.background
      layers.container.backgroundColor =
        run.segment.pill ? nil : FlashStatusTextColor.nsColor(cellBackground).cgColor
      let textRect = CGRect(x: 0, y: textY, width: rect.width, height: textHeight)
      layers.pill.frame = textRect
      layers.pill.contentsScale = scale
      layers.pill.isHidden = !run.segment.pill
      layers.pill.colors = [palette.bottomCG, palette.topCG]
      layers.pill.borderWidth = run.segment.pill && modeStyle == .normal ? 1 : 0
      layers.pill.borderColor =
        modeStyle == .normal ? OverlayPanel.statusModeNormalBorderCG : palette.borderCG
      layers.text.frame = textRect
      layers.effect.frame = textRect
      layers.text.alignmentMode = run.segment.pill ? .center : .left
      layers.effect.alignmentMode = layers.text.alignmentMode
      layers.text.contentsScale = scale
      layers.effect.contentsScale = scale
      layers.text.fontSize = font.pointSize
      layers.effect.fontSize = font.pointSize
      var segment = run.segment
      if segment.pill {
        segment.text =
          pillLabels.first { $0.padded == segment.text }?.label
          ?? segment.text.trimmingCharacters(in: .whitespaces)
        segment.bold = true
        segment.foreground = .rgb(Self.rgb(palette.foregroundCG))
        segment.background = .defaultBackground
        segment.reverse = false
      }
      if !segment.cycle, layers.previous?.cycle == true {
        layers.text.removeAnimation(forKey: kCATransition)
        layers.effect.removeAnimation(forKey: kCATransition)
      }
      let changed =
        layers.previous != segment || layers.previousFont != font
        || layers.previousPalette != modeStyle || cycling.contains(index)
      if changed {
        if cycling.contains(index) {
          let animation = CATransition()
          animation.type = .push
          animation.subtype = .fromBottom
          animation.duration = 0.42
          animation.beginTime = layers.text.convertTime(cycleStartedAt, from: nil)
          animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
          layers.text.add(animation, forKey: kCATransition)
          layers.effect.add(animation, forKey: kCATransition)
        }
        let attributed = FlashStatusBarRenderer.attributedSegment(segment, font: font)
        layers.text.string = FlashStatusBarRenderer.attributedStatusStringHidingAnimatedSpans(
          from: [segment], font: font)
        layers.effect.string = attributed
        layers.text.setNeedsDisplay()
        layers.effect.setNeedsDisplay()
        layers.previous = segment
        layers.previousFont = font
        layers.previousPalette = modeStyle
      }
      let animated = segment.blink || segment.breathing
      layers.effect.isHidden = !animated
      if animated {
        if changed || layers.effect.animation(forKey: "flashEffect") == nil {
          layers.effect.add(
            FlashStatusBarRenderer.effectOpacityAnimation(
              blink: segment.blink, breathing: segment.breathing, anchoredTo: layers.effect),
            forKey: "flashEffect")
        }
      } else {
        layers.effect.removeAnimation(forKey: "flashEffect")
      }
      layers.overline.isHidden = !segment.overline || segment.hidden
      let foreground = segment.reverse ? segment.background : segment.foreground
      let strokeColor = FlashStatusTextColor.nsColor(foreground).withAlphaComponent(
        segment.dim ? 0.6 : 1)
      layers.overline.backgroundColor = strokeColor.cgColor
      layers.overline.frame = CGRect(
        x: 0, y: textY + textHeight - 1, width: rect.width, height: 1 / max(1, scale))
      layers.curlyUnderline.isHidden =
        !segment.underline || segment.underlineStyle != .curly || segment.hidden
      if !layers.curlyUnderline.isHidden {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 2))
        var x: CGFloat = 0
        while x < rect.width {
          path.addQuadCurve(to: CGPoint(x: x + 2, y: 2), control: CGPoint(x: x + 1, y: 4))
          path.addQuadCurve(to: CGPoint(x: x + 4, y: 2), control: CGPoint(x: x + 3, y: 0))
          x += 4
        }
        layers.curlyUnderline.frame.origin.y = textY
        layers.curlyUnderline.path = path
        layers.curlyUnderline.fillColor = nil
        layers.curlyUnderline.lineWidth = 1 / max(1, scale)
        layers.curlyUnderline.strokeColor =
          segment.underlineColor == .defaultForeground
          ? strokeColor.cgColor : FlashStatusTextColor.nsColor(segment.underlineColor).cgColor
      }
      for decoration in [layers.overline, layers.curlyUnderline] {
        if animated {
          if changed || decoration.animation(forKey: "flashEffect") == nil {
            decoration.add(
              FlashStatusBarRenderer.effectOpacityAnimation(
                blink: segment.blink, breathing: segment.breathing, anchoredTo: decoration),
              forKey: "flashEffect")
          }
        } else {
          decoration.removeAnimation(forKey: "flashEffect")
        }
      }
    }
    for layers in runLayers.dropFirst(visibleRuns.count) {
      layers.container.isHidden = true
      layers.effect.removeAllAnimations()
      layers.text.removeAllAnimations()
      layers.overline.removeAllAnimations()
      layers.curlyUnderline.removeAllAnimations()
      layers.previous = nil
    }
  }

  private static func cycleTransitionIndices(
    previous: [StatusFormatLayout.PositionedRun], next: [StatusFormatLayout.PositionedRun]
  ) -> Set<Int> {
    func groups(_ runs: [StatusFormatLayout.PositionedRun]) -> [Range<Int>] {
      var result: [Range<Int>] = []
      for index in runs.indices where runs[index].segment.cycle {
        if let last = result.last, last.upperBound == index,
          runs[last.lowerBound].segment.alignment == runs[index].segment.alignment
        {
          result[result.count - 1] = last.lowerBound..<(index + 1)
        } else {
          result.append(index..<(index + 1))
        }
      }
      return result
    }
    var changed = Set<Int>()
    for (old, new) in zip(groups(previous), groups(next)) {
      let sameArticle = old.count == new.count && zip(old, new).allSatisfy { before, after in
        let lhs = previous[before].segment
        let rhs = next[after].segment
        return lhs.text == rhs.text && lhs.link == rhs.link && lhs.popup == rhs.popup
          && lhs.popupContent == rhs.popupContent
      }
      if !sameArticle { changed.formUnion(new) }
    }
    return changed
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

  private static func rgb(_ value: CGColor) -> UInt32 {
    let color = NSColor(cgColor: value)?.usingColorSpace(.sRGB) ?? .white
    return UInt32(color.redComponent * 255) << 16 | UInt32(color.greenComponent * 255) << 8
      | UInt32(color.blueComponent * 255)
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

  /// Flash's opt-in elastic spans consume overflow before native alignment and
  /// list drawing. Unmarked formats pass through to tmux's clipping unchanged.
  static func shrinkingDocument(_ document: StatusFormatDocument, columns: Int)
    -> StatusFormatDocument
  {
    var runs = document.runs
    let ordinary = runs.indices.filter {
      !runs[$0].isStyleBoundary && runs[$0].alignment != .absoluteCentre
        && runs[$0].list != .leftMarker && runs[$0].list != .rightMarker
    }
    var overflow = max(
      0, ordinary.reduce(0) { $0 + StatusFormatCells.width(runs[$1].text, styles: false) } - columns
    )
    guard overflow > 0 else { return document }
    var groups: [[Int]] = []
    var group: [Int] = []
    for index in ordinary {
      if runs[index].shrink {
        group.append(index)
      } else if !group.isEmpty {
        groups.append(group)
        group = []
      }
    }
    if !group.isEmpty { groups.append(group) }
    for group in groups where overflow > 0 {
      let width = group.reduce(0) { $0 + StatusFormatCells.width(runs[$1].text, styles: false) }
      let removed = min(overflow, max(0, width - 1))
      guard removed > 0 else { continue }
      var remaining = width - removed - 1
      var truncated = false
      for index in group {
        let text = runs[index].text
        runs[index].text = ""
        for character in text {
          let cellCount = StatusFormatCells.width(String(character), styles: false)
          if cellCount <= remaining && !truncated {
            runs[index].text.append(character)
            remaining -= cellCount
          } else if !truncated {
            runs[index].text.append("…")
            truncated = true
          }
        }
      }
      overflow -= removed
    }
    return StatusFormatDocument(runs: runs)
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
