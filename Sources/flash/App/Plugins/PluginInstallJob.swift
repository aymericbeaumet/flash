import CFlashTerminal
import Darwin
import Foundation

/// One install attempt owns its process group, drains both pipes concurrently,
/// and settles independently of the plugin lifecycle queue. Retention lasts
/// until the child is reaped, even when its definition is replaced meanwhile.
/// Jobs sharing a canonical plugin root acquire ownership in submission order;
/// a cancelled installer must release its process group before a replacement
/// can touch the same files.
final class PluginInstallJob {
  struct Output {
    var status: Int32
    var stdout: Data
    var stderr: Data
    var timedOut: Bool
    var cancelled: Bool
  }

  private static let ownershipQueue = DispatchQueue(label: "flash.plugin.install.ownership")
  private static var jobsByRoot: [String: [PluginInstallJob]] = [:]
  private let rootKey: String
  private let argv: [String]
  private let environment: [String: String]
  private let workingDirectory: String
  private let timeoutSeconds: TimeInterval
  private let queue = DispatchQueue(label: "flash.plugin.install", qos: .utility)
  private let completionQueue: DispatchQueue
  private let completion: (Output) -> Void
  private var pid: pid_t = 0
  private var stdoutFD: Int32 = -1
  private var stderrFD: Int32 = -1
  private var stdoutReader: DispatchSourceRead?
  private var stderrReader: DispatchSourceRead?
  private var exitSource: DispatchSourceProcess?
  private var deadline: DispatchWorkItem?
  private var escalation: DispatchWorkItem?
  private var status: Int32?
  private var stdout = Data()
  private var stderr = Data()
  private var timedOut = false
  private var cancelled = false
  private var finished = false
  private enum Termination { case active, terminating, killed }
  private var termination = Termination.active
  static let stdoutLimit = 4 * 1_024 * 1_024
  static let stderrLimit = 256 * 1_024

  init(
    argv: [String], environment: [String: String], workingDirectory: String,
    timeoutSeconds: TimeInterval, completionQueue: DispatchQueue,
    completion: @escaping (Output) -> Void
  ) throws {
    self.completionQueue = completionQueue
    self.completion = completion
    self.argv = argv
    self.environment = environment
    self.workingDirectory = workingDirectory
    self.timeoutSeconds = timeoutSeconds
    self.rootKey =
      URL(fileURLWithPath: workingDirectory).standardizedFileURL.resolvingSymlinksInPath().path
    guard let executable = argv.first, !executable.isEmpty else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
    }
    Self.ownershipQueue.async { [self] in
      Self.jobsByRoot[rootKey, default: []].append(self)
      if Self.jobsByRoot[rootKey]?.count == 1 { queue.async { self.startOwned() } }
    }
  }

  private func startOwned() {
    guard !finished else { return }
    do { try spawn() } catch {
      finish(
        Output(
          status: -1, stdout: Data(), stderr: Data(String(describing: error).utf8), timedOut: false,
          cancelled: cancelled))
    }
  }

  private func releaseOwnership() {
    Self.ownershipQueue.async { [self] in
      guard var jobs = Self.jobsByRoot[rootKey], let index = jobs.firstIndex(where: { $0 === self })
      else { return }
      jobs.remove(at: index)
      Self.jobsByRoot[rootKey] = jobs.isEmpty ? nil : jobs
      if index == 0, let next = jobs.first { next.queue.async { next.startOwned() } }
    }
  }

  private func spawn() throws {
    var out: [Int32] = [-1, -1]
    var err: [Int32] = [-1, -1]
    guard pipe(&out) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    guard pipe(&err) == 0 else {
      close(out[0])
      close(out[1])
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    defer {
      close(out[1])
      close(err[1])
    }
    do {
      pid = try ProcessGroupSpawn.spawn(
        argv: argv, environment: environment, workingDirectory: workingDirectory,
        stdout: .descriptor(out[1]), stderr: .descriptor(err[1]), closeInChild: out + err)
    } catch {
      close(out[0])
      close(err[0])
      throw error
    }
    stdoutFD = out[0]
    stderrFD = err[0]
    _ = fcntl(stdoutFD, F_SETFL, O_NONBLOCK)
    _ = fcntl(stderrFD, F_SETFL, O_NONBLOCK)
    stdoutReader = makeReader(stdoutFD, isStderr: false)
    stderrReader = makeReader(stderrFD, isStderr: true)
    let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
    source.setEventHandler { [weak self] in self?.childExited() }
    exitSource = source
    source.resume()
    let work = DispatchWorkItem { [weak self] in
      guard let self, !self.finished else { return }
      self.timedOut = true
      self.terminateGroup()
    }
    deadline = work
    queue.asyncAfter(deadline: .now() + max(0, timeoutSeconds), execute: work)
  }

  func cancel() {
    queue.async { [self] in
      guard !finished else { return }
      cancelled = true
      if pid == 0 {
        finish(
          Output(
            status: 128 + SIGTERM, stdout: Data(), stderr: Data(), timedOut: false, cancelled: true)
        )
      } else {
        terminateGroup()
      }
    }
  }

  private func makeReader(_ fd: Int32, isStderr: Bool) -> DispatchSourceRead {
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler { [weak self] in self?.readAvailable(isStderr: isStderr) }
    source.setCancelHandler { close(fd) }
    source.resume()
    return source
  }

  private func readAvailable(isStderr: Bool) {
    let fd = isStderr ? stderrFD : stdoutFD
    guard fd >= 0 else { return }
    var buffer = [UInt8](repeating: 0, count: 16_384)
    var drained = 0
    while drained < 256 * 1_024 {
      let count = read(fd, &buffer, buffer.count)
      if count > 0 {
        drained += count
        if isStderr {
          stderr.append(
            contentsOf: buffer.prefix(min(count, max(0, Self.stderrLimit - stderr.count))))
        } else {
          stdout.append(
            contentsOf: buffer.prefix(min(count, max(0, Self.stdoutLimit - stdout.count))))
        }
      } else if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) {
        closeReader(isStderr: isStderr)
        finishIfReady()
        return
      } else if errno == EINTR {
        continue
      } else {
        return
      }
    }
  }

  private func closeReader(isStderr: Bool) {
    if isStderr {
      stderrReader?.cancel()
      stderrReader = nil
      stderrFD = -1
    } else {
      stdoutReader?.cancel()
      stdoutReader = nil
      stdoutFD = -1
    }
  }

  private func childExited() {
    var raw: Int32 = 0
    if waitpid(pid, &raw, WNOHANG) == pid {
      status = raw & 0x7f == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f)
    }
    readAvailable(isStderr: false)
    readAvailable(isStderr: true)
    // Descendants cannot outlive the install command or keep its pipes open.
    if kill(-pid, 0) == 0 || errno == EPERM { terminateGroup() }
    finishIfReady()
  }

  private func terminateGroup() {
    guard !finished, termination == .active else { return }
    termination = .terminating
    kill(-pid, SIGTERM)
    let work = DispatchWorkItem { [weak self] in
      guard let self, !self.finished else { return }
      kill(-self.pid, SIGKILL)
      self.termination = .killed
      // A descendant can pass a pipe to an unrelated process. The install
      // owns only its group; close our pipe ends after the group deadline.
      self.readAvailable(isStderr: false)
      self.readAvailable(isStderr: true)
      self.closeReader(isStderr: false)
      self.closeReader(isStderr: true)
      self.childExited()
    }
    escalation = work
    queue.asyncAfter(deadline: .now() + .milliseconds(500), execute: work)
  }

  private func finishIfReady() {
    guard !finished, let status, stdoutFD < 0, stderrFD < 0 else { return }
    // Even a shell which backgrounds and closes both pipes still owns its
    // descendants. Keep the escalation armed until their group is gone.
    if termination != .killed, kill(-pid, 0) == 0 || errno == EPERM {
      terminateGroup()
      return
    }
    finish(
      Output(
        status: status, stdout: stdout, stderr: stderr, timedOut: timedOut, cancelled: cancelled))
  }

  private func finish(_ output: Output) {
    guard !finished else { return }
    finished = true
    deadline?.cancel()
    deadline = nil
    escalation?.cancel()
    escalation = nil
    exitSource?.cancel()
    exitSource = nil
    completionQueue.async { [completion] in completion(output) }
    releaseOwnership()
  }
}
