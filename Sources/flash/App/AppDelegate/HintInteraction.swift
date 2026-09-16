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
          FlashLog.debug(
            "[commit] captured_target_unavailable provider=\(selection.target.providerID) "
              + "role=\(selection.target.role ?? "?")")
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
  func performHintCommit(
    delayMs: Int = 0,
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
    if delayMs == 0 {
      start()
    } else {
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: start)
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
