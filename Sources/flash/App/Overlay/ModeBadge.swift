import AppKit
import FlashCore
import QuartzCore

/// The advanced-mode status bar (NORMAL / INSERT / COMMAND). When advanced
/// mode is configured it stays on screen continuously; otherwise it's
/// hidden. The historical "mode badge" identifiers now refer to this
/// status-bar layer to keep the surrounding overlay code stable.
extension OverlayPanel {
  static let statusBarEdgePadding: CGFloat = 13
  static let statusBarMinimumGap: CGFloat = 12
  static let statusBarMinimumRightTextWidth: CGFloat = 240

  func setModeBadge(text: String, visible: Bool, captureInput: Bool, style: OverlayModeBadgeStyle) {
    FlashLog.trace(
      "[overlay] set_mode_badge text=\(text) visible=\(visible) capture=\(captureInput) "
        + "style=\(style) input=\(inputMode)")
    updateModeBadge(text: text, visible: visible, captureInput: captureInput, style: style)
  }

  func updateModeBadge(
    text: String,
    visible: Bool,
    captureInput: Bool,
    style: OverlayModeBadgeStyle
  ) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }

    modeBadgeText = text
    modeBadgeStyle = style
    modeBadgeVisible = visible
    modeBadgeCapturesInput = captureInput
    if style != .command {
      commandPromptVisible = false
      commandCaretLayer.isHidden = true
      hideCommandTextField()
      clearCandidateFinderResults()
    }

    if transientContentVisible {
      var sublayers = contentLayer.sublayers ?? []
      if visible {
        let frame = ensurePanelFrame()
        configureModeBadge(panelFrame: frame)
        configureCommandPrompt(panelFrame: frame)
        configureCandidateFinderResults(panelFrame: frame)
        if !sublayers.contains(where: { $0 === modeBadgeLayer }) {
          sublayers.append(modeBadgeLayer)
        }
        for bar in secondaryStatusBars {
          if !sublayers.contains(where: { $0 === bar.backgroundLayer }) {
            sublayers.append(bar.backgroundLayer)
          }
        }
        if commandPromptVisible,
          !sublayers.contains(where: { $0 === commandPromptLayer })
        {
          sublayers.append(commandPromptLayer)
        } else if !commandPromptVisible {
          sublayers.removeAll { $0 === commandPromptLayer }
        }
        if candidateFinderResultsVisible,
          !sublayers.contains(where: { $0 === candidateFinderResultsLayer })
        {
          sublayers.append(candidateFinderResultsLayer)
        } else if !candidateFinderResultsVisible {
          sublayers.removeAll { $0 === candidateFinderResultsLayer }
        }
      } else {
        sublayers.removeAll { $0 === modeBadgeLayer }
        sublayers.removeAll { $0 === commandPromptLayer }
        sublayers.removeAll { $0 === candidateFinderResultsLayer }
        for bar in secondaryStatusBars {
          sublayers.removeAll { $0 === bar.backgroundLayer }
        }
        hideStatusBarClickWindows()
      }
      appendActiveWindowBorderLayerIfNeeded(to: &sublayers)
      contentLayer.sublayers = sublayers
      if captureInput {
        captureKeyboardInput()
      } else {
        refreshWindowLevelForCurrentContent()
      }
      return
    }

    renderModeBadgeOnlyOrHide()
  }

  func setStatusBarModel(_ model: FlashStatusBarModel) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }

    statusAppText = model.appText
    if !commandPromptVisible {
      let (pill, trailing) = Self.splitLeftRegion(model.modeText)
      modeBadgeText = pill
      statusLeftTrailingText = trailing
    }
    statusRightText = model.rightText
    guard modeBadgeVisible || commandPromptVisible || candidateFinderResultsVisible else {
      return
    }
    let frame = ensurePanelFrame()
    configureModeBadge(panelFrame: frame)
    if commandPromptVisible {
      configureCommandPrompt(panelFrame: frame)
    }
    if candidateFinderResultsVisible {
      configureCandidateFinderResults(panelFrame: frame)
    }
  }

  func setStatusRightText(_ text: String) {
    // Round-trip the left region (pill + trailing) so it isn't dropped by
    // the `splitLeftRegion` in `setStatusBarModel`.
    setStatusBarModel(
      FlashStatusBarModel(
        appText: statusAppText,
        modeText: modeBadgeText + statusLeftTrailingText,
        rightText: text))
  }

  func renderModeBadgeOnlyOrHide() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }

    let frame = ensurePanelFrame()
    let activeWindowBorderVisible = activeWindowBorderLayer.path != nil
    if modeBadgeVisible || activeWindowBorderVisible {
      configureModeBadge(panelFrame: frame)
      configureCommandPrompt(panelFrame: frame)
      configureCandidateFinderResults(panelFrame: frame)
      var sublayers: [CALayer] = []
      appendActiveWindowBorderLayerIfNeeded(to: &sublayers)
      if modeBadgeVisible {
        sublayers.append(modeBadgeLayer)
        for bar in secondaryStatusBars {
          sublayers.append(bar.backgroundLayer)
        }
      }
      if commandPromptVisible {
        sublayers.append(commandPromptLayer)
      }
      if candidateFinderResultsVisible {
        sublayers.append(candidateFinderResultsLayer)
      }
      contentLayer.sublayers = sublayers
      if modeBadgeCapturesInput {
        captureKeyboardInput()
      } else {
        if isKeyWindow {
          orderOut(nil)
        }
        refreshWindowLevelForCurrentContent()
        orderFrontRegardless()
      }
    } else if modeBadgeCapturesInput {
      contentLayer.sublayers = nil
      hideStatusBarClickWindows()
      captureKeyboardInput()
    } else {
      contentLayer.sublayers = nil
      hideStatusBarClickWindows()
      orderOut(nil)
    }
  }

  func orderOutIfNoPersistentContent() {
    guard
      !transientContentVisible,
      !modeBadgeVisible,
      !modeBadgeCapturesInput,
      !commandPromptVisible,
      !candidateFinderResultsVisible,
      activeWindowBorderLayer.path == nil
    else { return }
    orderOut(nil)
  }

  func appendModeBadgeLayerIfNeeded(to sublayers: inout [CALayer], panelFrame: CGRect) {
    guard modeBadgeVisible else { return }
    configureModeBadge(panelFrame: panelFrame)
    sublayers.append(modeBadgeLayer)
    for bar in secondaryStatusBars {
      sublayers.append(bar.backgroundLayer)
    }
    if commandPromptVisible {
      configureCommandPrompt(panelFrame: panelFrame)
      sublayers.append(commandPromptLayer)
    }
    if candidateFinderResultsVisible {
      configureCandidateFinderResults(panelFrame: panelFrame)
      sublayers.append(candidateFinderResultsLayer)
    }
  }

  private func configureModeBadge(panelFrame: CGRect) {
    let fontSize = Self.statusBarFontSize(overlayFontSize: CGFloat(overlayConfig.fontSize))
    let modeFontSize = Self.modeIndicatorFontSize(statusBarFontSize: fontSize)
    let labelFont = NSFont.monospacedSystemFont(ofSize: modeFontSize, weight: .bold)
    let rightFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
    let pillText = modeBadgeText
    let leftTrailingRaw = statusLeftTrailingText
    let leftWidth = Self.modeBadgeWidth(
      labels: modeLabels,
      currentText: pillText,
      fontSize: modeFontSize)
    let snapshot = OverlayPanel.currentScreenSnapshot()
    let visible = snapshot.mainVisibleFrame
    let screenFrame = snapshot.mainFrame ?? visible
    let scale = snapshot.mainScale
    let barFrame = Self.statusBarFrame(
      screenFrame: screenFrame,
      visibleFrame: visible,
      panelFrame: panelFrame,
      fontSize: fontSize)
    modeBadgeLayer.frame = Self.snap(
      barFrame,
      scale: scale)
    modeBadgeLayer.contentsScale = scale
    modeBadgeLayer.opacity = 1
    modeBadgeLayer.isHidden = false
    modeBadgeLayer.cornerRadius = 0
    modeBadgeLayer.borderWidth = 0
    let palette = modeBadgePalette()
    // The panel itself is `isOpaque = false` so the translucent native
    // menu bar above can bleed through any transparent pixels. Set an
    // explicit opaque `backgroundColor` (in addition to the gradient
    // stops) so every pixel of the bar is solid even when the
    // CAGradientLayer renderer does not.
    modeBadgeLayer.backgroundColor = Self.nordPolarNight0CG
    modeBadgeLayer.colors = [Self.nordPolarNight0CG, Self.nordPolarNight0CG]
    modeBadgeLayer.borderColor = Self.nordPolarNight0CG

    let textHeight = fontSize + 4
    let textY = max(0, (barFrame.height - textHeight) / 2)
    let contentX = Self.statusBarEdgePadding
    // `statusAppText` is whatever the template's `#[align=centre]` region
    // produced. It can carry tmux-style style markers, so build the
    // attributed string up front; the rendered width drives the
    // centring math below.
    let centreDisplay = statusAppText.trimmed
    let centreAttributed = FlashStatusBarRenderer.attributedStatusString(
      from: centreDisplay, font: rightFont)
    let measuredCentreWidth = centreDisplay.isEmpty ? 0 : ceil(centreAttributed.size().width)
    let rightDisplayText = Self.statusRightDisplayText(statusRightText)
    let rightReservedWidth =
      rightDisplayText.isEmpty
      ? 0
      : min(
        max(Self.statusBarMinimumRightTextWidth, barFrame.width * 0.32),
        barFrame.width * 0.52)
    let modeX = contentX
    let leftLabel = Self.statusLeftText(modeText: pillText)
    modeBadgeButtonLayer.frame = CGRect(
      x: modeX,
      y: textY,
      width: leftWidth,
      height: textHeight)
    modeBadgeButtonLayer.contentsScale = scale
    modeBadgeButtonLayer.colors = [palette.bottomCG, palette.topCG]
    // NORMAL mode: a thin, faint hairline so the dark-on-dark pill reads as
    // a framed badge. Other modes have a contrasting fill, so no border.
    if modeBadgeStyle == .normal {
      modeBadgeButtonLayer.borderWidth = 1
      modeBadgeButtonLayer.borderColor = Self.statusModeNormalBorderCG
    } else {
      modeBadgeButtonLayer.borderWidth = 0
      modeBadgeButtonLayer.borderColor = palette.borderCG
    }

    modeBadgeLabel.frame = CGRect(
      x: 0,
      y: 0,
      width: max(1, leftWidth),
      height: textHeight)
    modeBadgeLabel.font = labelFont
    modeBadgeLabel.fontSize = modeFontSize
    modeBadgeLabel.foregroundColor = palette.foregroundCG
    modeBadgeLabel.contentsScale = scale
    modeBadgeLabel.alignmentMode = .center
    if lastRenderedPill != leftLabel || lastRenderedPillStyle != modeBadgeStyle {
      modeBadgeLabel.string = NSAttributedString(
        string: leftLabel,
        attributes: [
          .font: labelFont,
          .foregroundColor: NSColor(cgColor: palette.foregroundCG) ?? Self.nordSnowStorm2,
        ])
      lastRenderedPill = leftLabel
      lastRenderedPillStyle = modeBadgeStyle
    }

    // Anything after `#{mode}` in the left bucket renders as its own
    // tmux-styled run right of the pill — not as part of the bold mode
    // label — so per-segment `#[fg=…]` styling is honoured instead of
    // leaking the pill palette into the trailing text.
    let leftTrailingDisplay = leftTrailingRaw.trimmed
    // A `#{cycle:…}` run arrives wrapped in `#[cyc]…#[nocyc]`. Pull it out so it
    // renders in its own clipped layer that can slide vertically, while the
    // static text around it (the pill, the "HN" label) stays in the base layer.
    let (cyclePrefix, cycleContent, cycleSuffix) = Self.splitCycleRun(leftTrailingDisplay)
    let baseDisplay = cyclePrefix + cycleSuffix
    let baseAttributed = FlashStatusBarRenderer.attributedStatusString(
      from: baseDisplay, font: rightFont)
    let baseWidth = baseDisplay.isEmpty ? 0 : ceil(baseAttributed.size().width)
    // Start the trailing run flush against the pill's right edge so the gap
    // to whatever follows is driven entirely by the template's own spacing
    // (e.g. `#{mode} · …`), exactly like every other segment boundary on the
    // bar. A hardcoded gap here would give the pill an inconsistent margin
    // its neighbours don't have. The bar's screen-edge inset stays put: it's
    // `statusBarEdgePadding` on `contentX`, not this gap.
    let leftTrailingX = modeBadgeButtonLayer.frame.maxX
    statusLeftTrailingLabel.frame = CGRect(
      x: leftTrailingX,
      y: textY,
      width: baseWidth,
      height: textHeight)
    statusLeftTrailingLabel.font = rightFont
    statusLeftTrailingLabel.fontSize = fontSize
    statusLeftTrailingLabel.foregroundColor = Self.tmuxGrey245CG
    statusLeftTrailingLabel.contentsScale = scale
    statusLeftTrailingLabel.alignmentMode = .left
    statusLeftTrailingLabel.isHidden = baseDisplay.isEmpty
    lastRenderedLeftTrailing = applyStatusText(
      to: statusLeftTrailingLabel,
      display: baseDisplay,
      attributed: baseAttributed,
      previous: lastRenderedLeftTrailing)

    var leftTrailingMaxX = statusLeftTrailingLabel.frame.maxX
    if let cycleContent, !cycleContent.isEmpty {
      // Position the cycle run just past the prefix ("· HN "). Clipped to one
      // line height so a push transition slides the current line up and out and
      // the next in from below.
      let prefixWidth =
        cyclePrefix.isEmpty
        ? 0
        : ceil(
          FlashStatusBarRenderer.attributedStatusString(from: cyclePrefix, font: rightFont)
            .size().width)
      let cycleAttributed = FlashStatusBarRenderer.attributedStatusString(
        from: cycleContent, font: rightFont)
      let cycleWidth = ceil(cycleAttributed.size().width)
      statusLeftTrailingCycleLayer.frame = CGRect(
        x: leftTrailingX + prefixWidth, y: textY, width: cycleWidth, height: textHeight)
      statusLeftTrailingCycleLayer.font = rightFont
      statusLeftTrailingCycleLayer.fontSize = fontSize
      statusLeftTrailingCycleLayer.foregroundColor = Self.tmuxGrey245CG
      statusLeftTrailingCycleLayer.contentsScale = scale
      statusLeftTrailingCycleLayer.alignmentMode = .left
      statusLeftTrailingCycleLayer.isHidden = false
      if cycleContent != lastRenderedLeftTrailingCycle {
        // Animate only a genuine line change — not the first appearance, and not
        // the effects/refresh re-renders that pass the same line.
        if lastRenderedLeftTrailingCycle != nil {
          let slide = CATransition()
          slide.type = .push
          slide.subtype = .fromBottom  // next enters from below, current exits up
          slide.duration = 0.42
          slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
          statusLeftTrailingCycleLayer.add(slide, forKey: "cycleSlide")
        }
        statusLeftTrailingCycleLayer.string = cycleAttributed
        statusLeftTrailingCycleLayer.setNeedsDisplay()
        lastRenderedLeftTrailingCycle = cycleContent
      }
      leftTrailingMaxX = statusLeftTrailingCycleLayer.frame.maxX
    } else {
      statusLeftTrailingCycleLayer.isHidden = true
      lastRenderedLeftTrailingCycle = nil
    }
    let hasLeftTrailing = !baseDisplay.isEmpty || !(cycleContent ?? "").isEmpty

    // Geometric centring for the `#[align=centre]` bucket. Position
    // around `barFrame.width / 2`, clamped so the centre label never
    // collides with the mode badge (and its trailing run) on its left or
    // the reserved right section on its right. If the centre text doesn't
    // fit between them, hide it rather than letting an overlap mangle the bar.
    let modeMaxX =
      hasLeftTrailing ? leftTrailingMaxX : modeBadgeButtonLayer.frame.maxX
    let rightSectionStart =
      barFrame.width - Self.statusBarEdgePadding
      - (rightReservedWidth > 0 ? rightReservedWidth + Self.statusBarMinimumGap : 0)
    let centreAvailable = max(0, rightSectionStart - modeMaxX - Self.statusBarMinimumGap * 2)
    let centreWidth = min(measuredCentreWidth, centreAvailable)
    let centreIdealX = (barFrame.width - centreWidth) / 2
    let centreMinX = modeMaxX + Self.statusBarMinimumGap
    let centreMaxX = rightSectionStart - Self.statusBarMinimumGap - centreWidth
    let centreX = max(centreMinX, min(centreIdealX, centreMaxX))
    statusAppLabel.frame = CGRect(
      x: centreX,
      y: textY,
      width: centreWidth,
      height: textHeight)
    statusAppLabel.font = rightFont
    statusAppLabel.fontSize = fontSize
    statusAppLabel.foregroundColor = Self.tmuxGrey245CG
    statusAppLabel.contentsScale = scale
    statusAppLabel.alignmentMode = .center
    statusAppLabel.isHidden = centreDisplay.isEmpty || centreWidth <= 0
    lastRenderedCentre = applyStatusText(
      to: statusAppLabel,
      display: centreDisplay,
      attributed: centreAttributed,
      previous: lastRenderedCentre)

    // Right section is right-aligned: pin its `maxX` to the bar edge
    // (minus padding) regardless of where the mode badge or the centre
    // bucket end. This is what the user's "geometric centre" layout
    // expects — the right text is anchored to the right margin, not
    // pushed inward by the centre label's width.
    let rightWidth = max(
      0,
      barFrame.width - modeMaxX - Self.statusBarMinimumGap
        - (centreWidth > 0 ? centreWidth + Self.statusBarMinimumGap * 2 : 0)
        - Self.statusBarEdgePadding)
    let rightX = barFrame.width - Self.statusBarEdgePadding - rightWidth
    statusRightLabel.frame = CGRect(
      x: rightX,
      y: textY,
      width: rightWidth,
      height: textHeight)
    statusRightLabel.font = rightFont
    statusRightLabel.fontSize = fontSize
    statusRightLabel.foregroundColor = Self.tmuxGrey245CG
    statusRightLabel.contentsScale = scale
    statusRightLabel.alignmentMode = .right
    statusRightLabel.isHidden = rightDisplayText.isEmpty
    // Only reassign + force a redraw when the right region actually changed
    // (or is animated — breathing/blink need the per-tick alpha advance).
    // CATextLayer otherwise auto-redraws on a genuine string change; the
    // forced `setNeedsDisplay` inside `applyStatusText` covers the animated
    // case where the glyphs are identical but the alpha moved.
    lastRenderedRight = applyStatusText(
      to: statusRightLabel,
      display: rightDisplayText,
      attributed: FlashStatusBarRenderer.attributedStatusString(
        from: rightDisplayText, font: rightFont),
      previous: lastRenderedRight)

    // Register clickable `#[link=…]` runs on the primary bar. The bar
    // panel is click-through, so each link gets a transparent catcher
    // window placed exactly over its rendered rect.
    let linkBarFrame = modeBadgeLayer.frame
    var links: [(rect: CGRect, url: URL)] = []
    if !statusLeftTrailingLabel.isHidden || !statusLeftTrailingCycleLayer.isHidden {
      // Measured from the full `leftTrailingRaw` (cycle sentinels are
      // zero-width markers), so the rotating title's link rect lands at
      // `prefixWidth` — exactly where the cycle layer draws it. The link rect
      // is recomputed each render, so it tracks whichever line is showing.
      links += statusLinkRects(
        raw: leftTrailingRaw, font: rightFont,
        labelFrame: CGRect(
          x: modeBadgeButtonLayer.frame.maxX, y: statusLeftTrailingLabel.frame.minY,
          width: leftTrailingMaxX - modeBadgeButtonLayer.frame.maxX,
          height: statusLeftTrailingLabel.frame.height),
        alignment: .left,
        barFrame: linkBarFrame, panelFrame: panelFrame)
    }
    if !statusAppLabel.isHidden {
      links += statusLinkRects(
        raw: statusAppText, font: rightFont,
        labelFrame: statusAppLabel.frame, alignment: .center,
        barFrame: linkBarFrame, panelFrame: panelFrame)
    }
    if !statusRightLabel.isHidden {
      links += statusLinkRects(
        raw: statusRightText, font: rightFont,
        labelFrame: statusRightLabel.frame, alignment: .right,
        barFrame: linkBarFrame, panelFrame: panelFrame)
    }
    if modeBadgeVisible {
      // Seed the per-screen link table with the primary bar; the secondary
      // bars append their own screens below. `f` reads this to hint the links
      // on the active window's screen only.
      statusBarLinkRectsByScreen = [(screenFrame: screenFrame, links: links)]
      syncStatusBarClickWindows(
        bandRects: statusBarScreenRects(panelFrame: panelFrame, fontSize: fontSize),
        links: links)
    } else {
      statusBarLinkRectsByScreen = []
      hideStatusBarClickWindows()
    }

    // Same bar on every other screen, sized to that screen's own native
    // top-band height so a 14"-MBP-with-notch + a square external monitor
    // both see a bar that exactly covers the reserved menu-bar band on
    // their own display.
    configureSecondaryStatusBars(
      panelFrame: panelFrame,
      fontSize: fontSize,
      modeFontSize: modeFontSize,
      labelFont: labelFont,
      rightFont: rightFont,
      palette: palette,
      leftWidth: leftWidth,
      leftLabel: leftLabel,
      leftTrailingDisplay: leftTrailingDisplay,
      centreDisplay: centreDisplay,
      rightDisplayText: rightDisplayText)
  }

  /// Mirror the primary bar onto every other `NSScreen`. Configures the
  /// per-screen `SecondaryStatusBar` layer hierarchies; the caller owns
  /// `contentLayer.sublayers` insertion (so this stays mode-agnostic and
  /// can be re-used by the normal / insert / command renderers).
  private func configureSecondaryStatusBars(
    panelFrame: CGRect,
    fontSize: CGFloat,
    modeFontSize: CGFloat,
    labelFont: NSFont,
    rightFont: NSFont,
    palette: ModeBadgePalette,
    leftWidth: CGFloat,
    leftLabel: String,
    leftTrailingDisplay: String,
    centreDisplay: String,
    rightDisplayText: String
  ) {
    let snapshot = OverlayPanel.currentScreenSnapshot()
    let mainFrame = snapshot.mainFrame
    // Skip the main screen — its bar is the primary one rendered above. With
    // `monitor = "primary"`, skip every other screen too (extras empty tears
    // down any bars from a previous `all` render).
    let extras =
      statusBarMonitor == .primary
      ? []
      : snapshot.screens.filter { $0.frame != mainFrame }

    // Shrink the cache before growing it: if a display disconnected the
    // tail bars become orphans whose layers we want to detach.
    while secondaryStatusBars.count > extras.count {
      let stale = secondaryStatusBars.removeLast()
      stale.backgroundLayer.removeFromSuperlayer()
    }
    while secondaryStatusBars.count < extras.count {
      secondaryStatusBars.append(SecondaryStatusBar())
    }

    for (bar, screen) in zip(secondaryStatusBars, extras) {
      let barFrame = Self.statusBarFrame(
        screenFrame: screen.frame,
        visibleFrame: screen.visibleFrame,
        panelFrame: panelFrame,
        fontSize: fontSize)
      bar.backgroundLayer.frame = Self.snap(barFrame, scale: screen.scale)
      bar.backgroundLayer.contentsScale = screen.scale
      bar.backgroundLayer.backgroundColor = Self.nordPolarNight0CG
      bar.backgroundLayer.colors = [Self.nordPolarNight0CG, Self.nordPolarNight0CG]
      bar.backgroundLayer.borderColor = Self.nordPolarNight0CG

      let textHeight = fontSize + 4
      let textY = max(0, (barFrame.height - textHeight) / 2)
      let contentX = Self.statusBarEdgePadding
      let modeX = contentX

      bar.modeButtonLayer.frame = CGRect(
        x: modeX, y: textY, width: leftWidth, height: textHeight)
      bar.modeButtonLayer.contentsScale = screen.scale
      bar.modeButtonLayer.colors = [palette.bottomCG, palette.topCG]
      if modeBadgeStyle == .normal {
        bar.modeButtonLayer.borderWidth = 1
        bar.modeButtonLayer.borderColor = Self.statusModeNormalBorderCG
      } else {
        bar.modeButtonLayer.borderWidth = 0
        bar.modeButtonLayer.borderColor = palette.borderCG
      }

      bar.modeLabel.frame = CGRect(x: 0, y: 0, width: max(1, leftWidth), height: textHeight)
      bar.modeLabel.font = labelFont
      bar.modeLabel.fontSize = modeFontSize
      bar.modeLabel.foregroundColor = palette.foregroundCG
      bar.modeLabel.contentsScale = screen.scale
      if bar.lastPill != leftLabel || bar.lastPillStyle != modeBadgeStyle {
        bar.modeLabel.string = NSAttributedString(
          string: leftLabel,
          attributes: [
            .font: labelFont,
            .foregroundColor: NSColor(cgColor: palette.foregroundCG) ?? Self.nordSnowStorm2,
          ])
        bar.lastPill = leftLabel
        bar.lastPillStyle = modeBadgeStyle
      }

      let leftTrailingAttributed = FlashStatusBarRenderer.attributedStatusString(
        from: leftTrailingDisplay, font: rightFont)
      let leftTrailingWidth =
        leftTrailingDisplay.isEmpty ? 0 : ceil(leftTrailingAttributed.size().width)
      // Flush against the pill's right edge, exactly like the primary bar
      // (see `leftTrailingX` above). The gap to the trailing run is driven
      // entirely by the template's own spacing (e.g. `#{mode} · …`); adding
      // a `statusBarMinimumGap` here gave secondary screens a wider mode↔dot
      // gap than the primary, which read as inconsistent across displays.
      bar.leftTrailingLabel.frame = CGRect(
        x: bar.modeButtonLayer.frame.maxX,
        y: textY,
        width: leftTrailingWidth,
        height: textHeight)
      bar.leftTrailingLabel.font = rightFont
      bar.leftTrailingLabel.fontSize = fontSize
      bar.leftTrailingLabel.foregroundColor = Self.tmuxGrey245CG
      bar.leftTrailingLabel.contentsScale = screen.scale
      bar.leftTrailingLabel.alignmentMode = .left
      bar.leftTrailingLabel.isHidden = leftTrailingDisplay.isEmpty
      bar.lastLeftTrailing = applyStatusText(
        to: bar.leftTrailingLabel,
        display: leftTrailingDisplay,
        attributed: leftTrailingAttributed,
        previous: bar.lastLeftTrailing)

      let centreAttributed = FlashStatusBarRenderer.attributedStatusString(
        from: centreDisplay, font: rightFont)
      let measuredCentreWidth = centreDisplay.isEmpty ? 0 : ceil(centreAttributed.size().width)
      let rightReservedWidth =
        rightDisplayText.isEmpty
        ? 0
        : min(
          max(Self.statusBarMinimumRightTextWidth, barFrame.width * 0.32),
          barFrame.width * 0.52)
      let modeMaxX =
        leftTrailingDisplay.isEmpty
        ? bar.modeButtonLayer.frame.maxX
        : bar.leftTrailingLabel.frame.maxX
      let rightSectionStart =
        barFrame.width - Self.statusBarEdgePadding
        - (rightReservedWidth > 0 ? rightReservedWidth + Self.statusBarMinimumGap : 0)
      let centreAvailable = max(0, rightSectionStart - modeMaxX - Self.statusBarMinimumGap * 2)
      let centreWidth = min(measuredCentreWidth, centreAvailable)
      let centreIdealX = (barFrame.width - centreWidth) / 2
      let centreMinX = modeMaxX + Self.statusBarMinimumGap
      let centreMaxX = rightSectionStart - Self.statusBarMinimumGap - centreWidth
      let centreX = max(centreMinX, min(centreIdealX, centreMaxX))
      bar.appLabel.frame = CGRect(x: centreX, y: textY, width: centreWidth, height: textHeight)
      bar.appLabel.font = rightFont
      bar.appLabel.fontSize = fontSize
      bar.appLabel.foregroundColor = Self.tmuxGrey245CG
      bar.appLabel.contentsScale = screen.scale
      bar.appLabel.alignmentMode = .center
      bar.appLabel.isHidden = centreDisplay.isEmpty || centreWidth <= 0
      bar.lastCentre = applyStatusText(
        to: bar.appLabel,
        display: centreDisplay,
        attributed: centreAttributed,
        previous: bar.lastCentre)

      let rightWidth = max(
        0,
        barFrame.width - modeMaxX - Self.statusBarMinimumGap
          - (centreWidth > 0 ? centreWidth + Self.statusBarMinimumGap * 2 : 0)
          - Self.statusBarEdgePadding)
      let rightX = barFrame.width - Self.statusBarEdgePadding - rightWidth
      bar.rightLabel.frame = CGRect(x: rightX, y: textY, width: rightWidth, height: textHeight)
      bar.rightLabel.font = rightFont
      bar.rightLabel.fontSize = fontSize
      bar.rightLabel.foregroundColor = Self.tmuxGrey245CG
      bar.rightLabel.contentsScale = screen.scale
      bar.rightLabel.alignmentMode = .right
      bar.rightLabel.isHidden = rightDisplayText.isEmpty
      bar.lastRight = applyStatusText(
        to: bar.rightLabel,
        display: rightDisplayText,
        attributed: FlashStatusBarRenderer.attributedStatusString(
          from: rightDisplayText, font: rightFont),
        previous: bar.lastRight)

      // Record this screen's `#[link=…]` rects for the `f` hint path. The
      // secondary bars are click-through (only the primary bar wires click
      // windows), but a hint chip opens the URL directly, so we still want the
      // rects here — computed against this screen's own bar + label frames so
      // the chip lands on the link the user sees on that display. Each region's
      // alignment matches the layer's `alignmentMode` set above (left / centre /
      // right).
      if modeBadgeVisible {
        let secondaryBarFrame = bar.backgroundLayer.frame
        var screenLinks: [(rect: CGRect, url: URL)] = []
        if !bar.leftTrailingLabel.isHidden {
          screenLinks += statusLinkRects(
            raw: statusLeftTrailingText, font: rightFont,
            labelFrame: bar.leftTrailingLabel.frame, alignment: .left,
            barFrame: secondaryBarFrame, panelFrame: panelFrame)
        }
        if !bar.appLabel.isHidden {
          screenLinks += statusLinkRects(
            raw: statusAppText, font: rightFont,
            labelFrame: bar.appLabel.frame, alignment: .center,
            barFrame: secondaryBarFrame, panelFrame: panelFrame)
        }
        if !bar.rightLabel.isHidden {
          screenLinks += statusLinkRects(
            raw: statusRightText, font: rightFont,
            labelFrame: bar.rightLabel.frame, alignment: .right,
            barFrame: secondaryBarFrame, panelFrame: panelFrame)
        }
        statusBarLinkRectsByScreen.append((screenFrame: screen.frame, links: screenLinks))
      }
    }
  }

  static func modeBadgeWidth(
    labels: Config.Mode.Labels,
    currentText: String,
    fontSize: CGFloat
  ) -> CGFloat {
    let count = max(labels.longestCount, currentText.count)
    return max(fontSize + 18, CGFloat(count) * fontSize * 0.66 + 16)
  }

  static func statusBarFontSize(overlayFontSize _: CGFloat) -> CGFloat {
    // `[statusbar] font_size`; the overlay hint size never applied here
    // (the parameter survives only for call-site stability).
    CGFloat(FlashTunables.statusBarFontSize)
  }

  static func modeIndicatorFontSize(statusBarFontSize: CGFloat) -> CGFloat {
    statusBarFontSize
  }

  static func nativeStatusBarFallbackHeight() -> CGFloat {
    currentScreenSnapshot().nativeStatusBarFallbackHeight
  }

  static func nativeStatusBarHeight(
    screenFrame: CGRect,
    visibleFrame: CGRect,
    fallbackHeight: CGFloat = nativeStatusBarFallbackHeight()
  ) -> CGFloat {
    let reservedTopBand = max(0, screenFrame.maxY - visibleFrame.maxY)
    return max(reservedTopBand, max(0, fallbackHeight))
  }

  static func statusBarHeight(
    screenFrame: CGRect,
    visibleFrame: CGRect,
    fontSize _: CGFloat
  ) -> CGFloat {
    nativeStatusBarHeight(screenFrame: screenFrame, visibleFrame: visibleFrame)
  }

  static func statusBarHeight(
    screenFrame: CGRect,
    visibleFrame: CGRect,
    fontSize _: CGFloat,
    fallbackNativeStatusBarHeight: CGFloat
  ) -> CGFloat {
    nativeStatusBarHeight(
      screenFrame: screenFrame,
      visibleFrame: visibleFrame,
      fallbackHeight: fallbackNativeStatusBarHeight)
  }

  static func statusBarFrame(
    screenFrame: CGRect,
    visibleFrame: CGRect,
    panelFrame: CGRect,
    fontSize: CGFloat
  ) -> CGRect {
    let height = statusBarHeight(
      screenFrame: screenFrame,
      visibleFrame: visibleFrame,
      fontSize: fontSize)
    return CGRect(
      x: screenFrame.minX - panelFrame.minX,
      y: screenFrame.maxY - height - panelFrame.minY,
      width: screenFrame.width,
      height: height)
  }
}

/// One status bar rendered on a non-main screen. Mirrors the primary bar's
/// text — mode pill on the left, focused-app name beside it, and the
/// `[statusbar].right` template on the right — but sized to that screen's
/// own native top-band height. Each secondary bar holds its own CALayer
/// set; the layout helper is the same `statusBarFrame` math the primary
/// uses, just fed a different `(screenFrame, visibleFrame)`.
final class SecondaryStatusBar {
  let backgroundLayer = CAGradientLayer()
  let modeButtonLayer = CAGradientLayer()
  let modeLabel = CATextLayer()
  let leftTrailingLabel = CATextLayer()
  let appLabel = CATextLayer()
  let rightLabel = CATextLayer()

  // Per-bar render cache — mirrors the primary bar's so an unchanged
  // segment skips its `.string` reassignment + redraw (see `applyStatusText`).
  var lastPill: String?
  var lastPillStyle: OverlayModeBadgeStyle?
  var lastLeftTrailing: String?
  var lastCentre: String?
  var lastRight: String?

  init() {
    backgroundLayer.cornerRadius = 0
    backgroundLayer.borderWidth = 0
    backgroundLayer.opacity = 1
    backgroundLayer.actions = OverlayPanel.noActions
    modeButtonLayer.cornerRadius = 4
    modeButtonLayer.borderWidth = 0
    modeButtonLayer.actions = OverlayPanel.noActions
    modeLabel.alignmentMode = .center
    modeLabel.actions = OverlayPanel.noActions
    leftTrailingLabel.alignmentMode = .left
    leftTrailingLabel.actions = OverlayPanel.noActions
    appLabel.alignmentMode = .left
    appLabel.actions = OverlayPanel.noActions
    rightLabel.alignmentMode = .right
    rightLabel.actions = OverlayPanel.noActions
    modeButtonLayer.sublayers = [modeLabel]
    backgroundLayer.sublayers = [appLabel, modeButtonLayer, leftTrailingLabel, rightLabel]
  }
}

extension OverlayPanel {
  static func statusLeftText(modeText: String) -> String {
    modeText
  }

  /// True when a rendered region carries an effect marker whose appearance
  /// advances every tick. Such regions must bypass the "skip if unchanged"
  /// cache so the breathing/blink alpha keeps moving.
  static func statusTextAnimated(_ display: String) -> Bool {
    display.contains("#[breathing")
      || display.contains("#[breathe")
      || display.contains("#[blink")
  }

  /// Advance breathing/blink attributes without running status-bar layout.
  ///
  /// Effect ticks do not change text, geometry, link hit targets, screen
  /// inventory, or command-field state. Re-entering `setStatusBarModel` for
  /// every 20-fps tick used to recompute all of those and kept Flash plus
  /// WindowServer busy while otherwise idle. This path rebuilds only the
  /// attributed strings whose effect markers actually depend on time.
  func refreshStatusBarEffects(currentTime: TimeInterval = CACurrentMediaTime()) {
    guard modeBadgeVisible else { return }

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }

    let font = NSFont.monospacedSystemFont(
      ofSize: Self.statusBarFontSize(overlayFontSize: CGFloat(overlayConfig.fontSize)),
      weight: .medium)
    let leftDisplay = statusLeftTrailingText.trimmed
    let centreDisplay = statusAppText.trimmed
    let rightDisplay = Self.statusRightDisplayText(statusRightText)
    let (cyclePrefix, cycleContent, cycleSuffix) = Self.splitCycleRun(leftDisplay)
    refreshAnimatedStatusText(
      on: statusLeftTrailingLabel,
      display: cyclePrefix + cycleSuffix,
      font: font,
      currentTime: currentTime)
    if let cycleContent {
      refreshAnimatedStatusText(
        on: statusLeftTrailingCycleLayer,
        display: cycleContent,
        font: font,
        currentTime: currentTime)
    }
    refreshAnimatedStatusText(
      on: statusAppLabel,
      display: centreDisplay,
      font: font,
      currentTime: currentTime)
    refreshAnimatedStatusText(
      on: statusRightLabel,
      display: rightDisplay,
      font: font,
      currentTime: currentTime)

    // Secondary bars mirror the complete left run in one layer, so refresh
    // that raw display directly instead of applying the primary bar's split
    // cycle-layer representation.
    for bar in secondaryStatusBars {
      refreshAnimatedStatusText(
        on: bar.leftTrailingLabel,
        display: leftDisplay,
        font: font,
        currentTime: currentTime)
      refreshAnimatedStatusText(
        on: bar.appLabel,
        display: centreDisplay,
        font: font,
        currentTime: currentTime)
      refreshAnimatedStatusText(
        on: bar.rightLabel,
        display: rightDisplay,
        font: font,
        currentTime: currentTime)
    }
  }

  private func refreshAnimatedStatusText(
    on layer: CATextLayer,
    display: String,
    font: NSFont,
    currentTime: TimeInterval
  ) {
    guard Self.statusTextAnimated(display) else { return }
    layer.string = FlashStatusBarRenderer.attributedStatusString(
      from: display,
      font: font,
      currentTime: currentTime)
    layer.setNeedsDisplay()
  }

  /// Push `attributed` into `layer` only when the displayed content changed
  /// (or is animated). Reassigning an identical string and forcing a
  /// `setNeedsDisplay()` redraws the layer and is what makes the bar flash
  /// on every app/mode change; skipping it is the whole point. Returns the
  /// new cache value for the caller to store.
  @discardableResult
  func applyStatusText(
    to layer: CATextLayer,
    display: String,
    attributed: @autoclosure () -> NSAttributedString,
    previous: String?
  ) -> String {
    if previous != display || Self.statusTextAnimated(display) {
      layer.string = attributed()
      layer.setNeedsDisplay()
    }
    return display
  }

  /// Split the rendered `#[align=left]` bucket into the mode pill label and
  /// the styled text that follows it. The bucket is `#{mode}` (a plain
  /// label) followed by optional tmux-styled content; the first `#[…]`
  /// marker marks the boundary. Without a marker the whole bucket is the
  /// pill (the default `#[align=left]#{mode}` template), and the trailing
  /// run is empty.
  /// Split a rendered run at its `#[cyc]…#[nocyc]` cycle sentinels into the
  /// static text before it, the rotating content (sentinels removed), and the
  /// text after it. Returns `(raw, nil, "")` when there's no cycle. v1 assumes
  /// at most one cycle per region; anything in the suffix renders in the base
  /// layer (fine when the cycle is the tail of the region, as with HN).
  static func splitCycleRun(_ raw: String) -> (prefix: String, cycle: String?, suffix: String) {
    guard let start = raw.range(of: "#[cyc]"),
      let end = raw.range(of: "#[nocyc]", range: start.upperBound..<raw.endIndex)
    else { return (raw, nil, "") }
    return (
      String(raw[..<start.lowerBound]),
      String(raw[start.upperBound..<end.lowerBound]),
      String(raw[end.upperBound...])
    )
  }

  static func splitLeftRegion(_ modeText: String) -> (pill: String, trailing: String) {
    // The engine wraps the resolved `#{mode}` in `#[pill]…#[nopill]`
    // sentinels, so the pill is exactly the mode label wherever it sits and
    // whatever styling surrounds it. Text before/after the pill both render
    // in the trailing label (which visually follows the badge).
    if let open = modeText.range(of: "#[pill]"),
      let close = modeText.range(of: "#[nopill]", range: open.upperBound..<modeText.endIndex)
    {
      let pill = String(modeText[open.upperBound..<close.lowerBound])
      let trailing =
        String(modeText[..<open.lowerBound]) + String(modeText[close.upperBound...])
      return (pill, trailing)
    }
    // No `#{mode}` in the left region: legacy split — everything before the
    // first marker is the pill (a marker-free region is all pill).
    guard let markerRange = modeText.range(of: "#[") else {
      return (modeText, "")
    }
    let pill = String(modeText[..<markerRange.lowerBound])
    let trailing = String(modeText[markerRange.lowerBound...])
    return (pill, trailing)
  }

  static func statusRightDisplayText(_ statusRightText: String) -> String {
    statusRightText.trimmed
  }

  func refreshWindowLevelForCurrentContent() {
    let target = Self.windowLevelForOverlayContent(
      inputMode: inputMode,
      commandPromptVisible: commandPromptVisible,
      candidateFinderResultsVisible: candidateFinderResultsVisible,
      transientContentVisible: transientContentVisible)
    if level != target {
      level = target
    }
  }

  static func windowLevelForOverlayContent(
    inputMode: OverlayInputMode,
    commandPromptVisible: Bool,
    candidateFinderResultsVisible: Bool,
    transientContentVisible: Bool
  ) -> NSWindow.Level {
    if transientContentVisible
      || commandPromptVisible
      || candidateFinderResultsVisible
      || inputMode == .commandLine
      || inputMode == .candidateFinder
    {
      return transientOverlayWindowLevel
    }
    return persistentStatusWindowLevel
  }

}
