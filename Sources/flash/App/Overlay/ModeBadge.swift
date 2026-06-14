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
    guard modeBadgeVisible || commandPromptVisible || candidateFinderResultsVisible else { return }
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
    modeBadgeLayer.colors = [Self.nordPolarNight0CG, Self.nordPolarNight0CG]
    modeBadgeLayer.borderColor = Self.nordPolarNight0CG

    let textHeight = fontSize + 4
    let textY = max(0, (barFrame.height - textHeight) / 2)
    let contentX = Self.statusBarEdgePadding
    let appText = statusAppText.trimmingCharacters(in: .whitespacesAndNewlines)
    let measuredAppWidth = appText.isEmpty
      ? 0
      : ceil((appText as NSString).size(withAttributes: [.font: rightFont]).width)
    let maxAppWidth = max(
      0,
      min(Self.statusBarMaximumAppNameWidth, barFrame.width * 0.22))
    let rightDisplayText = Self.statusRightDisplayText(statusRightText)
    let rightReservedWidth = rightDisplayText.isEmpty
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

    let appX = modeBadgeButtonLayer.frame.maxX + Self.statusBarMinimumGap
    let appAvailableWidth = max(
      0,
      barFrame.width - appX - Self.statusBarEdgePadding
        - (rightReservedWidth > 0 ? Self.statusBarMinimumGap + rightReservedWidth : 0))
    let appWidth = min(measuredAppWidth, maxAppWidth, appAvailableWidth)
    statusAppLabel.frame = CGRect(
      x: appX,
      y: textY,
      width: appWidth,
      height: textHeight)
    statusAppLabel.font = rightFont
    statusAppLabel.fontSize = fontSize
    statusAppLabel.foregroundColor = Self.tmuxGrey245CG
    statusAppLabel.contentsScale = scale
    statusAppLabel.isHidden = appText.isEmpty || appWidth <= 0
    statusAppLabel.string = appText

    let rightX =
      (appWidth > 0 ? statusAppLabel.frame.maxX : modeBadgeButtonLayer.frame.maxX)
      + Self.statusBarMinimumGap
    let rightWidth = max(
      0,
      barFrame.width - rightX - Self.statusBarEdgePadding)
    statusRightLabel.frame = CGRect(
      x: rightX,
      y: textY,
      width: rightWidth,
      height: textHeight)
    statusRightLabel.font = rightFont
    statusRightLabel.fontSize = fontSize
    statusRightLabel.foregroundColor = Self.tmuxGrey245CG
    statusRightLabel.contentsScale = scale
    statusRightLabel.isHidden = rightDisplayText.isEmpty
    statusRightLabel.string = FlashStatusBarRenderer.attributedStatusString(
      from: rightDisplayText,
      font: rightFont)
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

  static func statusLeftText(modeText: String) -> String {
    modeText
  }

  static func statusRightDisplayText(_ statusRightText: String) -> String {
    FlashStatusBarRenderer.stripClickRanges(
      from: statusRightText.trimmingCharacters(in: .whitespacesAndNewlines))
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
