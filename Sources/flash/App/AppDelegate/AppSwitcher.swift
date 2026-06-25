import AppKit
import FlashCore

/// `:apps` — a hint-based window switcher. Paints a hint chip on every visible
/// window of every running app, across all apps and monitors; committing a hint
/// raises the owning app. Switching is one keystroke and spatial rather than the
/// Cmd-Tab MRU dance.
///
/// Two deliberate fast-follows: (1) raising a *specific* window — multiple
/// windows of one app currently all raise the app's front window (needs AX
/// `kAXRaiseAction` + reliable CGWindow↔AXWindow matching); (2) a horizontal
/// strip of app ICONS for apps with no on-screen window — that needs the overlay
/// to render images, which the letter-chip path doesn't do yet.
extension AppDelegate {
  func presentAppSwitcher() {
    let targets = appSwitcherWindowTargets()
    guard !targets.isEmpty else {
      overlay.displayBanner("No windows to switch to")
      applyModeOverlay()
      return
    }
    let hints = HintAssigner.assign(targets: targets, alphabet: config.resolvedAlphabet.chars)
    // Mirror the synthetic-hint session setup (see displayMouseGridRegion): bump
    // the activation generation, clear transient state, install the hints, and
    // take over the overlay in hint-input mode.
    activationGen &+= 1
    activationInFlight = false
    activationInFlightGeneration = nil
    clearHintSessionState()
    currentHints = hints
    pendingAction = .leftClick
    overlay.overlayConfig = config.overlay
    overlay.debugConfig = config.debug
    overlay.inputMode = .hints
    overlay.display(hints: hints)
    FlashLog.trace("[apps] switcher shown windows=\(targets.count)")
  }

  /// One JumpTarget per visible interaction window of every switchable app, at
  /// the window's real frame. Commit raises the owning app.
  private func appSwitcherWindowTargets() -> [JumpTarget] {
    let flashPID = ProcessInfo.processInfo.processIdentifier
    let ignored = Set(config.open.ignoredApps.map { $0.lowercased() })
    let switchable = NSWorkspace.shared.runningApplications.filter { app in
      app.activationPolicy == .regular && !app.isTerminated
        && app.processIdentifier != flashPID
        && !Self.appSwitcherIsIgnored(app, ignored: ignored)
    }
    let appByPID = Dictionary(
      switchable.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { first, _ in first })

    let primaryH = ActionDispatcher.primaryScreenHeight()
    guard
      let info = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return [] }
    let entries = WindowSnapshot.entries(from: info, primaryH: primaryH)

    return Self.appSwitcherVisibleWindows(entries: entries, switchablePIDs: Set(appByPID.keys))
      .compactMap { window in
        guard let app = appByPID[window.pid] else { return nil }
        return JumpTarget(
          id: "apps:\(window.pid):\(Int(window.frame.minX)):\(Int(window.frame.minY))",
          frame: window.frame,
          pid: window.pid,
          activate: { _ in
            RunningApplicationActivation.activate(app, options: [.activateAllWindows])
          },
          providerID: "core.apps")
      }
  }

  /// Every visible interaction-surface window owned by a switchable pid, in
  /// z-order (front-most first). Pure so the filter/ordering is unit-testable.
  /// `entries` must be front-to-back (CGWindowList order).
  static func appSwitcherVisibleWindows(
    entries: [WindowSnapshot.Entry],
    switchablePIDs: Set<pid_t>
  ) -> [(pid: pid_t, frame: CGRect)] {
    entries
      .filter {
        WindowSnapshot.isInteractionSurfaceLayer($0.layer) && switchablePIDs.contains($0.pid)
      }
      .map { (pid: $0.pid, frame: $0.nsBounds) }
  }

  static func appSwitcherIsIgnored(_ app: NSRunningApplication, ignored: Set<String>) -> Bool {
    if let name = app.localizedName?.lowercased(), ignored.contains(name) { return true }
    if let bundleID = app.bundleIdentifier?.lowercased(), ignored.contains(bundleID) {
      return true
    }
    return false
  }
}
