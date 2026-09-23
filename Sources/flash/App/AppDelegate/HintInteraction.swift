import AppKit
import FlashCore

enum HintActivationRequest {
  case target(MouseCommand, AppContext?)
  case screen(MouseCommand)
  case grid(MouseCommand, AppContext?)
  case pointer
  case scroll
  case dock
  case statusItems
  case repeatLast(Int)
}

extension AppDelegate {
  /// AX/plugin verification may block, so it shares the discovery queue rather
  /// than the keyboard loop. Cancellation or replacement invalidates its token.
  func resolveHintPoints(
    _ selections: [(target: JumpTarget, point: CGPoint)],
    completion: @escaping (AppDelegate, [CGPoint]) -> Void
  ) {
    guard !activationLifecycle.inFlight else { return }
    guard selections.contains(where: { $0.target.resolveClickPoint != nil }) else {
      completion(self, selections.map(\.point))
      return
    }
    let token = activationLifecycle.begin()
    monitor.axQueue.async { [weak self] in
      var points: [CGPoint] = []
      for selection in selections {
        guard let point = selection.target.resolvedClickPoint(preferred: selection.point) else {
          // The gesture is dropped here: the user pressed a hint label and
          // gets no click at all, so this is warn-level, not a trace crumb.
          FlashLog.warn(
            "[commit] captured_target_unavailable provider=\(selection.target.providerID) "
              + "role=\(selection.target.role ?? "?") "
              + "label=\(selection.target.accessibilityLabel ?? "?") "
              + "point=(\(Int(selection.point.x)),\(Int(selection.point.y))); click dropped")
          DispatchQueue.main.async {
            guard let self, self.activationLifecycle.complete(token: token) else { return }
            self.cancelOverlay()
          }
          return
        }
        points.append(point)
      }
      DispatchQueue.main.async {
        guard let self, self.activationLifecycle.complete(token: token) else { return }
        completion(self, points)
      }
    }
  }

  /// Judge a grid point the way discovery judges a hint target — is it a text
  /// input? — before the click lands, so `F` enters INSERT under `f`'s rule.
  /// The AX hit-test runs on the geometry queue under the same commit token as
  /// `resolveHintPoints`, so a cancelled or replaced session drops it.
  func resolveGridClickTarget(
    at point: CGPoint,
    completion: @escaping (AppDelegate, NormalModePointerPolicy.ClickTarget) -> Void
  ) {
    guard !activationLifecycle.inFlight else { return }
    let token = activationLifecycle.begin()
    let topLeft = CGPoint(x: point.x, y: ActionDispatcher.primaryScreenHeight() - point.y)
    monitor.geometryQueue.async { [weak self] in
      let entersInsert = AXTextInputProbe.isTextInput(at: topLeft)
      DispatchQueue.main.async {
        guard let self, self.activationLifecycle.complete(token: token) else { return }
        FlashLog.trace("[commit] grid_target text_input=\(entersInsert)")
        completion(self, .grid(entersInsertMode: entersInsert))
      }
    }
  }

  func prepareHintActivation(_ request: HintActivationRequest) -> Bool {
    guard activationLifecycle.requestReplacement(request) else { return false }
    switch modeStore.mode {
    case .command: dispatchMode(.closeCommand(reason: "hint_activation"))
    case .terminal: dismissTerminal(restoreApplication: false)
    default: break
    }
    cancelPointerInsertHandoff(reason: "hint_replaced")
    overlay.hide()
    clearHintSessionState()
    return true
  }

  private func performHintActivation(_ request: HintActivationRequest) {
    switch request {
    case .target(let command, let context):
      activateMouseTarget(
        command, contextOverride: context.flatMap { monitor.context(for: $0.processID) })
    case .screen(let command): activateScreenScopeHints(command)
    case .grid(let command, let context):
      activateMouseGrid(
        command, contextOverride: context.flatMap { monitor.context(for: $0.processID) })
    case .pointer: enterPointerMode()
    case .scroll: activateScrollTargetHints()
    case .dock: activateDockHints()
    case .statusItems: activateStatusItemHints()
    case .repeatLast(let count): performMouseRepeat(repeatCount: count)
    }
  }

  /// The token covers the delay, dispatch, and completion. Input which has
  /// started always finishes; cancellation only suppresses its UI/mode outcome.
  /// How long a commit will wait for the target app to actually come
  /// forward. Long enough for a real handoff, short enough that an app which
  /// refuses activation still gets its click instead of the gesture vanishing.
  static let frontmostHandoffTimeoutMs = 400

  /// Whether the click has to wait for a focus handoff at all.
  static func hintCommitNeedsFrontmostHandoff(
    targetPID: pid_t?, frontmostPID: pid_t?
  ) -> Bool {
    guard let targetPID else { return false }
    return targetPID != frontmostPID
  }

  /// `NSRunningApplication.activate` is advisory and asynchronous: it returns
  /// long before the app is frontmost. A click posted in that window lands on
  /// whoever still is — macOS spends it raising a window, or another app eats
  /// it outright — which is the hint click that "doesn't go through". Wait for
  /// the workspace to confirm the switch instead of guessing at a delay, and
  /// fall back after `frontmostHandoffTimeoutMs` so a refusing app cannot
  /// strand the gesture.
  func whenFrontmost(pid: pid_t, then body: @escaping () -> Void) {
    if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
      body()
      return
    }
    var observer: NSObjectProtocol?
    var settled = false
    let finish: (Bool) -> Void = { confirmed in
      guard !settled else { return }
      settled = true
      if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
      if !confirmed {
        FlashLog.warn(
          "[click] focus handoff timed out pid=\(pid) "
            + "after=\(Self.frontmostHandoffTimeoutMs)ms; clicking anyway")
      }
      body()
    }
    observer = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { note in
      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      guard app?.processIdentifier == pid else { return }
      finish(true)
    }
    DispatchQueue.main.asyncAfter(
      deadline: .now() + .milliseconds(Self.frontmostHandoffTimeoutMs)
    ) { finish(false) }
  }

  func performHintCommit(
    awaitingFrontmost awaitedPID: pid_t? = nil,
    recording click: LastCommittedClick? = nil,
    action: @escaping (@escaping () -> Void) -> Void,
    completion: @escaping (AppDelegate) -> Void
  ) {
    MainThreadWatchdog.note("hint_commit")
    guard let token = activationLifecycle.prepareCommit() else { return }
    applyModeOverlay(captureOverride: false)
    let start = { [weak self] in
      guard let self, self.activationLifecycle.startCommit(token: token) else { return }
      if let click { self.lastCommittedClick = click }
      action { [weak self] in
        guard let self,
          let result = self.activationLifecycle.completeCommit(token: token)
        else { return }
        if self.hintSession.hints.isEmpty { self.overlay.releaseStatusBarHintSnapshot() }
        if result.applyOutcome { completion(self) }
        if !result.applyOutcome, result.replacement == nil {
          self.applyModeOverlay()
          self.scheduleNormalModeRecapture()
        }
        if let replacement = result.replacement { self.performHintActivation(replacement) }
      }
    }
    if let awaitedPID {
      whenFrontmost(pid: awaitedPID, then: start)
    } else {
      start()
    }
  }

  func clearHintSessionState(preservingStatusBarSnapshot: Bool = false) {
    for effect in hintSession.finish() {
      switch effect {
      case .releasePrimaryButton:
        _ = ActionDispatcher.releasePrimaryButton(at: NSEvent.mouseLocation)
      }
    }
    if !preservingStatusBarSnapshot, !activationLifecycle.isCommitting {
      overlay.releaseStatusBarHintSnapshot()
    }
  }
}
