import FlashCore
import FlashTerminal
import Foundation

enum StatusTerminalChange: Equatable {
  case start(String)
  case resize(String)
  case replace(String)
  case remove(String)

  /// How the terminal popups `current` become `desired`. An invalid name
  /// keeps its current definition, and so its running session.
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
        || previous.environment != next.environment || previous.lifecycle != next.lifecycle
      {
        changes.append(.replace(name))
      } else if previous.size != next.size {
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

/// Main-thread owner of every popup's PTY session, one per popup name. A
/// text popup's session runs the pager over a private snapshot of its
/// document; a terminal popup's session runs its command under the popup's
/// lifecycle. Presentation belongs to `StatusPopupController`, which tells
/// the registry when a showing starts (`open`, `preparePager`) and when it
/// ends (`hide`, exactly once per showing).
final class StatusTerminalRegistry {
  /// What a session runs.
  enum Kind {
    /// A text or inline popup's document in `less`, over a private snapshot
    /// file the registry owns.
    case pager(StatusPopupSnapshot)
    /// A terminal popup's command.
    case terminal(Config.Terminal)
  }

  private struct Entry {
    let kind: Kind
    let session: TerminalSession
  }

  /// The one restart mechanism: a persistent popup's process after it exits.
  private struct Restart {
    var backoff = TerminalRestartBackoff()
    var pending: PollDeadline?
  }

  /// A fresh popup lives for one showing; `less` pages on the alternate
  /// screen and keeps no history. Persistent popups keep the default.
  static let freshScrollbackLines = 1_000

  private var entries: [String: Entry] = [:]
  /// The terminal popups applied, each keeping its last good definition
  /// while a reload marks it invalid.
  private(set) var definitions: [String: Config.Terminal] = [:]
  /// The fresh terminal popups kept started ahead of their opening.
  private(set) var prewarmNames: Set<String> = []
  /// Prewarmed sessions nothing has shown yet.
  private(set) var prewarmedNames: Set<String> = []
  /// Fresh popups whose prewarmed process ended before any showing: one-shot
  /// reports, which start their process when shown until their definition
  /// changes.
  private(set) var startsOnShowNames: Set<String> = []
  private(set) var inputGenerations: [String: UInt64] = [:]
  private var nextInputGeneration: UInt64 = 0
  private var retiringSessions: [ObjectIdentifier: TerminalSession] = [:]
  /// Names whose previous process is still stopping: a prewarm waits for it.
  private var retiringNames: [String: Int] = [:]
  private var restarts: [String: Restart] = [:]
  private var colors = StatusPopupColors(Config.PopupStyle())
  var willChange: (([StatusTerminalChange]) -> Void)?
  var didChange: (() -> Void)?
  /// The grid a session starts at, and a hidden one refits to, before a view
  /// shows it on a particular screen.
  var gridResolver: (Config.PopupSize) -> (columns: Int, rows: Int) = { $0.unplacedGrid }
  private let processEnvironment: FlashProcessEnvironment
  /// Re-reads the login environment off the main thread, then calls back on
  /// main: a command that was missing may have been installed since.
  private let refreshEnvironment: (@escaping () -> Void) -> Void

  init(
    environment: FlashProcessEnvironment = .shared,
    refreshEnvironment: @escaping (@escaping () -> Void) -> Void = { completion in
      DispatchQueue.global(qos: .userInitiated).async {
        FlashProcessEnvironment.shared.refresh()
        DispatchQueue.main.async(execute: completion)
      }
    }
  ) {
    processEnvironment = environment
    self.refreshEnvironment = refreshEnvironment
  }

  var sessions: [String: TerminalSession] { entries.mapValues(\.session) }

  func session(named name: String) -> TerminalSession? { entries[name]?.session }

  func isPager(_ name: String) -> Bool {
    if case .pager = entries[name]?.kind { return true }
    return false
  }

  /// A terminal popup with no session yet: showing it forks its process.
  func needsSpawn(_ name: String) -> Bool { definitions[name] != nil && entries[name] == nil }

  func apply(
    style: Config.PopupStyle, terminals: [String: Config.Terminal],
    invalid: Set<String> = [], prewarm: Set<String> = []
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    colors = StatusPopupColors(style)
    for entry in entries.values {
      entry.session.setColors(foreground: colors.foreground, background: colors.background)
    }
    let changes = StatusTerminalChange.reconcile(
      current: definitions, desired: terminals, invalid: invalid)
    for change in changes {
      switch change {
      case .remove(let name):
        willChange?([.remove(name)])
        definitions.removeValue(forKey: name)
        startsOnShowNames.remove(name)
        restarts.removeValue(forKey: name)?.pending?.cancel()
        retire(detach(name), of: name)
      case .start(let name), .replace(let name):
        guard let definition = terminals[name] else { continue }
        // A persistent popup shown during its replacement keeps showing the
        // new process; anything else closes with the session it showed.
        if let previous = entries[name] {
          var keepsPresentation = false
          if case .terminal(let old) = previous.kind {
            keepsPresentation = old.lifecycle == .persistent && definition.lifecycle == .persistent
          }
          willChange?([keepsPresentation ? .replace(name) : .remove(name)])
        }
        definitions[name] = definition
        startsOnShowNames.remove(name)
        restarts.removeValue(forKey: name)?.pending?.cancel()
        let replaced = detach(name)
        if definition.lifecycle == .persistent {
          retire(replaced, of: name)
          start(name, definition)
        } else if let replaced {
          // The next process starts once the replaced one is gone: a program
          // holding a lock (newsboat's cache) would refuse to start.
          retire(replaced, of: name) { [weak self] in self?.prewarm(name) }
        }
      case .resize(let name):
        guard let definition = terminals[name] else { continue }
        definitions[name] = definition
        let grid = gridResolver(definition.size)
        entries[name]?.session.resize(columns: grid.columns, rows: grid.rows)
      }
    }
    let previousPrewarm = prewarmNames
    prewarmNames = prewarm.filter { definitions[$0]?.lifecycle == .fresh }
    for name in previousPrewarm.subtracting(prewarmNames) where prewarmedNames.contains(name) {
      retire(detach(name), of: name)
    }
    for name in prewarmNames.sorted() { self.prewarm(name) }
    if !changes.isEmpty || previousPrewarm != prewarmNames { didChange?() }
  }

  /// Attach a showing to `name`'s terminal: its running process — a
  /// persistent one, or a fresh one started ahead — or a new one. nil when
  /// `name` is not a terminal popup.
  @discardableResult
  func open(_ name: String) -> TerminalSession? {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let definition = definitions[name] else { return nil }
    if let entry = entries[name] {
      prewarmedNames.remove(name)
      return entry.session
    }
    start(name, definition)
    didChange?()
    return entries[name]?.session
  }

  /// A showing of `name` ended. A persistent process keeps running; a fresh
  /// one stops and, when prewarmed, the next starts once it is gone; a pager
  /// stops and its snapshot file goes.
  func hide(_ name: String) {
    guard let entry = entries[name] else { return }
    if case .terminal(let definition) = entry.kind, definition.lifecycle == .persistent { return }
    release(name)
  }

  /// A fresh popup whose process ended while it showed: its last screen stays
  /// until the showing ends, and nothing reads input any more.
  func hasEnded(_ name: String) -> Bool {
    guard let entry = entries[name], case .terminal(let definition) = entry.kind,
      definition.lifecycle == .fresh
    else { return false }
    switch entry.session.state {
    case .exited, .failed: return true
    case .idle, .running, .stopped: return false
    }
  }

  /// Screen geometry changed: hidden sessions whose size follows the screen
  /// refit, so the next showing starts at the right grid.
  func refitHidden(except shown: String?) {
    for (name, entry) in entries where name != shown {
      guard case .terminal(let definition) = entry.kind, definition.size.followsScreen else {
        continue
      }
      let grid = gridResolver(definition.size)
      entry.session.resize(columns: grid.columns, rows: grid.rows)
    }
  }

  private func prewarm(_ name: String) {
    guard let definition = definitions[name], definition.lifecycle == .fresh,
      prewarmNames.contains(name), !startsOnShowNames.contains(name), entries[name] == nil,
      retiringNames[name] == nil
    else { return }
    start(name, definition)
    prewarmedNames.insert(name)
    FlashLog.debug(
      "Status popup prewarmed", fields: ["popup_id": StatusFormatDocument.stableID(name)],
      source: "core:StatusTerminalRegistry.prewarm")
    didChange?()
  }

  /// Take `name`'s session out of the registry without stopping it.
  private func detach(_ name: String) -> Entry? {
    guard let entry = entries.removeValue(forKey: name) else { return nil }
    prewarmedNames.remove(name)
    inputGenerations.removeValue(forKey: name)
    restarts[name]?.pending?.cancel()
    restarts[name]?.pending = nil
    if case .pager(let snapshot) = entry.kind { snapshot.close() }
    return entry
  }

  /// End `name`'s session and close whatever shows it. A prewarmed fresh
  /// popup starts its next process once this one is gone, so a program
  /// holding a lock (newsboat's cache) can start again.
  private func release(_ name: String) {
    guard let entry = detach(name) else { return }
    willChange?([.remove(name)])
    retire(entry, of: name) { [weak self] in self?.prewarm(name) }
    didChange?()
  }

  func preparePager(name: String, data: Data, columns: Int, rows: Int) -> TerminalSession {
    if let entry = entries[name], case .pager(let snapshot) = entry.kind {
      if snapshot.data != data {
        snapshot.data = data
        snapshot.allowsRefresh = true
        publish(name: name, snapshot: snapshot, session: entry.session)
      }
      return entry.session
    }
    retire(detach(name), of: name)
    let snapshot = StatusPopupSnapshot(data: data)
    let pager = Config.Terminal(
      command: [
        // `-Ps` is drawn in reverse video, which turns an otherwise blank
        // prompt into a light block at the foot of every preview. `-R` passes
        // the prompt's own escapes through, and a leading "exit reverse" makes
        // less skip standout entirely, leaving the row genuinely empty.
        "/usr/bin/less", "-R", "--mouse", "--wheel-lines=3", "-~", "-Ps\u{1B}[27m",
        snapshot.fileURL.path,
      ],
      environment: ["LESS": "", "LESSOPEN": "", "LESSHISTFILE": "-", "LESSSECURE": "1"])
    let session = launch(
      name, kind: .pager(snapshot),
      configuration: Self.configuration(
        for: pager, environment: processEnvironment.environment, columns: columns, rows: rows,
        scrollbackLines: 0),
      startImmediately: false)
    publish(name: name, snapshot: snapshot, session: session)
    return session
  }

  func freezePopup(name: String, completion: @escaping () -> Void) {
    guard let entry = entries[name], case .pager(let snapshot) = entry.kind else {
      completion()
      return
    }
    snapshot.freeze { [weak self, weak session = entry.session] repaint in
      guard let self, let session, self.entries[name]?.session === session else { return }
      if repaint { session.send(Data("gR".utf8)) }
      completion()
    }
  }

  func stagePopup(name: String, data: Data) {
    guard case .pager(let snapshot)? = entries[name]?.kind else { return }
    snapshot.data = data
  }

  private func publish(name: String, snapshot: StatusPopupSnapshot, session: TerminalSession) {
    snapshot.publish { [weak self, weak session] result in
      guard let self, let session, self.entries[name]?.session === session else { return }
      switch result {
      case .success(let changed):
        if case .idle = session.state {
          session.start()
        } else if changed, snapshot.allowsRefresh {
          session.send(Data("gR".utf8))
        }
      case .failure(let error):
        FlashLog.warn("Status popup snapshot failed: \(error.localizedDescription)")
        self.release(name)
      }
    }
  }

  private func start(_ name: String, _ definition: Config.Terminal) {
    let grid = gridResolver(definition.size)
    launch(
      name, kind: .terminal(definition),
      configuration: Self.configuration(
        for: definition, environment: processEnvironment.environment, columns: grid.columns,
        rows: grid.rows))
  }

  @discardableResult
  private func launch(
    _ name: String, kind: Kind, configuration: TerminalConfiguration,
    startImmediately: Bool = true
  ) -> TerminalSession {
    advanceInputGeneration(for: name)
    let session = TerminalSession(configuration: configuration)
    entries[name] = Entry(kind: kind, session: session)
    var previousState: TerminalSessionState?
    var lastPID: Int32?
    session.onStateChange = { [weak self, weak session] state in
      if previousState != state {
        previousState = state
        if case .running(let pid) = state { lastPID = pid }
        Self.logLifecycle(name: name, state: state, pid: lastPID)
      }
      guard let self, let session, self.entries[name]?.session === session else { return }
      self.observe(state: state, name: name)
      if self.entries[name]?.session === session { self.didChange?() }
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
    session.setWantsFrames(false)
    session.setColors(foreground: colors.foreground, background: colors.background)
    if startImmediately { session.start() }
    return session
  }

  private func observe(state: TerminalSessionState, name: String) {
    guard let entry = entries[name] else { return }
    switch state {
    case .running:
      guard case .terminal(let definition) = entry.kind, definition.lifecycle == .persistent
      else { return }
      restarts[name, default: Restart()].backoff.running(
        at: ProcessInfo.processInfo.systemUptime)
      restarts[name]?.pending?.cancel()
      restarts[name]?.pending = nil
    case .exited, .failed:
      guard case .terminal(let definition) = entry.kind else {
        release(name)
        return
      }
      // A shown fresh process closes its popup when the user ended it (a
      // typed `exit`, `q` in a TUI); one that ended by itself keeps its last
      // screen until the showing ends.
      if definition.lifecycle == .persistent {
        // A missing or unusable command fails the same way on every retry:
        // it waits for an explicit restart or a reload instead of the backoff.
        if case .failed(let failure) = state, failure.isPermanent {
          restarts[name]?.pending?.cancel()
          restarts[name]?.pending = nil
          return
        }
        scheduleRestart(name)
      } else if prewarmedNames.contains(name) {
        startOnShow(name)
      } else if entry.session.receivedInput {
        release(name)
      }
    case .idle, .stopped:
      break
    }
  }

  /// `name`'s prewarmed process ended before any showing: a one-shot report.
  /// Started ahead it would be stale when shown, and replaced as it ends it
  /// would respawn forever, so it starts when shown until its definition
  /// changes.
  private func startOnShow(_ name: String) {
    startsOnShowNames.insert(name)
    FlashLog.info(
      "Status popup starts on show", fields: ["popup_id": StatusFormatDocument.stableID(name)],
      source: "core:StatusTerminalRegistry.prewarm")
    release(name)
  }

  /// Restart `name`'s persistent process after the backoff delay.
  private func scheduleRestart(_ name: String) {
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
    let session = entries[name]?.session
    let generation = inputGenerations[name]
    // The backoff rides the shared clock. Its first step (0.1 s) follows a
    // program the user just quit inside a popup they may still be looking
    // at: `.high`. Later steps back off a crash loop nobody is waiting on:
    // `.low`.
    restart.pending?.cancel()
    let deadline = PollDeadline(
      "core:popup_restart:\(StatusFormatDocument.stableID(name))", priority: .low, on: .main)
    restart.pending = deadline
    restarts[name] = restart
    deadline.arm(after: delay, priority: restart.backoff.attempt == 1 ? .high : .low) {
      [weak self] in
      guard let self else { return }
      self.restarts[name]?.pending = nil
      guard let session, self.entries[name]?.session === session,
        self.inputGenerations[name] == generation
      else { return }
      self.restartSession(name: name, resetBackoff: false)
    }
    FlashLog.info(
      "Status terminal restart scheduled",
      fields: [
        "popup_id": StatusFormatDocument.stableID(name),
        "attempt": String(restart.backoff.attempt), "delay_seconds": String(delay),
      ], source: "core:StatusTerminalRegistry.restart")
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
    case .failed(let failure):
      fields["state"] = "failed"
      fields["failure_category"] = failure.category
      fields["failure_reason"] = failure.reason
      fields["retries"] = failure.isPermanent ? "on_restart" : "automatic"
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

  /// Restart the process explicitly: every kind, whatever its lifecycle. A
  /// pager rereads the latest collected document. A command that could not
  /// start rereads the login environment first, so a tool installed since
  /// then is found.
  func restart(name: String) {
    guard let entry = entries[name], case .terminal(let definition) = entry.kind,
      case .failed(let failure) = entry.session.state, failure.isPermanent
    else { return restartSession(name: name, resetBackoff: true) }
    let session = entry.session
    refreshEnvironment { [weak self] in
      guard let self, self.entries[name]?.session === session else { return }
      self.restartSession(
        name: name, resetBackoff: true, environment: self.launchEnvironment(for: definition))
    }
  }

  /// After the login environment was re-read (a configuration reload), start
  /// again every persistent popup whose command could not start.
  func retryFailedLaunches() {
    dispatchPrecondition(condition: .onQueue(.main))
    for (name, entry) in entries {
      guard case .terminal(let definition) = entry.kind, definition.lifecycle == .persistent,
        case .failed(let failure) = entry.session.state, failure.isPermanent
      else { continue }
      restartSession(
        name: name, resetBackoff: true, environment: launchEnvironment(for: definition))
    }
  }

  private func launchEnvironment(for definition: Config.Terminal) -> [String: String] {
    Self.configuration(for: definition, environment: processEnvironment.environment).environment
  }

  /// End the process. A persistent popup restarts it after the backoff; a
  /// fresh popup or a pager closes.
  func quit(name: String) {
    guard let entry = entries[name] else { return }
    guard case .terminal(let definition) = entry.kind, definition.lifecycle == .persistent else {
      release(name)
      return
    }
    guard case .running = entry.session.state else { return }
    restarts[name]?.pending?.cancel()
    restarts[name]?.pending = nil
    willChange?([.replace(name)])
    advanceInputGeneration(for: name)
    let generation = inputGenerations[name]
    entry.session.stop { [weak self, weak session = entry.session] in
      guard let self, let session, self.entries[name]?.session === session,
        self.inputGenerations[name] == generation
      else { return }
      self.scheduleRestart(name)
    }
  }

  private func restartSession(
    name: String, resetBackoff: Bool, environment: [String: String]? = nil
  ) {
    guard let entry = entries[name] else { return }
    restarts[name]?.pending?.cancel()
    restarts[name]?.pending = nil
    if resetBackoff { restarts[name]?.backoff = TerminalRestartBackoff() }
    willChange?([.replace(name)])
    advanceInputGeneration(for: name)
    switch entry.kind {
    case .pager(let snapshot):
      let generation = inputGenerations[name]
      snapshot.write { [weak self, weak session = entry.session] result in
        guard let self, let session, self.entries[name]?.session === session,
          self.inputGenerations[name] == generation
        else { return }
        if case .success = result { session.restart() }
      }
    case .terminal:
      entry.session.restart(environment: environment)
    }
  }

  private func advanceInputGeneration(for name: String) {
    nextInputGeneration &+= 1
    inputGenerations[name] = nextInputGeneration
  }

  private func retire(_ entry: Entry?, of name: String, onStopped: (() -> Void)? = nil) {
    guard let session = entry?.session else {
      onStopped?()
      return
    }
    let identity = ObjectIdentifier(session)
    retiringSessions[identity] = session
    retiringNames[name, default: 0] += 1
    session.stop { [weak self] in
      guard let self else { return }
      self.retiringSessions.removeValue(forKey: identity)
      if let count = self.retiringNames[name], count > 1 {
        self.retiringNames[name] = count - 1
      } else {
        self.retiringNames.removeValue(forKey: name)
      }
      onStopped?()
    }
  }

  /// Stops every child at once: each gets its hangup, termination and reap
  /// deadlines on its own queue, so quitting takes as long as the slowest.
  func shutdown() {
    for restart in restarts.values { restart.pending?.cancel() }
    restarts.removeAll()
    prewarmNames.removeAll()
    prewarmedNames.removeAll()
    startsOnShowNames.removeAll()
    let names = entries.keys.sorted()
    if !names.isEmpty { willChange?(names.map(StatusTerminalChange.remove)) }
    for entry in entries.values {
      if case .pager(let snapshot) = entry.kind { snapshot.close() }
    }
    let sessions = entries.values.map(\.session) + Array(retiringSessions.values)
    entries.removeAll()
    definitions.removeAll()
    inputGenerations.removeAll()
    retiringSessions.removeAll()
    retiringNames.removeAll()
    TerminalSession.shutdown(sessions)
  }

  /// The launch of a popup command: arguments and the working directory
  /// expand `$VAR` and a leading `~` against the resolved environment.
  static func configuration(
    for definition: Config.Terminal, environment base: [String: String],
    columns: Int? = nil, rows: Int? = nil, scrollbackLines: Int? = nil
  ) -> TerminalConfiguration {
    let resolved = CommandLaunchConfiguration(
      command: definition.command,
      workingDirectory: definition.workingDirectory, overrides: definition.environment,
      environment: base)
    var environment = resolved.environment
    // The child has a color terminal; only an explicit override opts out.
    if definition.environment["NO_COLOR"] == nil { environment.removeValue(forKey: "NO_COLOR") }
    let grid = definition.size.unplacedGrid
    return TerminalConfiguration(
      command: resolved.command,
      workingDirectory: resolved.workingDirectory, environment: environment,
      columns: columns ?? grid.columns, rows: rows ?? grid.rows,
      scrollbackLines: scrollbackLines
        ?? (definition.lifecycle == .persistent
          ? TerminalConfiguration.defaultScrollbackLines : freshScrollbackLines))
  }
}
