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

  /// Repaint only the editable command surface after a keystroke. The status
  /// bars, click windows, panel ordering, and application activation are stable
  /// for the lifetime of the command field and must not be rebuilt per edit.
  func refreshCommandLineContentInPlace() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }

    let panelFrame = frame
    configureCommandPrompt(panelFrame: panelFrame)
    if candidateFinderResultsVisible {
      configureCandidateFinderResults(panelFrame: panelFrame)
    }
    var sublayers = contentLayer.sublayers ?? []
    if commandPromptVisible,
      !sublayers.contains(where: { $0 === commandPromptLayer })
    {
      sublayers.append(commandPromptLayer)
    }
    if candidateFinderResultsVisible {
      if !sublayers.contains(where: { $0 === candidateFinderResultsLayer }) {
        sublayers.append(candidateFinderResultsLayer)
      }
    } else {
      sublayers.removeAll { $0 === candidateFinderResultsLayer }
    }
    contentLayer.sublayers = sublayers
  }

  /// Reassert NORMAL routing without relaying out the persistent status bar or
  /// querying window geometry. With the session tap, changing `inputMode` is
  /// the capture operation; the key-window fallback still needs the full call.
  func recaptureNormalModeKeyboardInput() {
    inputMode = .normal
    modeBadgeCapturesInput = true
    guard !keyboardCaptureActive else { return }
    captureKeyboardInput()
  }

  func setStatusBarModel(_ model: FlashStatusBarModel) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }

    statusAppText = model.appText
    statusBarPopupTexts = model.popupTexts
    statusModePopupName = FlashStatusBarRenderer.popupNameForPill(in: model.modeText)
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
        rightText: text,
        popupTexts: statusBarPopupTexts))
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

  /// Re-lay-out the status bar after a display reconfiguration (a monitor
  /// plugged or unplugged). The primary bar anchors to `NSScreen.main` and the
  /// panel window spans the union of all screens; when a display disappears
  /// both of those move, leaving the bar stranded on coordinates that no longer
  /// exist — which reads as the status bar vanishing from the Mac. The caller
  /// invalidates the screen snapshot first; re-issuing the current badge state
  /// rebuilds the union panel frame, re-lays-out the bar across the surviving
  /// screens (pruning bars for removed displays and adding them for new ones),
  /// and re-orders the panel back into view.
  func statusBarDidChangeScreenParameters() {
    hideStatusBarPopup()
    updateModeBadge(
      text: modeBadgeText,
      visible: modeBadgeVisible,
      captureInput: modeBadgeCapturesInput,
      style: modeBadgeStyle)
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
    let pillLabel = Self.statusLeftText(modeText: pillText)
    let pillWidth = Self.modeBadgeWidth(
      labels: modeLabels,
      currentText: pillText,
      fontSize: modeFontSize)
    let palette = modeBadgePalette()
    let leftTrailingRaw = statusLeftTrailingText.trimmed
    let centreRaw = statusAppText.trimmed
    let rightRaw = Self.statusRightDisplayText(statusRightText)

    let snapshot = OverlayPanel.currentScreenSnapshot()
    let visible = snapshot.mainVisibleFrame
    let mainScreenFrame = snapshot.mainFrame ?? visible
    let mainNotch =
      snapshot.screens.first(where: { $0.frame == snapshot.mainFrame })?.notch ?? nil

    // One layout function for every screen: the primary bar renders through
    // the same code path as the secondaries (via `StatusBarSurface`), so the
    // two can never drift again — and secondaries gain the cycle layer and
    // clickable links the old copy silently lacked.
    var linksByScreen: [(screenFrame: CGRect, links: [(rect: CGRect, url: URL)])] = []
    var popupRegions: [StatusBarPopupRegion] = []
    let primaryInteractions = configureStatusBarSurface(
      PrimaryStatusBarSurface(panel: self),
      screenFrame: mainScreenFrame,
      visibleFrame: visible,
      scale: snapshot.mainScale,
      notch: mainNotch,
      panelFrame: panelFrame,
      fontSize: fontSize,
      modeFontSize: modeFontSize,
      labelFont: labelFont,
      rightFont: rightFont,
      palette: palette,
      pillWidth: pillWidth,
      pillLabel: pillLabel,
      leftTrailingRaw: leftTrailingRaw,
      centreRaw: centreRaw,
      rightRaw: rightRaw)
    linksByScreen.append((screenFrame: mainScreenFrame, links: primaryInteractions.links))
    popupRegions += primaryInteractions.popups

    // Same bar on every other screen, sized to that screen's own native
    // top-band height so a 14"-MBP-with-notch + a square external monitor
    // both see a bar that exactly covers the reserved menu-bar band on
    // their own display. `monitor = "primary"` skips them (and an empty
    // extras list tears down bars from a previous `all` render).
    let extras =
      statusBarMonitor == .primary
      ? []
      : snapshot.screens.filter { $0.frame != snapshot.mainFrame }
    while secondaryStatusBars.count > extras.count {
      let stale = secondaryStatusBars.removeLast()
      stale.backgroundLayer.removeFromSuperlayer()
    }
    while secondaryStatusBars.count < extras.count {
      secondaryStatusBars.append(SecondaryStatusBar())
    }
    for (bar, screen) in zip(secondaryStatusBars, extras) {
      let interactions = configureStatusBarSurface(
        bar,
        screenFrame: screen.frame,
        visibleFrame: screen.visibleFrame,
        scale: screen.scale,
        notch: screen.notch,
        panelFrame: panelFrame,
        fontSize: fontSize,
        modeFontSize: modeFontSize,
        labelFont: labelFont,
        rightFont: rightFont,
        palette: palette,
        pillWidth: pillWidth,
        pillLabel: pillLabel,
        leftTrailingRaw: leftTrailingRaw,
        centreRaw: centreRaw,
        rightRaw: rightRaw)
      linksByScreen.append((screenFrame: screen.frame, links: interactions.links))
      popupRegions += interactions.popups
    }

    if modeBadgeVisible {
      statusBarLinkRectsByScreen = linksByScreen
      // ONE sync carrying every screen's links: the click windows intersect
      // the flat list per band, so secondary-bar links are mouse-clickable
      // now (they used to be hint-only).
      syncStatusBarClickWindows(
        bandRects: statusBarScreenRects(panelFrame: panelFrame, fontSize: fontSize),
        links: linksByScreen.flatMap(\.links),
        popups: popupRegions)
    } else {
      statusBarLinkRectsByScreen = []
      hideStatusBarClickWindows()
    }
  }

  /// Extra points kept clear on each side of a notch (camera housing).
  /// `[statusbar] notch_margin`.
  static var statusBarNotchMargin: CGFloat { CGFloat(FlashTunables.statusBarNotchMargin) }

  /// Lay out ONE screen's bar onto `surface`. This is the single source of
  /// the bar's geometry — the primary bar (via `PrimaryStatusBarSurface`)
  /// and every `SecondaryStatusBar` run through it with their own screen
  /// frame, scale, and notch. Returns the screen-coordinate link rects for
  /// the click windows and the `f`-hint path.
  private func configureStatusBarSurface(
    _ surface: StatusBarSurface,
    screenFrame: CGRect,
    visibleFrame: CGRect,
    scale: CGFloat,
    notch: CGRect?,
    panelFrame: CGRect,
    fontSize: CGFloat,
    modeFontSize: CGFloat,
    labelFont: NSFont,
    rightFont: NSFont,
    palette: ModeBadgePalette,
    pillWidth: CGFloat,
    pillLabel: String,
    leftTrailingRaw: String,
    centreRaw: String,
    rightRaw: String
  ) -> (links: [(rect: CGRect, url: URL)], popups: [StatusBarPopupRegion]) {
    let barFrame = Self.statusBarFrame(
      screenFrame: screenFrame,
      visibleFrame: visibleFrame,
      panelFrame: panelFrame,
      fontSize: fontSize)
    surface.backgroundLayer.frame = Self.snap(barFrame, scale: scale)
    surface.backgroundLayer.contentsScale = scale
    surface.backgroundLayer.opacity = 1
    surface.backgroundLayer.isHidden = false
    surface.backgroundLayer.cornerRadius = 0
    surface.backgroundLayer.borderWidth = 0
    // The panel itself is `isOpaque = false` so the translucent native
    // menu bar above can bleed through any transparent pixels. Set an
    // explicit opaque `backgroundColor` (in addition to the gradient
    // stops) so every pixel of the bar is solid even when the
    // CAGradientLayer renderer does not.
    surface.backgroundLayer.backgroundColor = Self.nordPolarNight0CG
    surface.backgroundLayer.colors = [Self.nordPolarNight0CG, Self.nordPolarNight0CG]
    surface.backgroundLayer.borderColor = Self.nordPolarNight0CG

    let textHeight = fontSize + 4
    let textY = max(0, (barFrame.height - textHeight) / 2)
    let contentX = Self.statusBarEdgePadding
    // The notch in bar-local coordinates (bar x spans the full screen
    // width, so bar-local x = screen x - screenFrame.minX). The bar keeps
    // `statusBarNotchMargin` clear on both sides of it.
    let notchBar = notch.map { rect in
      CGRect(
        x: rect.minX - screenFrame.minX, y: 0, width: rect.width, height: barFrame.height)
    }

    // Pill.
    surface.modeButtonLayer.frame = CGRect(
      x: contentX,
      y: textY,
      width: pillWidth,
      height: textHeight)
    surface.modeButtonLayer.contentsScale = scale
    surface.modeButtonLayer.colors = [palette.bottomCG, palette.topCG]
    // NORMAL mode: a thin, faint hairline so the dark-on-dark pill reads as
    // a framed badge. Other modes have a contrasting fill, so no border.
    if modeBadgeStyle == .normal {
      surface.modeButtonLayer.borderWidth = 1
      surface.modeButtonLayer.borderColor = Self.statusModeNormalBorderCG
    } else {
      surface.modeButtonLayer.borderWidth = 0
      surface.modeButtonLayer.borderColor = palette.borderCG
    }
    surface.modeLabel.frame = CGRect(
      x: 0, y: 0, width: max(1, pillWidth), height: textHeight)
    surface.modeLabel.font = labelFont
    surface.modeLabel.fontSize = modeFontSize
    surface.modeLabel.foregroundColor = palette.foregroundCG
    surface.modeLabel.contentsScale = scale
    surface.modeLabel.alignmentMode = .center
    if surface.lastPill != pillLabel || surface.lastPillStyle != modeBadgeStyle {
      surface.modeLabel.string = NSAttributedString(
        string: pillLabel,
        attributes: [
          .font: labelFont,
          .foregroundColor: NSColor(cgColor: palette.foregroundCG) ?? Self.nordSnowStorm2,
        ])
      surface.lastPill = pillLabel
      surface.lastPillStyle = modeBadgeStyle
    }

    // The right reserve backs the right region off before anything else is
    // placed; the notch (when present) additionally walls off the middle.
    let rightReservedWidth =
      rightRaw.isEmpty
      ? 0
      : min(
        max(Self.statusBarMinimumRightTextWidth, barFrame.width * 0.32),
        barFrame.width * 0.52)
    let rightSectionStart =
      barFrame.width - Self.statusBarEdgePadding
      - (rightReservedWidth > 0 ? rightReservedWidth + Self.statusBarMinimumGap : 0)

    // Anything after `#{mode}` in the left bucket renders as its own
    // tmux-styled run right of the pill — not as part of the bold mode
    // label — so per-segment `#[fg=…]` styling is honoured instead of
    // leaking the pill palette into the trailing text. The run starts flush
    // against the pill's right edge: the gap to whatever follows is driven
    // entirely by the template's own spacing.
    let leftTrailingX = surface.modeButtonLayer.frame.maxX
    // Elastic fit: the `#[shrink]` span in the left run absorbs overflow first
    // so fixed content (the HN label, a story's domain and arrow) keeps its
    // full width whenever possible; the hard fallback trims the whole run.
    // The limit stops at the right section, and never crosses a notch.
    let leftLimit = min(
      rightSectionStart,
      notchBar.map { $0.minX - Self.statusBarNotchMargin } ?? .greatestFiniteMagnitude)
    let leftTrailingDisplay = Self.fitStatusBarText(
      leftTrailingRaw, font: rightFont,
      available: leftLimit - Self.statusBarMinimumGap - leftTrailingX)
    // A `#{cycle:…}` run arrives wrapped in `#[cyc]…#[nocyc]`. Pull it out
    // so it renders in its own clipped layer that can slide vertically,
    // while the static text around it stays in the base layer.
    let (cyclePrefix, cycleContent, cycleSuffix) = Self.splitCycleRun(leftTrailingDisplay)
    let baseDisplay = cyclePrefix + cycleSuffix
    let baseAttributed = FlashStatusBarRenderer.attributedStatusStringHidingAnimatedSpans(
      from: baseDisplay, font: rightFont)
    let baseWidth = baseDisplay.isEmpty ? 0 : ceil(baseAttributed.size().width)
    surface.leftTrailingLabel.frame = CGRect(
      x: leftTrailingX,
      y: textY,
      width: baseWidth,
      height: textHeight)
    surface.leftTrailingLabel.font = rightFont
    surface.leftTrailingLabel.fontSize = fontSize
    surface.leftTrailingLabel.foregroundColor = Self.tmuxGrey245CG
    surface.leftTrailingLabel.contentsScale = scale
    surface.leftTrailingLabel.alignmentMode = .left
    surface.leftTrailingLabel.isHidden = baseDisplay.isEmpty
    surface.lastLeftTrailing = applyStatusText(
      to: surface.leftTrailingLabel,
      display: baseDisplay,
      attributed: baseAttributed,
      previous: surface.lastLeftTrailing)

    var leftTrailingMaxX = surface.leftTrailingLabel.frame.maxX
    if let cycleContent, !cycleContent.isEmpty {
      // Position the cycle run just past the prefix ("· HN "). Clipped to
      // one line height so a push transition slides the current line up and
      // out and the next in from below.
      let prefixWidth =
        cyclePrefix.isEmpty
        ? 0
        : ceil(
          FlashStatusBarRenderer.attributedStatusString(from: cyclePrefix, font: rightFont)
            .size().width)
      let cycleAttributed = FlashStatusBarRenderer.attributedStatusStringHidingAnimatedSpans(
        from: cycleContent, font: rightFont)
      let cycleWidth = ceil(cycleAttributed.size().width)
      surface.cycleLayer.frame = CGRect(
        x: leftTrailingX + prefixWidth, y: textY, width: cycleWidth, height: textHeight)
      surface.cycleLayer.font = rightFont
      surface.cycleLayer.fontSize = fontSize
      surface.cycleLayer.foregroundColor = Self.tmuxGrey245CG
      surface.cycleLayer.contentsScale = scale
      surface.cycleLayer.alignmentMode = .left
      surface.cycleLayer.isHidden = false
      if cycleContent != surface.lastCycle {
        // Animate only a genuine line change — not the first appearance and
        // not a re-render that passes the same line.
        if surface.lastCycle != nil {
          let slide = CATransition()
          slide.type = .push
          slide.subtype = .fromBottom  // next enters from below, current exits up
          slide.duration = 0.42
          slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
          surface.cycleLayer.add(slide, forKey: "cycleSlide")
        }
        surface.cycleLayer.string = cycleAttributed
        surface.cycleLayer.setNeedsDisplay()
        surface.lastCycle = cycleContent
      }
      leftTrailingMaxX = surface.cycleLayer.frame.maxX
    } else {
      surface.cycleLayer.isHidden = true
      surface.lastCycle = nil
    }
    let hasLeftTrailing = !baseDisplay.isEmpty || !(cycleContent ?? "").isEmpty

    // Geometric centring for the `#[align=centre]` bucket. Position around
    // `barFrame.width / 2`, clamped so the centre label never collides with
    // the left run or the reserved right section. If it doesn't fit, trim it
    // inside that lane rather than letting an overlap mangle the bar. A
    // NOTCHED screen hides the centre outright: its honest position is under
    // the camera housing, and shoving it off-centre beside the notch reads
    // worse than not showing it.
    let modeMaxX =
      hasLeftTrailing ? leftTrailingMaxX : surface.modeButtonLayer.frame.maxX
    let centreLimitMaxX = rightSectionStart
    let centreAvailable = max(0, centreLimitMaxX - modeMaxX - Self.statusBarMinimumGap * 2)
    let centreDisplay =
      notchBar == nil
      ? Self.fitStatusBarText(
        centreRaw, font: rightFont, available: centreAvailable)
      : ""
    let centreAttributed = FlashStatusBarRenderer.attributedStatusStringHidingAnimatedSpans(
      from: centreDisplay, font: rightFont)
    let measuredCentreWidth = centreDisplay.isEmpty ? 0 : ceil(centreAttributed.size().width)
    let centreWidth = min(measuredCentreWidth, centreAvailable)
    let centreIdealX = (barFrame.width - centreWidth) / 2
    let centreMinX = modeMaxX + Self.statusBarMinimumGap
    let centreMaxX = centreLimitMaxX - Self.statusBarMinimumGap - centreWidth
    let centreX = max(centreMinX, min(centreIdealX, centreMaxX))
    surface.appLabel.frame = CGRect(
      x: centreX,
      y: textY,
      width: centreWidth,
      height: textHeight)
    surface.appLabel.font = rightFont
    surface.appLabel.fontSize = fontSize
    surface.appLabel.foregroundColor = Self.tmuxGrey245CG
    surface.appLabel.contentsScale = scale
    surface.appLabel.alignmentMode = .center
    surface.appLabel.isHidden = centreDisplay.isEmpty || centreWidth <= 0
    surface.lastCentre = applyStatusText(
      to: surface.appLabel,
      display: centreDisplay,
      attributed: centreAttributed,
      previous: surface.lastCentre)

    // Right section is right-aligned: pin its `maxX` to the bar edge, but
    // derive its left boundary from the ACTUAL centre frame. Subtracting the
    // centre width from the whole bar is insufficient when the centre run is
    // geometrically centred; it lets a long right run start underneath it.
    // On a notched screen the camera housing is another hard left boundary.
    let rightEdge = barFrame.width - Self.statusBarEdgePadding
    let centreBoundary =
      centreWidth > 0 ? surface.appLabel.frame.maxX : modeMaxX
    let notchBoundary =
      notchBar.map { $0.maxX + Self.statusBarNotchMargin } ?? 0
    let rightBoundary = max(
      modeMaxX + Self.statusBarMinimumGap,
      centreBoundary + Self.statusBarMinimumGap,
      notchBoundary)
    let rightAvailable = max(0, rightEdge - rightBoundary)
    // When no explicit `#[shrink]` span exists, keep the rightmost content
    // (typically battery/date) and put the ellipsis at its leading edge.
    let rightDisplay = Self.fitStatusBarText(
      rightRaw, font: rightFont, available: rightAvailable, fromTail: true)
    let measuredRightWidth =
      rightDisplay.isEmpty
      ? 0
      : ceil(
        FlashStatusBarRenderer.attributedStatusString(from: rightDisplay, font: rightFont)
          .size().width)
    let rightWidth = min(rightAvailable, measuredRightWidth)
    let rightX = rightEdge - rightWidth
    surface.rightLabel.frame = CGRect(
      x: rightX,
      y: textY,
      width: rightWidth,
      height: textHeight)
    surface.rightLabel.font = rightFont
    surface.rightLabel.fontSize = fontSize
    surface.rightLabel.foregroundColor = Self.tmuxGrey245CG
    surface.rightLabel.contentsScale = scale
    surface.rightLabel.alignmentMode = .right
    surface.rightLabel.isHidden = rightDisplay.isEmpty
    surface.lastRight = applyStatusText(
      to: surface.rightLabel,
      display: rightDisplay,
      attributed: FlashStatusBarRenderer.attributedStatusStringHidingAnimatedSpans(
        from: rightDisplay, font: rightFont),
      previous: surface.lastRight)

    // Animated spans: pooled overlay layers repaint them at full colour
    // with a repeating render-server opacity animation — the process does
    // ZERO periodic work, even while the battery chip breathes on AC.
    var overlayIndex = 0
    placeEffectOverlays(
      on: surface, raw: baseDisplay, host: surface.backgroundLayer,
      labelFrame: surface.leftTrailingLabel.frame, alignment: .left,
      font: rightFont, scale: scale, nextIndex: &overlayIndex)
    if let cycleContent, !surface.cycleLayer.isHidden {
      placeEffectOverlays(
        on: surface, raw: cycleContent, host: surface.cycleLayer,
        labelFrame: surface.cycleLayer.bounds, alignment: .left,
        font: rightFont, scale: scale, nextIndex: &overlayIndex)
    }
    if !surface.appLabel.isHidden {
      placeEffectOverlays(
        on: surface, raw: centreDisplay, host: surface.backgroundLayer,
        labelFrame: surface.appLabel.frame, alignment: .center,
        font: rightFont, scale: scale, nextIndex: &overlayIndex)
    }
    if !surface.rightLabel.isHidden {
      placeEffectOverlays(
        on: surface, raw: rightDisplay, host: surface.backgroundLayer,
        labelFrame: surface.rightLabel.frame, alignment: .right,
        font: rightFont, scale: scale, nextIndex: &overlayIndex)
    }
    // Park the unused tail of the pool.
    while overlayIndex < surface.effectOverlays.count {
      let layer = surface.effectOverlays[overlayIndex]
      layer.isHidden = true
      layer.removeAnimation(forKey: Self.effectAnimationKey)
      layer.name = nil
      overlayIndex += 1
    }

    // Clickable `#[link=…]` / `#[range=user|…]` runs, in screen coordinates.
    // Measured from the same fitted strings the layers render, so the rects
    // land exactly on the glyphs the user sees (the rotating cycle line's
    // rect tracks whichever line is showing).
    guard modeBadgeVisible else { return ([], []) }
    let linkBarFrame = surface.backgroundLayer.frame
    var links: [(rect: CGRect, url: URL)] = []
    var popups: [StatusBarPopupRegion] = []
    if let name = statusModePopupName,
      let content = statusBarPopupTexts[name],
      !content.isEmpty
    {
      popups.append(
        StatusBarPopupRegion(
          rect: CGRect(
            x: panelFrame.minX + linkBarFrame.minX + surface.modeButtonLayer.frame.minX,
            y: panelFrame.minY + linkBarFrame.minY,
            width: surface.modeButtonLayer.frame.width,
            height: linkBarFrame.height),
          name: name,
          content: content))
    }
    if !surface.leftTrailingLabel.isHidden || !surface.cycleLayer.isHidden {
      links += statusLinkRects(
        raw: leftTrailingDisplay, font: rightFont,
        labelFrame: CGRect(
          x: leftTrailingX, y: surface.leftTrailingLabel.frame.minY,
          width: leftTrailingMaxX - leftTrailingX,
          height: surface.leftTrailingLabel.frame.height),
        alignment: .left,
        barFrame: linkBarFrame, panelFrame: panelFrame)
      popups += statusPopupRects(
        raw: leftTrailingDisplay, popupTexts: statusBarPopupTexts, font: rightFont,
        labelFrame: CGRect(
          x: leftTrailingX, y: surface.leftTrailingLabel.frame.minY,
          width: leftTrailingMaxX - leftTrailingX,
          height: surface.leftTrailingLabel.frame.height),
        alignment: .left,
        barFrame: linkBarFrame, panelFrame: panelFrame)
    }
    if !surface.appLabel.isHidden {
      links += statusLinkRects(
        raw: centreDisplay, font: rightFont,
        labelFrame: surface.appLabel.frame, alignment: .center,
        barFrame: linkBarFrame, panelFrame: panelFrame)
      popups += statusPopupRects(
        raw: centreDisplay, popupTexts: statusBarPopupTexts, font: rightFont,
        labelFrame: surface.appLabel.frame, alignment: .center,
        barFrame: linkBarFrame, panelFrame: panelFrame)
    }
    if !surface.rightLabel.isHidden {
      links += statusLinkRects(
        raw: rightDisplay, font: rightFont,
        labelFrame: surface.rightLabel.frame, alignment: .right,
        barFrame: linkBarFrame, panelFrame: panelFrame)
      popups += statusPopupRects(
        raw: rightDisplay, popupTexts: statusBarPopupTexts, font: rightFont,
        labelFrame: surface.rightLabel.frame, alignment: .right,
        barFrame: linkBarFrame, panelFrame: panelFrame)
    }
    return (links, popups)
  }

  static let effectAnimationKey = "flashEffect"

  /// Paint `raw`'s animated spans onto pooled overlay layers inside `host`.
  /// Each overlay carries a repeating opacity animation built from the
  /// effect-curve oracle; the base layer under it renders the same glyphs
  /// at alpha 0, so geometry is identical and only the overlay pulses.
  /// Re-arming is idempotent — layers dropped from the render tree (bar
  /// hide/show, display changes) lose their animations, so every configure
  /// pass re-attaches missing ones, phase-anchored to the shared clock.
  private func placeEffectOverlays(
    on surface: StatusBarSurface,
    raw: String,
    host: CALayer,
    labelFrame: CGRect,
    alignment: CATextLayerAlignmentMode,
    font: NSFont,
    scale: CGFloat,
    nextIndex: inout Int
  ) {
    let (runs, totalWidth) = FlashStatusBarRenderer.effectRuns(from: raw, font: font)
    guard !runs.isEmpty else { return }
    let pad: CGFloat
    switch alignment {
    case .right:
      pad = max(0, labelFrame.width - totalWidth)
    case .center, .justified:
      pad = max(0, (labelFrame.width - totalWidth) / 2)
    default:
      pad = 0
    }
    for run in runs {
      let layer: CATextLayer
      if nextIndex < surface.effectOverlays.count {
        layer = surface.effectOverlays[nextIndex]
      } else {
        layer = CATextLayer()
        layer.actions = OverlayPanel.noActions
        layer.alignmentMode = .left
        surface.effectOverlays.append(layer)
      }
      nextIndex += 1
      if layer.superlayer !== host {
        layer.removeFromSuperlayer()
        host.addSublayer(layer)
      }
      // Cycle-hosted spans are positioned in the cycle layer's own bounds;
      // bar-hosted spans offset from the region label's frame.
      let originX = (host === surface.cycleLayer ? 0 : labelFrame.minX) + pad + run.xOffset
      let originY = host === surface.cycleLayer ? 0 : labelFrame.minY
      layer.frame = CGRect(
        x: originX, y: originY, width: run.width, height: labelFrame.height)
      layer.contentsScale = scale
      layer.isHidden = false
      let signature =
        "\(run.blink ? "b" : "")\(run.breathing ? "r" : "")|\(run.text.string)"
      if layer.name != signature {
        layer.string = run.text
        layer.setNeedsDisplay()
        layer.name = signature
        layer.removeAnimation(forKey: Self.effectAnimationKey)
      }
      if layer.animation(forKey: Self.effectAnimationKey) == nil {
        layer.add(
          FlashStatusBarRenderer.effectOpacityAnimation(
            blink: run.blink, breathing: run.breathing, anchoredTo: layer),
          forKey: Self.effectAnimationKey)
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
final class SecondaryStatusBar: StatusBarSurface {
  let backgroundLayer = CAGradientLayer()
  let modeButtonLayer = CAGradientLayer()
  let modeLabel = CATextLayer()
  let leftTrailingLabel = CATextLayer()
  let cycleLayer = CATextLayer()
  let appLabel = CATextLayer()
  let rightLabel = CATextLayer()

  // Per-bar render cache — mirrors the primary bar's so an unchanged
  // segment skips its `.string` reassignment + redraw (see `applyStatusText`).
  var lastPill: String?
  var lastPillStyle: OverlayModeBadgeStyle?
  var lastLeftTrailing: String?
  var lastCycle: String?
  var lastCentre: String?
  var lastRight: String?
  var effectOverlays: [CATextLayer] = []

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
    cycleLayer.alignmentMode = .left
    cycleLayer.actions = OverlayPanel.noActions
    cycleLayer.masksToBounds = true
    cycleLayer.isHidden = true
    appLabel.alignmentMode = .left
    appLabel.actions = OverlayPanel.noActions
    rightLabel.alignmentMode = .right
    rightLabel.actions = OverlayPanel.noActions
    modeButtonLayer.sublayers = [modeLabel]
    backgroundLayer.sublayers = [
      appLabel, modeButtonLayer, leftTrailingLabel, cycleLayer, rightLabel,
    ]
  }
}

/// One screen's worth of status-bar layers + render caches. The primary bar
/// (whose layers live directly on `OverlayPanel`) adapts via
/// `PrimaryStatusBarSurface`; each `SecondaryStatusBar` IS one. All layout
/// flows through `configureStatusBarSurface`, so every screen renders
/// through identical code.
protocol StatusBarSurface: AnyObject {
  var backgroundLayer: CAGradientLayer { get }
  var modeButtonLayer: CAGradientLayer { get }
  var modeLabel: CATextLayer { get }
  var leftTrailingLabel: CATextLayer { get }
  var cycleLayer: CATextLayer { get }
  var appLabel: CATextLayer { get }
  var rightLabel: CATextLayer { get }
  var lastPill: String? { get set }
  var lastPillStyle: OverlayModeBadgeStyle? { get set }
  var lastLeftTrailing: String? { get set }
  var lastCycle: String? { get set }
  var lastCentre: String? { get set }
  var lastRight: String? { get set }
  /// Pooled overlay layers for animated (`#[breathing]`/`#[blink]`) spans.
  var effectOverlays: [CATextLayer] { get set }
}

/// Adapter mapping the primary bar's loose `OverlayPanel` layers and caches
/// onto the shared surface shape. Allocated per configure pass (it holds no
/// state of its own).
final class PrimaryStatusBarSurface: StatusBarSurface {
  private unowned let panel: OverlayPanel
  init(panel: OverlayPanel) { self.panel = panel }

  var backgroundLayer: CAGradientLayer { panel.modeBadgeLayer }
  var modeButtonLayer: CAGradientLayer { panel.modeBadgeButtonLayer }
  var modeLabel: CATextLayer { panel.modeBadgeLabel }
  var leftTrailingLabel: CATextLayer { panel.statusLeftTrailingLabel }
  var cycleLayer: CATextLayer { panel.statusLeftTrailingCycleLayer }
  var appLabel: CATextLayer { panel.statusAppLabel }
  var rightLabel: CATextLayer { panel.statusRightLabel }
  var lastPill: String? {
    get { panel.lastRenderedPill }
    set { panel.lastRenderedPill = newValue }
  }
  var lastPillStyle: OverlayModeBadgeStyle? {
    get { panel.lastRenderedPillStyle }
    set { panel.lastRenderedPillStyle = newValue }
  }
  var lastLeftTrailing: String? {
    get { panel.lastRenderedLeftTrailing }
    set { panel.lastRenderedLeftTrailing = newValue }
  }
  var lastCycle: String? {
    get { panel.lastRenderedLeftTrailingCycle }
    set { panel.lastRenderedLeftTrailingCycle = newValue }
  }
  var lastCentre: String? {
    get { panel.lastRenderedCentre }
    set { panel.lastRenderedCentre = newValue }
  }
  var lastRight: String? {
    get { panel.lastRenderedRight }
    set { panel.lastRenderedRight = newValue }
  }
  var effectOverlays: [CATextLayer] {
    get { panel.statusEffectOverlays }
    set { panel.statusEffectOverlays = newValue }
  }
}

extension OverlayPanel {
  /// Fit one rendered status region into a hard pixel budget. The explicit
  /// `#[shrink]` span gets first refusal; when fixed content still overflows,
  /// truncate the complete marker-bearing run without dropping markers so
  /// links, popups, animated spans, and cycle sentinels remain well-scoped.
  /// Right-aligned regions request tail preservation, keeping their terminal
  /// battery/date values visible under pressure.
  static func fitStatusBarText(
    _ raw: String,
    font: NSFont,
    available: CGFloat,
    fromTail: Bool = false
  ) -> String {
    guard !raw.isEmpty, available > 0 else { return "" }
    let elastic = FlashStatusBarRenderer.fitToWidth(raw, font: font, available: available)
    func width(of value: String) -> CGFloat {
      ceil(FlashStatusBarRenderer.attributedStatusString(from: value, font: font).size().width)
    }
    guard width(of: elastic) > available else { return elastic }

    let tokens = FlashStatusBarMarkup.tokenizeValue(raw)
    let visibleCount = FlashStatusBarMarkup.visibleCount(tokens)
    guard visibleCount > 0 else { return "" }

    func truncated(to limit: Int) -> String {
      FlashStatusBarMarkup.serialize(
        FlashStatusBarMarkup.truncate(
          tokens, limit: limit, fromTail: fromTail, ellipsis: true))
    }

    let narrowest = truncated(to: 1)
    guard width(of: narrowest) <= available else { return "" }

    // Find the longest prefix/suffix that fits. Marker-preserving truncation
    // has monotonic visible width for the status bar's monospaced font.
    var low = 1
    var high = max(1, visibleCount - 1)
    var best = narrowest
    while low <= high {
      let mid = low + (high - low) / 2
      let candidate = truncated(to: mid)
      if width(of: candidate) <= available {
        best = candidate
        low = mid + 1
      } else {
        high = mid - 1
      }
    }
    return best
  }

  static func statusLeftText(modeText: String) -> String {
    modeText
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
    if previous != display {
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
