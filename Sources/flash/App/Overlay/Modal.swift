import AppKit
import FlashCore
import QuartzCore

/// Help and `:plugins`-style modal — a scrollable text panel centered on
/// the focused screen. Owns the NSScrollView / NSTextView wiring and
/// the click-outside dismissal monitors.
extension OverlayPanel {
  /// Modal backdrop gradient: dark Polar-Night-ish stops baked once so
  /// `displayModal` doesn't allocate new CGColors per render. All
  /// modal surfaces (help, plugins, mappings, plugin-reload toast)
  /// share these.
  static let modalBackgroundColors: [CGColor] = [
    NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.11, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.14, green: 0.15, blue: 0.18, alpha: 1).cgColor,
  ]
  static let modalBorderCGColor: CGColor =
    NSColor(calibratedRed: 0.30, green: 0.34, blue: 0.40, alpha: 1).cgColor

  func displayModal(_ text: String) {
    FlashLog.trace("[overlay] display_modal chars=\(text.count)")
    transientDisplayToken &+= 1

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer {
      CATransaction.commit()
      captureKeyboardInput()
    }

    let frame = ensurePanelFrame()
    recycleAll()
    commandPromptVisible = false
    inputMode = .modal

    let snapshot = OverlayPanel.currentScreenSnapshot()
    let visible = snapshot.mainVisibleFrame
    let scale = snapshot.mainScale
    let fontSize = max(CGFloat(overlayConfig.fontSize), 13)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let longestLine = lines.map(\.count).max() ?? text.count
    let lineHeight = fontSize + 5
    let width = min(
      max(920, CGFloat(longestLine) * fontSize * 0.60 + 56),
      max(360, visible.width - 32))
    let height = min(
      lineHeight * CGFloat(lines.count) + 34,
      max(260, visible.height - 80))
    let localX = visible.midX - frame.minX - width / 2
    let localY = visible.midY - frame.minY - height / 2

    let chip = dequeueHintLayer()
    chip.frame = Self.snap(
      CGRect(x: localX, y: localY, width: width, height: height),
      scale: scale)
    chip.contentsScale = scale
    chip.colors = Self.modalBackgroundColors
    // Reset chip state — the pool can hand back a chip that was
    // hidden / dimmed by `filter(prefix:)` on a previous activation,
    // and we'd inherit `isHidden = true` here, which is why the help
    // modal was rendering with no visible background.
    chip.isHidden = false
    chip.opacity = 1
    chip.cornerRadius = 8
    chip.borderColor = Self.modalBorderCGColor

    chip.sublayers = nil
    hintLayers.append(chip)
    var sublayers: [CALayer] = [chip]
    appendModeBadgeLayerIfNeeded(to: &sublayers, panelFrame: frame)
    contentLayer.sublayers = sublayers
    configureModalTextView(
      text: text,
      panelLocalFrame: chip.frame.insetBy(dx: 1, dy: 1),
      fontSize: fontSize,
      lineHeight: lineHeight,
      longestLine: longestLine,
      lineCount: lines.count)
    modalScrollView.isHidden = false
    ignoresMouseEvents = false
    installModalDismissMonitors()
    transientContentVisible = true
  }

  func configureModalTextView() {
    modalScrollView.isHidden = true
    modalScrollView.drawsBackground = false
    modalScrollView.borderType = .noBorder
    modalScrollView.hasVerticalScroller = true
    modalScrollView.hasHorizontalScroller = true
    modalScrollView.autohidesScrollers = true
    modalScrollView.scrollerStyle = .overlay
    modalTextView.isEditable = false
    modalTextView.isSelectable = true
    modalTextView.isRichText = false
    modalTextView.importsGraphics = false
    modalTextView.drawsBackground = false
    modalTextView.textColor = Self.nordSnowStorm2
    modalTextView.insertionPointColor = Self.nordSnowStorm2
    modalTextView.allowsUndo = false
    modalTextView.isHorizontallyResizable = true
    modalTextView.isVerticallyResizable = true
    modalTextView.minSize = NSSize(width: 0, height: 0)
    modalTextView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude)
    modalTextView.textContainerInset = NSSize(width: 18, height: 14)
    modalTextView.textContainer?.widthTracksTextView = false
    modalTextView.textContainer?.containerSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude)
    modalScrollView.documentView = modalTextView
  }

  func configureModalTextView(
    text: String,
    panelLocalFrame: CGRect,
    fontSize: CGFloat,
    lineHeight: CGFloat,
    longestLine: Int,
    lineCount: Int
  ) {
    let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
    modalTextView.overlayCoordinator = coordinator
    modalTextView.font = font
    modalTextView.textColor = Self.nordSnowStorm2
    modalTextView.string = text
    modalScrollView.frame = panelLocalFrame
    let contentWidth = max(
      panelLocalFrame.width,
      CGFloat(longestLine) * fontSize * 0.62 + modalTextView.textContainerInset.width * 2 + 24)
    let contentHeight = max(
      panelLocalFrame.height,
      lineHeight * CGFloat(lineCount) + modalTextView.textContainerInset.height * 2 + 8)
    modalTextView.frame = CGRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
    modalTextView.textContainer?.containerSize = NSSize(
      width: contentWidth,
      height: CGFloat.greatestFiniteMagnitude)
    modalTextView.needsDisplay = true
  }

  func hideModalTextView() {
    removeModalDismissMonitors()
    modalScrollView.isHidden = true
    modalTextView.string = ""
    modalTextView.overlayCoordinator = nil
    ignoresMouseEvents = true
    if firstResponder === modalTextView {
      makeFirstResponder(self)
    }
  }
}
