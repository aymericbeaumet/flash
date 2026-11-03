import AppKit
import FlashCore

/// The one runner behind `flash <words>` and `:<words>`: the same resolver
/// over the same inventory, the same dispatch, and a result each surface
/// presents its own way — the CLI prints it and exits with its status, the
/// command line shows its output.
extension AppDelegate {
  /// Where an invocation came from. Only `config check` runs differently:
  /// the CLI runs it in its own process and directory.
  enum CommandSurface {
    case cli
    case commandLine
  }

  /// The popup the command line shows a multi-line output in. Its name
  /// holds a `.`, which no `[popup.<name>]` may.
  static let commandOutputPopupName = "flash.output"

  /// Resolve `invocation` against the commands available right now and run
  /// it; `completion` runs once, on the main thread.
  func runInvocation(
    _ invocation: CommandInvocation, surface: CommandSurface,
    completion: @escaping (CommandInvocationResult) -> Void
  ) {
    let inventory =
      surface == .commandLine ? commandLineInventory() : makeCommandLineInventory()
    let resolution = NormalModeDispatcher.resolveCommandWords(
      invocation.words, inventory: inventory)
    performResolution(
      resolution, invocation: invocation, inventory: inventory, surface: surface,
      completion: completion)
  }

  func performResolution(
    _ resolution: NormalModeDispatcher.CommandLineResolution,
    invocation: CommandInvocation,
    inventory: NormalModeDispatcher.CommandLineInventory,
    surface: CommandSurface,
    completion: @escaping (CommandInvocationResult) -> Void
  ) {
    FlashLog.debug("[command] run=\(invocation.line) surface=\(surface)")
    let finish: (CommandInvocationResult) -> Void = { result in
      // The CLI prints the reason and the command line shows it; the log keeps
      // it for a script that ran unattended.
      if result.status == .failed {
        FlashLog.info(
          "[command] failed",
          fields: [
            "line": invocation.line, "surface": "\(surface)", "reason": result.message ?? "",
          ],
          source: "core:Command")
      }
      if invocation.capturesOutput, result.status == .succeeded, let output = result.output {
        NormalModeDispatcher.copy(output)
      }
      completion(result)
    }
    switch resolution {
    case .commands(let commands):
      performInvokedCommands(commands, finish)
    case .plugin(let command, let subcommand, let args):
      performInvokedCommands(
        [.pluginCommand(command: command, subcommand: subcommand, args: args)], finish)
    case .query(let query, let arguments):
      performQuery(query, arguments: arguments, surface: surface, completion: finish)
    case .open(let argv):
      Self.runOpen(argv, directory: invocation.workingDirectory) { status in
        finish(status == 0 ? .succeeded() : .failed("open exited with status \(status)"))
      }
    case .flashlight(let query):
      enterCommandLineMode(
        initialText: URLCommand.flashlightInput(query: query), candidateFinderScope: .all)
      finish(.succeeded())
    case .shell(let command):
      Self.runShell(command, directory: invocation.workingDirectory) { status, output in
        finish(status == 0 ? .succeeded(output) : .failed("exit status \(status)", output: output))
      }
    case .normalKeys(let keys):
      performNormalKeys(keys, completion: finish)
    case .incomplete, .ambiguous, .unknown, .empty:
      let message =
        resolution.rejection(of: invocation.words, inventory: inventory)
        ?? "nothing to run"
      warnUnsupportedCommand(invocation.line)
      finish(.rejected(message))
    }
  }

  /// The inventory a CLI invocation resolves against: the command line's,
  /// built for this one run.
  func makeCommandLineInventory() -> NormalModeDispatcher.CommandLineInventory {
    let registrations = pluginManager.commandRegistrations(in: pluginSelectorContext())
    var commands: [String: [String]] = [:]
    for registration in registrations {
      let key = registration.command.lowercased()
      var subcommands = commands[key] ?? []
      // `"*"` marks a wildcard command (whole remainder is args, e.g.
      // `:calc 2 + 2`): the resolver passes its words through, and
      // completion has no concrete subcommand to suggest.
      if !registration.subcommand.isEmpty,
        !subcommands.contains(where: {
          $0.localizedCaseInsensitiveCompare(registration.subcommand) == .orderedSame
        })
      {
        subcommands.append(registration.subcommand)
      }
      commands[key] = subcommands
    }
    let topics =
      manualTopicNames
      + HelpDocs.pluginTopics(pluginManager.pluginHelpTopics(), reserved: manualTopicNames)
      .map(\.name)
    return NormalModeDispatcher.CommandLineInventory.core(
      pluginCommands: commands, helpTopics: topics)
  }

  /// `:wq` and the other sequences: each step dispatches as a typed command
  /// does, confirmations included; a step that failed, or found no app to
  /// act in, stops the rest, and the step that ended the run is the result.
  /// A settle delay separates the chords, as `app save_and_quit` does.
  private func performInvokedCommands(
    _ commands: [URLCommand], _ completion: @escaping (CommandInvocationResult) -> Void
  ) {
    var first = true
    NormalModeDispatcher.runCommandSequence(
      commands,
      outcome: { (step: (outcome: NormalModeCommandOutcome, output: String?)) in step.outcome },
      perform: { [weak self] command, done in
        guard let self else { return }
        let run: () -> Void = {
          self.handleURLCommand(command) { outcome, output in done((outcome, output)) }
        }
        if first {
          first = false
          run()
        } else {
          DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) { run() }
        }
      },
      completion: { command, step in
        completion(
          Self.invocationResult(
            step.outcome, output: step.output, command: command.diagnosticDescription))
      })
  }

  /// What an outcome means to the caller: the app had no such command, or
  /// nothing to act in, is a failure the CLI reports.
  static func invocationResult(
    _ outcome: NormalModeCommandOutcome, output: String?, command: String
  ) -> CommandInvocationResult {
    switch outcome {
    case .performed, .chordSent: return .succeeded(output)
    // A failure's text says why.
    case .failed: return .failed(output ?? "\(command) failed")
    case .unavailable: return .failed("the focused app has no \(command)")
    case .noTarget: return .failed("no app to run \(command) in")
    case .refused: return .failed("\(command) would type into the terminal; not sent")
    }
  }

  private func performQuery(
    _ query: FlashQuery, arguments: [String: String], surface: CommandSurface,
    completion: @escaping (CommandInvocationResult) -> Void
  ) {
    let asJSON = arguments["json"] != nil
    switch query {
    case .status:
      let output = FlashQuery.render(.status, json: statusReport().data, asJSON: asJSON)
      completion(.succeeded(output))
    case .doctor:
      runDoctor { report in
        for line in report.lines {
          FlashLog.info("[doctor] \(line)")
        }
        let output = FlashQuery.render(.doctor, json: report.data, asJSON: asJSON)
        completion(
          report.issues == 0
            ? .succeeded(output)
            : .failed("doctor found \(report.issues) issue(s)", output: output))
      }
    case .configCheck:
      guard surface == .commandLine else {
        return completion(.local(.configCheck, arguments: arguments))
      }
      let environment = ProcessInfo.processInfo.environment
      let url =
        arguments["file"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        ?? ConfigLoader.resolvePath(environment: environment)
      let check = ConfigCheck.run(
        fileURL: url.resolvingSymlinksInPath(),
        text: (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) },
        defaultLayer: ConfigLoader.embeddedDefaultLayer(in: .main))
      let output = check.lines.isEmpty ? "\(url.path): ok" : check.lines.joined(separator: "\n")
      completion(
        check.exitCode == 0
          ? .succeeded(output) : .failed("\(url.path) has problems", output: output))
    case .configSchema:
      guard let defaults = ConfigLoader.embeddedDefaultLayer(in: .main)?.text else {
        return completion(.failed("this build has no config.default.toml to describe"))
      }
      completion(.succeeded(ConfigSchema.json(defaults: defaults)))
    case .completion:
      guard let shell = arguments["shell"].flatMap(CLIReference.Shell.init(rawValue:)) else {
        return completion(.failed("--shell must be zsh, bash or fish"))
      }
      completion(.succeeded(CLIReference.completion(for: shell)))
    case .manPage:
      completion(.succeeded(CLIReference.manPage()))
    case .eventsWatch:
      // The stream is the CLI's connection: the CLI subscribes on it.
      guard surface == .commandLine else {
        return completion(.local(.eventsWatch, arguments: arguments))
      }
      completion(.failed("events watch streams to a terminal: run flash events watch"))
    }
  }

  /// `open <args>`, forwarded verbatim to `/usr/bin/open` from `directory`:
  /// URLs, files, `-a App`. Deliberately dumb; app-finding lives in
  /// `flashlight`. `completion` gets its exit status on the main thread.
  static func runOpen(
    _ args: [String], directory: String?, completion: @escaping (Int32) -> Void
  ) {
    let environment = FlashProcessEnvironment.shared.environment
    DispatchQueue.global(qos: .userInitiated).async {
      let result = BoundedCommand.run(
        ["/usr/bin/open"] + args, environment: environment, directory: directory, timeout: nil,
        capture: .none)
      DispatchQueue.main.async { completion(result.status ?? 127) }
    }
  }

  /// The most output `:!` keeps, from the start; the rest is dropped and said so.
  static let shellOutputLimit = 1 << 20

  /// `:!{cmd}`, vim's way: the user's shell runs the line from `directory`
  /// with Flash's login environment; `completion` gets the exit status and
  /// the combined output on the main thread.
  static func runShell(
    _ command: String, directory: String?,
    completion: @escaping (Int32, String) -> Void
  ) {
    let environment = FlashProcessEnvironment.shared.environment
    let shell = environment["SHELL"] ?? "/bin/sh"
    DispatchQueue.global(qos: .userInitiated).async {
      // No timeout: `:!` waits for its command as vim does; the run ends
      // with the shell, not with what it left in the background.
      let result = BoundedCommand.run(
        [shell, "-c", command], environment: environment, directory: directory, timeout: nil,
        capture: .merged, outputLimit: shellOutputLimit)
      guard let status = result.status, result.launchFailure == nil else {
        DispatchQueue.main.async { completion(127, "could not start \(shell)") }
        return
      }
      var output = result.text
      if output.hasSuffix("\n") { output.removeLast() }
      if result.truncated { output += "\n[output truncated at \(shellOutputLimit) bytes]" }
      DispatchQueue.main.async { completion(status, output) }
    }
  }

  /// `:norm[al] {keys}`: what typing those keys runs in the focused app's
  /// NORMAL table — `gt`, `3gt`, `"ap`, `ma`, `@a`, `ctrl+w h`.
  private func performNormalKeys(
    _ text: String, completion: @escaping (CommandInvocationResult) -> Void
  ) {
    guard
      let resolved = Self.normalKeysAction(
        text, leader: config.mode.resolvedLeaderAtom, mappings: overlay.normalModeMappings,
        recordingMacro: overlay.normalModeRecordingMacro)
    else { return completion(.rejected("no NORMAL mapping for \(text)")) }
    switch resolved.action {
    case .flashCommand(let command):
      performMappedCommand(command, repeatCount: resolved.count) { outcome in
        completion(
          Self.invocationResult(
            outcome, output: nil, command: command.diagnosticDescription))
      }
    case .shellCommand(let argv):
      for _ in 0..<resolved.count { CommandMappingRunner.run(argv) }
      completion(.succeeded())
    }
  }

  /// What `:norm[al] {keys}` runs, and how many times: plain characters as
  /// typing them would (`3gt`, `ma`, `@a`, `"ap`), and a chord or
  /// `<leader>` key as the mapping it names, after a count and a register.
  static func normalKeysAction(
    _ text: String, leader: String?, mappings: CompiledMappings, recordingMacro: Bool
  ) -> (action: MappingCommand, count: Int)? {
    if let typed = NormalModeInterpreter.typedKeysAction(
      text.trimmed, mappings: mappings, recordingMacro: recordingMacro)
    {
      return typed
    }
    guard let parsed = normalKeys(text, leader: leader),
      let mapping = mappings.mapping(for: parsed.key)
    else { return nil }
    return (
      NormalModeInterpreter.applyingRegister(parsed.register, to: mapping.action), parsed.count
    )
  }

  /// `"x`, a count and a mapping key, as NORMAL reads them; the key in its
  /// compiled form, `<leader>` resolved.
  static func normalKeys(_ text: String, leader: String?) -> (
    key: String, count: Int, register: String?
  )? {
    var rest = Substring(text.trimmed)
    var register: String?
    if rest.first == "\"", rest.count >= 2, let name = rest.dropFirst().first,
      NormalModeInterpreter.isRegisterNameChar(name)
    {
      register = String(name)
      rest = rest.dropFirst(2)
    }
    let digits = rest.prefix { $0.isASCII && $0.isNumber }
    let count = Int(digits) ?? 1
    rest = rest.dropFirst(digits.count)
    guard !rest.isEmpty, var key = NormalModeInterpreter.canonicalizeMappingKey(String(rest))
    else { return nil }
    if key.contains("<leader>") {
      guard let leader else { return nil }
      key = key.replacingOccurrences(of: "<leader>", with: leader)
    }
    return (key, RepeatCount.clamp(count), register)
  }

  /// The command line's half of a result: output on a banner, several
  /// lines in the pager, or the clipboard with `#`. Failures were shown by
  /// the command itself, as they are when a mapping runs it.
  func presentCommandLineResult(
    _ result: CommandInvocationResult, invocation: CommandInvocation
  ) {
    guard let output = result.output, !output.isEmpty else { return }
    if invocation.capturesOutput, result.status == .succeeded {
      overlay.displayBanner("Copied: \(output)")
      return
    }
    guard output.contains("\n") else {
      overlay.displayBanner(output)
      return
    }
    presentCommandOutput(output)
  }

  /// A multi-line output in the shared pager, centred and focused like
  /// `mode terminal`; Escape or `q` closes it.
  func presentCommandOutput(_ text: String) {
    guard let screen = focusedAppScreen() else { return }
    dismissPopup(restoreApplication: false)
    overlay.statusPopupController.show(
      name: Self.commandOutputPopupName,
      document: [FlashStatusTextSegment(text: text, foreground: .defaultForeground)],
      visibleFrame: screen.visibleFrame, style: config.popupStyle, font: popupFont)
  }
}
