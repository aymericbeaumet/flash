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
        // A finished report has no process left to read keys: a key press
        // closes it instead, as leave_mode does.
        if self.modeStore.mode.isTerminal,
          self.overlay.statusPopupController.focusedName == origin.name,
          self.overlay.statusTerminals.hasEnded(origin.name),
          StatusPopupController.closesEndedPopup(event)
        {
          self.leaveMode()
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
        ?? self.currentNonFlashRunningApplication()?.processIdentifier
        ?? self.normalModeTargetPID
      self.dispatchMode(.openTerminal)
    }
    popup.willDismissFocus = { [weak self] in self?.terminalInputMappings?.flush() }
    popup.didDismissFocus = { [weak self] reason in
      guard let self else { return }
      if case .terminal = self.modeStore.mode {
        let targetPID = reason == "terminal_removed" ? self.terminalReturnApplicationPID : nil
        self.dispatchMode(.closeTerminal(targetPID: targetPID))
      }
      self.terminalReturnApplicationPID = nil
    }
    overlay.statusBarPopupDismissHandler = { [weak self] restoreApplication in
      self?.dismissPopup(restoreApplication: restoreApplication)
    }
    overlay.statusBarTerminalNeedsSpawnHandler = { [weak self] name in
      guard let self else { return false }
      return self.config.terminalPopupNames.contains(name)
        && self.overlay.statusTerminals.session(named: name) == nil
    }
    overlay.statusBarTerminalPrepareHandler = { [weak self] name in
      guard let self else { return false }
      guard self.config.terminalPopupNames.contains(name) else { return true }
      return self.overlay.statusTerminals.open(name) != nil
    }
    overlay.statusTerminals.gridResolver = { [weak self] size in
      guard let self else { return size.unplacedGrid }
      let style = self.config.popupStyle
      return size.grid(
        visible: OverlayPanel.currentScreenSnapshot().mainVisibleFrame.size,
        cell: TerminalView.cellSize(for: self.popupFont),
        inset: CGFloat(style.padding + style.borderWidth))
    }
    popup.inputInterceptor = { [weak self] event in
      guard let self, case .terminal = self.modeStore.mode,
        let name = self.overlay.statusPopupController.focusedName
      else { return false }
      self.terminalInputMappings?.handle(
        event: event,
        origin: StatusTerminalInputOrigin(
          name: name, session: self.overlay.statusTerminals.session(named: name),
          generation: self.overlay.statusTerminals.inputGenerations[name]))
      return true
    }
  }

  /// The monospaced font every popup draws with.
  var popupFont: NSFont {
    NSFont.monospacedSystemFont(
      ofSize: OverlayPanel.statusBarFontSize(overlayFontSize: CGFloat(config.overlay.fontSize)),
      weight: .medium)
  }

  func reloadTerminalPopupConfiguration() {
    // Replay pending prefix input while the original view/session is still bound.
    terminalInputMappings?.replaceMappings(
      (lastAppliedMappingMode ?? config.mode).compiledTerminal,
      timeoutMs: config.mode.sequenceTimeoutMs)
    // Sessions start with the login environment, so their commands see the
    // user's PATH and tooling.
    guard statusTerminalEnvironmentReady else { return }
    overlay.statusTerminals.apply(
      style: config.popupStyle, terminals: config.terminalPopups,
      invalid: config.invalidPopupNames, prewarm: config.prewarmedPopupNames)
  }

  /// `enter_terminal_mode`: the named popup standalone, centred on the
  /// focused app's screen and focused, which enters TERMINAL mode through the
  /// popup's focus; no name opens `terminal`. The popup already focused is a
  /// no-op; another one replaces it. A text popup shows the document the
  /// status bar last evaluated, so it needs the bar enabled.
  func enterTerminalMode(named requested: String?) {
    let name = requested ?? Config.defaultPopupName
    if modeStore.mode.isTerminal, overlay.statusPopupController.focusedName == name { return }
    let snapshot = OverlayPanel.currentScreenSnapshot()
    let context = currentNonFlashContext()
    let screen =
      snapshot.screens.first { screen in
        context.map {
          screen.frame.contains(CGPoint(x: $0.frontWindowFrame.midX, y: $0.frontWindowFrame.midY))
        } ?? false
      } ?? snapshot.screens.first { $0.frame == snapshot.mainFrame } ?? snapshot.screens.first
    guard let screen else { return }
    let fields = ["popup_id": StatusFormatDocument.stableID(name)]
    let terminals = overlay.statusTerminals
    let document: [FlashStatusTextSegment]?
    if terminals.definitions[name] != nil {
      document = nil
    } else if case .text? = config.popups[name] {
      guard config.statusBar.enabled, let evaluated = overlay.statusBarPopupDocuments[name] else {
        FlashLog.warn(
          "Text popup needs the status bar: [statusbar] enabled = true evaluates its text",
          fields: fields, source: "core:TerminalPopup.enterTerminalMode")
        return
      }
      document = evaluated
    } else {
      FlashLog.warn(
        config.terminalPopups[name] == nil
          ? "Popup not found" : "Popup starts once the login environment resolves",
        fields: fields, source: "core:TerminalPopup.enterTerminalMode")
      return
    }
    dismissPopup(restoreApplication: false)
    if document == nil, terminals.open(name) == nil { return }
    overlay.statusPopupController.show(
      name: name, document: document, visibleFrame: screen.visibleFrame,
      style: config.popupStyle, font: popupFont)
  }

  func suppressDismissedPopupHover() {
    let popup = overlay.statusPopupController
    if let name = popup.presentation.name, !popup.presentation.isStandalone {
      overlay.statusBarHoverGate = .dismissed(name)
    }
  }

  func dismissPopup(restoreApplication: Bool = true) {
    suppressDismissedPopupHover()
    let returnPID = terminalReturnApplicationPID
    if case .terminal = modeStore.mode {
      dispatchMode(.closeTerminal(targetPID: restoreApplication ? returnPID : nil))
    } else {
      overlay.hideStatusBarPopup(reason: "dismiss_popup")
    }
    if !restoreApplication { terminalReturnApplicationPID = returnPID }
  }

  func restartPopup(named name: String?) {
    guard let key = popupSessionName(name) else { return }
    terminalInputMappings?.flush()
    overlay.statusTerminals.restart(name: key)
  }

  func quitPopup(named name: String?) {
    guard let key = popupSessionName(name) else { return }
    terminalInputMappings?.flush()
    overlay.statusTerminals.quit(name: key)
  }

  /// The named popup's session, or the focused popup's without a name.
  private func popupSessionName(_ name: String?) -> String? {
    guard let key = name ?? overlay.statusPopupController.focusedName,
      overlay.statusTerminals.session(named: key) != nil
    else { return nil }
    return key
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
        guard let session = overlay.statusTerminals.session(named: name) else { return nil }
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
