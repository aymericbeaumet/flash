import FlashCore
import FlashTerminal
import Foundation

enum StatusTerminalChange: Equatable {
  case start(String)
  case resize(String)
  case replace(String)
  case remove(String)

  static func reconcile(
    current: [String: Config.Terminal],
    desired: [String: Config.Terminal],
    invalid: Set<String>
  ) -> [Self] {
    var changes: [Self] = []
    for name in current.keys.sorted() where desired[name] == nil && !invalid.contains(name) {
      changes.append(.remove(name))
    }
    for name in desired.keys.sorted() where !invalid.contains(name) {
      guard let next = desired[name] else { continue }
      guard let previous = current[name] else {
        changes.append(.start(name))
        continue
      }
      if previous.command != next.command || previous.workingDirectory != next.workingDirectory
        || previous.environment != next.environment || previous.persistent != next.persistent
      {
        changes.append(.replace(name))
      } else if previous.columns != next.columns || previous.rows != next.rows {
        changes.append(.resize(name))
      }
    }
    return changes
  }
}

struct TerminalRestartBackoff {
  /// Consecutive failed starts before restarts stop; a session that ran for
  /// at least a second resets the count. Without a ceiling a command that
  /// exits immediately respawns forever at 30 s.
  static let maxAttempts = 10

  private(set) var attempt = 0
  private var runningSince: TimeInterval?

  mutating func running(at time: TimeInterval) { runningSince = time }

  /// `nil` once the ceiling is reached: the session stays exited until an
  /// explicit restart or a definition change.
  mutating func nextDelay(at time: TimeInterval) -> TimeInterval? {
    if let runningSince, time - runningSince >= 1 { attempt = 0 }
    runningSince = nil
    attempt += 1
    guard attempt <= Self.maxAttempts else { return nil }
    return attempt == 1 ? 0.1 : min(30, pow(2, Double(min(5, attempt - 2))))
  }
}

/// Main-thread ownership of persistent declarations and explicitly opened terminals.
final class StatusTerminalRegistry {
  private(set) var sessions: [String: TerminalSession] = [:]
  private(set) var definitions: [String: Config.Terminal] = [:]
  private(set) var inputGenerations: [String: UInt64] = [:]
  private var nextInputGeneration: UInt64 = 0
  private var retiringSessions: [ObjectIdentifier: TerminalSession] = [:]
  private enum Ownership {
    case persistent
    case ephemeral(template: String?)
  }
  private var ownership: [String: Ownership] = [:]
  private struct Restart {
    var backoff = TerminalRestartBackoff()
    var pending: DispatchWorkItem?
  }
  private var restarts: [String: Restart] = [:]
  var willChange: (([StatusTerminalChange]) -> Void)?
  var didChange: (() -> Void)?
  private let processEnvironment: FlashProcessEnvironment

  init(environment: FlashProcessEnvironment = .shared) {
    processEnvironment = environment
  }

  func apply(
    _ statusBar: Config.StatusBar, terminals: [String: Config.Terminal] = [:],
    invalidTerminalNames: Set<String> = []
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    let colors = StatusPopupColors(statusBar.popupStyle)
    for session in sessions.values {
      session.setColors(foreground: colors.foreground, background: colors.background)
    }
    var desired = terminals.filter { $0.value.persistent }
    for (key, owner) in ownership {
      guard case .ephemeral(let template) = owner, let definition = definitions[key] else {
        continue
      }
      if let template {
        if invalidTerminalNames.contains(template) {
          desired[key] = definition
        } else if let terminal = terminals[template], !terminal.persistent,
          terminal == definition
        {
          desired[key] = definition
        }
      } else {
        desired[key] = definition
      }
    }
    let changes = StatusTerminalChange.reconcile(
      current: definitions, desired: desired, invalid: invalidTerminalNames)
    if !changes.isEmpty { willChange?(changes) }
    for change in changes {
      switch change {
      case .remove(let name):
        remove(name: name)
      case .start(let name), .replace(let name):
        guard let definition = desired[name] else { continue }
        start(name: name, definition: definition, ownership: .persistent, colors: colors)
      case .resize(let name):
        guard let definition = desired[name] else { continue }
        definitions[name] = definition
        sessions[name]?.resize(columns: definition.columns, rows: definition.rows)
      }
    }
    if !changes.isEmpty { didChange?() }
  }

  /// Only persistent declarations restart on their own. Every other terminal
  /// ends with its process: the popup or window closes and the session is
  /// released.
  func automaticallyRestarts(name: String) -> Bool {
    if case .persistent = ownership[name] { return true }
    return false
  }

  func openTerminal(name: String?, configuration config: Config) -> String? {
    dispatchPrecondition(condition: .onQueue(.main))
    let definition: Config.Terminal
    if let name {
      guard let terminal = config.terminals[name] else { return nil }
      if terminal.persistent {
        let key = name
        if sessions[key] == nil {
          start(
            name: key, definition: terminal, ownership: .persistent,
            colors: StatusPopupColors(config.statusBar.popupStyle))
          didChange?()
        }
        return key
      }
      definition = terminal
    } else {
      let shell = processEnvironment.environment["SHELL"] ?? "/bin/zsh"
      definition = .init(
        command: [shell, "-l"], workingDirectory: NSHomeDirectory(), columns: 100, rows: 28)
    }
    let key = name ?? "terminal:ephemeral:\(UUID().uuidString)"
    start(
      name: key, definition: definition, ownership: .ephemeral(template: name),
      colors: StatusPopupColors(config.statusBar.popupStyle))
    didChange?()
    return key
  }

  func prepareTerminal(name: String, configuration config: Config) -> String? {
    guard config.terminals[name] != nil || config.invalidTerminalNames.contains(name) else {
      return nil
    }
    if sessions[name] != nil { return name }
    return openTerminal(name: name, configuration: config)
  }

  func terminalKey(named name: String, focusedName: String?) -> String? {
    if sessions[name] != nil { return name }
    if name.isEmpty, let focusedName, sessions[focusedName] != nil { return focusedName }
    return nil
  }

  func releaseTerminal(name: String) {
    guard case .ephemeral = ownership[name] else { return }
    // Dismissal callbacks may release this terminal again.
    ownership.removeValue(forKey: name)
    willChange?([.remove(name)])
    remove(name: name)
    didChange?()
  }

  private func start(
    name: String, definition: Config.Terminal, ownership owner: Ownership,
    colors: StatusPopupColors
  ) {
    remove(name: name)
    advanceInputGeneration(for: name)
    ownership[name] = owner
    let session = TerminalSession(
      configuration: Self.configuration(
        for: definition, environment: processEnvironment.environment))
    sessions[name] = session
    definitions[name] = definition
    var previousState: TerminalSessionState?
    var lastPID: Int32?
    session.onStateChange = { [weak self, weak session] state in
      if previousState != state {
        previousState = state
        if case .running(let pid) = state { lastPID = pid }
        Self.logLifecycle(name: name, state: state, pid: lastPID)
      }
      guard let self, let session, self.sessions[name] === session else { return }
      self.observe(state: state, name: name, session: session)
      if self.sessions[name] === session { self.didChange?() }
    }
    session.onInputRejected = { count in
      FlashLog.warn(
        "Status terminal input queue full",
        fields: ["popup_id": StatusFormatDocument.stableID(name), "rejected_bytes": String(count)],
        source: "core:StatusTerminalRegistry.input")
    }
    let popupID = StatusFormatDocument.stableID(name)
    session.onDiagnostic = { diagnostic in
      let phase: String
      let pid: Int32
      switch diagnostic {
      case .reapDeferred(let childPID):
        phase = "reap_deferred"
        pid = childPID
      case .reaped(let childPID):
        phase = "reaped"
        pid = childPID
      }
      FlashLog.info(
        "Terminal process cleanup changed",
        fields: ["popup_id": popupID, "child_pid": String(pid), "phase": phase],
        source: "core:StatusTerminalRegistry.process")
    }
    session.setColors(foreground: colors.foreground, background: colors.background)
    session.start()
  }

  private func observe(state: TerminalSessionState, name: String, session: TerminalSession) {
    guard automaticallyRestarts(name: name) else {
      switch state {
      case .exited, .failed: releaseTerminal(name: name)
      case .idle, .running, .stopped: break
      }
      return
    }
    var restart = restarts[name] ?? Restart()
    switch state {
    case .running:
      restart.pending?.cancel()
      restart.pending = nil
      restart.backoff.running(at: ProcessInfo.processInfo.systemUptime)
    case .exited, .failed:
      scheduleRestart(name: name, session: session)
      return
    case .idle, .stopped:
      break
    }
    restarts[name] = restart
  }

  private func scheduleRestart(name: String, session: TerminalSession) {
    guard automaticallyRestarts(name: name) else { return }
    var restart = restarts[name] ?? Restart()
    guard restart.pending == nil else { return }
    guard let delay = restart.backoff.nextDelay(at: ProcessInfo.processInfo.systemUptime) else {
      FlashLog.warn(
        "Status terminal restart parked after repeated failures",
        fields: [
          "popup_id": StatusFormatDocument.stableID(name),
          "attempts": String(restart.backoff.attempt),
        ], source: "core:StatusTerminalRegistry.restart")
      restarts[name] = restart
      return
    }
    let generation = inputGenerations[name]
    let work = DispatchWorkItem { [weak self, weak session] in
      guard let self, let session, self.sessions[name] === session,
        self.inputGenerations[name] == generation, self.automaticallyRestarts(name: name)
      else { return }
      self.restarts[name]?.pending = nil
      self.restartSession(name: name, resetBackoff: false)
    }
    restart.pending = work
    restarts[name] = restart
    FlashLog.info(
      "Status terminal restart scheduled",
      fields: [
        "popup_id": StatusFormatDocument.stableID(name),
        "attempt": String(restart.backoff.attempt), "delay_seconds": String(delay),
      ], source: "core:StatusTerminalRegistry.restart")
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  private func remove(name: String) {
    restarts.removeValue(forKey: name)?.pending?.cancel()
    ownership.removeValue(forKey: name)
    inputGenerations.removeValue(forKey: name)
    retire(sessions.removeValue(forKey: name))
    definitions.removeValue(forKey: name)
  }

  private static func logLifecycle(name: String, state: TerminalSessionState, pid: Int32?) {
    var fields = ["popup_id": StatusFormatDocument.stableID(name)]
    var isFailure = false
    switch state {
    case .idle:
      fields["state"] = "idle"
    case .running(let pid):
      fields["state"] = "running"
      fields["pid"] = String(pid)
    case .exited(let code):
      fields["state"] = "exited"
      fields["exit_code"] = String(code)
      fields["pid"] = pid.map(String.init)
      isFailure = code != 0
    case .failed(let reason):
      fields["state"] = "failed"
      fields["failure_category"] = "startup_failed"
      fields["failure_reason"] = reason
      isFailure = true
    case .stopped:
      fields["state"] = "stopped"
      fields["pid"] = pid.map(String.init)
    }
    if isFailure {
      FlashLog.warn(
        "Status terminal state changed", fields: fields,
        source: "core:StatusTerminalRegistry.lifecycle")
    } else {
      FlashLog.info(
        "Status terminal state changed", fields: fields,
        source: "core:StatusTerminalRegistry.lifecycle")
    }
  }

  func restart(name: String) {
    restartSession(name: name, resetBackoff: true)
  }

  func quit(name: String) {
    guard let session = sessions[name] else { return }
    guard automaticallyRestarts(name: name) else {
      releaseTerminal(name: name)
      return
    }
    guard case .running = session.state else { return }
    restarts[name]?.pending?.cancel()
    restarts[name]?.pending = nil
    willChange?([.replace(name)])
    advanceInputGeneration(for: name)
    let generation = inputGenerations[name]
    session.stop { [weak self, weak session] in
      guard let self, let session, self.sessions[name] === session,
        self.inputGenerations[name] == generation
      else { return }
      self.scheduleRestart(name: name, session: session)
    }
  }

  private func restartSession(name: String, resetBackoff: Bool) {
    guard let session = sessions[name] else { return }
    restarts[name]?.pending?.cancel()
    restarts[name]?.pending = nil
    if resetBackoff { restarts[name] = nil }
    willChange?([.replace(name)])
    advanceInputGeneration(for: name)
    session.restart()
  }

  private func advanceInputGeneration(for name: String) {
    nextInputGeneration &+= 1
    inputGenerations[name] = nextInputGeneration
  }

  private func retire(_ session: TerminalSession?) {
    guard let session else { return }
    let identity = ObjectIdentifier(session)
    retiringSessions[identity] = session
    session.stop { [weak self] in self?.retiringSessions.removeValue(forKey: identity) }
  }

  func shutdown() {
    for restart in restarts.values { restart.pending?.cancel() }
    restarts.removeAll()
    ownership.removeAll()
    willChange?(sessions.keys.sorted().map(StatusTerminalChange.remove))
    for session in Array(sessions.values) + Array(retiringSessions.values) { session.shutdown() }
    sessions.removeAll()
    definitions.removeAll()
    inputGenerations.removeAll()
    retiringSessions.removeAll()
  }

  static func configuration(
    for definition: Config.Terminal, environment base: [String: String]
  ) -> TerminalConfiguration {
    let resolved = CommandLaunchConfiguration(
      command: definition.command,
      workingDirectory: definition.workingDirectory, overrides: definition.environment,
      environment: base)
    var environment = resolved.environment
    // The child has a color terminal; only an explicit override opts out.
    if definition.environment["NO_COLOR"] == nil { environment.removeValue(forKey: "NO_COLOR") }
    return TerminalConfiguration(
      command: resolved.command,
      workingDirectory: resolved.workingDirectory, environment: environment,
      columns: definition.columns, rows: definition.rows)
  }

}
