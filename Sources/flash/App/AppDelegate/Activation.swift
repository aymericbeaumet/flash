import AppKit
import ApplicationServices
import Carbon.HIToolbox
import FlashCore
import FlashProviders

/// Activation pipeline: from a `URLCommand` (CLI / Apple Event / native
/// mapping) to the OverlayPanel showing hint chips. Handles the
/// activation generation token, the prepared-model lookup, and the
/// no-targets / accessibility-revoked exit paths.
extension AppDelegate {
  // MARK: Activation

  func activateMouseTarget(_ command: MouseCommand, contextOverride: AppContext?) {
    let behavior: HintCommitBehavior = command.isMove ? .moveMouse : .click
    activate(action: command.action, commitBehavior: behavior, contextOverride: contextOverride)
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
    mouseGridDepth = 0
    sourceAppPID = context?.processID
    pendingAction = command.action
    pendingHintCommitBehavior = command.isMove ? .mouseGridMove : .mouseGridClick
    currentPrefix = ""
    overlay.overlayConfig = config.overlay
    overlay.debugConfig = config.debug
    overlay.mouseGridSteps = steps
    displayMouseGridRegion(region, depth: 0)
  }

  func displayMouseGridRegion(_ region: MouseGrid.Region, depth: Int) {
    let steps = config.hints.mouseGridSteps
    let region = MouseGrid.preparedRegion(
      region, alphabet: config.resolvedAlphabet.chars, steps: steps)
    mouseGridRegion = region
    let hints = MouseGrid.hints(
      in: region,
      depth: depth,
      alphabet: config.resolvedAlphabet.chars,
      steps: steps)
    guard !hints.isEmpty else {
      applyModeOverlay()
      return
    }
    activationGen &+= 1
    activationInFlight = false
    activationInFlightGeneration = nil
    currentHints = hints
    currentPrefix = ""
    overlay.inputMode = .hints
    overlay.display(hints: hints)
  }

  private func activate(
    action: JumpAction,
    commitBehavior: HintCommitBehavior = .click,
    targetFilter: ((JumpTarget) -> Bool)? = nil,
    contextOverride: AppContext? = nil
  ) {
    let profiler = FlashProfiler(kind: "activation", debug: config.debug)
    profiler.mark("url", detail: "action=\(action)")
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
    let wasBusy = activationInFlight || !currentHints.isEmpty
    if wasBusy {
      FlashLog.trace(
        "[activation] restart previous_in_flight=\(activationInFlight) "
          + "previous_hints=\(currentHints.count) gen=\(activationGen)")
      cancelOverlay()
      profiler.mark(
        "restart",
        detail: "in_flight=\(activationInFlight) visible_hints=\(currentHints.count)")
    }

    let contextStart = profiler.intervalStart()
    guard let context = contextOverride ?? currentNonFlashContext() else {
      FlashLog.debug("[activation] no target app")
      FlashLog.trace("[activation] no_context mode=\(flashMode) target_override=\(contextOverride != nil)")
      profiler.finish(outcome: "no_context")
      applyModeOverlay()
      return
    }
    FlashLog.debug(
      "[activation] target pid=\(context.processID) bundle=\(context.bundleIdentifier) "
        + "source=\(contextOverride == nil ? "focused" : "override")"
    )
    profiler.finishInterval(
      "current_context",
      since: contextStart,
      detail: "pid=\(context.processID) bundle=\(context.bundleIdentifier)"
    )
    sourceAppPID = context.processID
    pendingAction = action
    pendingHintCommitBehavior = commitBehavior

    overlay.overlayConfig = config.overlay
    overlay.debugConfig = config.debug

    let permissionStart = profiler.intervalStart()
    if !isAccessibilityTrusted() {
      profiler.finishInterval(
        "accessibility_check", since: permissionStart, detail: "trusted=false")
      promptForAccessibility()
      profiler.finish(
        outcome: "accessibility_denied",
        detail: "pid=\(context.processID) bundle=\(context.bundleIdentifier)")
      FlashLog.debug(
        "[activation] accessibility_denied pid=\(context.processID) "
          + "bundle=\(context.bundleIdentifier)"
      )
      applyModeOverlay()
      return
    }
    profiler.finishInterval("accessibility_check", since: permissionStart, detail: "trusted=true")

    activationGen &+= 1
    let myGen = activationGen
    activationInFlight = true
    activationInFlightGeneration = myGen
    overlay.inputMode = .hints
    FlashLog.trace(
      "[activation] dispatch_discover gen=\(myGen) pid=\(context.processID) "
        + "bundle=\(context.bundleIdentifier)")
    monitor.discoverAsync(
      context: context,
      profiler: profiler,
      targetFilter: targetFilter
    ) { [weak self] hints in
      guard let self else { return }
      if self.activationInFlightGeneration == myGen {
        self.activationInFlight = false
        self.activationInFlightGeneration = nil
      }
      FlashLog.trace(
        "[activation] discover_complete gen=\(myGen) current_gen=\(self.activationGen) "
          + "hints=\(hints.count) mode=\(self.flashMode)")
      // The walk is done; gate is open for the next activation
      // regardless of whether *this* walk's result is still relevant.
      guard self.activationGen == myGen else {
        profiler.finish(
          outcome: "stale_generation",
          detail: "pid=\(context.processID) bundle=\(context.bundleIdentifier)")
        FlashLog.debug(
          "[activation] stale_generation pid=\(context.processID) "
            + "bundle=\(context.bundleIdentifier)"
        )
        return
      }
      if hints.isEmpty {
        // Empty result is also the symptom of accessibility
        // permission being revoked between activations: AX walks
        // silently return [] when the process is no longer trusted.
        // Cheap to re-check — and we want the permission banner to
        // appear instead of the user staring at nothing.
        if !PermissionCheck.isAccessibilityTrusted {
          self.cachedAccessibilityTrusted = false
          self.promptForAccessibility()
          profiler.finish(
            outcome: "accessibility_revoked",
            detail: "pid=\(context.processID) bundle=\(context.bundleIdentifier)")
          FlashLog.debug(
            "[activation] accessibility_revoked pid=\(context.processID) "
              + "bundle=\(context.bundleIdentifier)"
          )
        } else {
          profiler.finish(
            outcome: "no_targets",
            detail: "pid=\(context.processID) bundle=\(context.bundleIdentifier)")
          FlashLog.debug(
            "[activation] no_targets pid=\(context.processID) "
              + "bundle=\(context.bundleIdentifier)"
          )
        }
        self.applyModeOverlay()
        return
      }
      self.currentHints = hints
      self.currentPrefix = ""
      let displayStart = profiler.intervalStart()
      self.overlay.display(hints: hints)
      profiler.finishInterval(
        "overlay_display", since: displayStart, detail: "hints=\(hints.count)")
      profiler.finish(
        outcome: "displayed",
        detail: "pid=\(context.processID) bundle=\(context.bundleIdentifier) hints=\(hints.count)")
      FlashLog.debug(
        "[activation] displayed pid=\(context.processID) "
          + "bundle=\(context.bundleIdentifier) hints=\(hints.count)"
      )
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
      applyModeOverlay()
      return
    }
    overlay.hide()
    currentHints = []
    currentPrefix = ""
    sourceAppPID = nil
    mouseGridRegion = nil
    mouseGridDepth = 0
    pendingHintCommitBehavior = .click
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
      "  (./Scripts/dev.sh resets this for you next time.)",
      "",
      "System Settings has been opened.",
    ]
    overlay.displayBanner(lines.joined(separator: "\n"), durationMs: 10_000)
  }
}
