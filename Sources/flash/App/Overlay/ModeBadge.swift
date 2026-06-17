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
  static let statusBarMaximumAppNameWidth: CGFloat = 220
  static let statusBarMinimumRightTextWidth: CGFloat = 240

  func setModeBadge(text: String, visible: Bool, captureInput: Bool, mode: FlashMode) {
    FlashLog.trace(
      "[overlay] set_mode_badge text=\(text) visible=\(visible) capture=\(captureInput) "
        + "mode=\(mode) input=\(inputMode)")
    let style: OverlayModeBadgeStyle = mode == .normal ? .normal : .insert
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
      }
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
      modeBadgeText = model.modeText
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
    setStatusBarModel(
      FlashStatusBarModel(appText: statusAppText, modeText: modeBadgeText, rightText: text))
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
      if activeWindowBorderVisible {
        sublayers.append(activeWindowBorderLayer)
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
      captureKeyboardInput()
    } else {
      contentLayer.sublayers = nil
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
    let text = modeBadgeText
    let leftWidth = Self.modeBadgeWidth(
      labels: modeLabels,
      currentText: text,
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
    let centreDisplay = FlashStatusBarRenderer.stripClickRanges(from: statusAppText.trimmed)
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
    let leftLabel = Self.statusLeftText(modeText: text)
    modeBadgeButtonLayer.frame = CGRect(
      x: modeX,
      y: textY,
      width: leftWidth,
      height: textHeight)
    modeBadgeButtonLayer.contentsScale = scale
    modeBadgeButtonLayer.colors = [palette.bottomCG, palette.topCG]
    modeBadgeButtonLayer.borderColor = palette.borderCG

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
    modeBadgeLabel.string = NSAttributedString(
      string: leftLabel,
      attributes: [
        .font: labelFont,
        .foregroundColor: NSColor(cgColor: palette.foregroundCG) ?? Self.nordSnowStorm2,
      ])

    // Geometric centring for the `#[align=centre]` bucket. Position
    // around `barFrame.width / 2`, clamped so the centre label never
    // collides with the mode badge on its left or the reserved right
    // section on its right. If the centre text doesn't fit between
    // them, hide it rather than letting an overlap mangle the bar.
    let modeMaxX = modeBadgeButtonLayer.frame.maxX
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
    statusAppLabel.string = centreAttributed
    statusAppLabel.setNeedsDisplay()

    // Right section is right-aligned: pin its `maxX` to the bar edge
    // (minus padding) regardless of where the mode badge or the centre
    // bucket end. This is what the user's "geometric centre" layout
    // expects — the right text is anchored to the right margin, not
    // pushed inward by the centre label's width.
    let rightWidth = max(
      0,
      barFrame.width - modeBadgeButtonLayer.frame.maxX - Self.statusBarMinimumGap
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
    statusRightLabel.string = FlashStatusBarRenderer.attributedStatusString(
      from: rightDisplayText,
      font: rightFont)
    // CATextLayer normally auto-redraws on string change, but a per-tick
    // re-publish that only changes per-glyph alpha occasionally lands on
    // the same backing-store identity check and the layer skips
    // compositing. An explicit `setNeedsDisplay` forces the bitmap to
    // refresh every tick — cheap (short string) and the only knob that
    // reliably renders the breathing effect on the screen.
    statusRightLabel.setNeedsDisplay()

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
    centreDisplay: String,
    rightDisplayText: String
  ) {
    let snapshot = OverlayPanel.currentScreenSnapshot()
    let mainFrame = snapshot.mainFrame
    // Skip the main screen — its bar is the primary one rendered above.
    let extras = snapshot.screens.filter { $0.frame != mainFrame }

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
      bar.modeButtonLayer.borderColor = palette.borderCG

      bar.modeLabel.frame = CGRect(x: 0, y: 0, width: max(1, leftWidth), height: textHeight)
      bar.modeLabel.font = labelFont
      bar.modeLabel.fontSize = modeFontSize
      bar.modeLabel.foregroundColor = palette.foregroundCG
      bar.modeLabel.contentsScale = screen.scale
      bar.modeLabel.string = NSAttributedString(
        string: leftLabel,
        attributes: [
          .font: labelFont,
          .foregroundColor: NSColor(cgColor: palette.foregroundCG) ?? Self.nordSnowStorm2,
        ])

      let centreAttributed = FlashStatusBarRenderer.attributedStatusString(
        from: centreDisplay, font: rightFont)
      let measuredCentreWidth = centreDisplay.isEmpty ? 0 : ceil(centreAttributed.size().width)
      let rightReservedWidth =
        rightDisplayText.isEmpty
        ? 0
        : min(
          max(Self.statusBarMinimumRightTextWidth, barFrame.width * 0.32),
          barFrame.width * 0.52)
      let modeMaxX = bar.modeButtonLayer.frame.maxX
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
      bar.appLabel.string = centreAttributed
      bar.appLabel.setNeedsDisplay()

      let rightWidth = max(
        0,
        barFrame.width - bar.modeButtonLayer.frame.maxX - Self.statusBarMinimumGap
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
      bar.rightLabel.string = FlashStatusBarRenderer.attributedStatusString(
        from: rightDisplayText,
        font: rightFont)
      bar.rightLabel.setNeedsDisplay()
    }
  }

  /// Drop every secondary status bar from the rendered layer tree. Called
  /// when the mode badge goes invisible so we don't keep extra-screen
  /// bars on the wallpaper after advanced mode is disabled.
  func hideSecondaryStatusBars() {
    guard !secondaryStatusBars.isEmpty else { return }
    var sublayers = contentLayer.sublayers ?? []
    for bar in secondaryStatusBars {
      sublayers.removeAll { $0 === bar.backgroundLayer }
    }
    contentLayer.sublayers = sublayers
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
    13
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
  let appLabel = CATextLayer()
  let rightLabel = CATextLayer()

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
    appLabel.alignmentMode = .left
    appLabel.actions = OverlayPanel.noActions
    rightLabel.alignmentMode = .right
    rightLabel.actions = OverlayPanel.noActions
    modeButtonLayer.sublayers = [modeLabel]
    backgroundLayer.sublayers = [appLabel, modeButtonLayer, rightLabel]
  }
}

extension OverlayPanel {
  static func statusLeftText(modeText: String) -> String {
    modeText
  }

  static func statusRightDisplayText(_ statusRightText: String) -> String {
    FlashStatusBarRenderer.stripClickRanges(
      from: statusRightText.trimmed)
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
      || inputMode == .modal
    {
      return transientOverlayWindowLevel
    }
    return persistentStatusWindowLevel
  }

}
