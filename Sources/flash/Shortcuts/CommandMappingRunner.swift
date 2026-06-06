import Foundation

struct CommandMappingLaunchPlan: Equatable {
  var executableURL: URL
  var arguments: [String]
}

enum CommandMappingRunner {
  static func launchPlan(for argv: [String]) -> CommandMappingLaunchPlan? {
    let expanded = argv.map(expandLeadingTilde)
    guard let executable = expanded.first, !executable.isEmpty else { return nil }
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
    process.environment = commandEnvironment()
    if let null = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null")) {
      process.standardOutput = null
      process.standardError = null
    }
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

  private static func commandEnvironment() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    if environment["PATH", default: ""].isEmpty {
      environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    }
    return environment
  }

  private static func argvDiagnostic(_ argv: [String]) -> String {
    MappingAction.shellCommand(argv).diagnosticDescription
  }
}
