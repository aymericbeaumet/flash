import AppKit
import FlashCore

/// `:apps` — a hint-based app switcher. Paints one hint chip on each running
/// app's front on-screen window (across all apps and monitors); committing a
/// hint raises that app. Switching is one keystroke and spatial rather than the
/// Cmd-Tab MRU dance.
///
/// v1 scope: one chip per app, on its topmost visible window. Two deliberate
/// fast-follows (both need more than the current hint pipeline can express):
///   - per-window switching (raise a *specific* window via AX `kAXRaiseAction`);
///   - apps with no on-screen window (hidden / minimised / another Space) —
///     hinting those needs the chip to show an app NAME, which the letter-chip
///     renderer doesn't do yet. Those apps remain reachable via `:flashlight`.
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

  /// One JumpTarget per switchable app, anchored on that app's front-most
  /// on-screen interaction window. Commit raises the owning app.
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

    return Self.appSwitcherTopWindows(entries: entries, switchablePIDs: Set(appByPID.keys))
      .compactMap { window in
        guard let app = appByPID[window.pid] else { return nil }
        return JumpTarget(
          id: "apps:\(window.pid)",
          frame: window.frame,
          pid: window.pid,
          activate: { _ in
            RunningApplicationActivation.activate(app, options: [.activateAllWindows])
          },
          providerID: "core.apps")
      }
  }

  /// The front-most on-screen interaction window for each switchable pid, in
  /// z-order (front app first). Pure so the dedup/ordering is unit-testable.
  /// `entries` must be front-to-back (CGWindowList order).
  static func appSwitcherTopWindows(
    entries: [WindowSnapshot.Entry],
    switchablePIDs: Set<pid_t>
  ) -> [(pid: pid_t, frame: CGRect)] {
    var seen: Set<pid_t> = []
    var out: [(pid: pid_t, frame: CGRect)] = []
    for entry in entries
    where WindowSnapshot.isInteractionSurfaceLayer(entry.layer)
      && switchablePIDs.contains(entry.pid)
    {
      if seen.insert(entry.pid).inserted {
        out.append((entry.pid, entry.nsBounds))
      }
    }
    return out
  }

  static func appSwitcherIsIgnored(_ app: NSRunningApplication, ignored: Set<String>) -> Bool {
    if let name = app.localizedName?.lowercased(), ignored.contains(name) { return true }
    if let bundleID = app.bundleIdentifier?.lowercased(), ignored.contains(bundleID) {
      return true
    }
    return false
  }
}
