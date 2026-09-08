import CFlashTerminal
import Darwin
import Foundation

/// An owned stdout job. Output is drained as it arrives, and a process group
/// keeps shell pipelines within the controller's reload/quit lifetime.
final class StatusFormatCommandJob {
  private let queue: DispatchQueue
  private let onLine: (String) -> Void
  private let onCompletion: (Int32, String) -> Void
  private var process: pid_t = 0
  private var reader: DispatchSourceRead?
  private var exitSource: DispatchSourceProcess?
  private var timeout: DispatchWorkItem?
  private var cancellation: DispatchWorkItem?
  private var descriptor: Int32 = -1
  private var pending = Data()
  private var output = Data()
  private var exitStatus: Int32?
  private var reachedEOF = false
  private var completed = false
  var processIdentifier: pid_t { process }

  init(
    queue: DispatchQueue, argv: [String], environment: [String: String],
    workingDirectory: String? = nil, timeoutSeconds: TimeInterval? = nil,
    onLine: @escaping (String) -> Void,
    onCompletion: @escaping (Int32, String) -> Void
  ) throws {
    self.queue = queue
    self.onLine = onLine
    self.onCompletion = onCompletion
    guard let executable = argv.first, !executable.isEmpty else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
    }
    var descriptors: [Int32] = [-1, -1]
    guard pipe(&descriptors) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawnattr_init(&attributes)
    defer {
      posix_spawn_file_actions_destroy(&actions)
      posix_spawnattr_destroy(&attributes)
      close(descriptors[1])
    }
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO)
    posix_spawn_file_actions_addclose(&actions, descriptors[1])
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addclose(&actions, descriptors[0])
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
    posix_spawnattr_setflags(
      &attributes,
      Int16(
        POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK
          | POSIX_SPAWN_SETSIGDEF))
    posix_spawnattr_setpgroup(&attributes, 0)
    let error = Self.withCStringArray(argv) { arguments in
      Self.withCStringArray(environment.keys.sorted().map { "\($0)=\(environment[$0]!)" }) {
        environment in
        posix_spawn(&process, executable, &actions, &attributes, arguments, environment)
      }
    }
    guard error == 0 else {
      close(descriptors[0])
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(error))
    }
    descriptor = descriptors[0]
    _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
    let readSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
    readSource.setEventHandler { [weak self] in self?.readAvailable() }
    reader = readSource
    readSource.resume()
    let source = DispatchSource.makeProcessSource(
      identifier: process, eventMask: .exit, queue: queue)
    source.setEventHandler { [weak self] in
      guard let self else { return }
      var status: Int32 = 0
      if waitpid(self.process, &status, WNOHANG) == self.process {
        self.exitStatus = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        self.readAvailable()
        self.finishIfReady()
      }
    }
    exitSource = source
    source.resume()
    if let timeoutSeconds, timeoutSeconds > 0 {
      let item = DispatchWorkItem { [weak self] in self?.cancel() }
      timeout = item
      queue.asyncAfter(deadline: .now() + timeoutSeconds, execute: item)
    }
  }

  func cancel() {
    guard !completed, cancellation == nil, process > 0 else { return }
    let pid = process
    kill(-pid, SIGTERM)
    let item = DispatchWorkItem { [weak self] in
      guard let self, !self.completed, self.process == pid else { return }
      kill(-pid, SIGKILL)
    }
    cancellation = item
    queue.asyncAfter(deadline: .now() + .milliseconds(500), execute: item)
  }

  /// Called on the jobs' owner queue. One deadline covers the whole batch, so
  /// quitting cannot multiply a per-process grace period by the source count.
  @discardableResult
  static func shutdown(
    _ jobs: [StatusFormatCommandJob], graceSeconds: TimeInterval = 0.1,
    deadlineSeconds: TimeInterval = 1
  ) -> [pid_t] {
    let active = jobs.filter { !$0.completed && $0.process > 0 }
    guard !active.isEmpty else { return [] }
    for job in active {
      job.closeSources()
      kill(-job.process, SIGTERM)
    }
    let started = ProcessInfo.processInfo.systemUptime
    let deadline = started + max(0, deadlineSeconds)
    let killAt = min(deadline, started + max(0, graceSeconds))
    var killed = false
    while true {
      let now = ProcessInfo.processInfo.systemUptime
      if !killed, now >= killAt {
        for job in active { kill(-job.process, SIGKILL) }
        killed = true
      }
      for job in active where job.exitStatus == nil { job.reapIfExited() }
      let allReaped = active.allSatisfy { $0.exitStatus != nil }
      let anyGroupAlive = active.contains { kill(-$0.process, 0) == 0 || errno == EPERM }
      if allReaped && !anyGroupAlive { break }
      if now >= deadline { break }
      usleep(2_000)
    }
    if !killed { for job in active { kill(-job.process, SIGKILL) } }
    for job in active {
      job.reapIfExited()
      job.completed = job.exitStatus != nil
      job.reachedEOF = true
    }
    return active.filter { !$0.completed || kill(-$0.process, 0) == 0 }.map(\.process)
  }

  private func readAvailable() {
    guard descriptor >= 0, !reachedEOF else { return }
    var buffer = [UInt8](repeating: 0, count: 16_384)
    var consumed = 0
    var latestLine: String?
    defer { if let latestLine { onLine(latestLine) } }
    while consumed < 262_144 {
      let count = read(descriptor, &buffer, buffer.count)
      if count > 0 {
        consumed += count
        let data = buffer.prefix(count)
        pending.append(contentsOf: data)
        output.append(contentsOf: data)
        if output.count > 1_048_576 { output.removeFirst(output.count - 1_048_576) }
        while let newline = pending.firstIndex(of: 10) {
          latestLine = String(decoding: pending[..<newline], as: UTF8.self)
          pending.removeSubrange(...newline)
        }
        if pending.count > 1_048_576 { pending.removeFirst(pending.count - 1_048_576) }
      } else if count == 0 {
        reachedEOF = true
        if !pending.isEmpty {
          latestLine = String(decoding: pending, as: UTF8.self)
          pending.removeAll()
        }
        reader?.cancel()
        reader = nil
        close(descriptor)
        descriptor = -1
        if let line = latestLine {
          onLine(line)
          latestLine = nil
        }
        finishIfReady()
        return
      } else if errno == EINTR {
        continue
      } else {
        return
      }
    }
  }

  private func finishIfReady() {
    guard !completed, reachedEOF, let exitStatus else { return }
    completed = true
    closeSources()
    // A command which backgrounds children still owns their process group.
    kill(-process, SIGKILL)
    onCompletion(exitStatus, String(decoding: output, as: UTF8.self))
  }

  private func reapIfExited() {
    guard exitStatus == nil else { return }
    var status: Int32 = 0
    let result = waitpid(process, &status, WNOHANG)
    if result == process {
      exitStatus = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    } else if result == -1, errno == ECHILD {
      exitStatus = 0
    }
  }

  private func closeSources() {
    timeout?.cancel()
    timeout = nil
    cancellation?.cancel()
    cancellation = nil
    reader?.cancel()
    reader = nil
    exitSource?.cancel()
    exitSource = nil
    if descriptor >= 0 {
      close(descriptor)
      descriptor = -1
    }
  }

  private static func withCStringArray<T>(
    _ strings: [String], body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T
  ) -> T {
    var pointers = strings.map { strdup($0) } + [nil]
    defer { for pointer in pointers { free(pointer) } }
    return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
  }

  deinit {
    closeSources()
    if !completed, process > 0 {
      kill(-process, SIGKILL)
      let deadline = ProcessInfo.processInfo.systemUptime + 1
      repeat {
        reapIfExited()
        if exitStatus != nil { break }
        usleep(2_000)
      } while ProcessInfo.processInfo.systemUptime < deadline
    }
  }
}
