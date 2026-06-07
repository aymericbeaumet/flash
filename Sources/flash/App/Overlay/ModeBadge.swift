import AppKit
import FlashCore
import QuartzCore

/// The mode badge cell (NORMAL / INSERT / COMMAND). When advanced mode
/// is configured it stays on screen continuously; otherwise it's
/// hidden. This file owns the badge gradient layer, its text label, and
/// the helpers that decide when the badge alone is enough to keep the
/// overlay on screen.
extension OverlayPanel {
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
      }
      return
    }

    renderModeBadgeOnlyOrHide()
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
    let fontSize = max(CGFloat(overlayConfig.fontSize), 11)
    let labelFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
    let text = modeBadgeText
    let width = Self.modeBadgeWidth(
      labels: modeLabels,
      currentText: text,
      fontSize: fontSize)
    let height = fontSize + 8
    let snapshot = OverlayPanel.currentScreenSnapshot()
    let visible = snapshot.mainVisibleFrame
    let localX = visible.minX - panelFrame.minX + 10
    let localY = visible.minY - panelFrame.minY + 10
    let scale = snapshot.mainScale
    modeBadgeLayer.frame = Self.snap(
      CGRect(x: localX, y: localY, width: width, height: height),
      scale: scale)
    modeBadgeLayer.contentsScale = scale
    modeBadgeLayer.opacity = 1
    let palette = modeBadgePalette()
    modeBadgeLayer.colors = [palette.bottomCG, palette.topCG]
    modeBadgeLayer.borderColor = palette.borderCG

    modeBadgeLabel.frame = CGRect(x: 0, y: 4, width: width, height: fontSize + 2)
    modeBadgeLabel.font = labelFont
    modeBadgeLabel.fontSize = fontSize
    modeBadgeLabel.foregroundColor = palette.foregroundCG
    modeBadgeLabel.contentsScale = scale
    modeBadgeLabel.string = text
  }

  static func modeBadgeWidth(
    labels: Config.Mode.Labels,
    currentText: String,
    fontSize: CGFloat
  ) -> CGFloat {
    let count = max(labels.longestCount, currentText.count)
    return max(fontSize + 14, CGFloat(count) * fontSize * 0.64 + 14)
  }

}
