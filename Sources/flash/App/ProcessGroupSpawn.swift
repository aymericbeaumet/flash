import CFlashTerminal
import Darwin
import Foundation

/// The one way the resident spawns a command it owns: `posix_spawn` into a
/// process group of its own, so a timeout, a reload or a quit can signal
/// every process the command started, grandchildren included. stdin reads
/// `/dev/null`, every signal starts at its default with an empty mask (the
/// resident blocks and ignores some), and no descriptor is inherited but the
/// ones asked for. `StatusFormatCommandJob`, `PluginInstallJob` and
/// `BoundedCommand` spawn through it.
enum ProcessGroupSpawn {
  /// Where the child's stdout or stderr goes.
  enum Sink: Equatable {
    case devNull
    /// The write end of a pipe the caller reads.
    case descriptor(Int32)
  }

  /// Spawn `argv` (`argv[0]` an absolute path) as the leader of a new
  /// process group, from `workingDirectory` when given. `closeInChild` lists
  /// the pipe ends the child must not keep: the read ends, and each write end
  /// once it is duplicated onto stdout or stderr. Returns the leader's pid,
  /// which is also the group id.
  static func spawn(
    argv: [String], environment: [String: String], workingDirectory: String? = nil,
    stdout: Sink, stderr: Sink, closeInChild: [Int32]
  ) throws -> pid_t {
    guard let executable = argv.first, !executable.isEmpty else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
    }
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawnattr_init(&attributes)
    defer {
      posix_spawn_file_actions_destroy(&actions)
      posix_spawnattr_destroy(&attributes)
    }
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    for (target, sink) in [(STDOUT_FILENO, stdout), (STDERR_FILENO, stderr)] {
      switch sink {
      case .devNull:
        posix_spawn_file_actions_addopen(&actions, target, "/dev/null", O_WRONLY, 0)
      case .descriptor(let descriptor):
        posix_spawn_file_actions_adddup2(&actions, descriptor, target)
      }
    }
    for descriptor in Set(closeInChild) { posix_spawn_file_actions_addclose(&actions, descriptor) }
    if let workingDirectory {
      flash_spawn_file_actions_addchdir(&actions, workingDirectory)
    }
    var mask = sigset_t()
    var defaults = sigset_t()
    sigemptyset(&mask)
    sigfillset(&defaults)
    sigdelset(&defaults, SIGKILL)
    sigdelset(&defaults, SIGSTOP)
    posix_spawnattr_setsigmask(&attributes, &mask)
    posix_spawnattr_setsigdefault(&attributes, &defaults)
    posix_spawnattr_setpgroup(&attributes, 0)
    posix_spawnattr_setflags(
      &attributes,
      Int16(
        POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK
          | POSIX_SPAWN_SETSIGDEF))
    var pid: pid_t = 0
    let error = withCStringArray(argv) { arguments in
      withCStringArray(environment.keys.sorted().map { "\($0)=\(environment[$0]!)" }) {
        environment in
        posix_spawn(&pid, executable, &actions, &attributes, arguments, environment)
      }
    }
    guard error == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(error)) }
    return pid
  }

  /// A NULL-terminated C string array alive for `body`.
  static func withCStringArray<T>(
    _ strings: [String], body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T
  ) -> T {
    var pointers = strings.map { strdup($0) } + [nil]
    defer { for pointer in pointers { free(pointer) } }
    return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
  }
}
