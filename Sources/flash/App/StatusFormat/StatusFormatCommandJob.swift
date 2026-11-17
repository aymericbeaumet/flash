import CFlashTerminal
import Darwin
import FlashTerminal
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
    guard argv.first?.isEmpty == false else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
    }
    var descriptors: [Int32] = [-1, -1]
    guard pipe(&descriptors) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    defer { close(descriptors[1]) }
    do {
      process = try ProcessGroupSpawn.spawn(
        argv: argv, environment: environment, workingDirectory: workingDirectory,
        stdout: .descriptor(descriptors[1]), stderr: .devNull, closeInChild: descriptors)
    } catch {
      close(descriptors[0])
      throw error
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
      // A command which backgrounds children still owns their process
      // group; signal it while the zombie leader still holds the group id —
      // reaped, that id can be reused by an unrelated process. The children
      // also hold the pipe, so their end is what lets the read reach EOF.
      kill(-self.process, SIGKILL)
      // The exit event can precede the reapable state by the kernel's last
      // exit steps; a non-blocking wait there returned nothing and the job
      // never completed. The reap waits them out.
      self.exitStatus = ProcessExit.reap(self.process) ?? 0
      self.readAvailable()
      self.finishIfReady()
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
  /// Every wait ends on the kernel's exit events: the grace period ends as
  /// soon as every group has left on SIGTERM, and the deadline only bounds a
  /// group that will not.
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
    let started = DispatchTime.now()
    let deadline = started + max(0, deadlineSeconds)
    let killAt = min(deadline, started + max(0, graceSeconds))
    let groups = active.map(\.process)
    var exited: Set<pid_t> = []
    _ = ProcessExit.waitForGroups(groups, until: killAt, exited: &exited)
    // A command which backgrounds children still owns their process group.
    for job in active { kill(-job.process, SIGKILL) }
    _ = ProcessExit.waitForGroups(groups, until: deadline, exited: &exited)
    for job in active {
      if job.exitStatus == nil, exited.contains(job.process) {
        job.exitStatus = ProcessExit.reap(job.process) ?? 0
      } else {
        job.reapIfExited()
      }
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

  deinit {
    closeSources()
    if !completed, process > 0 {
      kill(-process, SIGKILL)
      // Reaped when the kernel reports the exit, off whichever thread
      // dropped the last reference; nothing waits in `deinit`.
      ProcessExit.reapWhenExited(process)
    }
  }
}
