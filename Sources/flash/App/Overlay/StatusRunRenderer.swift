import AppKit
import QuartzCore

/// Draws positioned status runs into pooled layers — the one run renderer the
/// bar and desktop widgets share. The caller lays the runs out (cells, lanes,
/// line stacking) and supplies each run's container frame and text rect; this
/// owns text, fills, decorations, blink/breathing and value transitions.
final class StatusRunRenderer {
  /// One run's layers. The text layer always exists; the pill, the outgoing
  /// transition copy, the animated-effect copy and the decorations are made
  /// on first use, hidden by default, so a plain run costs two layers.
  final class RunLayer {
    let container = CALayer()
    let text = CATextLayer()
    var previous: FlashStatusTextSegment?
    var previousFont: NSFont?
    var previousForeground: CGColor?
    var previousFrame: CGRect?

    private(set) var existingPill: CAGradientLayer?
    private(set) var existingOutgoing: CATextLayer?
    private(set) var existingEffect: CATextLayer?
    private(set) var existingOverline: CALayer?
    private(set) var existingCurlyUnderline: CAShapeLayer?

    init() {
      for layer in [container, text] { layer.actions = OverlayPanel.noActions }
      container.masksToBounds = true
      text.alignmentMode = .left
      text.truncationMode = .none
      container.addSublayer(text)
    }

    var pill: CAGradientLayer {
      if let existingPill { return existingPill }
      let layer = CAGradientLayer()
      layer.cornerRadius = 4
      layer.isHidden = true
      attach(layer, rank: 0)
      existingPill = layer
      return layer
    }

    /// Holds the previous string while a transition fades or slides it out.
    /// Its model opacity is always 0; only explicit animations reveal it.
    var outgoing: CATextLayer {
      if let existingOutgoing { return existingOutgoing }
      let layer = CATextLayer()
      layer.alignmentMode = .left
      layer.truncationMode = .none
      layer.opacity = 0
      attach(layer, rank: 1)
      existingOutgoing = layer
      return layer
    }

    var effect: CATextLayer {
      if let existingEffect { return existingEffect }
      let layer = CATextLayer()
      layer.alignmentMode = .left
      layer.truncationMode = .none
      layer.isHidden = true
      attach(layer, rank: 3)
      existingEffect = layer
      return layer
    }

    var overline: CALayer {
      if let existingOverline { return existingOverline }
      let layer = CALayer()
      layer.isHidden = true
      attach(layer, rank: 4)
      existingOverline = layer
      return layer
    }

    var curlyUnderline: CAShapeLayer {
      if let existingCurlyUnderline { return existingCurlyUnderline }
      let layer = CAShapeLayer()
      layer.isHidden = true
      attach(layer, rank: 5)
      existingCurlyUnderline = layer
      return layer
    }

    /// Paint order within the container: pill, outgoing, text, effect,
    /// overline, curly underline — whatever order they are first used in.
    private func attach(_ layer: CALayer, rank: Int) {
      layer.actions = OverlayPanel.noActions
      let ordered: [CALayer?] = [
        existingPill, existingOutgoing, text, existingEffect, existingOverline,
        existingCurlyUnderline,
      ]
      let below = ordered.prefix(rank).compactMap { $0 }.count
      container.insertSublayer(layer, at: UInt32(below))
    }

    /// Every animation on the run's layers, created or not yet.
    func removeAllAnimations() {
      text.removeAllAnimations()
      for layer in [existingOutgoing, existingEffect, existingOverline, existingCurlyUnderline] {
        layer?.removeAllAnimations()
      }
    }
  }

  /// A run to draw: its cells, its container frame in the host layer, and the
  /// text band inside that container.
  struct Item {
    var run: StatusFormatLayout.PositionedRun
    var frame: CGRect
    var textRect: CGRect
  }

  /// The bar's mode pill. Without one (a widget), `#[pill]` draws as text.
  struct Pill {
    var palette: OverlayPanel.ModeBadgePalette
    var modeStyle: OverlayModeBadgeStyle
    /// Pill texts padded to the reserved cells, and the label each shows.
    var labels: [(padded: String, label: String)]
  }

  /// What the last `render` had to touch, for the render trace.
  struct RenderStats: Equatable {
    var visible = 0
    var changed = 0
    var crossfades = 0
    var cycles = 0
  }

  private(set) var runLayers: [RunLayer] = []
  private(set) var lastRenderStats = RenderStats()
  private var previousRuns: [StatusFormatLayout.PositionedRun] = []

  static let cycleAnimationKey = "flashCycle"
  static let crossfadeAnimationKey = "flashCrossfade"
  static let effectAnimationKey = "flashEffect"
  static let cycleTransitionDuration: CFTimeInterval = 0.45
  /// A value ticking in place (a metric sample, the clock) crossfades just
  /// long enough to avoid a hard flicker; anything longer keeps two digit
  /// sets superimposed for a visible share of every second on a 1 Hz bar.
  static let crossfadeDuration: CFTimeInterval = 0.1

  /// Forget what every run layer last drew, so the next `render` redraws each
  /// run's text instead of only the runs whose value changed.
  func invalidateDrawnRuns() {
    for layers in runLayers {
      layers.previous = nil
      layers.previousFont = nil
      layers.previousForeground = nil
    }
  }

  func render(
    _ items: [Item], in host: CALayer, font: NSFont, scale: CGFloat, pill: Pill? = nil
  ) {
    let runs = items.map(\.run)
    let cycling = Self.cycleTransitionIndices(previous: previousRuns, next: runs)
    previousRuns = runs
    let cycleStartedAt = CACurrentMediaTime()
    var stats = RenderStats(visible: items.count)
    for (index, item) in items.enumerated() {
      if index == runLayers.count {
        let layers = RunLayer()
        runLayers.append(layers)
        host.addSublayer(layers.container)
      }
      let layers = runLayers[index]
      let run = item.run
      let rect = item.frame
      let textRect = item.textRect
      let isPill = pill != nil && run.segment.pill
      layers.container.frame = rect
      layers.container.isHidden = false
      layers.container.contentsScale = scale
      let cellBackground = run.segment.reverse ? run.segment.foreground : run.segment.background
      let paintsBackground =
        !isPill && (run.segment.reverse || cellBackground != .defaultBackground)
      layers.container.backgroundColor =
        paintsBackground ? FlashStatusTextColor.nsColor(cellBackground).cgColor : nil
      if let pill, isPill {
        let layer = layers.pill
        layer.frame = textRect
        layer.contentsScale = scale
        layer.isHidden = false
        layer.colors = [pill.palette.bottomCG, pill.palette.topCG]
        layer.borderWidth = pill.modeStyle == .normal ? 1 : 0
        layer.borderColor =
          pill.modeStyle == .normal ? OverlayPanel.statusModeNormalBorderCG : pill.palette.borderCG
      } else {
        layers.existingPill?.isHidden = true
      }
      layers.text.frame = textRect
      layers.text.alignmentMode = isPill ? .center : .left
      layers.text.contentsScale = scale
      layers.text.fontSize = font.pointSize
      var segment = run.segment
      if let pill, isPill {
        segment.text =
          pill.labels.first { $0.padded == segment.text }?.label
          ?? segment.text.trimmingCharacters(in: .whitespaces)
        segment.bold = true
        segment.foreground = .defaultForeground
        segment.background = .defaultBackground
        segment.reverse = false
      }
      let pillForeground = isPill ? pill?.palette.foregroundCG : nil
      let foregroundColor = pillForeground.flatMap { NSColor(cgColor: $0) }
      let allowsTransition = !isPill && !segment.isModeLabel
      if !allowsTransition {
        layers.text.removeAnimation(forKey: Self.cycleAnimationKey)
        layers.text.removeAnimation(forKey: Self.crossfadeAnimationKey)
        layers.existingEffect?.removeAnimation(forKey: Self.cycleAnimationKey)
        layers.existingOutgoing?.removeAllAnimations()
        layers.existingOutgoing?.string = nil
      } else if !segment.cycle, layers.previous?.cycle == true {
        layers.text.removeAnimation(forKey: Self.cycleAnimationKey)
        layers.existingEffect?.removeAnimation(forKey: Self.cycleAnimationKey)
        layers.existingOutgoing?.removeAllAnimations()
      }
      let animated = segment.blink || segment.breathing
      let sameFont = layers.previousFont == font
      let cycles = allowsTransition && cycling.contains(index)
      let changed =
        layers.previous != segment || !sameFont
        || layers.previousForeground != pillForeground || cycles
      // The effect copy is drawn only for an animated run; a later animated
      // value always differs from what a plain one drew, so it redraws then.
      if animated || layers.existingEffect != nil {
        let effect = layers.effect
        effect.frame = textRect
        effect.alignmentMode = layers.text.alignmentMode
        effect.contentsScale = scale
        effect.fontSize = font.pointSize
      }
      if changed {
        stats.changed += 1
        let outgoingString = layers.text.string
        let previousText = layers.previous?.text
        let samePlace = layers.previousFrame == rect && sameFont
        layers.text.string = FlashStatusBarRenderer.attributedStatusStringHidingAnimatedSpans(
          from: [segment], font: font, foregroundColor: foregroundColor)
        layers.text.setNeedsDisplay()
        if animated || layers.existingEffect != nil {
          layers.effect.string = FlashStatusBarRenderer.attributedSegment(
            segment, font: font, foregroundColor: foregroundColor)
          layers.effect.setNeedsDisplay()
        }
        layers.previous = segment
        layers.previousFont = font
        layers.previousForeground = pillForeground
        if cycles {
          stats.cycles += 1
          Self.runCycleTransition(
            layers, outgoing: outgoingString, textRect: textRect, travel: rect.height,
            startedAt: cycleStartedAt)
        } else if allowsTransition, !segment.cycle, samePlace, let previousText,
          previousText != segment.text
        {
          // A value changing in place (a metric tick, the clock) crossfades
          // instead of snapping; a run that moved or was re-segmented does not.
          stats.crossfades += 1
          Self.runCrossfade(layers, outgoing: outgoingString, textRect: textRect)
        }
      }
      layers.previousFrame = rect
      layers.existingEffect?.isHidden = !animated
      if animated {
        if changed || layers.effect.animation(forKey: Self.effectAnimationKey) == nil {
          layers.effect.add(
            FlashStatusBarRenderer.effectOpacityAnimation(
              blink: segment.blink, breathing: segment.breathing, anchoredTo: layers.effect),
            forKey: Self.effectAnimationKey)
        }
      } else {
        layers.existingEffect?.removeAnimation(forKey: Self.effectAnimationKey)
      }
      let foreground = segment.reverse ? segment.background : segment.foreground
      let strokeColor = (foregroundColor ?? FlashStatusTextColor.nsColor(foreground))
        .withAlphaComponent(segment.dim ? 0.6 : 1)
      if segment.overline && !segment.hidden {
        let overline = layers.overline
        overline.isHidden = false
        overline.backgroundColor = strokeColor.cgColor
        overline.frame = CGRect(
          x: 0, y: textRect.maxY - 1, width: rect.width, height: 1 / max(1, scale))
      } else {
        layers.existingOverline?.isHidden = true
      }
      if segment.underline && segment.underlineStyle == .curly && !segment.hidden {
        let curly = layers.curlyUnderline
        curly.isHidden = false
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 2))
        var x: CGFloat = 0
        while x < rect.width {
          path.addQuadCurve(to: CGPoint(x: x + 2, y: 2), control: CGPoint(x: x + 1, y: 4))
          path.addQuadCurve(to: CGPoint(x: x + 4, y: 2), control: CGPoint(x: x + 3, y: 0))
          x += 4
        }
        curly.frame.origin.y = textRect.minY
        curly.path = path
        curly.fillColor = nil
        curly.lineWidth = 1 / max(1, scale)
        curly.strokeColor =
          segment.underlineColor == .defaultForeground
          ? strokeColor.cgColor : FlashStatusTextColor.nsColor(segment.underlineColor).cgColor
      } else {
        layers.existingCurlyUnderline?.isHidden = true
      }
      for decoration in [layers.existingOverline, layers.existingCurlyUnderline].compactMap({ $0 })
      {
        if animated && !decoration.isHidden {
          if changed || decoration.animation(forKey: Self.effectAnimationKey) == nil {
            decoration.add(
              FlashStatusBarRenderer.effectOpacityAnimation(
                blink: segment.blink, breathing: segment.breathing, anchoredTo: decoration),
              forKey: Self.effectAnimationKey)
          }
        } else {
          decoration.removeAnimation(forKey: Self.effectAnimationKey)
        }
      }
    }
    for layers in runLayers.dropFirst(items.count) {
      layers.container.isHidden = true
      layers.removeAllAnimations()
      layers.previous = nil
      layers.previousFrame = nil
    }
    lastRenderStats = stats
  }

  private static func basic(_ keyPath: String, from: CGFloat, to: CGFloat) -> CABasicAnimation {
    let animation = CABasicAnimation(keyPath: keyPath)
    animation.fromValue = from
    animation.toValue = to
    return animation
  }

  private static func prepareOutgoing(_ layers: RunLayer, string: Any?, textRect: CGRect) -> Bool {
    guard let string else { return false }
    let outgoing = layers.outgoing
    outgoing.string = string
    outgoing.frame = textRect
    outgoing.alignmentMode = layers.text.alignmentMode
    outgoing.fontSize = layers.text.fontSize
    outgoing.contentsScale = layers.text.contentsScale
    outgoing.setNeedsDisplay()
    return true
  }

  /// Carousel article change as one vertical push: the old line travels the
  /// full run height up (`travel`, the clipping container's height) and fades
  /// out while the new line rises the same distance from below and fades in,
  /// so the strip visibly enters and leaves through the run's edges. Both
  /// share one duration and the standard ease-in-out curve (cubic-bezier 0.4,
  /// 0, 0.2, 1), so they read as one strip sliding. Every run of one carousel
  /// group shares `startedAt`.
  private static func runCycleTransition(
    _ layers: RunLayer, outgoing: Any?, textRect: CGRect, travel: CGFloat,
    startedAt: CFTimeInterval
  ) {
    let distance = max(travel, textRect.height)
    let beginTime = layers.text.convertTime(startedAt, from: nil)
    let curve = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
    let incoming = CAAnimationGroup()
    incoming.animations = [
      basic("opacity", from: 0, to: 1),
      basic("transform.translation.y", from: -distance, to: 0),
    ]
    incoming.duration = cycleTransitionDuration
    incoming.beginTime = beginTime
    incoming.fillMode = .backwards
    incoming.timingFunction = curve
    layers.text.add(incoming, forKey: cycleAnimationKey)
    layers.existingEffect?.add(incoming, forKey: cycleAnimationKey)
    guard prepareOutgoing(layers, string: outgoing, textRect: textRect) else { return }
    let leaving = CAAnimationGroup()
    leaving.animations = [
      basic("opacity", from: 1, to: 0),
      basic("transform.translation.y", from: 0, to: distance),
    ]
    leaving.duration = cycleTransitionDuration
    leaving.beginTime = beginTime
    leaving.fillMode = .backwards
    leaving.timingFunction = curve
    layers.outgoing.add(leaving, forKey: cycleAnimationKey)
  }

  private static func runCrossfade(_ layers: RunLayer, outgoing: Any?, textRect: CGRect) {
    let fadeIn = basic("opacity", from: 0, to: 1)
    fadeIn.duration = crossfadeDuration
    fadeIn.timingFunction = CAMediaTimingFunction(name: .easeOut)
    layers.text.add(fadeIn, forKey: crossfadeAnimationKey)
    guard prepareOutgoing(layers, string: outgoing, textRect: textRect) else { return }
    let fadeOut = basic("opacity", from: 1, to: 0)
    fadeOut.duration = crossfadeDuration
    fadeOut.timingFunction = CAMediaTimingFunction(name: .easeIn)
    layers.outgoing.add(fadeOut, forKey: crossfadeAnimationKey)
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
      // A lane re-budget (another lane grew, the centre changed) re-truncates
      // the elastic title and can drop the row's tail runs; that is the same
      // article and must not push the carousel.
      let sameArticle = zip(old, new).allSatisfy { before, after in
        sameCarouselArticle(previous[before].segment, next[after].segment)
      }
      if !sameArticle { changed.formUnion(new) }
    }
    return changed
  }

  static func sameCarouselArticle(_ lhs: FlashStatusTextSegment, _ rhs: FlashStatusTextSegment)
    -> Bool
  {
    guard lhs.link == rhs.link, lhs.popup == rhs.popup, lhs.popupContent == rhs.popupContent
    else { return false }
    return truncationEquivalent(lhs.text, rhs.text)
  }

  /// True when one text is the other cut short (with or without the `…`
  /// marker), i.e. they differ only by elastic contraction or lane clamping.
  static func truncationEquivalent(_ lhs: String, _ rhs: String) -> Bool {
    func core(_ text: String) -> Substring {
      var value = Substring(text)
      while let last = value.last, last == "…" || last == " " { value = value.dropLast() }
      return value
    }
    let left = core(lhs)
    let right = core(rhs)
    return left.hasPrefix(right) || right.hasPrefix(left)
  }
}
