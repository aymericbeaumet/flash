import AppKit
import FlashCore
import QuartzCore

/// The hint-chip render path: lays out one `CAGradientLayer` chip per
/// `AssignedHint`, dim-renders matched prefix on every keystroke
/// (`filter`), recycles chips into a pool to amortise the
/// `CALayer` allocation cost, and handles the per-screen scale
/// resolution for crisp 1pt borders on mixed-DPI setups.
///
/// Mouse-grid hints share this code path and ship as a separate frame
/// + palette pair drawn through the same chip layer.
extension OverlayPanel {
  func display(hints: [AssignedHint]) {
    FlashLog.trace("[overlay] display hints=\(hints.count) input=\(inputMode)")
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer {
      CATransaction.commit()
      captureKeyboardInput()
    }

    let snapshot = OverlayPanel.currentScreenSnapshot()
    let frame = snapshot.unionFrame
    applyPanelFrame(frame)

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
    let panelOrigin = frame.origin
    let screensInPanel: [(scale: CGFloat, panelRect: CGRect)] = snapshot.screens.map { s in
      let r = CGRect(
        x: s.frame.minX - panelOrigin.x,
        y: s.frame.minY - panelOrigin.y,
        width: s.frame.width,
        height: s.frame.height
      )
      return (s.scale, r)
    }
    // Single-display fast path: the per-chip linear scan over the
    // panel-local screen list resolves to the same scale every time,
    // so skip the loop and CGPoint construction entirely.
    let singleDisplayScale: CGFloat? =
      screensInPanel.count == 1 ? screensInPanel[0].scale : nil
    let fallbackScale =
      snapshot.mainScale

    // Hoisted out of the per-chip loop: colors, font, and chip height
    // are identical for every chip in this activation. Chip *width*
    // is per-hint — `HintAssigner` now packs singles + 2-char labels
    // in the same activation (so the user can commit a 1-key hint
    // whenever the target count allows), and using a single uniform
    // width sized to the first hint clipped/squished every label
    // with a different length.
    let gradientColors: [CGColor] = [bgBottom.cgColor, bgTop.cgColor]
    let borderCG = border?.cgColor ?? OverlayPanel.fallbackBorderCGColor
    // Important hints (tmux panes, browser tabs) read from a parallel
    // set of `overlay.important_hint_*` config keys so the user can
    // restyle them without rebuilding. Fall back to the regular hint
    // palette when a key fails to parse — a malformed colour leaves
    // the chip looking like a normal `f` hint instead of a black
    // sentinel block.
    let importantBgTop =
      nsColor(fromHex: overlayConfig.importantHintBGTop) ?? bgTop
    let importantBgBottom =
      nsColor(fromHex: overlayConfig.importantHintBGBottom) ?? bgBottom
    let importantBorder =
      nsColor(fromHex: overlayConfig.importantHintBorder) ?? border
    let importantFG =
      nsColor(fromHex: overlayConfig.importantHintFG) ?? fg
    let importantGradientColors: [CGColor] = [
      importantBgBottom.cgColor, importantBgTop.cgColor,
    ]
    let importantBorderCG = importantBorder?.cgColor ?? borderCG
    let importantFGCG = importantFG.cgColor
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

    let debugEnabled = debugConfig.showHintsBounds
    if debugEnabled {
      debugShapeLayer.strokeColor =
        (nsColor(fromHex: debugConfig.hintsBoundsFG) ?? NSColor.systemPink).cgColor
      debugShapeLayer.fillColor =
        (nsColor(fromHex: debugConfig.hintsBoundsBG) ?? NSColor.clear).cgColor
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
    newSublayers.reserveCapacity(hints.count * 2 + 1)
    if debugEnabled {
      newSublayers.append(debugShapeLayer)
    }

    hintLayers.reserveCapacity(hints.count)
    labelLayers.reserveCapacity(hints.count)

    for (idx, hint) in hints.enumerated() {
      let targetFrame = hint.target.frame
      let isMouseGridHint = hint.target.providerID == "mouse_grid"
      // At the final mouse-grid step the chip IS the click point — no
      // gap-free cell tile is meaningful at that scale. Render those
      // hints with the regular f-hint look so the cluster reads
      // cleanly and individual chips never get a redundant translucent
      // backdrop.
      let isMouseGridFinalChip =
        isMouseGridHint && hint.target.role == MouseGrid.finalChipRole
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
      // Every chip layer stays at full opacity. Mouse-grid cell
      // translucency rides on the tint's colour alpha instead (set
      // below), so the opaque label chip nested inside each cell — and
      // therefore the letter — never inherits the see-through tint.
      chip.opacity = 1
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
      label.foregroundColor = fg.cgColor

      let labelLen = hint.display.count
      let chipW: CGFloat
      if let cached = widthByLen[labelLen] {
        chipW = cached
      } else {
        chipW = Self.chipWidth(forLabelLength: labelLen, fontSize: fontSize)
        widthByLen[labelLen] = chipW
      }

      // Outer chip frame. Mouse-grid *cells* fill the whole cell (gap-
      // free packing — clicking *anywhere* in a cell commits its hint,
      // no dead "between letters" zone). Mouse-grid *final chips* and
      // regular hints both use a centred fixed-size chip — the final
      // chip's targetFrame already IS the chip rect, so `chipFrame`
      // centres a fixed-size chip on it identical to the regular path.
      let chipGlobal: CGRect =
        (isMouseGridHint && !isMouseGridFinalChip)
        ? targetFrame
        : Self.chipFrame(target: targetFrame, width: chipW, height: chipHeight)
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
      let chipScale: CGFloat
      if let single = singleDisplayScale {
        chipScale = single
      } else {
        let chipMid = CGPoint(x: chipLocal.midX, y: chipLocal.midY)
        var resolved = fallbackScale
        for sp in screensInPanel where sp.panelRect.contains(chipMid) {
          resolved = sp.scale
          break
        }
        chipScale = resolved
      }
      // Snap to device-pixel grid so the 1pt border lands on integer
      // device-pixels (otherwise it gets anti-aliased into two half-
      // intensity rows and reads as pixelated). Mouse-grid cells skip
      // the snap because they must touch their neighbours exactly —
      // per-cell rounding can drift cells apart by a pixel and create a
      // visible gap, which is precisely the anti-feature the grid avoids.
      // Cells skip snap so they touch their neighbours exactly; final
      // chips and regular hints snap for crisp 1pt borders.
      chip.frame =
        (isMouseGridHint && !isMouseGridFinalChip)
        ? chipLocal : Self.snap(chipLocal, scale: chipScale)
      chip.contentsScale = chipScale
      label.contentsScale = chipScale

      if isMouseGridHint && !isMouseGridFinalChip {
        // Cell backdrop: a translucent tint so the user still sees the
        // page underneath to aim. Translucency rides on the colour alpha
        // (not layer opacity) so the centred label chip nested below
        // renders fully opaque. `mouseGridOpacity` controls only this
        // tint — never the letter — so the hint stays readable on any
        // background (light or dark) without its contrast drifting.
        let tint = Self.mouseGridColor(index: idx)
        let alpha = CGFloat(mouseGridOpacity)
        chip.cornerRadius = 0
        chip.borderWidth = 1
        chip.colors = [
          (tint.blended(withFraction: 0.08, of: .black) ?? tint)
            .withAlphaComponent(alpha).cgColor,
          (tint.blended(withFraction: 0.40, of: .white) ?? tint)
            .withAlphaComponent(alpha).cgColor,
        ]
        chip.borderColor = tint.withAlphaComponent(min(1, alpha + 0.3)).cgColor

        // Centred hint: the exact "f"-hint chip design (same gradient,
        // corner radius, border, glyph) so the letter is always crisp
        // regardless of the underlying page colour.
        let labelChip = CAGradientLayer()
        labelChip.actions = OverlayPanel.noActions
        labelChip.cornerRadius = 3
        labelChip.borderWidth = 1
        labelChip.colors = gradientColors
        labelChip.borderColor = borderCG
        labelChip.contentsScale = chipScale
        // Centre on the cell in panel-local space, snap for a crisp
        // border, then re-express in the cell chip's own coordinates.
        let labelAbs = Self.snap(
          CGRect(
            x: chipLocal.midX - chipW / 2,
            y: chipLocal.midY - chipHeight / 2,
            width: chipW,
            height: chipHeight),
          scale: chipScale)
        labelChip.frame = CGRect(
          x: labelAbs.minX - chipLocal.minX,
          y: labelAbs.minY - chipLocal.minY,
          width: labelAbs.width,
          height: labelAbs.height)
        label.frame = CGRect(x: 0, y: labelYOffset, width: chipW, height: labelHeight)
        labelChip.addSublayer(label)
        chip.addSublayer(labelChip)
      } else {
        chip.cornerRadius = 3
        chip.borderWidth = 1
        if isMouseGridFinalChip {
          // Final mouse-grid step only: make the chip background
          // slightly translucent so the user can see what's behind the
          // cluster while picking the precise click target. The label
          // is a sub-layer that keeps its own (fully opaque) colour so
          // the letter stays bright and readable — only the chip
          // surround dims.
          let alpha: CGFloat = 0.7
          chip.colors = gradientColors.map { color -> CGColor in
            NSColor(cgColor: color)?
              .withAlphaComponent(alpha)
              .cgColor ?? color
          }
          chip.borderColor =
            NSColor(cgColor: borderCG)?
            .withAlphaComponent(min(1, alpha + 0.2))
            .cgColor ?? borderCG
        } else if hint.target.important {
          chip.colors = importantGradientColors
          chip.borderColor = importantBorderCG
          label.foregroundColor = importantFGCG
          label.string = Self.attributedLabel(
            display: hint.display, typedPrefixLen: 0,
            font: labelFont, fgNS: importantFG)
        } else {
          chip.colors = gradientColors
          chip.borderColor = borderCG
        }
        label.frame = CGRect(x: 0, y: labelYOffset, width: chipW, height: labelHeight)
        // `recycleAll()` already cleared `sublayers`, so attaching with
        // `addSublayer(label)` skips the per-chip array alloc that
        // `chip.sublayers = [label]` carried.
        chip.addSublayer(label)
      }
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
    "masksToBounds": NSNull(), "shadowColor": NSNull(), "shadowOpacity": NSNull(),
    "shadowRadius": NSNull(), "shadowOffset": NSNull(), "shadowPath": NSNull(),
    "onOrderIn": NSNull(), "onOrderOut": NSNull(), "sublayers": NSNull(),
    "path": NSNull(), "strokeColor": NSNull(), "fillColor": NSNull(), "lineWidth": NSNull(),
    "colors": NSNull(),
  ]

  func hide() {
    FlashLog.trace(
      "[overlay] hide transient=\(transientContentVisible) mode_badge=\(modeBadgeVisible) "
        + "capture=\(modeBadgeCapturesInput) input=\(inputMode)")
    transientContentVisible = false
    commandPromptVisible = false
    commandPromptPrefix = ":"
    commandCaretLayer.isHidden = true
    hideModalTextView()
    hideCommandTextField()
    clearCandidateFinderResults()
    commandLineText = ""
    commandLineCursorIndex = 0
    candidateFinderQuery = ""
    recycleAll()
    renderModeBadgeOnlyOrHide()
  }

  func captureKeyboardInput() {
    let keyBefore = isKeyWindow
    refreshWindowLevelForCurrentContent()
    // macOS Tahoe (26) refuses to grant key-window status to a non-
    // activating panel while another app holds activation, even with
    // `becomesKeyOnlyIfNeeded = false`. Force activation so the panel
    // can become key. The action dispatch path (`currentNonFlashContext()`)
    // still targets whatever app was frontmost before Flash activated,
    // so verbs like `r` (`app_reload`) continue to land on the user's
    // actual workflow app.
    //
    // Tahoe also dropped `activate(ignoringOtherApps:)`'s ability to
    // override an active app. The new `activate()` (no args) is the only
    // call the system honours; the old one is silently ignored.
    // `yieldActivation(to: nil)` first releases any activation the OS
    // would otherwise keep parked on the previous app, so the subsequent
    // `activate()` actually lands instead of being shelved.
    // Force activation through `NSRunningApplication.activate(options:)`
    // — the only path that still works on macOS Tahoe (26) for an
    // accessory app under another app's activation. The plain
    // `NSApp.activate()` is asynchronous and waits for the frontmost
    // app to yield (which Firefox/Alacritty/etc. never do); the
    // deprecated `NSApp.activate(ignoringOtherApps:)` is silently
    // ignored under cooperative-activation rules. The
    // NSRunningApplication path threads through Launch Services and
    // *does* land synchronously enough for the immediate `makeKey`
    // calls below to take.
    if !NSApp.isActive {
      NSRunningApplication.current.activate(options: [.activateAllWindows])
    }
    orderFrontRegardless()
    makeKeyAndOrderFront(nil)
    makeKey()
    let responderDescription: String
    if inputMode == .commandLine {
      commandTextField.isHidden = false
      makeFirstResponder(commandTextField)
      syncCommandTextFieldSelection()
      responderDescription = "command"
      FlashLog.trace(
        "[overlay] capture_keyboard key_before=\(keyBefore) key_after=\(isKeyWindow) "
          + "responder=\(responderDescription) active=\(NSApp.isActive) input=\(inputMode)")
      return
    }
    if inputMode == .modal {
      modalTextView.overlayCoordinator = coordinator
      modalScrollView.isHidden = false
      makeFirstResponder(modalTextView)
      responderDescription = "modal"
      FlashLog.trace(
        "[overlay] capture_keyboard key_before=\(keyBefore) key_after=\(isKeyWindow) "
          + "responder=\(responderDescription) active=\(NSApp.isActive) input=\(inputMode)")
      return
    }
    makeFirstResponder(self)
    responderDescription = "panel"
    FlashLog.trace(
      "[overlay] capture_keyboard key_before=\(keyBefore) key_after=\(isKeyWindow) "
        + "responder=\(responderDescription) active=\(NSApp.isActive) input=\(inputMode)")
  }

  func ensurePanelFrame() -> CGRect {
    let frame = OverlayPanel.unionScreenFrame()
    applyPanelFrame(frame)
    return frame
  }

  /// Idempotent panel + contentView + contentLayer frame sync. Called
  /// by `display`, `displayBanner`, and `ensurePanelFrame` so the
  /// "are we already at this frame?" branch is in one place.
  func applyPanelFrame(_ frame: CGRect) {
    guard self.frame != frame else { return }
    self.setFrame(frame, display: false)
    self.contentView?.frame = NSRect(origin: .zero, size: frame.size)
    contentLayer.frame = contentView?.bounds ?? .zero
  }

  func filter(prefix: String, hints: [AssignedHint]) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let upper = prefix.uppercased()
    let prefixLen = upper.count
    let fontSize = CGFloat(overlayConfig.fontSize)
    let labelFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
    let fgNS = nsColor(fromHex: overlayConfig.hintFG) ?? .black
    let importantFGNS = nsColor(fromHex: overlayConfig.importantHintFG) ?? fgNS
    var visible = Set<Int>()
    var cache: [AttributedLabelKey: NSAttributedString] = [:]
    cache.reserveCapacity(hints.count)
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
        // Memoise per `(display, typedPrefixLen, important)` — the
        // important variant's fg colour differs, so it can't share
        // the regular cache key.
        let labelFG: NSColor = hint.target.important ? importantFGNS : fgNS
        let key = AttributedLabelKey(
          display: hint.display,
          typedPrefixLen: prefixLen,
          important: hint.target.important)
        if let cached = cache[key] {
          l.string = cached
        } else {
          let attr = Self.attributedLabel(
            display: hint.display, typedPrefixLen: prefixLen,
            font: labelFont, fgNS: labelFG)
          cache[key] = attr
          l.string = attr
        }
      }
    }
    if debugConfig.showHintsBounds {
      rebuildDebugPath(visibleIndices: visible)
    }
    CATransaction.commit()
  }

  private struct AttributedLabelKey: Hashable {
    let display: String
    let typedPrefixLen: Int
    let important: Bool
  }

  /// Centered paragraph style — immutable, allocated once.
  /// CATextLayer ignores `alignmentMode` when its string is an
  /// NSAttributedString, so alignment rides along as a
  /// `.paragraphStyle` attribute. Shared across every chip label;
  /// NSParagraphStyle is documented thread-safe for read-only use.
  static let centeredParagraphStyle: NSParagraphStyle = {
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

  func recycleAll() {
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
    activeWindowBorderLayer.path = nil
    commandCaretLayer.isHidden = true
    hideModalTextView()
    clearCandidateFinderResults()
    lastTargetLocalRects.removeAll(keepingCapacity: true)
  }

  func makeChipLayer() -> CAGradientLayer {
    let l = CAGradientLayer()
    // Static styling that never changes after creation — set once at
    // pool-fill time so the per-chip render loop only touches frame +
    // colors.
    l.cornerRadius = 3
    l.borderWidth = 1
    l.actions = OverlayPanel.noActions
    return l
  }

  func makeLabelLayer() -> CATextLayer {
    let l = CATextLayer()
    l.alignmentMode = .center
    l.actions = OverlayPanel.noActions
    return l
  }

  func dequeueHintLayer() -> CAGradientLayer {
    let layer = hintLayerPool.popLast() ?? makeChipLayer()
    layer.isHidden = false
    layer.opacity = 1
    return layer
  }

  func dequeueLabelLayer() -> CATextLayer {
    let layer = labelLayerPool.popLast() ?? makeLabelLayer()
    layer.isHidden = false
    layer.opacity = 1
    return layer
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

  private static let mouseGridColors: [NSColor] = [
    NSColor(calibratedRed: 0.94, green: 0.27, blue: 0.31, alpha: 1),
    NSColor(calibratedRed: 0.96, green: 0.55, blue: 0.19, alpha: 1),
    NSColor(calibratedRed: 0.98, green: 0.80, blue: 0.25, alpha: 1),
    NSColor(calibratedRed: 0.35, green: 0.72, blue: 0.38, alpha: 1),
    NSColor(calibratedRed: 0.23, green: 0.64, blue: 0.82, alpha: 1),
    NSColor(calibratedRed: 0.42, green: 0.47, blue: 0.91, alpha: 1),
    NSColor(calibratedRed: 0.72, green: 0.39, blue: 0.86, alpha: 1),
    NSColor(calibratedRed: 0.94, green: 0.43, blue: 0.71, alpha: 1),
  ]

  private static func mouseGridColor(index: Int) -> NSColor {
    mouseGridColors[index % mouseGridColors.count]
  }

  private static func mouseGridDepth(from id: String) -> Int? {
    let parts = id.split(separator: ":", maxSplits: 2)
    guard parts.count == 3, parts[0] == "mouse_grid" else { return nil }
    return Int(parts[1])
  }
}
