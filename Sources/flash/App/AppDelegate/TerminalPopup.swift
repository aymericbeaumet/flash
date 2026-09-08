import AppKit
import FlashTerminal

struct StatusTerminalInputOrigin: Equatable {
  var name: String
  var session: TerminalSession?
  var generation: UInt64?

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.name == rhs.name && lhs.session === rhs.session && lhs.generation == rhs.generation
  }
}

extension AppDelegate {
  func configureTerminalPopupInput() {
    let popup = overlay.statusPopupController
    terminalInputMappings = TerminalInputMappingHandler<StatusTerminalInputOrigin>(
      mappings: (lastAppliedMappingMode ?? config.mode).compiledTerminal,
      timeoutMs: config.mode.sequenceTimeoutMs,
      replay: { [weak self] event, origin in
        guard let self else { return }
        // A restart can reuse the session object; a late release still belongs
        // to the old child and must never become input to its replacement.
        if origin.session != nil,
          self.overlay.statusTerminals.inputGenerations[origin.name] != origin.generation
        {
          return
        }
        self.overlay.statusPopupController.terminalView.replay(event: event, to: origin.session)
      },
      dispatch: { [weak self] mapping, _ in
        self?.performMappingCommand(mapping.action)
      })
    popup.willFocus = { [weak self] in
      guard let self else { return }
      self.terminalInputMappings?.flush()
      self.terminalReturnApplicationPID =
        self.currentNonFlashContext()?.processID
        ?? self.normalModeTargetPID
      self.dispatchMode(.openTerminal)
    }
    popup.willDismissFocus = { [weak self] in self?.terminalInputMappings?.flush() }
    popup.didDismissFocus = { [weak self] in
      guard let self else { return }
      if case .terminal = self.modeStore.mode { self.dispatchMode(.closeTerminal) }
      self.terminalReturnApplicationPID = nil
    }
    popup.inputInterceptor = { [weak self] event in
      guard let self, case .terminal = self.modeStore.mode,
        let name = self.overlay.statusPopupController.focusedName
      else { return false }
      self.terminalInputMappings?.handle(
        event: event,
        origin: StatusTerminalInputOrigin(
          name: name, session: self.overlay.statusTerminals.sessions[name],
          generation: self.overlay.statusTerminals.inputGenerations[name]))
      return true
    }
  }

  func reloadTerminalPopupConfiguration() {
    // Replay pending prefix input while the original view/session is still bound.
    terminalInputMappings?.replaceMappings(
      (lastAppliedMappingMode ?? config.mode).compiledTerminal,
      timeoutMs: config.mode.sequenceTimeoutMs)
    if statusTerminalEnvironmentReady { overlay.statusTerminals.apply(config.statusBar) }
  }

  func restartStatusTerminal(named name: String?) {
    guard let name = name ?? overlay.statusPopupController.focusedName else { return }
    terminalInputMappings?.flush()
    overlay.statusTerminals.restart(name: name)
  }

  func statusTerminalDebugState() -> [String: Any] {
    let popup = overlay.statusPopupController
    return [
      "focused": popup.focusedName as Any? ?? NSNull(),
      "visible": popup.isVisible,
      "frame": [
        "x": popup.frame.minX, "y": popup.frame.minY,
        "width": popup.frame.width, "height": popup.frame.height,
      ],
      "anchors": overlay.statusBarInteractionsByScreen.flatMap { screen in
        screen.popups.map { region -> [String: Any] in
          [
            "name": region.name, "x": region.rect.minX, "y": region.rect.minY,
            "width": region.rect.width, "height": region.rect.height,
          ]
        }
      },
      "sessions": overlay.statusTerminals.sessions.keys.sorted().compactMap {
        name -> [String: Any]? in
        guard let session = overlay.statusTerminals.sessions[name] else { return nil }
        var value: [String: Any] = ["name": name]
        switch session.state {
        case .idle: value["state"] = "idle"
        case .running(let pid):
          value["state"] = "running"
          value["pid"] = Int(pid)
        case .exited(let code):
          value["state"] = "exited"
          value["exit_code"] = Int(code)
        case .failed: value["state"] = "failed"
        case .stopped: value["state"] = "stopped"
        }
        value["columns"] = session.frame?.columns
        value["rows"] = session.frame?.rows
        return value
      },
    ]
  }
}
