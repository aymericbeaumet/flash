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
    hideSelectionMarker()
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
    // Critical hints (tmux panes, browser tabs) read from a parallel
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
    // The status bar stays in its own window below this transient level, so the
    // status-bar link hints render over the bar instead of behind it. App hints
    // never overlap the bar (they're filtered out of the menu-bar band by the
    // visible-region test), so nothing else changes visually.
    syncStatusBarForTransientRender(appendingPromptLayersTo: &newSublayers, panelFrame: frame)

    hintLayers.reserveCapacity(hints.count)
    labelLayers.reserveCapacity(hints.count)

    for (idx, hint) in hints.enumerated() {
      let targetFrame = hint.target.frame
      let isMouseGridHint = hint.target.providerID == "mouse_grid"
      // When the clicking mouse-grid step has cells smaller than a chip, the
      // chip IS the click point — no gap-free cell tile is meaningful at
      // that scale. Render those hints with the regular f-hint look so the
      // cluster reads cleanly and individual chips never get a redundant
      // translucent backdrop. Larger clicking cells stay tiles.
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
          // Mouse-grid cluster only: make the chip background
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
        } else if hint.target.priority.usesAccentHintStyle {
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

    appendToastLayerIfNeeded(to: &newSublayers)
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

  /// Render (or move) the `--adjust` marker: the matched target's outline plus
  /// a crosshair at the exact point the commit key will click. Coordinates are
  /// NSScreen (bottom-left); layers live in panel-local space. Drawn for the
  /// `--adjust` point and the `--search` selection.
  func showSelectionMarker(at point: CGPoint, targetFrame: CGRect) {
    let origin = frame.origin
    let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
    let localFrame = CGRect(
      x: targetFrame.minX - origin.x,
      y: targetFrame.minY - origin.y,
      width: targetFrame.width,
      height: targetFrame.height)
    let path = CGMutablePath()
    path.addRect(localFrame)
    path.addEllipse(in: CGRect(x: local.x - 4, y: local.y - 4, width: 8, height: 8))
    path.move(to: CGPoint(x: local.x - 12, y: local.y))
    path.addLine(to: CGPoint(x: local.x + 12, y: local.y))
    path.move(to: CGPoint(x: local.x, y: local.y - 12))
    path.addLine(to: CGPoint(x: local.x, y: local.y + 12))
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    adjustmentMarkerLayer.path = path
    adjustmentMarkerLayer.isHidden = false
    attachSelectionMarker()
    CATransaction.commit()
  }

  func hideSelectionMarker() {
    adjustmentMarkerLayer.isHidden = true
  }

  /// Every transient render rebuilds `contentLayer.sublayers` without the
  /// marker, so each draw re-attaches it, above whatever it marks.
  private func attachSelectionMarker() {
    guard contentLayer.sublayers?.last !== adjustmentMarkerLayer else { return }
    adjustmentMarkerLayer.removeFromSuperlayer()
    contentLayer.addSublayer(adjustmentMarkerLayer)
  }

  /// Present pointer mode: frame + order the panel (so tap capture stays
  /// active — `keyboardCaptureIsActive` requires visibility), then draw the
  /// cursor ring. Subsequent moves go through `movePointerMarker`.
  func presentPointerMode(at point: CGPoint) {
    applyPanelFrame(OverlayPanel.unionScreenFrame())
    transientContentVisible = true
    movePointerMarker(to: point)
    captureKeyboardInput()
  }

  /// Pointer-mode feedback: a ring around the cursor, on the adjustment
  /// marker layer (the two states are mutually exclusive).
  func movePointerMarker(to point: CGPoint) {
    let origin = frame.origin
    let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
    let path = CGMutablePath()
    path.addEllipse(in: CGRect(x: local.x - 11, y: local.y - 11, width: 22, height: 22))
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    adjustmentMarkerLayer.path = path
    adjustmentMarkerLayer.isHidden = false
    attachSelectionMarker()
    CATransaction.commit()
  }

  func hide() {
    FlashLog.trace(
      "[overlay] hide transient=\(transientContentVisible) bar=\(modeSurface.barVisible) "
        + "capture=\(modeSurface.capturesInput) input=\(inputMode)")
    scheduleCursorVisibilityUpdate()
    hideSelectionMarker()
    transientContentVisible = false
    commandPromptVisible = false
    commandPromptPrefix = ":"
    hideCommandTextField()
    clearCandidateFinderResults()
    commandLineText = ""
    commandLineCursorIndex = 0
    recycleAll()
    if let current = toast, !current.outlivesTeardown {
      toast = nil
      current.layer.removeFromSuperlayer()
    }
    renderPersistentContent()
  }

  /// Escalating delays for the command-line key-recovery ladder. Activation is
  /// granted asynchronously, so the first pass routinely runs before the panel
  /// holds key; these retries cover that without becoming a resident poll.
  static let commandLineKeyRecoveryDelaysMs = [30, 80, 160, 320, 640]

  /// The ladder's next step, or nil once it is exhausted. `attempt` is the
  /// number of retries already spent, so a fresh capture starts at 0 and each
  /// retry advances exactly one rung. Restarting from 0 on every retry is what
  /// turned this into an unbounded 30 ms loop that spun for seconds.
  static func commandLineKeyRecoveryDelayMs(afterAttempt attempt: Int) -> Int? {
    guard attempt >= 0, attempt < commandLineKeyRecoveryDelaysMs.count else { return nil }
    return commandLineKeyRecoveryDelaysMs[attempt]
  }

  /// Which app to name as the source of an activation request.
  ///
  /// `NSWorkspace.frontmostApplication` settles asynchronously and can report
  /// Flash itself. `activate(from:)` is the request that actually hands this
  /// non-activating panel the key window, and gating it on that pointer meant
  /// it was skipped in precisely the case with no other working remedy — the
  /// app nominally active, no key window, and a retry ladder with nothing left
  /// to try. Fall back to the app Flash last saw focused.
  static func activationSourcePID(
    workspaceFrontPID: pid_t?, lastNonFlashPID: pid_t?, currentPID: pid_t
  ) -> pid_t? {
    if let workspaceFrontPID, workspaceFrontPID != currentPID { return workspaceFrontPID }
    if let lastNonFlashPID, lastNonFlashPID != currentPID { return lastNonFlashPID }
    return nil
  }

  /// Whether the command line actually has a live caret: AppKit blinks the
  /// field editor's insertion point only in a window it reports as key.
  /// `shouldDrawInsertionPoint` is not that signal — it stays true for an
  /// editing field in a panel that is not key yet, including right after a
  /// reopen that is still waiting on activation — so recovery that trusted it
  /// stopped before the caret ever appeared.
  var commandLineHoldsKeyboardFocus: Bool {
    guard isKeyWindow, let editor = commandTextField.currentEditor() else { return false }
    return firstResponder === editor
  }

  /// Restart the field editor's insertion-point blink. The caret is AppKit's
  /// own; Flash draws none. Idempotent, and it does not move the caret — the
  /// selection is owned by `syncCommandTextFieldSelection` — so it is safe to
  /// repeat.
  func rearmCommandLineCaret() {
    guard inputMode == .commandLine,
      let editor = commandTextField.currentEditor() as? NSTextView
    else { return }
    editor.updateInsertionPointStateAndRestartTimer(true)
  }

  /// Delays for the post-open caret re-arm. Two turns: the next one, and one
  /// far enough out to be past an activation handoff. Deliberately a fixed,
  /// tiny list rather than a retry loop — arming is idempotent and there is no
  /// state to poll for.
  static let commandLineCaretRearmDelaysMs = [0, 80]

  private func scheduleCommandLineCaretRearm() {
    commandLineCaretRearmGeneration &+= 1
    let generation = commandLineCaretRearmGeneration
    for delayMs in Self.commandLineCaretRearmDelaysMs {
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
        guard let self, self.commandLineCaretRearmGeneration == generation else { return }
        self.rearmCommandLineCaret()
      }
    }
  }

  func captureKeyboardInput(recoveryAttempt: Int = 0) {
    let keyBefore = isKeyWindow
    refreshWindowLevelForCurrentContent()
    // NORMAL / hints input is captured by the global keyboard tap, so we don't
    // take key/active status here — the focused app keeps its colored window
    // controls and there's no activation race to leak a key. Just float the
    // overlay above the content. (Command-line / modal still take the key
    // window below for their text fields, as does the no-tap fallback.)
    // Passive input never takes the keyboard from the focused app.
    if inputMode == .passive {
      orderFrontRegardless()
      return
    }
    if tapCapturesInput {
      orderFrontRegardless()
      // If we still hold activation from a prior command-line / modal (which do
      // take the key window for their text fields), hand it back so the focused
      // app reactivates and shows colored window controls. The tap keeps
      // capturing regardless of who is active.
      if inputMode == .normal, NSApp.isActive {
        NSApp.deactivate()
      }
      FlashLog.trace(
        "[overlay] capture_keyboard via=tap input=\(inputMode) active=\(NSApp.isActive)")
      return
    }
    // macOS Tahoe (26) refuses to grant key-window status to a non-
    // activating panel while another app holds activation, even with
    // `becomesKeyOnlyIfNeeded = false`. Force activation so the panel
    // can become key. The action dispatch path (`currentNonFlashContext()`)
    // still targets whatever app was frontmost before Flash activated,
    // so verbs like `r` (`app_reload`) continue to land on the user's
    // actual workflow app.
    //
    // Activation requests are advisory on modern macOS. Try both the
    // modern AppKit activation entry point and the RunningApplication
    // request; the normal-mode coordinator verifies the result and runs
    // bounded recovery if WindowServer does not hand us key ownership
    // immediately.
    // Being the active app is NOT enough — the command-line panel itself must be
    // the KEY window for the field editor's caret to blink. After a *cancel*
    // close the app stays active, so gating only on `!isActive` skipped
    // re-activation and the non-activating panel never regained key (`makeKey()`
    // alone doesn't grant it on this macOS), leaving no caret. Re-activate
    // whenever we aren't the key window so the panel reliably regains it.
    // Deliberately still gated on `isKeyWindow`, not on caret liveness: the
    // field editor is reused across opens, so a stale one can report a live
    // caret before this open has activated Flash at all, and skipping
    // activation there would send the user's keystrokes to the app behind.
    // The request is idempotent, so asking once more costs nothing.
    if !NSApp.isActive || !isKeyWindow {
      requestApplicationActivationForKeyboardCapture()
    }
    orderFrontRegardless()
    makeKeyAndOrderFront(nil)
    makeKey()
    let responderDescription: String
    if commandTextFieldIsLaidOut {
      commandTextField.isHidden = false
      // The field editor is reused across open/close cycles, and a reused one
      // arrives carrying the previous session's insertion-point state. When
      // that state already looked correct, nothing re-armed the blink and the
      // command line opened with no visible cursor until the first keystroke
      // redrew it — which is exactly the reported symptom: always able to
      // type, cursor appears on the first character.
      //
      // The old code skipped the rebuild whenever the field was already
      // "editing", to avoid stomping a live caret on an async candidate merge.
      // That guard protects nothing here: this runs once per open, and the
      // re-renders that merge late candidates never reach it (measured at one
      // capture pass against five renders for a single open). So rebuild
      // unconditionally and re-arm every time.
      let hadEditor = commandTextField.currentEditor() != nil
      makeFirstResponder(nil)
      makeFirstResponder(commandTextField)
      syncCommandTextFieldSelection()
      rearmCommandLineCaret()
      // Arming once is not enough. The blink only starts if AppKit considers
      // the panel key at that instant, and this pass usually runs before the
      // activation it just requested has settled. Re-arm once the turn has
      // settled.
      scheduleCommandLineCaretRearm()
      responderDescription = hadEditor ? "command(rebuilt)" : "command(new)"
      FlashLog.trace(
        "[overlay] capture_keyboard key_before=\(keyBefore) key_after=\(isKeyWindow) "
          + "responder=\(responderDescription) active=\(NSApp.isActive) input=\(inputMode) "
          + "editor=\(commandTextField.currentEditor() != nil)")
      let editorView = commandTextField.currentEditor() as? NSTextView
      let drawsCaretDescription = editorView?.shouldDrawInsertionPoint.description ?? "no_editor"
      FlashLog.trace(
        "[overlay] capture_keyboard_key attempt=\(recoveryAttempt) "
          + "visible=\(isVisible) on_active_space=\(isOnActiveSpace) "
          + "is_key=\(isKeyWindow) app_key_is_self=\(NSApp.keyWindow === self) "
          + "app_active=\(NSApp.isActive) draws_caret=\(drawsCaretDescription)")
      // Activation is granted asynchronously on modern macOS, so a single
      // makeKey() pass can land before we're active and leave the field
      // caret dead — and the normal-mode recapture ladder deliberately
      // skips while a modal is up, so nothing would ever retry. Run a
      // short bounded ladder of our own until the panel actually holds
      // key. Any newer capture pass supersedes it (generation).
      commandLineKeyRecoveryGeneration &+= 1
      guard !commandLineHoldsKeyboardFocus else { return }
      guard let delayMs = Self.commandLineKeyRecoveryDelayMs(afterAttempt: recoveryAttempt)
      else {
        FlashLog.warn(
          "[overlay] capture_keyboard key_recovery_exhausted attempts=\(recoveryAttempt) "
            + "active=\(NSApp.isActive) app_key_is_self=\(NSApp.keyWindow === self); "
            + "command line has no caret")
        return
      }
      let generation = commandLineKeyRecoveryGeneration
      let nextAttempt = recoveryAttempt + 1
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
        guard let self,
          self.commandLineKeyRecoveryGeneration == generation,
          self.inputMode == .commandLine,
          !self.commandLineHoldsKeyboardFocus
        else { return }
        FlashLog.trace(
          "[overlay] capture_keyboard key_retry delay=\(delayMs) attempt=\(nextAttempt)")
        self.captureKeyboardInput(recoveryAttempt: nextAttempt)
      }
      return
    }
    makeFirstResponder(self)
    responderDescription = "panel"
    FlashLog.trace(
      "[overlay] capture_keyboard key_before=\(keyBefore) key_after=\(isKeyWindow) "
        + "responder=\(responderDescription) active=\(NSApp.isActive) input=\(inputMode)")
  }

  @discardableResult
  private func requestApplicationActivationForKeyboardCapture() -> Bool {
    let current = NSRunningApplication.current
    let front = NSWorkspace.shared.frontmostApplication
    let frontDescription: String
    if let front {
      frontDescription = "\(front.bundleIdentifier ?? "nil"):\(front.processIdentifier)"
    } else {
      frontDescription = "nil"
    }

    let sourcePID = Self.activationSourcePID(
      workspaceFrontPID: front?.processIdentifier,
      lastNonFlashPID: coordinator?.lastFocusedApplicationPID,
      currentPID: current.processIdentifier)
    var acceptedFrom = false
    if #available(macOS 14.0, *) {
      NSApp.activate()
      if let sourcePID, let source = NSRunningApplication(processIdentifier: sourcePID),
        !source.isTerminated
      {
        acceptedFrom = current.activate(from: source, options: [.activateAllWindows])
      }
    }
    let acceptedDirect = current.activate(options: [.activateAllWindows])
    let activeAfterRequest = NSApp.isActive
    FlashLog.trace(
      "[overlay] capture_activation front=\(frontDescription) "
        + "source=\(sourcePID.map(String.init) ?? "nil") "
        + "accepted_from=\(acceptedFrom) accepted_direct=\(acceptedDirect) "
        + "active=\(activeAfterRequest)")
    return activeAfterRequest || acceptedFrom || acceptedDirect
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
    if statusBarWindow.frame != frame {
      statusBarWindow.setFrame(frame, display: false)
      statusBarWindow.contentView?.frame = NSRect(origin: .zero, size: frame.size)
      statusBarWindow.contentLayer.frame = statusBarWindow.contentView?.bounds ?? .zero
    }
    guard self.frame != frame else { return }
    self.setFrame(frame, display: false)
    self.contentView?.frame = NSRect(origin: .zero, size: frame.size)
    contentLayer.frame = contentView?.bounds ?? .zero
  }

  /// Per keystroke: toggles each chip by prefix and re-renders only the
  /// visible labels. Labels are unique within a set, so there is nothing to
  /// memoize across chips; the visible-index set exists only for debug bounds.
  func filter(prefix: String, hints: [AssignedHint]) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let upper = prefix.uppercased()
    let prefixLen = upper.count
    let labelFont = NSFont.monospacedSystemFont(
      ofSize: CGFloat(overlayConfig.fontSize), weight: .bold)
    let fgNS = nsColor(fromHex: overlayConfig.hintFG) ?? .black
    let importantFGNS = nsColor(fromHex: overlayConfig.importantHintFG) ?? fgNS
    let tracksBounds = debugConfig.showHintsBounds
    var visible = Set<Int>()
    for (idx, hint) in hints.enumerated() {
      guard idx < hintLayers.count, idx < labelLayers.count else { break }
      let matches = hint.display.hasPrefix(upper)
      hintLayers[idx].isHidden = !matches
      // Hidden chips keep their previous label; nobody sees it.
      guard matches else { continue }
      if tracksBounds { visible.insert(idx) }
      let label = labelLayers[idx]
      // Keep CATextLayer's own font in lockstep with the attributed
      // string's weight — see the note in `display(hints:)`. Cheap;
      // CATextLayer compares font references and noops on equal.
      label.font = labelFont
      label.string = Self.attributedLabel(
        display: hint.display, typedPrefixLen: prefixLen, font: labelFont,
        fgNS: hint.target.priority.usesAccentHintStyle ? importantFGNS : fgNS)
    }
    if tracksBounds {
      rebuildDebugPath(visibleIndices: visible)
    }
    CATransaction.commit()
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
    // NOT the active-window border: it's owned by `setActiveWindowBorder`
    // (its visibility is `path != nil`), independent of transient hint/alert
    // content. Clearing it here blanked the colored focus border whenever an
    // alert/banner/hide ran, so it stayed gone until the next geometry event.
    // Transient renderers re-attach it via
    // `appendActiveWindowBorderLayerIfNeeded`.
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

}
