import FlashCore
import Foundation

/// `macro record|stop|play|repeat`: vim's `q{reg}` … `q`, `@{reg}`, `@@` and
/// `.`, over Flash commands rather than keystrokes. A recording keeps the
/// commands NORMAL dispatched — never the keys that chose them (the keyboard
/// tap logs and persists no keys) — in this process only.
enum MacroCommand: Hashable {
  /// Start recording into a register (`qa`); an uppercase name appends to
  /// the lowercase register (`qA`), as in Vim.
  case record(register: String)
  /// Stop the recording (`q` while recording).
  case stop
  /// Replay a register, or the last one played (`@a`, `@@`); `:` replays
  /// the last command line (`@:`).
  case play(register: String?)
  /// Run the last NORMAL command again, with its count unless a count is
  /// given (`.`, `3.`, `1.`).
  case repeatLast(count: Int?)

  var name: CommandName {
    switch self {
    case .record: return CommandName("macro", "record")
    case .stop: return CommandName("macro", "stop")
    case .play: return CommandName("macro", "play")
    case .repeatLast: return CommandName("macro", "repeat")
    }
  }

  var argTokens: [String] {
    switch self {
    case .record(let register): return ["--register=\(register)"]
    case .play(let register?): return ["--register=\(register)"]
    case .repeatLast(let count?): return ["--count=\(count)"]
    case .play(nil), .stop, .repeatLast(nil): return []
    }
  }

  var explanation: String {
    switch self {
    case .record(let register):
      return register == register.lowercased()
        ? "Records the commands that follow into the macro register \(register)."
        : "Records the commands that follow at the end of the macro register "
          + "\(register.lowercased())."
    case .stop: return "Stops recording the macro."
    case .play(":"): return "Runs the last command line again."
    case .play(let register?): return "Replays the macro in register \(register)."
    case .play(nil): return "Replays the last macro played."
    case .repeatLast(let count?): return "Runs the last NORMAL command again, \(count) time(s)."
    case .repeatLast(nil): return "Runs the last NORMAL command again."
    }
  }

  /// A macro register: one ASCII letter or digit, lowercase.
  static func register(_ raw: String) -> String? {
    guard raw.count == 1, let character = raw.first, character.isASCII,
      character.isLetter || character.isNumber
    else { return nil }
    return raw.lowercased()
  }

  /// The register `q{x}` records into, as typed: an uppercase letter appends.
  static func recordingRegister(_ raw: String) -> String? {
    register(raw).map { _ in raw }
  }

  /// The register `@{x}` plays: a macro register, or `:` for the last
  /// command line.
  static func playRegister(_ raw: String) -> String? {
    raw == ":" ? raw : register(raw)
  }
}

/// One step a macro replays: a command NORMAL dispatched with the count it
/// ran with, or a command line as it was submitted.
struct MacroStep: Equatable {
  enum Content: Equatable {
    case command(MappingCommand)
    case commandLine(String)
  }

  var content: Content
  var repeatCount: Int

  init(action: MappingCommand, repeatCount: Int) {
    self.init(content: .command(action), repeatCount: repeatCount)
  }

  private init(content: Content, repeatCount: Int) {
    self.content = content
    self.repeatCount = repeatCount
  }

  /// A submitted command line (`:tab next`), replayed as typed.
  static func commandLine(_ line: String) -> MacroStep {
    MacroStep(content: .commandLine(line), repeatCount: 1)
  }

  /// The command, for a step that is one.
  var action: MappingCommand? {
    guard case .command(let action) = content else { return nil }
    return action
  }
}

/// The macros of this process: what `.` repeats, the recording in progress
/// and the recorded registers. Pure state; the app delegate dispatches.
struct MacroState: Equatable {
  /// The register being recorded, and what it holds so far.
  private(set) var recording: (register: String, steps: [MacroStep])?
  private(set) var registers: [String: [MacroStep]] = [:]
  private(set) var lastPlayed: String?
  /// What `.` runs.
  private(set) var lastStep: MacroStep?
  /// The last command line submitted, what `@:` runs.
  private(set) var lastCommandLine: String?

  static func == (lhs: MacroState, rhs: MacroState) -> Bool {
    lhs.recording?.register == rhs.recording?.register
      && lhs.recording?.steps == rhs.recording?.steps && lhs.registers == rhs.registers
      && lhs.lastPlayed == rhs.lastPlayed && lhs.lastStep == rhs.lastStep
      && lhs.lastCommandLine == rhs.lastCommandLine
  }

  var isRecording: Bool { recording != nil }

  /// A NORMAL command was dispatched: `.` repeats it, and a recording keeps
  /// it. A macro played while recording is recorded too, so one macro can
  /// replay another; recording, stopping and `.` are neither, and a command
  /// that only changes the mode or shows help is no change to repeat. The
  /// command line's `:` is not recorded: the line submitted is
  /// (`noteCommandLine`).
  mutating func note(_ step: MacroStep) {
    guard let action = step.action else { return }
    if case .flashCommand(.macro(let command)) = action {
      if case .play = command { recording?.steps.append(step) }
      return
    }
    if !Self.opensCommandLine(action) { recording?.steps.append(step) }
    if Self.repeats(action) { lastStep = step }
  }

  /// A command line was submitted and ran: `@:` runs it again, and a
  /// recording keeps it as typed. `.` never repeats one, as in Vim.
  mutating func noteCommandLine(_ line: String) {
    let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !line.isEmpty else { return }
    lastCommandLine = line
    recording?.steps.append(.commandLine(line))
  }

  /// `:`, and a mapping that opens the command line with text: what a
  /// recording keeps is the line submitted from it.
  static func opensCommandLine(_ action: MappingCommand) -> Bool {
    switch action.command {
    case .commandMode?, .enterCommand?: return true
    default: return false
    }
  }

  static func repeats(_ action: MappingCommand) -> Bool {
    guard case .flashCommand(let command) = action else { return true }
    switch command {
    case .insertMode, .normalMode, .leaveMode, .commandMode, .terminalMode,
      .holdMode, .visualMode, .visualReselect, .layerMode,
      .showUsage, .showMappings, .showPlugins, .showMonitors, .showTelemetry, .showAbout,
      .reloadPlugins, .showLogs, .showCommands,
      .appSwitch, .flashlight, .enterCommand, .macro,
      // Vim's `.` repeats a change, never a motion: `j` then `.` would
      // only move again.
      .move, .cursor, .scrollCursor,
      // Escape cancels; it changes nothing to repeat.
      .appCancel:
      return false
    default:
      return true
    }
  }

  /// Start recording into `register`; an uppercase name appends to what
  /// the lowercase register holds (`qA`).
  mutating func startRecording(_ register: String) {
    let name = register.lowercased()
    recording = (name, register == name ? [] : registers[name] ?? [])
  }

  /// End the recording; the register it filled, if one was recording.
  @discardableResult
  mutating func stopRecording() -> (register: String, count: Int)? {
    guard let recording else { return nil }
    registers[recording.register] = recording.steps
    self.recording = nil
    return (recording.register, recording.steps.count)
  }

  /// The steps `macro play` replays, or nil when the register is empty;
  /// `:` is the last command line.
  mutating func steps(for register: String?) -> (register: String, steps: [MacroStep])? {
    guard let name = register ?? lastPlayed else { return nil }
    if name == ":" {
      guard let line = lastCommandLine else { return nil }
      lastPlayed = name
      return (name, [.commandLine(line)])
    }
    guard let steps = registers[name], !steps.isEmpty else { return nil }
    lastPlayed = name
    return (name, steps)
  }
}
