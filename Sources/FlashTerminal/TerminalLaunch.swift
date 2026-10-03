import Darwin
import Foundation

/// Why a session's process did not start.
public enum TerminalLaunchFailure: Equatable, Sendable {
  /// The argv or environment cannot reach `execve`: empty, or with NUL bytes.
  case invalidCommand
  /// A command without a `/` that no directory of `PATH` holds as an
  /// executable file.
  case commandNotFound(String)
  /// `execve` refused the executable (missing, not executable, bad format).
  case cannotExecute(String, errno: Int32)
  /// The working directory could not be entered.
  case workingDirectory(String, errno: Int32)
  /// No PTY or child process could be created, for instance at a process limit.
  case spawnFailed(errno: Int32)
  /// The child exited, but its status could not be collected.
  case exitStatusUnavailable

  /// Starting the same command again fails the same way until the command,
  /// its executable, its directory or `PATH` changes; the others are
  /// transient.
  public var isPermanent: Bool {
    switch self {
    case .invalidCommand, .commandNotFound, .cannotExecute, .workingDirectory: true
    case .spawnFailed, .exitStatusUnavailable: false
    }
  }

  /// A diagnostics category that never names the command.
  public var category: String {
    switch self {
    case .invalidCommand: "invalid_command"
    case .commandNotFound: "command_not_found"
    case .cannotExecute: "cannot_execute"
    case .workingDirectory: "working_directory"
    case .spawnFailed: "spawn_failed"
    case .exitStatusUnavailable: "exit_status_unavailable"
    }
  }

  /// The system's reason, without the command or any path.
  public var reason: String {
    switch self {
    case .invalidCommand: "Invalid terminal command or environment"
    case .commandNotFound: "command not found"
    case .cannotExecute(_, let code), .workingDirectory(_, let code), .spawnFailed(let code):
      String(cString: strerror(code))
    case .exitStatusUnavailable: "Terminal child exit status is unavailable"
    }
  }

  /// One line naming what failed, for people.
  public var description: String {
    switch self {
    case .invalidCommand, .spawnFailed, .exitStatusUnavailable: reason
    case .commandNotFound(let command): "\(command): command not found"
    case .cannotExecute(let executable, _): "\(executable): \(reason)"
    case .workingDirectory(let directory, _): "working directory \(directory): \(reason)"
    }
  }
}

public enum TerminalExecutable {
  /// Where `execve` finds `command`: itself when it names a path, otherwise
  /// the first regular executable file named `command` in a `PATH`
  /// directory, or nil. Empty `PATH` entries are skipped, so a bare name
  /// never resolves against whatever directory Flash runs in.
  public static func resolve(_ command: String, path: String?) -> String? {
    guard !command.isEmpty else { return nil }
    if command.contains("/") { return command }
    for directory in (path ?? defaultPath).split(separator: ":") {
      let candidate = String(directory) + "/" + command
      var info = stat()
      guard stat(candidate, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
        access(candidate, X_OK) == 0
      else { continue }
      return candidate
    }
    return nil
  }

  /// `execvp`'s search path when the environment has no `PATH`.
  public static let defaultPath = "/usr/bin:/bin:/usr/sbin:/sbin"
}
