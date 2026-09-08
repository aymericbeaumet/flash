import AppKit
import FlashCore
import QuartzCore

/// The advanced-mode status bar (NORMAL / INSERT / COMMAND). When advanced
/// mode is configured it stays on screen continuously; otherwise it's
/// hidden. The historical "mode badge" identifiers now refer to this
/// status-bar layer to keep the surrounding overlay code stable.
extension OverlayPanel {
  static let statusBarEdgePadding: CGFloat = 13

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

    statusBarModel = model
    statusBarPopupTexts = model.popupTexts
    statusBarPopupDocuments = model.popupDocuments
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
  /// plugged or unplugged). The primary bar anchors to the screen at origin (0, 0), and the
  /// panel window spans the union of all screens; when a display disappears
  /// both of those move, leaving the bar stranded on coordinates that no longer
  /// exist — which reads as the status bar vanishing from the Mac. The caller
  /// invalidates the screen snapshot first; re-issuing the current badge state
  /// rebuilds the union panel frame, re-lays-out the bar across the surviving
  /// screens (pruning bars for removed displays and adding them for new ones),
  /// and re-orders the panel back into view.
  func statusBarDidChangeScreenParameters() {
    if statusPopupController.presentation.isStandalone {
      let snapshot = Self.currentScreenSnapshot()
      let screen =
        snapshot.screens.first { $0.frame.intersects(statusPopupController.frame) }
        ?? snapshot.screens.first { $0.frame == snapshot.mainFrame } ?? snapshot.screens.first
      if let screen { statusPopupController.repositionTerminal(visibleFrame: screen.visibleFrame) }
    } else {
      hideStatusBarPopup()
    }
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
    configureModeBadge(
      panelFrame: panelFrame,
      screenSnapshot: Self.currentScreenSnapshot())
  }

  /// The status-bar surface layout with display geometry supplied explicitly.
  /// Production passes the cached WindowServer snapshot; tests pass a stable
  /// synthetic screen so notch behavior and lane boundaries are deterministic.
  func configureModeBadge(panelFrame: CGRect, screenSnapshot snapshot: ScreenSnapshot) {
    let fontSize = Self.statusBarFontSize(overlayFontSize: CGFloat(overlayConfig.fontSize))
    let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
    let visible = snapshot.mainVisibleFrame
    let mainFrame = snapshot.mainFrame ?? visible
    let mainNotch = snapshot.screens.first(where: { $0.frame == snapshot.mainFrame })?.notch ?? nil
    let extras =
      statusBarMonitor == .primary ? [] : snapshot.screens.filter { $0.frame != snapshot.mainFrame }
    while secondaryStatusBars.count > extras.count {
      secondaryStatusBars.removeLast().backgroundLayer.removeFromSuperlayer()
    }
    while secondaryStatusBars.count < extras.count {
      secondaryStatusBars.append(NativeStatusBarSurface())
    }
    var interactions: [StatusBarScreenInteractions] = []
    let document = statusBarModel.document
    func configure(
      _ surface: NativeStatusBarSurface, screen: CGRect, visible: CGRect,
      scale: CGFloat, notch: CGRect?
    ) {
      surface.render(
        document: document,
        barFrame: Self.statusBarFrame(
          screenFrame: screen, visibleFrame: visible, panelFrame: panelFrame, fontSize: fontSize),
        screenFrame: screen, scale: scale, notch: notch, font: font, labels: modeLabels,
        palette: modeBadgePalette(), modeStyle: modeBadgeStyle)
      let hits = surface.interactionRects(
        panelFrame: panelFrame, popupTexts: statusBarPopupTexts,
        popupDocuments: statusBarPopupDocuments)
      interactions.append(.init(screenFrame: screen, links: hits.links, popups: hits.popups))
    }
    configure(
      primaryStatusBarSurface, screen: mainFrame, visible: visible, scale: snapshot.mainScale,
      notch: mainNotch)
    for (surface, screen) in zip(secondaryStatusBars, extras) {
      configure(
        surface, screen: screen.frame, visible: screen.visibleFrame, scale: screen.scale,
        notch: screen.notch)
    }
    if modeBadgeVisible {
      statusBarInteractionsByScreen = interactions
      syncStatusBarClickWindows(
        bandRects: statusBarScreenRects(panelFrame: panelFrame, fontSize: fontSize),
        links: interactions.flatMap(\.links), popups: interactions.flatMap(\.popups))
    } else {
      statusBarInteractionsByScreen = []
      hideStatusBarClickWindows()
    }
  }

  static var statusBarNotchMargin: CGFloat { CGFloat(FlashTunables.statusBarNotchMargin) }

  static func modeBadgeWidth(
    labels: Config.Mode.Labels,
    currentText _: String,
    fontSize: CGFloat
  ) -> CGFloat {
    max(fontSize + 18, CGFloat(labels.longestCount) * fontSize * 0.66 + 16)
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

extension OverlayPanel {
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
