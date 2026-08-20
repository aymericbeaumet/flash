import AppKit
import ApplicationServices
import Carbon.HIToolbox
import FlashCore

/// Activation pipeline: from a `URLCommand` (CLI / Apple Event / native
/// mapping) to the OverlayPanel showing hint chips. Handles the
/// activation generation token, the prepared-model lookup, and the
/// no-targets / accessibility-revoked exit paths.
extension AppDelegate {
  // MARK: Activation

  func activateMouseTarget(_ command: MouseCommand, contextOverride: AppContext?) {
    let behavior: HintCommitBehavior =
      command.isDrag ? .drag : command.isMove ? .moveMouse : .click
    activate(
      action: command.action,
      commitBehavior: behavior,
      clickModifiers: command.modifiers,
      contextOverride: contextOverride)
  }

  func activateMouseGrid(_ command: MouseCommand, contextOverride: AppContext?) {
    let context = contextOverride ?? currentNonFlashContext() ?? normalModeContext()
    let steps = config.hints.mouseGridSteps
    let region = MouseGrid.preparedRegion(
      MouseGrid.initialRegion(
        context: context,
        screens: NSScreen.screens,
        fallback: OverlayPanel.unionScreenFrame()),
      alphabet: config.resolvedAlphabet.chars,
      steps: steps)
    mouseGridRegion = region
    mouseGridInitialRegion = region
    mouseGridDepth = 0
    sourceAppPID = context?.processID
    pendingAction = command.action
    pendingClickModifiers = command.modifiers
    pendingHintCommitBehavior =
      command.isDrag ? .mouseGridDrag : command.isMove ? .mouseGridMove : .mouseGridClick
    currentPrefix = ""
    overlay.overlayConfig = config.overlay
    overlay.debugConfig = config.debug
    overlay.mouseGridOpacity = Float(config.hints.mouseGridOpacity)
    displayMouseGridRegion(region, depth: 0)
  }

  func displayMouseGridRegion(_ region: MouseGrid.Region, depth: Int) {
    let steps = config.hints.mouseGridSteps
    let region = MouseGrid.preparedRegion(
      region, alphabet: config.resolvedAlphabet.chars, steps: steps)
    mouseGridRegion = region
    // At the final visible step the renderer swaps to a compact chip
    // cluster centered on the past rectangle — give MouseGrid the exact
    // rendered chip dimensions so the cluster's geometry can never
    // disagree with the chip the user sees.
    let fontSize = CGFloat(config.overlay.fontSize)
    let finalChipSize = CGSize(
      width: OverlayPanel.chipWidth(forLabelLength: 1, fontSize: fontSize),
      height: OverlayPanel.chipHeight(forFontSize: fontSize))
    let hints = MouseGrid.hints(
      in: region,
      depth: depth,
      alphabet: config.resolvedAlphabet.chars,
      steps: steps,
      finalChipSize: finalChipSize)
    guard !hints.isEmpty else {
      applyModeOverlay()
      return
    }
    activationLifecycle.invalidate()
    currentHints = hints
    currentPrefix = ""
    // Single projection-driven writer (yields `.hints` with the grid hints up),
    // not a direct `overlay.inputMode` poke.
    applyModeOverlay()
    overlay.display(hints: hints)
  }

  private func activate(
    action: JumpAction,
    commitBehavior: HintCommitBehavior = .click,
    clickModifiers: ClickModifiers = [],
    targetFilter: ((JumpTarget) -> Bool)? = nil,
    contextOverride: AppContext? = nil
  ) {
    FlashLog.trace(
      "[activation] begin action=\(action) behavior=\(commitBehavior) mode=\(flashMode) "
        + "hints=\(currentHints.count) in_flight=\(activationInFlight) gen=\(activationGen)")

    // Cancel any in-flight walk and clear any visible hints. The
    // earlier "drop on busy" behaviour rejected the new trigger; the
    // user-facing rule now is "the most recent mouse target wins" —
    // pressing the hotkey again while hints are up restarts from
    // scratch (cancel current, kick off a fresh walk on the now-
    // focused window). cancelOverlay() bumps activationGen, so any
    // in-flight discoverAsync completion will see a stale generation
    // and bail before rendering.
    if activationInFlight || !currentHints.isEmpty {
      FlashLog.trace(
        "[activation] restart previous_in_flight=\(activationInFlight) "
          + "previous_hints=\(currentHints.count) gen=\(activationGen)")
      cancelOverlay()
    }

    guard let context = contextOverride ?? currentNonFlashContext() else {
      FlashLog.debug("[activation] no target app")
      FlashLog.trace(
        "[activation] no_context mode=\(flashMode) target_override=\(contextOverride != nil)")
      applyModeOverlay()
      return
    }
    FlashLog.debug(
      "[activation] target pid=\(context.processID) bundle=\(context.bundleIdentifier) "
        + "source=\(contextOverride == nil ? "focused" : "override")"
    )
    sourceAppPID = context.processID
    pendingAction = action
    pendingClickModifiers = clickModifiers
    pendingHintCommitBehavior = commitBehavior

    overlay.overlayConfig = config.overlay
    overlay.debugConfig = config.debug

    if !isAccessibilityTrusted() {
      promptForAccessibility()
      FlashLog.debug(
        "[activation] accessibility_denied pid=\(context.processID) "
          + "bundle=\(context.bundleIdentifier)"
      )
      applyModeOverlay()
      return
    }

    let myGen = activationLifecycle.begin()
    // Route through the single projection-driven writer (which yields `.hints`
    // while a walk is in flight) instead of a direct `overlay.inputMode` poke, so
    // inputMode + capture can't drift from the mode.
    applyModeOverlay()
    FlashLog.trace(
      "[activation] dispatch_discover gen=\(myGen) pid=\(context.processID) "
        + "bundle=\(context.bundleIdentifier)")
    monitor.discoverAsync(
      context: context,
      targetFilter: targetFilter
    ) { [weak self] hints in
      guard let self else { return }
      self.activationLifecycle.complete(token: myGen)
      FlashLog.trace(
        "[activation] discover_complete gen=\(myGen) current_gen=\(self.activationGen) "
          + "hints=\(hints.count) mode=\(self.flashMode)")
      // The walk is done; gate is open for the next activation
      // regardless of whether *this* walk's result is still relevant.
      guard self.activationLifecycle.isCurrent(myGen) else {
        FlashLog.debug(
          "[activation] stale_generation pid=\(context.processID) "
            + "bundle=\(context.bundleIdentifier)"
        )
        return
      }
      // Left-click hints (`f`) also label the Flash status bar's `#[link=…]`
      // runs, but only on the bar sitting on the active window's screen — so
      // the visible links get a hint without duplicating them across every
      // mirrored bar.
      let statusBarTargets: [JumpTarget] =
        commitBehavior == .click && action == .leftClick
        ? self.statusBarLinkTargets(forActiveWindowFrame: context.frontWindowFrame)
        : []

      if hints.isEmpty {
        // Empty result is also the symptom of accessibility
        // permission being revoked between activations: AX walks
        // silently return [] when the process is no longer trusted.
        // Cheap to re-check — and we want the permission banner to
        // appear instead of the user staring at nothing. Surface it
        // regardless of any status-bar links (which don't need AX).
        if !PermissionCheck.isAccessibilityTrusted {
          self.cachedAccessibilityTrusted = false
          self.promptForAccessibility()
          FlashLog.debug(
            "[activation] accessibility_revoked pid=\(context.processID) "
              + "bundle=\(context.bundleIdentifier)"
          )
          self.applyModeOverlay()
          return
        }
        if statusBarTargets.isEmpty {
          FlashLog.debug(
            "[activation] no_targets pid=\(context.processID) "
              + "bundle=\(context.bundleIdentifier)"
          )
          self.applyModeOverlay()
          return
        }
      }
      // Re-assign labels over the combined set so the app targets and the
      // status-bar links share one prefix-free alphabet (app targets keep the
      // shorter labels — they come first).
      let displayHints =
        statusBarTargets.isEmpty
        ? hints
        : self.assignHints(hints.map(\.target) + statusBarTargets)
      self.currentHints = displayHints
      self.currentPrefix = ""
      self.overlay.display(hints: displayHints)
      FlashLog.debug(
        "[activation] displayed pid=\(context.processID) "
          + "bundle=\(context.bundleIdentifier) hints=\(displayHints.count) "
          + "status_links=\(statusBarTargets.count)"
      )
    }
  }

  /// Assign prefix-free hint labels over `targets` using the active alphabet —
  /// the same policy `AppMonitor` uses, so a re-assembled hint set (app targets
  /// + status-bar links) stays consistent with a plain discovery result.
  private func assignHints(_ targets: [JumpTarget]) -> [AssignedHint] {
    let resolved = config.resolvedAlphabet
    return HintAssigner.assign(
      targets: targets,
      alphabet: resolved.chars,
      leftHand: resolved.leftHand,
      keyScores: resolved.keyScores,
      minLength: config.hints.minLength)
  }

  /// Hint targets for the Flash status bar's `#[link=…]` runs on the bar that
  /// sits on the active window's screen. The rects are captured each render
  /// (`configureModeBadge`) in screen coordinates; here we pick the screen the
  /// focused window predominantly occupies and turn each link run into a
  /// `JumpTarget`. Commit posts the same host click as every other hint, and
  /// `StatusBarClickView` handles it through normal Cocoa hit-testing.
  /// Returns `[]` when the bar is hidden or the active window is on a screen
  /// without a bar.
  private func statusBarLinkTargets(forActiveWindowFrame windowFrame: CGRect) -> [JumpTarget] {
    let byScreen = overlay.statusBarLinkRectsByScreen
    guard !byScreen.isEmpty, !windowFrame.isNull else { return [] }
    func overlapArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
      let r = a.intersection(b)
      return r.isNull ? 0 : r.width * r.height
    }
    guard
      let best = byScreen.max(by: {
        overlapArea($0.screenFrame, windowFrame) < overlapArea($1.screenFrame, windowFrame)
      }),
      overlapArea(best.screenFrame, windowFrame) > 0
    else { return [] }
    return best.links.enumerated().map { idx, link in
      // A short, leading-edge chip: the 2pt-high frame makes `chipFrame` centre
      // the chip on the bar band's midline and anchor it to the run's leading
      // edge (the run is wider than a chip), so the label lands over the link.
      let frame = CGRect(
        x: link.rect.minX,
        y: link.rect.midY - 1,
        width: max(link.rect.width, 1),
        height: 2)
      return JumpTarget(
        id: "statusbar_link_\(idx)_\(link.url.absoluteString)",
        frame: frame,
        role: "AXLink",
        url: link.url.absoluteString,
        entersInsertMode: false,
        providerID: "statusbar")
    }
  }

  private func isAccessibilityTrusted() -> Bool {
    if cachedAccessibilityTrusted { return true }
    let trusted = PermissionCheck.isAccessibilityTrusted
    if trusted { cachedAccessibilityTrusted = true }
    return trusted
  }

  func cancelOverlay() {
    FlashLog.trace(
      "[overlay] cancel hints=\(currentHints.count) in_flight=\(activationInFlight) "
        + "mode=\(flashMode) gen=\(activationGen) input=\(overlay.inputMode)")
    if overlay.inputMode == .commandLine {
      finishCommandLineInteraction(reason: "cancel_overlay")
      return
    }
    // Dismissal observers fire on every app switch, including when no
    // transient overlay is up. Even then, re-render the mode badge so
    // normal mode can immediately recapture keyboard input.
    if currentHints.isEmpty && !activationInFlight {
      overlay.hide()
      let captureOverride =
        Self.pointerInsertHandoffRecaptureSuppressionIsActive(
          until: pointerInsertHandoffRecaptureSuppressedUntil)
        ? false : nil
      applyModeOverlay(captureOverride: captureOverride)
      return
    }
    overlay.hide()
    clearHintSessionState()
    invalidateActivation(reason: "cancel_overlay")
    applyModeOverlay()
  }

  func promptForAccessibility() {
    // Open the Privacy & Security → Accessibility pane directly.
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    {
      let now = Date()
      if let last = lastPermissionPromptAt, now.timeIntervalSince(last) < 5 {
        // Settings was already opened recently; don't re-open.
      } else {
        NSWorkspace.shared.open(url)
        lastPermissionPromptAt = now
      }
    }
    let bundlePath = Bundle.main.bundlePath
    let lines = [
      "Flash needs Accessibility permission",
      "to read clickable elements from the focused app",
      "and to dispatch the click on commit.",
      "",
      "System Settings → Privacy & Security → Accessibility",
      "",
      "If Flash is NOT in the list:",
      "  Click '+' and add this exact path:",
      "  \(bundlePath)",
      "  Then enable the toggle.",
      "",
      "If Flash IS already in the list (toggle ON):",
      "  The grant is bound to the previous binary's hash.",
      "  Toggle Flash OFF then ON to re-bind to the current build.",
      "  (./Scripts/install.sh --dev resets this for you next time.)",
      "",
      "System Settings has been opened.",
    ]
    overlay.displayBanner(lines.joined(separator: "\n"), durationMs: 10_000)
  }
}
