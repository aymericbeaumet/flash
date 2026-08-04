import AppKit
import Darwin
import FlashCore

extension OverlayPanel {
  /// Install the dismissal event monitors once at `init`. The closures
  /// gate on overlay state so transient (hint) and capture (normal-mode)
  /// surfaces share one monitor pair instead of churning install/remove
  /// per activation.
  ///
  /// Dismissal triggers: scroll wheel, any mouse-button press. Mouse
  /// move is intentionally NOT a dismissal trigger because the
  /// pointer can drift past the overlay while the user is reaching
  /// for a key. Non-matching keystrokes are dismissed by
  /// `AppDelegate.overlayDidCommit` when no hint label matches the
  /// running prefix.
  func installPointerMonitors() {
    let mask: NSEvent.EventTypeMask = [
      .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
    ]
    pointerGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) {
      [weak self] event in
      self?.deliverPointerIntent(for: event)
    }
    pointerLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) {
      [weak self] event in
      self?.deliverPointerIntent(for: event)
      return event
    }
  }

  private func deliverPointerIntent(for event: NSEvent) {
    guard pointerMonitorShouldDispatch() else { return }
    // Drop our own synthesized scroll/click events (keyboard-driven
    // normal-mode scrolling, hint clicks) so they don't bounce back
    // through this monitor and flip Flash into insert mode.
    if event.cgEvent?.getIntegerValueField(.eventSourceUserData)
      == ActionDispatcher.syntheticMouseEventTag
    {
      return
    }
    // A click on Flash's own status-bar window (a `#[link=…]` run, or the
    // click-through band) is Flash UI, not an app interaction — the local
    // monitor sees it because the panel is in this process. Never treat it as a
    // "clicked the app" intent (which would flip NORMAL → INSERT). This matters
    // under an auto-hidden menu bar, where `pointIsInMenuBar` sees a zero-height
    // reserved band and would otherwise route the click to the app decision.
    if event.window is StatusBarClickPanel {
      return
    }
    // A scroll wheel event only has a job when transient hint content is
    // showing — then a scroll means "let me read the page", so the hints get
    // out of the way (`pointerDecision` returns `.cancelOverlay`). In every
    // other state (idle NORMAL, command line, candidate finder) the decision is
    // a guaranteed no-op `.passThrough`, so drop the event here rather than
    // paying a `DispatchQueue.main.async` hop + policy call + `FlashLog.trace`
    // per tick. A single inertial-scroll gesture emits ~125 events/sec; without
    // this gate that flooded the main run loop with no-op dispatches (and, at
    // trace level, that many log writes), starving the keyboard-capture tap that
    // shares the run loop — felt as laggy mode switches and even sluggish ⌘Tab,
    // worst in scroll-heavy apps like Notes. Once the first scroll dismisses the
    // hints, `transientContentVisible` flips false and the rest of the gesture is
    // dropped here too.
    if event.type == .scrollWheel, !transientContentVisible {
      return
    }
    let intent: OverlayPointerIntent =
      event.type == .scrollWheel ? .scroll : .click(Self.pointerClick(event))
    DispatchQueue.main.async { [weak self] in
      self?.coordinator?.overlayDidCancelByPointer(intent)
    }
  }

  private func pointerMonitorShouldDispatch() -> Bool {
    // Transient surfaces (hint chips, banner, modal-without-text) all
    // dismiss on pointer input. Normal-mode capture also dismisses,
    // matching the previous "pointerIntent" gate.
    if transientContentVisible { return true }
    return Self.pointerIntentMonitorShouldRun(
      inputMode: inputMode,
      modeBadgeVisible: modeBadgeVisible,
      modeBadgeCapturesInput: modeBadgeCapturesInput)
  }

  static func pointerIntentMonitorShouldRun(
    inputMode: OverlayInputMode,
    modeBadgeVisible: Bool,
    modeBadgeCapturesInput: Bool
  ) -> Bool {
    // Command line + candidate finder both dismiss on any click outside
    // their (mouse-event-ignoring) panel — the click reaches the
    // underlying app via `ignoresMouseEvents = true`, and the global
    // monitor lets us recognise it as an "interact with something else"
    // signal worth tearing the prompt down for.
    if inputMode == .commandLine || inputMode == .candidateFinder {
      return true
    }
    // Idle NORMAL must run the monitor so a click on the focused app (e.g. a
    // website text field) is recognised and enters insert. It is intentionally
    // NOT gated on `modeBadgeCapturesInput` because capture can be temporarily
    // suppressed while the mode surface still needs click-intent classification.
    _ = modeBadgeCapturesInput
    return inputMode == .normal && modeBadgeVisible
  }

  private static func pointerClick(_ event: NSEvent? = nil) -> OverlayPointerClick {
    let action: JumpAction
    if event?.type == .rightMouseDown {
      action = .rightClick
    } else if (event?.clickCount ?? 1) >= 2 {
      action = .doubleClick
    } else {
      action = .leftClick
    }
    let modifiers = ClickModifiers(
      eventFlags: event?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? [],
      allowed: .all)
    let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
    let flashWasActive =
      NSApp.isActive
      || frontmostPID == getpid()
    return OverlayPointerClick(
      action: action,
      location: NSEvent.mouseLocation,
      modifiers: modifiers,
      flashWasActive: flashWasActive,
      frontmostPIDAtClick: frontmostPID)
  }

  func removePointerMonitors() {
    for m in [pointerGlobalMonitor, pointerLocalMonitor] {
      if let m { NSEvent.removeMonitor(m) }
    }
    pointerGlobalMonitor = nil
    pointerLocalMonitor = nil
  }
}
