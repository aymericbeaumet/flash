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

  func clearHintSessionState() {
    for effect in hintSession.finish() {
      switch effect {
      case .releasePrimaryButton:
        _ = ActionDispatcher.releasePrimaryButton(at: NSEvent.mouseLocation)
      }
    }
  }
}
