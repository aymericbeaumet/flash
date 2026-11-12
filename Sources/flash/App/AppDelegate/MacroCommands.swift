import AppKit

/// `.`, `q{reg}` … `q` and `@{reg}` (`macro repeat|record|stop|play`): NORMAL
/// remembers the commands it dispatched, never the keys, and replays them
/// through the same dispatch, each step reporting how it ended so a failed
/// step stops the rest.
extension AppDelegate {
  /// The deepest a macro may replay another (`@a` recording `@b`).
  static let macroDepthLimit = 8

  /// NORMAL dispatched `action`: what `.` repeats, and what a recording keeps.
  func noteNormalModeStep(_ action: MappingCommand, repeatCount: Int) {
    macros.note(MacroStep(action: action, repeatCount: repeatCount))
  }

  func performMacroCommand(
    _ command: MacroCommand, repeatCount: Int,
    completion: @escaping (NormalModeCommandOutcome, String?) -> Void
  ) {
    switch command {
    case .record(let register):
      if let finished = macros.stopRecording() {
        FlashLog.info("[macro] recorded register=\(finished.register) steps=\(finished.count)")
      }
      macros.startRecording(register)
      overlay.normalModeRecordingMacro = true
      overlay.displayBanner("recording @\(register.lowercased())")
      completion(.performed, nil)
    case .stop:
      overlay.normalModeRecordingMacro = false
      guard let finished = macros.stopRecording() else {
        FlashLog.debug("[macro] stop_without_recording")
        return completion(.failed, "no macro is recording")
      }
      FlashLog.info("[macro] recorded register=\(finished.register) steps=\(finished.count)")
      overlay.displayBanner("recorded @\(finished.register): \(finished.count) command(s)")
      completion(.performed, nil)
    case .play(let register):
      guard let macro = macros.steps(for: register) else {
        FlashLog.debug("[macro] register_empty", fields: ["register": register ?? "last"])
        return completion(
          .failed, register.map { "macro register \($0) is empty" } ?? "no macro played yet")
      }
      let steps = Array(repeating: macro.steps, count: normalizedRepeatCount(repeatCount))
        .flatMap { $0 }
      playMacroSteps(steps[...], depth: 1) { completion($0, nil) }
    case .repeatLast(let count):
      guard var step = macros.lastStep else {
        FlashLog.debug("[macro] nothing_to_repeat")
        return completion(.failed, "no command to repeat yet")
      }
      // `3.` and `1.` repeat with the count typed, `.` with the one it ran with.
      if let count { step.repeatCount = normalizedRepeatCount(count) }
      performMacroStep(step, depth: 1) { completion($0, nil) }
    }
  }

  private func playMacroSteps(
    _ steps: ArraySlice<MacroStep>, depth: Int,
    completion: @escaping (NormalModeCommandOutcome) -> Void
  ) {
    guard let step = steps.first else { return completion(.performed) }
    performMacroStep(step, depth: depth) { [weak self] outcome in
      guard let self, steps.count > 1,
        NormalModeDispatcher.commandSequenceContinues(after: outcome)
      else { return completion(outcome) }
      // The settle a typed sequence leaves between chords (`:wq`).
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) {
        self.playMacroSteps(steps.dropFirst(), depth: depth, completion: completion)
      }
    }
  }

  private func performMacroStep(
    _ step: MacroStep, depth: Int, completion: @escaping (NormalModeCommandOutcome) -> Void
  ) {
    let action: MappingCommand
    switch step.content {
    case .commandLine(let line):
      return performMacroCommandLine(line, completion: completion)
    case .command(let command):
      action = command
    }
    switch action {
    case .flashCommand(.macro(.play(let register))):
      guard depth < Self.macroDepthLimit, let nested = macros.steps(for: register) else {
        FlashLog.warn("[macro] nested play stopped register=\(register ?? "@") depth=\(depth)")
        return completion(.failed)
      }
      let steps = Array(repeating: nested.steps, count: normalizedRepeatCount(step.repeatCount))
        .flatMap { $0 }
      playMacroSteps(steps[...], depth: depth + 1, completion: completion)
    case .flashCommand(let command):
      performMappedCommand(command, repeatCount: step.repeatCount, completion: completion)
    case .shellCommand(let argv):
      for _ in 0..<normalizedRepeatCount(step.repeatCount) { CommandMappingRunner.run(argv) }
      completion(.performed)
    }
  }

  /// A recorded or repeated (`@:`) command line runs as typed again, through
  /// the command line's own resolver; it fails when it no longer runs.
  private func performMacroCommandLine(
    _ line: String, completion: @escaping (NormalModeCommandOutcome) -> Void
  ) {
    let invocation = CommandInvocation(
      words: NormalModeDispatcher.commandLineWords(line),
      workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
    runInvocation(invocation, surface: .commandLine) { [weak self] result in
      self?.presentCommandLineResult(result, invocation: invocation)
      completion(result.status == .succeeded ? .performed : .failed)
    }
  }

  /// `config reload` (`:so[urce]`): re-read the file now, as a save would.
  func reloadConfigNow() -> String {
    forceConfigReload()
    let path = ConfigLoader.resolvePath(environment: ProcessInfo.processInfo.environment).path
    let problems = config.loadingDiagnostics.count
    return problems == 0 ? "reloaded \(path)" : "reloaded \(path): \(problems) problem(s)"
  }

  /// `config edit`: the file in its default app, seeded first when missing.
  static func openConfigurationFile() {
    let environment = ProcessInfo.processInfo.environment
    StarterConfig.seedIfNeeded(environment: environment)
    let url = ConfigLoader.resolvePath(environment: environment)
    NSWorkspace.shared.open(
      url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
  }
}
