import FlashCore
import FlashTerminal
import Foundation

enum StatusTerminalChange: Equatable {
  case start(String)
  case resize(String)
  case replace(String)
  case remove(String)

  static func reconcile(
    current: [String: Config.StatusBar.TerminalPopup],
    desired: [String: Config.StatusBar.TerminalPopup],
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
        || previous.environment != next.environment
      {
        changes.append(.replace(name))
      } else if previous.columns != next.columns || previous.rows != next.rows {
        changes.append(.resize(name))
      }
    }
    return changes
  }
}

/// Main-thread ownership of declared sessions; presentation never creates a child.
final class StatusTerminalRegistry {
  private(set) var sessions: [String: TerminalSession] = [:]
  private(set) var definitions: [String: Config.StatusBar.TerminalPopup] = [:]
  private(set) var inputGenerations: [String: UInt64] = [:]
  private var nextInputGeneration: UInt64 = 0
  private var retiringSessions: [ObjectIdentifier: TerminalSession] = [:]
  var willChange: (([StatusTerminalChange]) -> Void)?
  var didChange: (() -> Void)?

  func apply(_ statusBar: Config.StatusBar) {
    dispatchPrecondition(condition: .onQueue(.main))
    let colors = StatusPopupColors(statusBar.popupStyle)
    for session in sessions.values {
      session.setColors(foreground: colors.foreground, background: colors.background)
    }
    let changes = StatusTerminalChange.reconcile(
      current: definitions, desired: statusBar.terminalPopups,
      invalid: statusBar.invalidTerminalPopupNames)
    if !changes.isEmpty { willChange?(changes) }
    for change in changes {
      switch change {
      case .remove(let name):
        inputGenerations.removeValue(forKey: name)
        retire(sessions.removeValue(forKey: name))
        definitions.removeValue(forKey: name)
      case .start(let name), .replace(let name):
        guard let definition = statusBar.terminalPopups[name] else { continue }
        advanceInputGeneration(for: name)
        retire(sessions.removeValue(forKey: name))
        let session = TerminalSession(
          configuration: Self.configuration(
            for: definition, environment: FlashProcessEnvironment.shared.environment))
        sessions[name] = session
        definitions[name] = definition
        session.onStateChange = { [weak self, weak session] _ in
          guard let self, self.sessions[name] === session else { return }
          self.didChange?()
        }
        session.onInputRejected = { count in
          FlashLog.warn("[terminal] input queue full name=\(name) rejected_bytes=\(count)")
        }
        session.setColors(foreground: colors.foreground, background: colors.background)
        session.start()
      case .resize(let name):
        guard let definition = statusBar.terminalPopups[name] else { continue }
        definitions[name] = definition
        sessions[name]?.resize(columns: definition.columns, rows: definition.rows)
      }
    }
    if !changes.isEmpty { didChange?() }
  }

  func restart(name: String) {
    guard sessions[name] != nil else { return }
    advanceInputGeneration(for: name)
    sessions[name]?.restart()
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
    willChange?(sessions.keys.sorted().map(StatusTerminalChange.remove))
    for session in Array(sessions.values) + Array(retiringSessions.values) { session.shutdown() }
    sessions.removeAll()
    definitions.removeAll()
    inputGenerations.removeAll()
    retiringSessions.removeAll()
  }

  static func configuration(
    for definition: Config.StatusBar.TerminalPopup, environment base: [String: String]
  ) -> TerminalConfiguration {
    var environment = base
    for (name, value) in definition.environment {
      environment[name] = expand(value, environment: base)
    }
    return TerminalConfiguration(
      command: definition.command.map { expand($0, environment: environment) },
      workingDirectory: definition.workingDirectory.map { expand($0, environment: environment) },
      environment: environment, columns: definition.columns, rows: definition.rows)
  }

  static func expand(_ value: String, environment: [String: String]) -> String {
    let value = CommandMappingRunner.expandLeadingTilde(value)
    var result = ""
    var cursor = value.startIndex
    while cursor < value.endIndex {
      guard value[cursor] == "$" else {
        result.append(value[cursor])
        cursor = value.index(after: cursor)
        continue
      }
      let start = cursor
      cursor = value.index(after: cursor)
      let braced = cursor < value.endIndex && value[cursor] == "{"
      if braced { cursor = value.index(after: cursor) }
      let nameStart = cursor
      while cursor < value.endIndex,
        value[cursor].isASCII,
        value[cursor].isLetter || value[cursor].isNumber || value[cursor] == "_"
      {
        cursor = value.index(after: cursor)
      }
      let name = String(value[nameStart..<cursor])
      if !name.isEmpty, !braced || (cursor < value.endIndex && value[cursor] == "}") {
        if braced { cursor = value.index(after: cursor) }
        result += environment[name] ?? String(value[start..<cursor])
      } else {
        result += String(value[start..<cursor])
      }
    }
    return result
  }
}
