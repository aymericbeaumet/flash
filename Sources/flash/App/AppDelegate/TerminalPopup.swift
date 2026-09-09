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
        self.terminalReturnApplicationPID
        ?? self.currentNonFlashContext()?.processID
        ?? self.normalModeTargetPID
      self.dispatchMode(.openTerminal)
    }
    popup.willDismissFocus = { [weak self] in self?.terminalInputMappings?.flush() }
    popup.didDismissFocus = { [weak self] in
      guard let self else { return }
      if case .terminal = self.modeStore.mode { self.dispatchMode(.closeTerminal(targetPID: nil)) }
      self.terminalReturnApplicationPID = nil
    }
    overlay.statusBarPopupDismissHandler = { [weak self] restoreApplication in
      self?.dismissTerminal(restoreApplication: restoreApplication)
    }
    overlay.statusBarTerminalPrepareHandler = { [weak self] name in
      guard let self else { return false }
      guard self.config.terminals[name] != nil || self.config.invalidTerminalNames.contains(name)
      else { return true }
      return self.overlay.statusTerminals.prepareTerminal(name: name, configuration: self.config)
        != nil
    }
    popup.didDismiss = { [weak self] name in
      self?.overlay.statusTerminals.releaseTerminal(name: name)
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
    if statusTerminalEnvironmentReady {
      overlay.statusTerminals.apply(
        config.statusBar, terminals: config.terminals,
        invalidTerminalNames: config.invalidTerminalNames)
    }
  }

  func showTerminal(named name: String?) {
    let snapshot = OverlayPanel.currentScreenSnapshot()
    let context = currentNonFlashContext()
    let screen =
      snapshot.screens.first { screen in
        context.map {
          screen.frame.contains(CGPoint(x: $0.frontWindowFrame.midX, y: $0.frontWindowFrame.midY))
        } ?? false
      } ?? snapshot.screens.first { $0.frame == snapshot.mainFrame } ?? snapshot.screens.first
    guard let screen else { return }
    if let name, config.terminals[name] == nil {
      FlashLog.warn("Terminal declaration not found", source: "core:TerminalPopup.show")
      return
    }
    dismissTerminal(restoreApplication: false)
    guard let key = overlay.statusTerminals.openTerminal(name: name, configuration: config) else {
      return
    }
    overlay.statusPopupController.showTerminal(
      name: key, visibleFrame: screen.visibleFrame, style: config.statusBar.popupStyle,
      font: NSFont.monospacedSystemFont(
        ofSize: OverlayPanel.statusBarFontSize(overlayFontSize: CGFloat(config.overlay.fontSize)),
        weight: .medium))
  }

  func suppressDismissedTerminalHover() {
    let popup = overlay.statusPopupController
    if let name = popup.presentation.identity?.name, !popup.presentation.isStandalone {
      overlay.statusBarHoverGate = .dismissed(name)
    }
  }

  func dismissTerminal(restoreApplication: Bool = true) {
    suppressDismissedTerminalHover()
    let returnPID = terminalReturnApplicationPID
    if case .terminal = modeStore.mode {
      dispatchMode(.closeTerminal(targetPID: restoreApplication ? returnPID : nil))
    } else {
      overlay.hideStatusBarPopup(reason: "terminal_dismiss")
    }
    if !restoreApplication { terminalReturnApplicationPID = returnPID }
  }

  func restartStatusTerminal(named name: String?) {
    let focused = overlay.statusPopupController.focusedName
    let key =
      name.flatMap { overlay.statusTerminals.terminalKey(named: $0, focusedName: focused) }
      ?? (name == nil ? focused : nil)
    guard let key else { return }
    terminalInputMappings?.flush()
    overlay.statusTerminals.restart(name: key)
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
