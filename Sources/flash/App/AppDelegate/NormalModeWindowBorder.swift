import AppKit
import ApplicationServices
import FlashCore

// Active-window border: paints a colored stroke around the focused app's
// frontmost window so the user always knows which window is active — a thin
// green stroke in normal mode, a thicker blue one in insert. This file decides
// where the stroke goes; `OverlayPanel` owns the drawn frame and derives the
// colour from the badge it shows. Especially useful
// for apps with several windows. Focused-window AX and workspace lifecycle
// notifications drive immediate updates; bounded one-shot WindowServer checks
// after those events absorb delayed state propagation without a resident poll.
// The static helpers below are pure decision functions so NormalModeTests can
// exercise the visibility / equality logic without spinning up an `AppDelegate`.

/// One authoritative front-window read for the stroke; see
/// `scheduleActiveWindowBorderRead`.
struct ActiveWindowBorderRead {
  let pid: pid_t
  let reason: String
  let generation: UInt64
  /// Apply through the reconciliation diff (redraw or hide only on change)
  /// rather than repainting unconditionally.
  let reconciles: Bool
  /// The settle series this pass belongs to when a read that finds the
  /// window where the stroke already is ends it: the later passes would read
  /// the same window list (`scheduleActiveWindowBorderReconciliation`).
  var endsSettleSeries: UInt64? = nil
}

/// When the authoritative window-list read follows the cached paint.
enum ActiveWindowBorderReadTiming {
  /// This turn: the cache is a guess the read corrects at once (a window AX
  /// event: the window that fired may be the one on top now).
  case nextTurn
  /// Only when nothing is cached. With a cache the next truth is the settle
  /// pass that follows an activation, or the next AX event for a transition
  /// over the same app and window (a HYPER hold), so the read — 5 ms, 18 ms
  /// at p95, on main during the activation animation — is not paid here.
  case onlyWithoutCache
  /// Unless the cache is the window list's own answer with no window event
  /// since (`activeWindowBorder.eventEpoch`): a mode change moves no window,
  /// and re-reading on each one cost 1.8 ms at p50, up to 15 ms, on main.
  case unlessFresh
}

/// What the stroke remembers between events: the frames it can paint before
/// any WindowServer round trip, how fresh they are, the read queued for the
/// next main turn and the generations that retire superseded work.
struct ActiveWindowBorderState {
  /// The settle series in flight: bumped to start one and to end or cancel
  /// it, so the passes of an older series do nothing.
  var settleSeries: UInt64 = 0
  /// Bumped by every update, hide and geometry event: a read or an async
  /// frame that carries an older value was superseded.
  var updateGeneration: UInt64 = 0
  /// The authoritative front-window read queued for the next main turn.
  var pendingRead: ActiveWindowBorderRead?
  /// Last frame observed for each app's front window, fed by the AX geometry
  /// notifications Flash already subscribes to, so an app switch paints the
  /// right rectangle on the activation itself and the settle pass 80 ms
  /// later, after the activation animation, corrects it.
  var frames: [pid_t: CGRect] = [:]
  /// Bumped by every event that can move, raise or replace an app's front
  /// window: a border-relevant AX notification, an activation, a quit, a
  /// Space or display change.
  private(set) var eventEpoch: UInt64 = 0
  /// The epoch each app's cached frame was read at: while no event has
  /// followed, the cache is the window list's answer and a mode change
  /// does not ask again.
  private(set) var readEpochs: [pid_t: UInt64] = [:]
  var suspensions: Set<PollScheduler.Suspension> = []

  mutating func noteWindowEvent() { eventEpoch &+= 1 }

  /// `pid`'s frame was just read from the window list.
  mutating func noteRead(of pid: pid_t) { readEpochs[pid] = eventEpoch }

  mutating func forget(_ pid: pid_t) {
    frames.removeValue(forKey: pid)
    readEpochs.removeValue(forKey: pid)
  }

  /// Whether painting `pid` from the cache must be followed by a
  /// window-list read.
  func needsRead(_ timing: ActiveWindowBorderReadTiming, of pid: pid_t) -> Bool {
    guard frames[pid] != nil else { return true }
    switch timing {
    case .nextTurn: return true
    case .onlyWithoutCache: return false
    case .unlessFresh: return readEpochs[pid] != eventEpoch
    }
  }

  /// Queue `read`, the latest winning. True when no read was queued yet:
  /// the caller schedules the turn that performs it.
  mutating func queue(_ read: ActiveWindowBorderRead) -> Bool {
    defer { pendingRead = read }
    return pendingRead == nil
  }

  /// The queued read, unless a hide, a geometry event or a newer identity
  /// superseded it.
  mutating func takePendingRead() -> ActiveWindowBorderRead? {
    guard let read = pendingRead else { return nil }
    pendingRead = nil
    return read.generation == updateGeneration ? read : nil
  }
}

extension AppDelegate {
  /// Which app the stroke must frame.
  ///
  /// `NSWorkspace.shared.frontmostApplication` settles asynchronously: for
  /// tens of milliseconds after an activation notification it still names the
  /// app the user just left. Resolving the border target through it drew the
  /// stroke around the *previous* window, and nothing corrected it until the
  /// new app happened to emit an AX geometry notification — several hundred
  /// milliseconds, or the next app switch. The notification names the app that
  /// activated, so when one is in hand it wins.
  static func activeWindowBorderTargetPID(
    activatedPID: pid_t?, frontmostPID: pid_t?
  ) -> pid_t? {
    activatedPID ?? frontmostPID
  }

  /// `read` says when the WindowServer read follows the cached paint; see
  /// `ActiveWindowBorderReadTiming`.
  func updateActiveWindowBorder(
    reason: String, activated: NSRunningApplication? = nil,
    read: ActiveWindowBorderReadTiming = .nextTurn
  ) {
    guard
      Self.activeWindowBorderShouldBeVisible(
        configEnabled: overlay.overlayConfig.windowBorder,
        modeBadgeEnabled: modeBadgeEnabled,
        hasHints: hintSession.isActive,
        sessionActive: activeWindowBorder.suspensions.isEmpty,
        fullScreenAppFrontmost: frontmostAppIsFullScreen)
    else {
      hideActiveWindowBorder(reason: "hidden_\(reason)")
      return
    }
    FlashLog.trace("[mode] active_border_update reason=\(reason) mode=\(flashMode)")
    activeWindowBorder.updateGeneration &+= 1
    guard let app = activeWindowBorderApplication(activated: activated) else {
      applyActiveWindowBorder(frame: nil)
      return
    }
    paintActiveWindowBorder(pid: app.processIdentifier, reason: reason, read: read)
  }

  /// Paint `pid`'s stroke: the frame the AX notifications last reported for
  /// the app right away, then the authoritative read as `read` says. The
  /// read supersedes the cache under the same generation, so a stale entry
  /// self-corrects instead of persisting. The visibility gate is
  /// `updateActiveWindowBorder`'s.
  func paintActiveWindowBorder(pid: pid_t, reason: String, read: ActiveWindowBorderReadTiming) {
    if let cached = activeWindowBorder.frames[pid] {
      FlashLog.trace(
        "[mode] active_border_cached reason=\(reason) pid=\(pid) frame=\(Self.describe(cached))")
      applyActiveWindowBorder(frame: cached)
    }
    guard activeWindowBorder.needsRead(read, of: pid) else { return }
    scheduleActiveWindowBorderRead(
      ActiveWindowBorderRead(
        pid: pid, reason: reason, generation: activeWindowBorder.updateGeneration,
        reconciles: false))
  }

  /// Read the authoritative front-window frame on the next main-queue turn,
  /// coalescing every request made before then into one read: the latest wins.
  ///
  /// The read runs on main on purpose. `CGWindowListCopyWindowInfo` first
  /// synchronizes with this process's pending Core Animation transaction while
  /// holding the WindowServer connection lock; a main-thread commit carrying
  /// WindowServer actions (the status-bar render every app switch performs)
  /// needs that same lock. Issued from another queue the two waited on each
  /// other until SkyLight's 500 ms timeout (sampled:
  /// `SLSConnectionSynchronizeSLSCATransaction` against
  /// `SLSConnectionSetLastSLSCATransaction`), freezing the main thread and
  /// leaving the stroke on the previous window for half a second on every
  /// switch. On main the read can never overlap a commit, and costs about a
  /// millisecond.
  private func scheduleActiveWindowBorderRead(_ read: ActiveWindowBorderRead) {
    guard activeWindowBorder.queue(read) else { return }
    DispatchQueue.main.async { [weak self] in self?.performActiveWindowBorderRead() }
  }

  func performActiveWindowBorderRead() {
    guard let read = activeWindowBorder.takePendingRead() else { return }
    let startedAt = DispatchTime.now().uptimeNanoseconds
    let frame = activeWindowBorderFrameReader(read.pid)
    activeWindowBorder.noteRead(of: read.pid)
    FlashLog.trace(
      "[mode] active_border_frame reason=\(read.reason) pid=\(read.pid) "
        + "read_ms=\(Self.elapsedMs(startedAt, DispatchTime.now().uptimeNanoseconds)) "
        + "frame=\(Self.describe(frame))")
    rememberActiveWindowBorderFrame(frame, for: read.pid)
    guard read.reconciles else {
      applyActiveWindowBorder(frame: frame)
      return
    }
    let action = applyActiveWindowBorderReconciliation(frame: frame, reason: read.reason)
    // The window is where the stroke already is: the window list has caught
    // up with the event, and the remaining passes would read the same.
    if let series = read.endsSettleSeries, action == .none,
      series == activeWindowBorder.settleSeries
    {
      activeWindowBorder.settleSeries &+= 1
      FlashLog.trace("[mode] active_border_settled reason=\(read.reason)")
    }
  }

  /// Record what the front window of `pid` looks like now, so the next
  /// activation of that app can paint before any WindowServer round trip.
  func rememberActiveWindowBorderFrame(_ frame: CGRect?, for pid: pid_t) {
    activeWindowBorder.frames[pid] = frame
  }

  func forgetActiveWindowBorderFrames(for pid: pid_t) {
    activeWindowBorder.forget(pid)
  }

  /// A move or resize names the window that changed, so its geometry is one
  /// AX read on the element that fired — not a `CGWindowListCopyWindowInfo`
  /// scan of every on-screen window, which the old path ran three times per
  /// event (once on main to resolve the context, once to place the stroke,
  /// once more on the settle tick). That scan cost is what made the border
  /// trail a dragged window instead of riding with it, so there is no settle
  /// poll here: the next AX event is the next truth.
  func observedWindowGeometryDidChange(
    pid: pid_t,
    window: AXUIElement,
    notification: String,
    statusBarReservesSpace: Bool,
    statusBarMonitor: Config.StatusBar.Monitor
  ) {
    let borderVisible = Self.activeWindowBorderShouldBeVisible(
      configEnabled: overlay.overlayConfig.windowBorder,
      modeBadgeEnabled: modeBadgeEnabled,
      hasHints: hintSession.isActive,
      sessionActive: activeWindowBorder.suspensions.isEmpty,
      fullScreenAppFrontmost: frontmostAppIsFullScreen)
    FlashLog.trace("[mode] active_border_geometry reason=\(notification) visible=\(borderVisible)")
    if !borderVisible { hideActiveWindowBorder(reason: "hidden_\(notification)") }
    activeWindowBorder.updateGeneration &+= 1
    let generation = activeWindowBorder.updateGeneration
    let primaryHeight = ScreenSpace.primaryHeight
    monitor.geometryQueue.async { [weak self] in
      let frame = WindowMover.readWindowFrameInNSCoords(
        window: window, primaryHeight: primaryHeight)
      DispatchQueue.main.async {
        guard let self else { return }
        if let frame {
          self.windowLayoutManager.observedWindowFrameChange(
            pid: pid, window: window, frame: frame, notification: notification,
            statusBarReservesSpace: statusBarReservesSpace,
            statusBarMonitor: statusBarMonitor)
        }
        self.rememberActiveWindowBorderFrame(frame, for: pid)
        if notification == kAXWindowResizedNotification as String,
          Self.resizeMayChangeNativeFullScreen(
            frame: frame, screens: NSScreen.screens.map(\.frame),
            fullScreen: self.frontmostAppIsFullScreen)
        {
          self.refreshNativeFullScreen(pid: pid, reason: "window_resized")
        }
        guard borderVisible, self.activeWindowBorder.updateGeneration == generation else { return }
        self.applyActiveWindowBorder(frame: frame)
      }
    }
  }

  /// Only a resize into a whole display's frame can enter native full
  /// screen, and only one while full screen can leave it, so ordinary resizes
  /// and drags read nothing more.
  static func resizeMayChangeNativeFullScreen(
    frame: CGRect?, screens: [CGRect], fullScreen: Bool
  ) -> Bool {
    if fullScreen { return true }
    guard let frame else { return false }
    return screens.contains {
      abs($0.minX - frame.minX) <= 1 && abs($0.minY - frame.minY) <= 1
        && abs($0.width - frame.width) <= 1 && abs($0.height - frame.height) <= 1
    }
  }

  static func elapsedMs(_ from: UInt64, _ to: UInt64) -> String {
    String(format: "%.1f", Double(to &- from) / 1_000_000)
  }

  static func describe(_ frame: CGRect?) -> String {
    guard let frame else { return "nil" }
    return "(\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height)))"
  }

  private func applyActiveWindowBorder(frame: CGRect?) {
    overlay.setActiveWindowBorder(around: frame)
  }

  func hideActiveWindowBorder(reason: String) {
    activeWindowBorder.updateGeneration &+= 1
    overlay.setActiveWindowBorder(around: nil)
    cancelActiveWindowBorderReconciliations(reason: reason)
  }

  func cancelActiveWindowBorderReconciliations(reason: String) {
    activeWindowBorder.settleSeries &+= 1
    FlashLog.trace("[mode] active_border_reconcile_cancel reason=\(reason)")
  }

  /// A bounded fan-out of settle passes after one event whose window-list
  /// state settles late. `endsWhenSettled` ends the series at the first pass
  /// that finds the window where the stroke already is (an activation: the
  /// 80 ms pass, after the activation animation, is its first authoritative
  /// read, and the 250 and 750 ms passes run only while it still disagrees).
  /// The AX-event settle keeps every pass: its first read can still see a
  /// closing window fading out of the list.
  func scheduleActiveWindowBorderReconciliation(
    delaysMs: [Int], reason: String, endsWhenSettled: Bool = false
  ) {
    guard !delaysMs.isEmpty,
      Self.activeWindowBorderShouldBeVisible(
        configEnabled: overlay.overlayConfig.windowBorder,
        modeBadgeEnabled: modeBadgeEnabled,
        hasHints: hintSession.isActive,
        sessionActive: activeWindowBorder.suspensions.isEmpty,
        fullScreenAppFrontmost: frontmostAppIsFullScreen)
    else { return }
    activeWindowBorder.settleSeries &+= 1
    let generation = activeWindowBorder.settleSeries
    for delayMs in delaysMs {
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
        guard let self, self.activeWindowBorder.settleSeries == generation else {
          return
        }
        self.reconcileActiveWindowBorder(
          reason: "\(reason)_settled_\(delayMs)ms",
          endsSettleSeries: endsWhenSettled ? generation : nil)
      }
    }
  }

  func reconcileActiveWindowBorder(reason: String, endsSettleSeries: UInt64? = nil) {
    guard
      Self.activeWindowBorderShouldBeVisible(
        configEnabled: overlay.overlayConfig.windowBorder,
        modeBadgeEnabled: modeBadgeEnabled,
        hasHints: hintSession.isActive,
        sessionActive: activeWindowBorder.suspensions.isEmpty,
        fullScreenAppFrontmost: frontmostAppIsFullScreen)
    else {
      hideActiveWindowBorder(reason: "reconcile_state")
      return
    }

    activeWindowBorder.updateGeneration &+= 1
    guard let app = activeWindowBorderApplication() else {
      applyActiveWindowBorderReconciliation(frame: nil, reason: reason)
      return
    }
    scheduleActiveWindowBorderRead(
      ActiveWindowBorderRead(
        pid: app.processIdentifier, reason: reason,
        generation: activeWindowBorder.updateGeneration, reconciles: true,
        endsSettleSeries: endsSettleSeries))
  }

  @discardableResult
  private func applyActiveWindowBorderReconciliation(
    frame: CGRect?, reason: String
  ) -> ActiveWindowBorderReconciliationAction {
    let action = Self.activeWindowBorderReconciliationAction(
      trackedFrame: overlay.activeWindowBorderFrame,
      currentFrame: frame,
      tolerance: Self.activeWindowBorderFrameTolerance)
    switch action {
    case .none:
      break
    case .hide:
      FlashLog.trace("[mode] active_border_reconcile action=hide reason=\(reason)")
      overlay.setActiveWindowBorder(around: nil)
    case .redraw:
      FlashLog.trace("[mode] active_border_reconcile action=redraw reason=\(reason)")
      overlay.setActiveWindowBorder(around: frame)
    }
    return action
  }

  func setActiveWindowBorderSessionSuspended(
    _ suspended: Bool,
    source: PollScheduler.Suspension,
    reason: String
  ) {
    if suspended {
      terminalInputMappings?.flush()
      overlay?.hideStatusBarPopup()
      guard source.set(true, in: &activeWindowBorder.suspensions) else { return }
      FlashLog.trace("[mode] active_border_session_suspend reason=\(reason)")
      hideActiveWindowBorder(reason: reason)
      windowLayoutSessionChanged(suspended: true)
      return
    }

    guard source.set(false, in: &activeWindowBorder.suspensions) else { return }
    FlashLog.trace("[mode] active_border_session_resume reason=\(reason)")
    guard activeWindowBorder.suspensions.isEmpty else { return }
    windowLayoutSessionChanged(suspended: false)
    reconcileFrontmostApplication()
    updateActiveWindowBorder(reason: reason)
    scheduleActiveWindowBorderReconciliation(
      delaysMs: Self.activeWindowBorderRecoveryDelaysMs, reason: reason)
  }

  static func activeWindowBorderShouldBeVisible(
    configEnabled: Bool,
    modeBadgeEnabled: Bool,
    hasHints: Bool,
    sessionActive: Bool,
    fullScreenAppFrontmost: Bool
  ) -> Bool {
    // The active window carries a frame in BOTH modes — a thin green stroke in
    // normal, a thicker blue one in insert — so the focused window stays
    // identifiable (most useful for apps with several windows). The user can
    // opt out wholesale (`[overlay] window_border = false`). Advanced mode
    // (an all-mode `mode leave` or `mode normal` binding) is the gate: without it
    // there's no normal/insert distinction to visualise. Suspended while hints
    // are up (chips aren't double-framed), whenever the user session or
    // displays are inactive, so Flash never survives over the lock surface,
    // and while a full-screen app is frontmost, which Flash stays out of.
    guard configEnabled else { return false }
    guard modeBadgeEnabled else { return false }
    if hasHints { return false }
    if !sessionActive { return false }
    if fullScreenAppFrontmost { return false }
    return true
  }

  enum ActiveWindowBorderReconciliationAction: Equatable {
    case none
    case hide
    case redraw
  }

  static func activeWindowBorderReconciliationAction(
    trackedFrame: CGRect?,
    currentFrame: CGRect?,
    tolerance: CGFloat
  ) -> ActiveWindowBorderReconciliationAction {
    if currentFrame == nil { return trackedFrame == nil ? .none : .hide }
    return activeWindowBorderFramesApproximatelyEqual(
      trackedFrame, currentFrame, tolerance: tolerance) ? .none : .redraw
  }

  static func activeWindowBorderSecureUISuspendsSession(bundleIdentifier: String?) -> Bool {
    guard let bundleIdentifier else { return false }
    return bundleIdentifier == "com.apple.loginwindow"
      || bundleIdentifier.hasPrefix("com.apple.ScreenSaver")
  }

  static func activeWindowBorderFramesApproximatelyEqual(
    _ lhs: CGRect?,
    _ rhs: CGRect?,
    tolerance: CGFloat
  ) -> Bool {
    switch (lhs, rhs) {
    case (.none, .none):
      return true
    case (.some(let lhs), .some(let rhs)):
      return abs(lhs.minX - rhs.minX) <= tolerance
        && abs(lhs.minY - rhs.minY) <= tolerance
        && abs(lhs.width - rhs.width) <= tolerance
        && abs(lhs.height - rhs.height) <= tolerance
    default:
      return false
    }
  }

  /// Mode is global/sticky, so the border target is simply the currently
  /// focused non-Flash app (the old per-insert "owner pid" is gone). Identity
  /// only — no WindowServer geometry.
  private func activeWindowBorderApplication(
    activated: NSRunningApplication? = nil
  ) -> NSRunningApplication? {
    let flashBundleIdentifier = Bundle.main.bundleIdentifier ?? "com.flash.app"
    let preferred =
      activated.flatMap { $0.bundleIdentifier == flashBundleIdentifier ? nil : $0 }
    guard let app = preferred ?? currentNonFlashRunningApplication(),
      !app.isTerminated,
      !Self.activeWindowBorderSecureUISuspendsSession(bundleIdentifier: app.bundleIdentifier)
    else { return nil }
    return app
  }

}
