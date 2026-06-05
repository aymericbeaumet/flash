import AppKit
import FlashCore
import QuartzCore

enum OverlayModeBadgeStyle {
  case insert
  case normal
  case command
}

struct AppFinderDisplayItem: Equatable {
  var title: String
  var highlightedRanges: [Range<Int>] = []
  var isSelected: Bool
}

final class OverlayPanel: NSPanel {
  private static let appFinderMaxRows = 6

  private let contentLayer = CALayer()
  private var hintLayers: [CAGradientLayer] = []
  private var labelLayers: [CATextLayer] = []
  private var hintLayerPool: [CAGradientLayer] = []
  private var labelLayerPool: [CATextLayer] = []
  private let modeBadgeLayer = CAGradientLayer()
  private let modeBadgeLabel = CATextLayer()
  private let commandPromptLayer = CALayer()
  private let commandPromptLabel = CATextLayer()
  private let commandInputField = CommandInputField()
  private let appFinderResultsLayer = CALayer()
  private let appFinderResultsLabel = CATextLayer()
  private let focusIndicatorLayer = CAShapeLayer()
  private var modeBadgeVisible = false
  private var modeBadgeText = "INSERT"
  private var modeBadgeStyle: OverlayModeBadgeStyle = .insert
  private var modeBadgeCapturesInput = false
  private var commandPromptVisible = false
  private var commandPromptPrefix = ":"
  private var appFinderResultsVisible = false
  private var appFinderResultsMeasurementText = ""
  private var appFinderResultsAttributedText: NSAttributedString?
  private var focusIndicatorToken: UInt64 = 0
  private var transientContentVisible = false
  private var isUpdatingCommandInputField = false

  /// One shape layer holds every debug border, drawn as a single CGPath. This
  /// is one GPU draw call regardless of how many targets are visible —
  /// vs. N CALayers which previously caused a perceptible stutter when debug
  /// mode was on with 300+ hints.
  private let debugShapeLayer = CAShapeLayer()
  private var lastTargetLocalRects: [CGRect] = []

  weak var coordinator: OverlayCoordinator?

  var overlayConfig: Config.Overlay = .init()
  var debugConfig: Config.Debug = .init()
  var modeLabels: Config.Mode.Labels = .init()
  var magicModifiers: ClickModifiers = .defaultMagic
  var inputMode: OverlayInputMode = .hints
  var normalModePending: String = ""
  var normalModeMappings: [ModeMapping] = Config.Mode.defaultNormalMappings
  var commandLineText: String = "" {
    didSet { commandLineCursorIndex = min(commandLineCursorIndex, commandLineText.count) }
  }
  var commandLineCursorIndex: Int = 0 {
    didSet { commandLineCursorIndex = min(max(commandLineCursorIndex, 0), commandLineText.count) }
  }
  var appFinderQuery: String = ""

  // Fallback border colour when the configured `hint_border` is malformed.
  private static let fallbackBorderCGColor = NSColor.black.withAlphaComponent(0.4).cgColor

  init() {
    let frame = OverlayPanel.unionScreenFrame()
    super.init(
      contentRect: frame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    self.level = .screenSaver
    self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    self.isOpaque = false
    self.backgroundColor = .clear
    self.hasShadow = false
    self.animationBehavior = .none
    self.ignoresMouseEvents = true
    self.hidesOnDeactivate = false
    self.isReleasedWhenClosed = false
    self.acceptsMouseMovedEvents = false
    self.becomesKeyOnlyIfNeeded = false

    let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
    view.wantsLayer = true
    view.layer = contentLayer
    contentLayer.frame = view.bounds
    contentLayer.actions = OverlayPanel.noActions

    debugShapeLayer.fillColor = NSColor.clear.cgColor
    debugShapeLayer.strokeColor = NSColor.systemPink.cgColor
    debugShapeLayer.lineWidth = 1
    debugShapeLayer.isHidden = true
    debugShapeLayer.actions = OverlayPanel.noActions
    contentLayer.addSublayer(debugShapeLayer)

    modeBadgeLayer.cornerRadius = 4
    modeBadgeLayer.borderWidth = 1
    modeBadgeLayer.opacity = 1
    modeBadgeLayer.actions = OverlayPanel.noActions
    modeBadgeLabel.alignmentMode = .center
    modeBadgeLabel.actions = OverlayPanel.noActions
    modeBadgeLayer.sublayers = [modeBadgeLabel]
    commandPromptLayer.cornerRadius = 4
    commandPromptLayer.borderWidth = 1
    commandPromptLayer.actions = OverlayPanel.noActions
    commandPromptLabel.alignmentMode = .left
    commandPromptLabel.actions = OverlayPanel.noActions
    commandPromptLayer.sublayers = [commandPromptLabel]
    commandInputField.isHidden = true
    commandInputField.focusRingType = .none
    commandInputField.isBordered = false
    commandInputField.isBezeled = false
    commandInputField.drawsBackground = false
    commandInputField.isEditable = true
    commandInputField.isSelectable = true
    commandInputField.usesSingleLineMode = true
    commandInputField.cell?.wraps = false
    commandInputField.cell?.isScrollable = true
    commandInputField.commandDelegate = self
    appFinderResultsLayer.cornerRadius = 4
    appFinderResultsLayer.borderWidth = 1
    appFinderResultsLayer.actions = OverlayPanel.noActions
    appFinderResultsLabel.alignmentMode = .left
    appFinderResultsLabel.actions = OverlayPanel.noActions
    appFinderResultsLayer.sublayers = [appFinderResultsLabel]
    focusIndicatorLayer.fillColor = NSColor.clear.cgColor
    focusIndicatorLayer.strokeColor = NSColor.systemTeal.cgColor
    focusIndicatorLayer.lineWidth = 2
    focusIndicatorLayer.actions = OverlayPanel.noActions

    self.contentView = view
    view.addSubview(commandInputField)
  }

  /// Allocate `count` chip+label layers and stash them in the pools. Called
  /// once at app launch to keep the first-activation layer allocation cost
  /// off the hot path.
  func warmPool(count: Int) {
    hintLayerPool.reserveCapacity(count)
    labelLayerPool.reserveCapacity(count)
    for _ in 0..<count {
      hintLayerPool.append(makeChipLayer())
      labelLayerPool.append(makeLabelLayer())
    }
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
  override var acceptsFirstResponder: Bool { true }

  /// Active scroll event monitor — non-nil while the overlay is up.
  /// We use NSEvent's *global* monitor for `.scrollWheel` because the
  /// panel has `ignoresMouseEvents = true` so scroll events go to
  /// whichever app is under the cursor, not to us. A global monitor
  /// observes those events without intercepting them, which is what
  /// we want: dismiss the overlay but let the user's scroll reach
  /// the underlying app uninterrupted. The local monitor catches the
  /// (rare) case where the overlay or another Flash window is
  /// frontmost when a scroll arrives — without this the user could
  /// scroll our own UI without dismissing.
  private var scrollGlobalMonitor: Any?
  private var scrollLocalMonitor: Any?
  private var clickGlobalMonitor: Any?
  private var clickLocalMonitor: Any?

  func display(hints: [AssignedHint]) {
    FlashLog.trace("[overlay] display hints=\(hints.count) input=\(inputMode)")
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer {
      CATransaction.commit()
      captureKeyboardInput()
      installInputMonitors()
    }

    let frame = OverlayPanel.unionScreenFrame()
    if self.frame != frame {
      self.setFrame(frame, display: false)
      self.contentView?.frame = NSRect(origin: .zero, size: frame.size)
      contentLayer.frame = contentView?.bounds ?? .zero
    }

    recycleAll()
    transientContentVisible = true
    commandPromptVisible = false

    let bgTop = nsColor(fromHex: overlayConfig.hintBGTop) ?? .systemYellow
    let bgBottom = nsColor(fromHex: overlayConfig.hintBGBottom) ?? bgTop
    let fg = nsColor(fromHex: overlayConfig.hintFG) ?? .black
    let border = nsColor(fromHex: overlayConfig.hintBorder)
    let fontSize = CGFloat(overlayConfig.fontSize)
    // Resolve per-screen backing scale per chip below — but precompute
    // a sorted list of (screen, frameInPanelLocal) pairs once so the
    // per-chip lookup is a tight linear scan over (usually) one or two
    // screens. Hint chips render fuzzy when contentsScale doesn't match
    // the host screen's backingScaleFactor, so on a mixed-DPI dual-
    // monitor setup the chip layer's scale must follow the screen the
    // chip lands on, not `NSScreen.main`.
    let screensInPanel: [(scale: CGFloat, panelRect: CGRect)] = {
      let panelOrigin = frame.origin
      return NSScreen.screens.map { s in
        let r = CGRect(
          x: s.frame.minX - panelOrigin.x,
          y: s.frame.minY - panelOrigin.y,
          width: s.frame.width,
          height: s.frame.height
        )
        return (s.backingScaleFactor, r)
      }
    }()
    let fallbackScale =
      NSScreen.main?.backingScaleFactor ?? screensInPanel.first?.scale ?? 2

    // Hoisted out of the per-chip loop: colors, font, and chip height
    // are identical for every chip in this activation. Chip *width*
    // is per-hint — `HintAssigner` now packs singles + 2-char labels
    // in the same activation (so the user can commit a 1-key hint
    // whenever the target count allows), and using a single uniform
    // width sized to the first hint clipped/squished every label
    // with a different length.
    let gradientColors: [CGColor] = [bgBottom.cgColor, bgTop.cgColor]
    let fgCG = fg.cgColor
    let borderCG = border?.cgColor ?? OverlayPanel.fallbackBorderCGColor
    // Single weight, bold monospaced — labels always render in bold so
    // small chips stay readable. Once the user has typed a prefix,
    // those leading characters re-render at 30% alpha via
    // `attributedLabel(...)`; the weight stays bold so glyph advance
    // and therefore chip width don't change across keystrokes.
    let labelFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
    let chipHeight = Self.chipHeight(forFontSize: fontSize)
    let labelYOffset = (chipHeight - fontSize - 2) / 2
    let labelHeight = fontSize + 2
    // The full label space in HintAssigner caps out at a handful of
    // distinct lengths (usually 1 and 2). Cache `chipWidth` by length
    // so we pay the arithmetic once per distinct length, not per chip.
    var widthByLen: [Int: CGFloat] = [:]
    widthByLen.reserveCapacity(2)

    let debugEnabled = debugConfig.showBounds
    if debugEnabled {
      debugShapeLayer.strokeColor =
        (nsColor(fromHex: debugConfig.boundsFG) ?? NSColor.systemPink).cgColor
      debugShapeLayer.fillColor = (nsColor(fromHex: debugConfig.boundsBG) ?? NSColor.clear).cgColor
    }
    lastTargetLocalRects.removeAll(keepingCapacity: true)
    if debugEnabled {
      lastTargetLocalRects.reserveCapacity(hints.count)
    }

    // Build sublayers off-tree, then batch-attach with a single
    // assignment to `contentLayer.sublayers`. The previous approach
    // (N `addSublayer` calls) was N tree mutations on the host layer,
    // each of which triggers AppKit's needs-display bookkeeping.
    var newSublayers: [CALayer] = []
    newSublayers.reserveCapacity(hints.count + 1)
    if debugEnabled {
      newSublayers.append(debugShapeLayer)
    }

    hintLayers.reserveCapacity(hints.count)
    labelLayers.reserveCapacity(hints.count)

    for hint in hints {
      let targetFrame = hint.target.frame
      let local = CGRect(
        x: targetFrame.minX - frame.minX,
        y: targetFrame.minY - frame.minY,
        width: targetFrame.width,
        height: targetFrame.height
      )
      if debugEnabled {
        lastTargetLocalRects.append(local)
      }

      let chip = dequeueHintLayer()
      // The chip pool retains visual state across activations. If the
      // previous overlay was dismissed mid-filter (e.g. by typing the
      // first character of a hint), most chips were `isHidden = true`.
      // Without this reset, the next activation pulls hidden chips out
      // of the pool and the user sees only the debug outlines.
      chip.isHidden = false
      let label = dequeueLabelLayer()
      label.isHidden = false
      // CATextLayer's own `font` + `fontSize` properties are the
      // authoritative source for weight + size; the per-attribute
      // `.font` in the attributed string is treated as a hint and is
      // unreliable for the system monospaced face (SF Mono). Setting
      // both keeps every codepath that touches the layer in
      // lockstep, including when chips are reused from the pool with
      // a stale regular-weight font from a previous render.
      label.font = labelFont
      label.fontSize = fontSize
      label.string = Self.attributedLabel(
        display: hint.display, typedPrefixLen: 0,
        font: labelFont, fgNS: fg)
      label.foregroundColor = fgCG

      let labelLen = hint.display.count
      let chipW: CGFloat
      if let cached = widthByLen[labelLen] {
        chipW = cached
      } else {
        chipW = Self.chipWidth(forLabelLength: labelLen, fontSize: fontSize)
        widthByLen[labelLen] = chipW
      }
      label.frame = CGRect(
        x: 0, y: labelYOffset, width: chipW, height: labelHeight)

      let chipGlobal = Self.chipFrame(
        target: targetFrame,
        width: chipW,
        height: chipHeight
      )
      let chipLocal = CGRect(
        x: chipGlobal.minX - frame.minX,
        y: chipGlobal.minY - frame.minY,
        width: chipGlobal.width,
        height: chipGlobal.height
      )
      // Pick the screen this chip is rendered on so the chip and its
      // label use the correct backing scale. Without this the gradient
      // chip + 1px border + text were rasterised at NSScreen.main's
      // scale even when the host window was on a different-DPI
      // display, which looked muddy/blurry.
      let chipMid = CGPoint(x: chipLocal.midX, y: chipLocal.midY)
      var chipScale = fallbackScale
      for sp in screensInPanel where sp.panelRect.contains(chipMid) {
        chipScale = sp.scale
        break
      }
      // Snap to device-pixel grid so the 1pt border lands on integer
      // device-pixels (otherwise it gets anti-aliased into two half-
      // intensity rows and reads as pixelated).
      chip.frame = Self.snap(chipLocal, scale: chipScale)
      chip.contentsScale = chipScale
      chip.colors = gradientColors
      chip.borderColor = borderCG
      label.contentsScale = chipScale

      chip.sublayers = [label]
      newSublayers.append(chip)
      hintLayers.append(chip)
      labelLayers.append(label)
    }
    appendModeBadgeLayerIfNeeded(to: &newSublayers, panelFrame: frame)

    contentLayer.sublayers = newSublayers
    if debugEnabled {
      rebuildDebugPath(visibleIndices: nil)
      debugShapeLayer.isHidden = false
    } else {
      debugShapeLayer.isHidden = true
      debugShapeLayer.path = nil
    }
  }

  private func rebuildDebugPath(visibleIndices: Set<Int>?) {
    let path = CGMutablePath()
    for (idx, rect) in lastTargetLocalRects.enumerated() {
      if let visibleIndices, !visibleIndices.contains(idx) { continue }
      path.addRect(rect)
    }
    debugShapeLayer.path = path
  }

  static let noActions: [String: CAAction] = [
    "position": NSNull(), "bounds": NSNull(), "frame": NSNull(),
    "transform": NSNull(), "contents": NSNull(), "hidden": NSNull(),
    "opacity": NSNull(), "backgroundColor": NSNull(), "cornerRadius": NSNull(),
    "borderWidth": NSNull(), "borderColor": NSNull(), "foregroundColor": NSNull(),
    "onOrderIn": NSNull(), "onOrderOut": NSNull(), "sublayers": NSNull(),
    "path": NSNull(), "strokeColor": NSNull(), "fillColor": NSNull(), "lineWidth": NSNull(),
    "colors": NSNull(),
  ]

  func hide() {
    FlashLog.trace(
      "[overlay] hide transient=\(transientContentVisible) mode_badge=\(modeBadgeVisible) "
        + "capture=\(modeBadgeCapturesInput) input=\(inputMode)")
    removeInputMonitors()
    transientContentVisible = false
    commandPromptVisible = false
    commandPromptPrefix = ":"
    commandInputField.isHidden = true
    clearAppFinderResults()
    commandLineText = ""
    commandLineCursorIndex = 0
    appFinderQuery = ""
    recycleAll()
    renderModeBadgeOnlyOrHide()
  }

  private func captureKeyboardInput() {
    FlashLog.trace("[overlay] capture_keyboard key_before=\(isKeyWindow) input=\(inputMode)")
    orderFrontRegardless()
    makeKey()
    if inputMode == .commandLine {
      makeFirstResponder(commandInputField)
    } else {
      makeFirstResponder(self)
    }
  }

  func setModeBadge(text: String, visible: Bool, captureInput: Bool, mode: FlashMode) {
    FlashLog.trace(
      "[overlay] set_mode_badge text=\(text) visible=\(visible) capture=\(captureInput) "
        + "mode=\(mode) input=\(inputMode)")
    let style: OverlayModeBadgeStyle = mode == .normal ? .normal : .insert
    updateModeBadge(text: text, visible: visible, captureInput: captureInput, style: style)
  }

  private func updateModeBadge(
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
      commandInputField.isHidden = true
      clearAppFinderResults()
    }

    if transientContentVisible {
      var sublayers = contentLayer.sublayers ?? []
      if visible {
        let frame = ensurePanelFrame()
        configureModeBadge(panelFrame: frame)
        configureCommandPrompt(panelFrame: frame)
        configureAppFinderResults(panelFrame: frame)
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
        if appFinderResultsVisible,
          !sublayers.contains(where: { $0 === appFinderResultsLayer })
        {
          sublayers.append(appFinderResultsLayer)
        } else if !appFinderResultsVisible {
          sublayers.removeAll { $0 === appFinderResultsLayer }
        }
      } else {
        sublayers.removeAll { $0 === modeBadgeLayer }
        sublayers.removeAll { $0 === commandPromptLayer }
        sublayers.removeAll { $0 === appFinderResultsLayer }
      }
      contentLayer.sublayers = sublayers
      if captureInput {
        captureKeyboardInput()
      }
      return
    }

    renderModeBadgeOnlyOrHide()
  }

  /// Install (idempotent) the dismissal event monitors. Calling this
  /// twice is safe — the second call removes the previous monitors
  /// before installing fresh ones.
  ///
  /// Dismissal triggers: scroll wheel, any mouse-button press. Mouse
  /// move is intentionally NOT a dismissal trigger because the
  /// pointer can drift past the overlay while the user is reaching
  /// for a key. Non-matching keystrokes are dismissed by
  /// `AppDelegate.overlayDidCommit` when no hint label matches the
  /// running prefix.
  private func installInputMonitors() {
    removeInputMonitors()
    let dismiss: () -> Void = { [weak self] in
      // Hop to main to keep all coordinator interactions on the same
      // thread as display(). NSEvent monitors fire on main already,
      // but the local-monitor closure may return synchronously; the
      // dispatch ensures we don't reentrantly tear down the monitor
      // while it's executing.
      DispatchQueue.main.async {
        self?.coordinator?.overlayDidCancel()
      }
    }
    let pointerDismiss: () -> Void = { [weak self] in
      DispatchQueue.main.async {
        self?.coordinator?.overlayDidCancelByPointer()
      }
    }
    scrollGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { _ in
      dismiss()
    }
    scrollLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
      dismiss()
      return event
    }
    // Mouse-button presses (single, double, or right click) dismiss
    // immediately. The user has clearly chosen a different action
    // than typing a hint; keep the overlay out of the way. The
    // local monitor catches clicks on the overlay/Flash itself —
    // without it the overlay would persist if the user clicked one
    // of its chips.
    let clickMask: NSEvent.EventTypeMask = [
      .leftMouseDown, .rightMouseDown, .otherMouseDown,
    ]
    clickGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: clickMask) { _ in
      pointerDismiss()
    }
    clickLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: clickMask) { event in
      pointerDismiss()
      return event
    }
  }

  private func removeInputMonitors() {
    for m in [scrollGlobalMonitor, scrollLocalMonitor, clickGlobalMonitor, clickLocalMonitor] {
      if let m { NSEvent.removeMonitor(m) }
    }
    scrollGlobalMonitor = nil
    scrollLocalMonitor = nil
    clickGlobalMonitor = nil
    clickLocalMonitor = nil
  }

  /// Show a transient banner centered on the focused screen. Multi-line strings (with
  /// `\n`) are rendered as wrapped text. Used to signal edge cases (no targets,
  /// Accessibility denied) — staying within the "transparent hint overlay only" UI rule.
  func displayBanner(_ text: String, durationMs: Int? = 700) {
    bannerToken &+= 1
    let myToken = bannerToken

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer {
      CATransaction.commit()
      orderFrontRegardless()
    }

    let frame = OverlayPanel.unionScreenFrame()
    if self.frame != frame {
      self.setFrame(frame, display: false)
      self.contentView?.frame = NSRect(origin: .zero, size: frame.size)
      contentLayer.frame = contentView?.bounds ?? .zero
    }
    recycleAll()

    let fontSize = max(CGFloat(overlayConfig.fontSize), 16)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let longestLine = lines.map(\.count).max() ?? text.count

    let label = dequeueLabelLayer()
    label.string = text
    label.fontSize = fontSize
    label.foregroundColor = (nsColor(fromHex: overlayConfig.hintFG) ?? .black).cgColor
    label.alignmentMode = .center
    label.isWrapped = true
    label.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
    label.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)

    let lineHeight = fontSize + 6
    let approxWidth = CGFloat(longestLine) * fontSize * 0.62 + 40
    let chipHeight = lineHeight * CGFloat(lines.count) + 16
    let centerX: CGFloat
    let centerY: CGFloat
    if let main = NSScreen.main {
      centerX = main.frame.midX - frame.minX
      centerY = main.frame.midY - frame.minY
    } else {
      centerX = (contentView?.bounds.midX ?? 0)
      centerY = (contentView?.bounds.midY ?? 0)
    }

    let chip = dequeueHintLayer()
    chip.frame = CGRect(
      x: centerX - approxWidth / 2, y: centerY - chipHeight / 2, width: approxWidth,
      height: chipHeight)
    let bannerTop = nsColor(fromHex: overlayConfig.hintBGTop) ?? .systemYellow
    let bannerBottom = nsColor(fromHex: overlayConfig.hintBGBottom) ?? bannerTop
    chip.colors = [bannerBottom.cgColor, bannerTop.cgColor]
    chip.cornerRadius = 6
    chip.borderColor =
      nsColor(fromHex: overlayConfig.hintBorder)?.cgColor ?? OverlayPanel.fallbackBorderCGColor
    let textHeight = lineHeight * CGFloat(lines.count)
    label.frame = CGRect(
      x: 8, y: (chipHeight - textHeight) / 2, width: approxWidth - 16, height: textHeight)
    chip.sublayers = [label]
    var sublayers: [CALayer] = [chip]
    appendModeBadgeLayerIfNeeded(to: &sublayers, panelFrame: frame)
    contentLayer.sublayers = sublayers
    transientContentVisible = true
    hintLayers.append(chip)
    labelLayers.append(label)

    if let durationMs {
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(durationMs)) { [weak self] in
        // Only hide if a newer banner hasn't replaced us — otherwise we'd hide it early.
        guard let self, self.bannerToken == myToken else { return }
        self.hide()
      }
    }
  }

  private var bannerToken: UInt64 = 0

  func displayHelp(_ text: String) {
    FlashLog.trace("[overlay] display_help chars=\(text.count)")
    bannerToken &+= 1

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer {
      CATransaction.commit()
      captureKeyboardInput()
    }

    let frame = ensurePanelFrame()
    recycleAll()
    commandPromptVisible = false
    inputMode = .help

    let screen = NSScreen.main ?? NSScreen.screens.first
    let visible = screen?.visibleFrame ?? frame
    let scale = screen?.backingScaleFactor ?? 2
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
    chip.colors = [
      NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.11, alpha: 1).cgColor,
      NSColor(calibratedRed: 0.14, green: 0.15, blue: 0.18, alpha: 1).cgColor,
    ]
    chip.cornerRadius = 8
    chip.borderColor = NSColor(calibratedRed: 0.30, green: 0.34, blue: 0.40, alpha: 1).cgColor

    let label = dequeueLabelLayer()
    label.frame = CGRect(x: 18, y: 16, width: width - 36, height: height - 30)
    label.contentsScale = scale
    label.alignmentMode = .left
    label.isWrapped = false
    label.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
    label.fontSize = fontSize
    label.foregroundColor = NSColor(calibratedRed: 0.91, green: 0.93, blue: 0.96, alpha: 1).cgColor
    label.string = text

    chip.sublayers = [label]
    hintLayers.append(chip)
    labelLayers.append(label)
    var sublayers: [CALayer] = [chip]
    appendModeBadgeLayerIfNeeded(to: &sublayers, panelFrame: frame)
    contentLayer.sublayers = sublayers
    transientContentVisible = true
  }

  func displayCommandLine(
    _ text: String,
    suggestions: [AppFinderDisplayItem]? = nil,
    cursorIndex: Int? = nil
  ) {
    FlashLog.trace(
      "[overlay] display_command_line text=\(text) cursor=\(cursorIndex ?? text.count) "
        + "suggestions=\(suggestions?.count ?? 0)")
    inputMode = .commandLine
    commandLineText = text
    commandLineCursorIndex = cursorIndex ?? text.count
    updateCommandInputField(text: commandLineText, cursorIndex: commandLineCursorIndex)
    commandPromptVisible = true
    commandPromptPrefix = ":"
    if let suggestions {
      setAppFinderResults(items: suggestions, emptyText: "no matching app")
    } else {
      clearAppFinderResults()
    }
    updateModeBadge(text: modeLabels.command, visible: true, captureInput: true, style: .command)
  }

  func displayAppFinder(query: String, items: [AppFinderDisplayItem]) {
    FlashLog.trace("[overlay] display_app_finder query=\(query) items=\(items.count)")
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer {
      CATransaction.commit()
      captureKeyboardInput()
    }

    appFinderQuery = query
    commandInputField.isHidden = true
    inputMode = .appFinder
    commandLineText = query
    commandLineCursorIndex = query.count
    commandPromptPrefix = "Applications> "
    commandPromptVisible = true
    setAppFinderResults(items: items, emptyText: "no matching app")
    updateModeBadge(text: modeLabels.command, visible: true, captureInput: true, style: .command)
  }

  func displayFocusIndicator(around targetFrame: CGRect, durationMs: Int = 1_200) {
    guard !targetFrame.isNull, targetFrame.width > 0, targetFrame.height > 0 else { return }
    focusIndicatorToken &+= 1
    let token = focusIndicatorToken

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer {
      CATransaction.commit()
      orderFrontRegardless()
    }

    let panelFrame = ensurePanelFrame()
    let local = CGRect(
      x: targetFrame.minX - panelFrame.minX - 4,
      y: targetFrame.minY - panelFrame.minY - 4,
      width: targetFrame.width + 8,
      height: targetFrame.height + 8)
    let scale = NSScreen.main?.backingScaleFactor ?? NSScreen.screens.first?.backingScaleFactor ?? 2
    let snapped = Self.snap(local, scale: scale)
    let path = CGMutablePath()
    path.addRoundedRect(in: snapped, cornerWidth: 5, cornerHeight: 5)
    focusIndicatorLayer.frame = contentLayer.bounds
    focusIndicatorLayer.path = path
    focusIndicatorLayer.strokeColor = NSColor.systemTeal.cgColor
    focusIndicatorLayer.fillColor = NSColor.clear.cgColor
    focusIndicatorLayer.lineWidth = 2

    var sublayers = contentLayer.sublayers ?? []
    if !sublayers.contains(where: { $0 === focusIndicatorLayer }) {
      sublayers.append(focusIndicatorLayer)
    }
    contentLayer.sublayers = sublayers

    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(durationMs)) { [weak self] in
      guard let self, self.focusIndicatorToken == token else { return }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      self.focusIndicatorLayer.path = nil
      var sublayers = self.contentLayer.sublayers ?? []
      sublayers.removeAll { $0 === self.focusIndicatorLayer }
      self.contentLayer.sublayers = sublayers
      CATransaction.commit()
      self.renderModeBadgeOnlyOrHide()
    }
  }

  private struct ModeBadgePalette {
    var top: NSColor
    var bottom: NSColor
    var foreground: NSColor
    var border: NSColor
  }

  private func ensurePanelFrame() -> CGRect {
    let frame = OverlayPanel.unionScreenFrame()
    if self.frame != frame {
      self.setFrame(frame, display: false)
      self.contentView?.frame = NSRect(origin: .zero, size: frame.size)
      contentLayer.frame = contentView?.bounds ?? .zero
    }
    return frame
  }

  private func renderModeBadgeOnlyOrHide() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }

    let frame = ensurePanelFrame()
    if modeBadgeVisible {
      configureModeBadge(panelFrame: frame)
      configureCommandPrompt(panelFrame: frame)
      configureAppFinderResults(panelFrame: frame)
      var sublayers: [CALayer] = [modeBadgeLayer]
      if commandPromptVisible {
        sublayers.append(commandPromptLayer)
      }
      if appFinderResultsVisible {
        sublayers.append(appFinderResultsLayer)
      }
      if focusIndicatorLayer.path != nil {
        sublayers.append(focusIndicatorLayer)
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

  private func appendModeBadgeLayerIfNeeded(to sublayers: inout [CALayer], panelFrame: CGRect) {
    guard modeBadgeVisible else { return }
    configureModeBadge(panelFrame: panelFrame)
    sublayers.append(modeBadgeLayer)
    if commandPromptVisible {
      configureCommandPrompt(panelFrame: panelFrame)
      sublayers.append(commandPromptLayer)
    }
    if appFinderResultsVisible {
      configureAppFinderResults(panelFrame: panelFrame)
      sublayers.append(appFinderResultsLayer)
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
    let screen = NSScreen.main ?? NSScreen.screens.first
    let visible = screen?.visibleFrame ?? panelFrame
    let localX = visible.minX - panelFrame.minX + 10
    let localY = visible.minY - panelFrame.minY + 10
    let scale = screen?.backingScaleFactor ?? 2
    modeBadgeLayer.frame = Self.snap(
      CGRect(x: localX, y: localY, width: width, height: height),
      scale: scale)
    modeBadgeLayer.contentsScale = scale
    modeBadgeLayer.opacity = 1
    let palette = modeBadgePalette()
    modeBadgeLayer.colors = [
      palette.bottom.cgColor,
      palette.top.cgColor,
    ]
    modeBadgeLayer.borderColor = palette.border.cgColor

    modeBadgeLabel.frame = CGRect(x: 0, y: 3, width: width, height: fontSize + 2)
    modeBadgeLabel.font = labelFont
    modeBadgeLabel.fontSize = fontSize
    modeBadgeLabel.foregroundColor = palette.foreground.cgColor
    modeBadgeLabel.contentsScale = scale
    modeBadgeLabel.string = text
  }

  private func configureCommandPrompt(panelFrame: CGRect) {
    guard commandPromptVisible else { return }
    let fontSize = max(CGFloat(overlayConfig.fontSize), 11)
    let labelFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
    let prompt: String
    if inputMode == .commandLine {
      prompt = commandPromptPrefix
    } else {
      let cursor = min(max(commandLineCursorIndex, 0), commandLineText.count)
      let cursorStringIndex = commandLineText.index(commandLineText.startIndex, offsetBy: cursor)
      let commandWithCursor =
        String(commandLineText[..<cursorStringIndex]) + "|"
        + String(commandLineText[cursorStringIndex...])
      prompt = "\(commandPromptPrefix)\(commandWithCursor)"
    }
    let screen = NSScreen.main ?? NSScreen.screens.first
    let visible = screen?.visibleFrame ?? panelFrame
    let scale = screen?.backingScaleFactor ?? 2
    let gap: CGFloat = 6
    let height = modeBadgeLayer.frame.height
    let localX = modeBadgeLayer.frame.maxX + gap
    let localY = modeBadgeLayer.frame.minY
    let maxWidth = max(120, visible.maxX - panelFrame.minX - localX - 10)
    let measuredCount =
      inputMode == .commandLine
      ? max(commandPromptPrefix.count + commandLineText.count, commandPromptPrefix.count + 14)
      : prompt.count
    let width = min(max(96, CGFloat(measuredCount) * fontSize * 0.62 + 18), maxWidth)
    commandPromptLayer.frame = Self.snap(
      CGRect(x: localX, y: localY, width: width, height: height),
      scale: scale)
    commandPromptLayer.contentsScale = scale
    commandPromptLayer.backgroundColor =
      NSColor(calibratedRed: 0.02, green: 0.02, blue: 0.025, alpha: 1).cgColor
    commandPromptLayer.borderColor =
      NSColor(calibratedRed: 0.23, green: 0.24, blue: 0.27, alpha: 1).cgColor

    let promptWidth = min(
      width - 8,
      max(10, CGFloat(commandPromptPrefix.count) * fontSize * 0.62 + 6))
    commandPromptLabel.frame = CGRect(
      x: 4,
      y: 3,
      width: inputMode == .commandLine ? promptWidth : width - 8,
      height: fontSize + 2)
    commandPromptLabel.font = labelFont
    commandPromptLabel.fontSize = fontSize
    commandPromptLabel.foregroundColor =
      NSColor(calibratedRed: 0.94, green: 0.95, blue: 0.97, alpha: 1).cgColor
    commandPromptLabel.contentsScale = scale
    commandPromptLabel.alignmentMode = .left
    commandPromptLabel.string = prompt

    if inputMode == .commandLine {
      commandInputField.isHidden = false
      commandInputField.font = labelFont
      commandInputField.textColor =
        NSColor(calibratedRed: 0.94, green: 0.95, blue: 0.97, alpha: 1)
      commandInputField.frame = CGRect(
        x: commandPromptLayer.frame.minX + promptWidth,
        y: commandPromptLayer.frame.minY + 1,
        width: max(20, commandPromptLayer.frame.width - promptWidth - 6),
        height: commandPromptLayer.frame.height - 2)
    } else {
      commandInputField.isHidden = true
    }
  }

  private func updateCommandInputField(text: String, cursorIndex: Int) {
    isUpdatingCommandInputField = true
    commandInputField.stringValue = text
    if let editor = commandInputField.currentEditor() {
      editor.string = text
      editor.selectedRange = NSRange(
        location: min(max(cursorIndex, 0), text.count),
        length: 0)
    }
    isUpdatingCommandInputField = false
  }

  private func clearAppFinderResults() {
    appFinderResultsVisible = false
    appFinderResultsMeasurementText = ""
    appFinderResultsAttributedText = nil
  }

  private func setAppFinderResults(items: [AppFinderDisplayItem], emptyText: String) {
    let shownItems = Array(items.prefix(Self.appFinderMaxRows))
    if shownItems.isEmpty {
      appFinderResultsMeasurementText = emptyText
      appFinderResultsAttributedText = NSAttributedString(
        string: emptyText,
        attributes: [
          .font: NSFont.monospacedSystemFont(
            ofSize: max(CGFloat(overlayConfig.fontSize), 11),
            weight: .medium),
          .foregroundColor: NSColor(calibratedRed: 0.62, green: 0.65, blue: 0.70, alpha: 1),
        ])
      appFinderResultsVisible = true
      return
    }

    // Text draws top-to-bottom, so reverse the visible window: rank 1
    // appears on the bottom row, closest to the command line.
    let visualItems = Array(shownItems.reversed())
    let fontSize = max(CGFloat(overlayConfig.fontSize), 11)
    let baseFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
    let selectedFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
    let highlightFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
    let baseColor = NSColor(calibratedRed: 0.91, green: 0.93, blue: 0.96, alpha: 1)
    let selectedColor = NSColor.white
    let highlightColor = NSColor(calibratedRed: 1.00, green: 0.87, blue: 0.25, alpha: 1)
    let markerColor = NSColor(calibratedRed: 0.46, green: 0.73, blue: 1.00, alpha: 1)
    let attributed = NSMutableAttributedString()
    var plainLines: [String] = []

    for item in visualItems {
      if attributed.length > 0 {
        attributed.append(NSAttributedString(string: "\n", attributes: [.font: baseFont]))
      }
      let marker = item.isSelected ? "> " : "  "
      let line = marker + item.title
      plainLines.append(line)
      let lineAttributed = NSMutableAttributedString(
        string: line,
        attributes: [
          .font: item.isSelected ? selectedFont : baseFont,
          .foregroundColor: item.isSelected ? selectedColor : baseColor,
        ])
      if item.isSelected {
        lineAttributed.addAttribute(
          .foregroundColor,
          value: markerColor,
          range: NSRange(location: 0, length: min(1, lineAttributed.length)))
      }
      for range in item.highlightedRanges {
        guard range.lowerBound >= 0, range.upperBound <= item.title.count else { continue }
        let titleStart = line.index(line.startIndex, offsetBy: marker.count)
        guard
          let lower = line.index(
            titleStart,
            offsetBy: range.lowerBound,
            limitedBy: line.endIndex),
          let upper = line.index(
            titleStart,
            offsetBy: range.upperBound,
            limitedBy: line.endIndex)
        else { continue }
        let nsRange = NSRange(lower..<upper, in: line)
        lineAttributed.addAttributes(
          [.foregroundColor: highlightColor, .font: highlightFont],
          range: nsRange)
      }
      attributed.append(lineAttributed)
    }

    appFinderResultsMeasurementText = plainLines.joined(separator: "\n")
    appFinderResultsAttributedText = attributed
    appFinderResultsVisible = true
  }

  private func configureAppFinderResults(panelFrame: CGRect) {
    guard appFinderResultsVisible else { return }
    let fontSize = max(CGFloat(overlayConfig.fontSize), 11)
    let labelFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
    let screen = NSScreen.main ?? NSScreen.screens.first
    let visible = screen?.visibleFrame ?? panelFrame
    let scale = screen?.backingScaleFactor ?? 2
    let lines = appFinderResultsMeasurementText.split(
      separator: "\n",
      omittingEmptySubsequences: false)
    let lineCount = max(lines.count, 1)
    let longest = lines.map(\.count).max() ?? appFinderResultsMeasurementText.count
    let lineHeight = fontSize + 5
    let x = commandPromptLayer.frame.minX
    let maxWidth = max(180, visible.maxX - panelFrame.minX - x - 10)
    let width = min(max(220, CGFloat(longest) * fontSize * 0.62 + 18), maxWidth)
    let height = lineHeight * CGFloat(lineCount) + 10
    let y = commandPromptLayer.frame.maxY + 6

    appFinderResultsLayer.frame = Self.snap(
      CGRect(x: x, y: y, width: width, height: height),
      scale: scale)
    appFinderResultsLayer.contentsScale = scale
    appFinderResultsLayer.backgroundColor =
      NSColor(calibratedRed: 0.02, green: 0.02, blue: 0.025, alpha: 1).cgColor
    appFinderResultsLayer.borderColor =
      NSColor(calibratedRed: 0.23, green: 0.24, blue: 0.27, alpha: 1).cgColor

    appFinderResultsLabel.frame = CGRect(x: 7, y: 5, width: width - 14, height: height - 10)
    appFinderResultsLabel.font = labelFont
    appFinderResultsLabel.fontSize = fontSize
    appFinderResultsLabel.foregroundColor =
      NSColor(calibratedRed: 0.91, green: 0.93, blue: 0.96, alpha: 1).cgColor
    appFinderResultsLabel.contentsScale = scale
    appFinderResultsLabel.alignmentMode = .left
    appFinderResultsLabel.string =
      appFinderResultsAttributedText ?? NSAttributedString(string: appFinderResultsMeasurementText)
  }

  private func modeBadgePalette() -> ModeBadgePalette {
    switch modeBadgeStyle {
    case .insert:
      return ModeBadgePalette(
        top: Self.nordPolarNight1,
        bottom: Self.nordPolarNight0,
        foreground: Self.nordFrost2,
        border: Self.nordFrost2)
    case .normal:
      return ModeBadgePalette(
        top: Self.nordPolarNight1,
        bottom: Self.nordPolarNight0,
        foreground: Self.nordAuroraGreen,
        border: Self.nordAuroraGreen)
    case .command:
      return ModeBadgePalette(
        top: Self.nordPolarNight1,
        bottom: Self.nordPolarNight0,
        foreground: Self.nordAuroraPurple,
        border: Self.nordAuroraPurple)
    }
  }

  private static let nordPolarNight0 = NSColor(calibratedRed: 0.18, green: 0.20, blue: 0.25, alpha: 1)
  private static let nordPolarNight1 = NSColor(calibratedRed: 0.23, green: 0.26, blue: 0.32, alpha: 1)
  private static let nordFrost2 = NSColor(calibratedRed: 0.53, green: 0.75, blue: 0.82, alpha: 1)
  private static let nordAuroraGreen = NSColor(calibratedRed: 0.64, green: 0.75, blue: 0.55, alpha: 1)
  private static let nordAuroraPurple = NSColor(calibratedRed: 0.71, green: 0.56, blue: 0.68, alpha: 1)

  static func modeBadgeWidth(
    labels: Config.Mode.Labels,
    currentText: String,
    fontSize: CGFloat
  ) -> CGFloat {
    let count = max(labels.longestCount, currentText.count)
    return max(fontSize + 14, CGFloat(count) * fontSize * 0.64 + 14)
  }

  func filter(prefix: String, hints: [AssignedHint]) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let upper = prefix.uppercased()
    let prefixLen = upper.count
    let fontSize = CGFloat(overlayConfig.fontSize)
    let labelFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
    let fgNS = nsColor(fromHex: overlayConfig.hintFG) ?? .black
    var visible = Set<Int>()
    for (idx, hint) in hints.enumerated() {
      guard idx < hintLayers.count, idx < labelLayers.count else { break }
      let chip = hintLayers[idx]
      let matches = hint.display.hasPrefix(upper)
      chip.isHidden = !matches
      // Only rebuild the visible chips' labels — hidden chips don't
      // contribute to what the user sees and there's nothing wasted in
      // leaving their previous-prefix label state in place.
      if matches {
        visible.insert(idx)
        let l = labelLayers[idx]
        // Keep CATextLayer's own font in lockstep with the attributed
        // string's weight — see the note in `display(hints:)`. Cheap;
        // CATextLayer compares font references and noops on equal.
        l.font = labelFont
        l.string = Self.attributedLabel(
          display: hint.display, typedPrefixLen: prefixLen,
          font: labelFont, fgNS: fgNS)
      }
    }
    if debugConfig.showBounds {
      rebuildDebugPath(visibleIndices: visible)
    }
    CATransaction.commit()
  }

  /// Centered paragraph style — immutable, allocated once.
  /// CATextLayer ignores `alignmentMode` when its string is an
  /// NSAttributedString, so alignment rides along as a
  /// `.paragraphStyle` attribute. Shared across every chip label;
  /// NSParagraphStyle is documented thread-safe for read-only use.
  private static let centeredParagraphStyle: NSParagraphStyle = {
    let p = NSMutableParagraphStyle()
    p.alignment = .center
    return p.copy() as! NSParagraphStyle
  }()

  /// Build the chip label's attributed string. The whole label renders
  /// in `font` (bold monospaced); the first `typedPrefixLen` characters
  /// re-render at 30 % alpha (i.e. 70 % transparent) so the un-typed
  /// remainder visually dominates the chip. Weight never changes —
  /// glyph advances must not vary with prefix length, since the chip
  /// width was already computed in `display(hints:)`.
  ///
  /// Takes NSColor directly (not CGColor) so the caller can hoist the
  /// color alloc out of the per-chip loop — `NSColor(cgColor:)` is
  /// hundreds of nanoseconds per call and the per-keystroke filter
  /// rebuild calls this N times.
  private static func attributedLabel(
    display: String,
    typedPrefixLen: Int,
    font: NSFont,
    fgNS: NSColor
  ) -> NSAttributedString {
    let attr = NSMutableAttributedString(string: display)
    let full = NSRange(location: 0, length: (display as NSString).length)
    attr.addAttributes(
      [
        .font: font,
        .foregroundColor: fgNS,
        .paragraphStyle: centeredParagraphStyle,
      ],
      range: full
    )
    let typedLen = min(max(typedPrefixLen, 0), full.length)
    if typedLen > 0 {
      attr.addAttribute(
        .foregroundColor,
        value: fgNS.withAlphaComponent(0.3),
        range: NSRange(location: 0, length: typedLen)
      )
    }
    return attr
  }

  /// Round `rect` to the device-pixel grid for `scale`. A 1pt border
  /// drawn on a half-pixel x/y looks like two adjacent half-intensity
  /// pixel rows, which the eye reads as fuzzy. Snapping the frame's
  /// origin and size to multiples of `1/scale` puts the border on a
  /// single device-pixel row and renders crisp.
  static func snap(_ rect: CGRect, scale: CGFloat) -> CGRect {
    guard scale > 0 else { return rect }
    let s = scale
    let x = (rect.origin.x * s).rounded() / s
    let y = (rect.origin.y * s).rounded() / s
    let w = (rect.size.width * s).rounded() / s
    let h = (rect.size.height * s).rounded() / s
    return CGRect(x: x, y: y, width: w, height: h)
  }

  private func recycleAll() {
    // Batch detach: one assignment to `sublayers` instead of N
    // removeFromSuperlayer calls. The debugShapeLayer is re-added by
    // display(hints:) if debug is enabled, so detaching it here too is
    // safe — it's not retained anywhere else.
    contentLayer.sublayers = nil
    for chip in hintLayers {
      // Each chip has exactly one sublayer (its label). Wipe so the
      // chip is clean when next dequeued from the pool.
      chip.sublayers = nil
      hintLayerPool.append(chip)
    }
    labelLayerPool.append(contentsOf: labelLayers)
    hintLayers.removeAll(keepingCapacity: true)
    labelLayers.removeAll(keepingCapacity: true)
    debugShapeLayer.path = nil
    debugShapeLayer.isHidden = true
    focusIndicatorLayer.path = nil
    commandInputField.isHidden = true
    clearAppFinderResults()
    lastTargetLocalRects.removeAll(keepingCapacity: true)
  }

  private func makeChipLayer() -> CAGradientLayer {
    let l = CAGradientLayer()
    // Static styling that never changes after creation — set once at
    // pool-fill time so the per-chip render loop only touches frame +
    // colors.
    l.cornerRadius = 3
    l.borderWidth = 1
    l.actions = OverlayPanel.noActions
    return l
  }

  private func makeLabelLayer() -> CATextLayer {
    let l = CATextLayer()
    l.alignmentMode = .center
    l.actions = OverlayPanel.noActions
    return l
  }

  private func dequeueHintLayer() -> CAGradientLayer {
    if let last = hintLayerPool.popLast() { return last }
    return makeChipLayer()
  }

  private func dequeueLabelLayer() -> CATextLayer {
    if let last = labelLayerPool.popLast() { return last }
    return makeLabelLayer()
  }

  /// Chip's bounding rect in global NSScreen coordinates, for a target
  /// rect + uniform chip size.
  ///
  /// Centring is gated on height first:
  ///  - If the target's height is under 130 % of the chip height, the
  ///    chip is centred vertically on the target's midpoint.
  ///  - Horizontal centring additionally requires the target's width to
  ///    be under 130 % of the chip width.
  ///  - Otherwise the chip anchors to the target's top-left corner.
  static func chipFrame(target: CGRect, width: CGFloat, height: CGFloat) -> CGRect {
    let centerY = target.height < height * 1.3
    let centerX = centerY && target.width < width * 1.3
    let x = centerX ? target.midX - width / 2 : target.minX
    let y = centerY ? target.midY - height / 2 : target.maxY - height
    return CGRect(x: x, y: y, width: width, height: height)
  }

  /// Convenience overload. Used by `commit` (`hint.target.frame` is the
  /// only thing it knows) to derive the click point — the renderer
  /// inside `display(hints:)` calls the `(target:width:height:)` form
  /// directly so it can reuse the per-render uniform chip size.
  static func chipFrame(for hint: AssignedHint, fontSize: CGFloat) -> CGRect {
    let width = chipWidth(forLabelLength: hint.display.count, fontSize: fontSize)
    let height = chipHeight(forFontSize: fontSize)
    return chipFrame(target: hint.target.frame, width: width, height: height)
  }

  /// Centralised chip-dimension formulas so the renderer in
  /// `display(hints:)` and the click-point computation in `commit`
  /// never drift out of sync.
  static func chipWidth(forLabelLength labelLen: Int, fontSize: CGFloat) -> CGFloat {
    max(14, CGFloat(labelLen) * fontSize * 0.6 + 6)
  }

  static func chipHeight(forFontSize fontSize: CGFloat) -> CGFloat {
    fontSize + 4
  }

  static func unionScreenFrame() -> NSRect {
    var u: NSRect = .null
    for s in NSScreen.screens { u = u.union(s.frame) }
    if u.isNull, let main = NSScreen.main { return main.frame }
    return u
  }

  /// Hex → NSColor with a tiny memo. `display(hints:)` parses 4 hex
  /// strings per render and `filter(...)` parses one more per
  /// keystroke; the values come from `overlayConfig` so they're
  /// constant across activations until the user edits flash.toml.
  /// Sentinel `NSColor.clear` represents "parse failure" so we can
  /// distinguish nil-cached from absent-from-cache.
  private var colorCache: [String: NSColor] = [:]
  private static let parseFailureSentinel = NSColor.clear

  private func nsColor(fromHex hex: String) -> NSColor? {
    if let cached = colorCache[hex] {
      return cached === OverlayPanel.parseFailureSentinel ? nil : cached
    }
    var s = hex.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") { s.removeFirst() }
    guard let v = UInt64(s, radix: 16) else {
      colorCache[hex] = OverlayPanel.parseFailureSentinel
      return nil
    }
    let result: NSColor?
    switch s.count {
    case 6:
      let r = CGFloat((v >> 16) & 0xff) / 255
      let g = CGFloat((v >> 8) & 0xff) / 255
      let b = CGFloat(v & 0xff) / 255
      result = NSColor(red: r, green: g, blue: b, alpha: 1)
    case 8:
      let r = CGFloat((v >> 24) & 0xff) / 255
      let g = CGFloat((v >> 16) & 0xff) / 255
      let b = CGFloat((v >> 8) & 0xff) / 255
      let a = CGFloat(v & 0xff) / 255
      result = NSColor(red: r, green: g, blue: b, alpha: a)
    default:
      result = nil
    }
    colorCache[hex] = result ?? OverlayPanel.parseFailureSentinel
    return result
  }
}

extension OverlayPanel: CommandInputFieldDelegate {
  func commandInputFieldDidChange(_ field: CommandInputField) {
    guard !isUpdatingCommandInputField else { return }
    commandLineText = field.stringValue
    commandLineCursorIndex = field.cursorIndex
    coordinator?.overlayDidUpdateCommandLine(
      commandLineText,
      cursorIndex: commandLineCursorIndex,
      resetSelection: true)
  }

  func commandInputFieldDidCancel(_ field: CommandInputField) {
    commandLineText = ""
    commandLineCursorIndex = 0
    coordinator?.overlayDidCancelCommandLine()
  }

  func commandInputFieldDidSubmit(_ field: CommandInputField) {
    let command = field.stringValue
    commandLineText = ""
    commandLineCursorIndex = 0
    coordinator?.overlayDidSubmitCommandLine(command)
  }

  func commandInputFieldDidRequestSelectionMove(_ field: CommandInputField, delta: Int) -> Bool {
    coordinator?.overlayDidMoveCommandLineSelection(delta) ?? false
  }
}

protocol CommandInputFieldDelegate: AnyObject {
  func commandInputFieldDidChange(_ field: CommandInputField)
  func commandInputFieldDidCancel(_ field: CommandInputField)
  func commandInputFieldDidSubmit(_ field: CommandInputField)
  func commandInputFieldDidRequestSelectionMove(_ field: CommandInputField, delta: Int) -> Bool
}

final class CommandInputField: NSTextField {
  weak var commandDelegate: CommandInputFieldDelegate?

  var cursorIndex: Int {
    currentEditor()?.selectedRange.location ?? stringValue.count
  }

  override func textDidChange(_ notification: Notification) {
    super.textDidChange(notification)
    commandDelegate?.commandInputFieldDidChange(self)
  }

  override func keyDown(with event: NSEvent) {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let ignoredChar =
      NormalModeInterpreter.firstCharacter(event.charactersIgnoringModifiers)?
      .lowercased().first

    if event.keyCode == 53 || (modifiers.contains(.control) && ignoredChar == "c") {
      commandDelegate?.commandInputFieldDidCancel(self)
      return
    }

    switch event.keyCode {
    case 36, 76:
      commandDelegate?.commandInputFieldDidSubmit(self)
      return
    case 48:
      let delta = modifiers.contains(.shift) ? -1 : 1
      _ = commandDelegate?.commandInputFieldDidRequestSelectionMove(self, delta: delta)
      return
    case 125:
      if commandDelegate?.commandInputFieldDidRequestSelectionMove(self, delta: -1) == true {
        return
      }
    case 126:
      if commandDelegate?.commandInputFieldDidRequestSelectionMove(self, delta: 1) == true {
        return
      }
    default:
      break
    }

    super.keyDown(with: event)
  }
}

protocol OverlayCoordinator: AnyObject {
  func overlayDidCancel()
  func overlayDidCancelByPointer()
  func overlayDidCommit(prefix: String, clickModifiers: ClickModifiers)
  func overlayDidUpdatePrefix(_ prefix: String)
  func overlayDidHandleNormalMode(_ command: URLCommand?, repeatCount: Int)
  func overlayDidHandleMapping(_ event: NSEvent) -> Bool
  func overlayDidCancelHelp()
  func overlayDidCancelCommandLine()
  func overlayDidUpdateCommandLine(_ command: String, cursorIndex: Int, resetSelection: Bool)
  func overlayDidMoveCommandLineSelection(_ delta: Int) -> Bool
  func overlayDidSubmitCommandLine(_ command: String)
  func overlayDidCancelAppFinder()
  func overlayDidUpdateAppFinderQuery(_ query: String)
  func overlayDidMoveAppFinderSelection(_ delta: Int)
  func overlayDidSubmitAppFinder()
}
