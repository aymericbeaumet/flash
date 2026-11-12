import AppKit
import FlashCore

/// The panel's switcher route reaches the coordinator through this, as the
/// surface switch does (`OverlaySurfaceSwitching`).
protocol OverlayWindowSwitching: AnyObject {
  /// One key while the switcher is up.
  func overlayDidSwitchWindow(_ command: WindowSwitcherKeyCommand)
}

/// `window switch`: every window of every app, most recently focused first,
/// in a list on the hint overlay. Each row has a hint label, so one key
/// picks a window; Tab, Shift-Tab and the arrows move the selection and
/// Return chooses it. The list stays up until a label, Return or Escape:
/// nothing holds a modifier for it, so no chord opens it by default.
///
/// The list is a hint-session phase, like a confirmation: the tap swallows
/// and routes every key to it in every mode, and the focused app stays
/// active until a window is chosen. Opening it reads only memory
/// (`WindowSwitcherCatalog`); choosing raises the window on the window
/// layout AX queue and activates its app.
extension AppDelegate: OverlayWindowSwitching {
  func performWindowSwitch() {
    if hintSession.windowSwitcher != nil {
      // `window switch` again while the list is up, from the CLI or a chord
      // Carbon delivered (no live tap): the next window.
      applyWindowSwitcher(.move(1))
      return
    }
    presentWindowSwitcher()
  }

  /// `window last` (tmux's `last-window`, vim's `ctrl-w p`): the window the
  /// switcher would open on, focused at once. Nothing to go back to stays
  /// silent.
  func performWindowLast() {
    let windows = windowSwitcherCatalog.rows
    let current = windowSwitcherCatalog.current
    let selection = WindowSwitcherPlanner.initialSelection(rows: windows, current: current)
    guard windows.indices.contains(selection), windows[selection].id != current else {
      FlashLog.debug("[switcher] last: no previous window")
      return
    }
    focusWindowSwitcherChoice(windows[selection].id)
  }

  func presentWindowSwitcher() {
    let windows = windowSwitcherCatalog.rows
    // Nothing to switch to stays silent, as empty hint discovery does.
    guard !windows.isEmpty else {
      FlashLog.debug("[switcher] no_windows")
      return
    }
    // Where the user is looking: the focused window's display, from the
    // frame its border strokes or last cached (read before the session hides
    // the border), else the pointer's.
    let focusedFrame =
      overlay.activeWindowBorderFrame
      ?? lastFocusedApplicationPID.flatMap { activeWindowBorderFrameCache[$0] }
    let anchor = focusedFrame.map { CGPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
    guard prepareHintActivation(.windowSwitcher) else { return }
    windowSwitcherFocusGeneration &+= 1
    let selection = WindowSwitcherPlanner.initialSelection(
      rows: windows, current: windowSwitcherCatalog.current)
    var state = WindowSwitcherState(
      rows: windowSwitcherRows(windows, selection: selection), selection: selection)
    state.anchor = anchor
    hintSession.phase = .switching(state)
    applyModeOverlay()
    drawWindowSwitcher(state)
    FlashLog.debug("[switcher] open rows=\(windows.count)")
  }

  /// Labels from the hint alphabet, one key each while the alphabet covers
  /// every window, the easiest on the row the selection starts on.
  private func windowSwitcherRows(
    _ windows: [WindowSwitcherCatalog.Window], selection: Int
  ) -> [WindowSwitcherRow<WindowSwitcherKey>] {
    let resolved = config.resolvedAlphabet
    let labels = HintAssigner.generateLabels(
      count: windows.count, alphabet: resolved.chars, leftHand: resolved.leftHand,
      keyScores: resolved.keyScores, keyRows: resolved.keyRows, minLength: 1)
    var labelByRow = [String](repeating: "", count: windows.count)
    for (label, row) in zip(
      labels, WindowSwitcherPlanner.labelOrder(count: windows.count, first: selection))
    {
      labelByRow[row] = label.lowercased()
    }
    let hidden = Set(
      NSWorkspace.shared.runningApplications.lazy.filter(\.isHidden).map(\.processIdentifier))
    return windows.enumerated().map { index, window in
      WindowSwitcherRow(
        window: window, label: labelByRow[index],
        app: windowSwitcherCatalog.appName(for: window.pid) ?? "",
        appHidden: hidden.contains(window.pid))
    }
  }

  func overlayDidSwitchWindow(_ command: WindowSwitcherKeyCommand) {
    guard hintSession.windowSwitcher != nil else {
      cancelOverlay()
      return
    }
    applyWindowSwitcher(command)
  }

  private func applyWindowSwitcher(_ command: WindowSwitcherKeyCommand) {
    guard var state = hintSession.windowSwitcher else { return }
    switch state.apply(command) {
    case .redraw:
      hintSession.phase = .switching(state)
      drawWindowSwitcher(state)
    case .choose(let row):
      FlashLog.debug(
        "[switcher] choose pid=\(row.window.pid) badge=\(row.badge?.rawValue ?? "-")")
      noteHintCommitted()
      cancelOverlay()
      focusWindowSwitcherChoice(row.window.id)
    case .cancel:
      cancelOverlay()
    case .ignore:
      break
    }
  }

  /// The first draw of a session logs `[latency] hints_visible
  /// surface=window_switcher` once Core Animation committed it.
  private func drawWindowSwitcher(_ state: WindowSwitcherState<WindowSwitcherKey>) {
    let display = WindowSwitcherDisplay(
      rows: state.rows.map { row in
        WindowSwitcherDisplay.Row(
          label: row.label.uppercased(), app: row.app, title: row.window.title,
          badge: row.badge?.rawValue, icon: windowSwitcherCatalog.icon(for: row.window.pid))
      },
      selection: state.selection, typed: state.typed.uppercased(), anchor: state.anchor)
    announceHintSession(surface: "window_switcher", targets: state.rows.count)
    guard let probe = hintSession.latencyProbe else {
      overlay.displayWindowSwitcher(display)
      return
    }
    hintSession.latencyProbe = nil
    let rows = state.rows.count
    CATransaction.begin()
    CATransaction.setCompletionBlock {
      let visibleAt = ProcessInfo.processInfo.systemUptime
      let line = probe.line(
        visibleAt: visibleAt, prepared: .none, outcome: .none, targets: rows, appClass: .other,
        bundleIdentifier: nil, surface: "window_switcher", missReason: nil)
      Trace.run(in: probe.trace) { FlashLog.info(line) }
      probe.recordTelemetry(
        endedAt: visibleAt, surface: "window_switcher",
        outcome: HintLatencyProbe.Outcome.none.rawValue,
        appClass: HintLatencyProbe.AppClass.other.rawValue, targets: rows)
    }
    overlay.displayWindowSwitcher(display)
    CATransaction.commit()
  }

  /// Bring the chosen window forward: unhide its app, then, on the window
  /// layout AX queue, check the element still is that app's window,
  /// unminimize and raise it, and activate the app. A window that closed
  /// since the list was read focuses nothing. A switcher opened meanwhile
  /// owns what comes forward next, so this one no longer activates.
  func focusWindowSwitcherChoice(_ key: WindowSwitcherKey) {
    guard let app = NSRunningApplication(processIdentifier: key.pid), !app.isTerminated else {
      FlashLog.warn("[switcher] app_gone pid=\(key.pid); nothing focused")
      return
    }
    windowSwitcherFocusGeneration &+= 1
    let generation = windowSwitcherFocusGeneration
    if app.isHidden { app.unhide() }
    windowLayoutManager.focusSwitcherWindow(pid: key.pid, window: key.element) {
      [weak self] raised in
      guard let self else { return }
      guard raised else {
        FlashLog.warn("[switcher] window_gone pid=\(key.pid); nothing focused")
        self.windowSwitcherCatalog.windowsMayHaveChanged(pid: key.pid)
        return
      }
      guard generation == self.windowSwitcherFocusGeneration else { return }
      // Only the raised window comes forward, not all of the app's: a
      // window switcher moves one window, where `app next` moves the app.
      RunningApplicationActivation.activate(app, options: [], restoringMinimizedWindows: false)
      self.preparePendingApplicationActivation(app, reason: "window_switcher")
      self.scheduleNormalModeRecapture()
    }
  }

  /// `@windows`: the switcher's catalog as flashlight rows, with the same
  /// badges, read from memory on main.
  func windowListRows() -> (rows: [WindowListSource.Row], current: WindowSwitcherKey?) {
    let hidden = Set(
      NSWorkspace.shared.runningApplications.lazy.filter(\.isHidden).map(\.processIdentifier))
    let rows = windowSwitcherCatalog.rows.map { window in
      let row = WindowSwitcherRow(
        window: window, label: "", app: windowSwitcherCatalog.appName(for: window.pid) ?? "",
        appHidden: hidden.contains(window.pid))
      return WindowListSource.Row(
        key: window.id, title: window.title, app: row.app, badge: row.badge?.rawValue)
    }
    return (rows, windowSwitcherCatalog.current)
  }

  // MARK: Catalog events

  /// The regular apps the switcher lists, in launch order, Flash excluded.
  func windowSwitcherAppPIDs() -> [pid_t] {
    let flash = ProcessInfo.processInfo.processIdentifier
    return NSWorkspace.shared.runningApplications
      .filter { $0.activationPolicy == .regular && !$0.isTerminated }
      .map(\.processIdentifier)
      .filter { $0 != flash }
  }

  /// Read every app's windows again: at launch, when an app launches or
  /// quits and when the active Space changes. The apps stacked on the
  /// active Space, front first, order the windows nobody focused yet; the
  /// window list is read here, on main, never on the build queue.
  func refreshWindowSwitcherCatalog() {
    let flash = ProcessInfo.processInfo.processIdentifier
    let stacked =
      (WindowSnapshot.windowList([.optionOnScreenOnly, .excludeDesktopElements]) ?? [])
      .compactMap { info -> pid_t? in
        guard (info[kCGWindowLayer as String] as? Int) == 0,
          let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != flash
        else { return nil }
        return pid
      }
    let running = windowSwitcherAppPIDs()
    windowSwitcherCatalog.refresh(
      pids: running,
      order: WindowSwitcherPlanner.appOrder(stacked: stacked, running: running))
  }

  /// AX notifications that can add, close, retitle or minimize a window.
  static let windowSwitcherNotifications: Set<String> = [
    kAXWindowCreatedNotification as String,
    kAXUIElementDestroyedNotification as String,
    kAXWindowMiniaturizedNotification as String,
    kAXWindowDeminiaturizedNotification as String,
    kAXTitleChangedNotification as String,
  ]
}
