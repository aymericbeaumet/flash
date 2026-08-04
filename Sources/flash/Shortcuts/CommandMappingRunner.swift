import FlashCore
import Foundation

struct CommandMappingLaunchPlan: Equatable {
  var executableURL: URL
  var arguments: [String]
}

enum CommandMappingRunner {
  static func launchPlan(for argv: [String]) -> CommandMappingLaunchPlan? {
    let expanded = argv.map(expandLeadingTilde)
    guard let executable = expanded.first, !executable.isEmpty else { return nil }
    guard !mappingCommandHeadNamesFlash(executable) else { return nil }
    let rest = Array(expanded.dropFirst())
    if executable.contains("/") {
      return CommandMappingLaunchPlan(
        executableURL: URL(fileURLWithPath: executable),
        arguments: rest)
    }
    return CommandMappingLaunchPlan(
      executableURL: URL(fileURLWithPath: "/usr/bin/env"),
      arguments: expanded)
  }

  @discardableResult
  static func run(_ argv: [String]) -> Bool {
    guard let plan = launchPlan(for: argv) else {
      FlashLog.warn("[mappings] shell command has no executable")
      return false
    }
    let process = Process()
    process.executableURL = plan.executableURL
    process.arguments = plan.arguments
    FlashProcessEnvironment.shared.apply(to: process)
    // Discard output through the shared null device. Do NOT open our own
    // `FileHandle(forWritingTo: /dev/null)` and assign it to both streams: an
    // owned FileHandle is double-closed when `Process` tears it down after
    // launch, which corrupts an unrelated descriptor and surfaces as
    // intermittent EBADF ("Bad file descriptor") on a *later* launch — that is
    // why `[mode.normal] <leader>…` shell mappings would stop firing. Also pin
    // stdin so the child never inherits one of Flash's (launchd-owned) fds.
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      FlashLog.debug("[mappings] launched \(argvDiagnostic(argv)) pid=\(process.processIdentifier)")
      return true
    } catch {
      FlashLog.warn("[mappings] failed to launch \(argvDiagnostic(argv)): \(error)")
      return false
    }
  }

  static func expandLeadingTilde(_ value: String) -> String {
    guard value == "~" || value.hasPrefix("~/") else { return value }
    return (value as NSString).expandingTildeInPath
  }

  private static func argvDiagnostic(_ argv: [String]) -> String {
    MappingCommand.shellCommand(argv).diagnosticDescription
  }
}
