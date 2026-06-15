import AppKit
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
    // Modal mode owns its own scroll view: a wheel tick over the help /
    // `:plugins` / `:clipboard` panel scrolls the content directly via
    // the embedded `NSScrollView`. Cancelling on every wheel event made
    // those modals impossible to scroll with the trackpad — the first
    // tick dismissed the modal before the user could read past the
    // viewport. Clicks still dismiss (handled by the dedicated modal
    // dismiss monitors with their own hit-test against the panel).
    if inputMode == .modal, event.type == .scrollWheel {
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
    return inputMode == .normal && modeBadgeVisible && modeBadgeCapturesInput
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
    return OverlayPointerClick(
      action: action,
      location: NSEvent.mouseLocation,
      modifiers: modifiers)
  }

  func removePointerMonitors() {
    for m in [pointerGlobalMonitor, pointerLocalMonitor] {
      if let m { NSEvent.removeMonitor(m) }
    }
    pointerGlobalMonitor = nil
    pointerLocalMonitor = nil
  }

  func installModalDismissMonitors() {
    removeModalDismissMonitors()
    let clickMask: NSEvent.EventTypeMask = [
      .leftMouseDown, .rightMouseDown, .otherMouseDown,
    ]
    modalClickGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: clickMask) {
      [weak self] _ in
      DispatchQueue.main.async {
        guard let self, self.inputMode == .modal else { return }
        self.coordinator?.overlayDidCancelModal()
      }
    }
    modalClickLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: clickMask) {
      [weak self] event in
      guard let self, self.inputMode == .modal else { return event }
      guard event.window === self else { return event }
      if self.modalScrollView.frame.contains(event.locationInWindow) {
        return event
      }
      DispatchQueue.main.async {
        self.coordinator?.overlayDidCancelModal()
      }
      return nil
    }
  }

  func removeModalDismissMonitors() {
    for m in [modalClickGlobalMonitor, modalClickLocalMonitor] {
      if let m { NSEvent.removeMonitor(m) }
    }
    modalClickGlobalMonitor = nil
    modalClickLocalMonitor = nil
  }
}
