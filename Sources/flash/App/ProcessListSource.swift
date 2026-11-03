import AppKit
import FlashCore
import Foundation

/// `@processes`: every visible process as a live flashlight source, read
/// from the resident's process table off main when a query names it.
/// Selecting a row asks whether to kill that process (`process kill`).
final class ProcessListSource: FlashSource {
  static let label = "processes.processes"
  let identifier = "core.processes"
  let displayName = "core.processes"
  let priority = 40
  var capabilities: FlashSourceCapabilities { [.candidates] }
  var servesLiveCandidates: Bool { true }
  var candidateSourceDescriptors: [CandidateSourceDescriptor] {
    [CandidateSourceDescriptor(name: Self.label, type: "processes")]
  }

  /// One read serves the keystrokes of a query typed within this long.
  private static let cacheTTL: TimeInterval = 2
  private let perform: (URLCommand) -> Void
  private let read: () -> [ProcessTable.Process]
  private let queue = DispatchQueue(label: "flash.source.processes", qos: .userInitiated)
  private let lock = NSLock()
  private var cache: (at: TimeInterval, rows: [Candidate])?

  /// `perform` runs a selected row's verb on main.
  init(
    read: @escaping () -> [ProcessTable.Process] = { ProcessTable.shared.processes() },
    perform: @escaping (URLCommand) -> Void
  ) {
    self.read = read
    self.perform = perform
  }

  func supports(_ context: AppContext) -> Bool { false }
  func discover(in context: AppContext) throws -> [JumpTarget] { [] }

  func liveCandidates(
    matching text: String,
    in environment: FlashSourceEnvironment,
    scope: CandidateScope,
    completion: @escaping ([Candidate]) -> Void
  ) {
    queue.async { [weak self] in
      guard let self else { return }
      let now = ProcessInfo.processInfo.systemUptime
      self.lock.lock()
      let cached = self.cache.flatMap { now - $0.at < Self.cacheTTL ? $0.rows : nil }
      self.lock.unlock()
      let rows = cached ?? self.read().map(Self.candidate(for:))
      if cached == nil {
        self.lock.lock()
        self.cache = (now, rows)
        self.lock.unlock()
      }
      DispatchQueue.main.async { completion(rows) }
    }
  }

  func resolveCandidate(
    _ candidate: Candidate,
    in environment: FlashSourceEnvironment,
    completion: @escaping (CandidateResolution) -> Void
  ) {
    let pid = candidate.sourcePayload.flatMap { pid_t($0) }.flatMap { $0 > 0 ? $0 : nil }
    // The next query reads the table afresh: this row may be about to go.
    lock.lock()
    cache = nil
    lock.unlock()
    DispatchQueue.main.async { [perform] in
      guard let pid else {
        completion(.unresolved)
        return
      }
      // The flashlight settles first; the kill then asks its question.
      completion(.resolved(pid: nil))
      perform(.processKill(pid: pid))
    }
  }

  /// One row: the process name over its pid and resource shares; the pid is
  /// also a search alias.
  static func candidate(for process: ProcessTable.Process) -> Candidate {
    let memoryPercent =
      Double(process.residentBytes) / Double(ProcessTable.physicalMemory) * 100
    return Candidate(
      kind: .plugin("process"), sourceID: "core.processes", source: label,
      title: process.name,
      subtitle: String(
        format: "pid %d · %.1f%% CPU · %.1f%% MEM", process.pid, process.cpuPercent,
        memoryPercent),
      sourcePayload: String(process.pid), searchAliases: String(process.pid))
  }
}

/// `process kill --pid=<pid>`: SIGTERM one process, after asking.
enum ProcessKill {
  static func prompt(name: String, pid: pid_t) -> String {
    "Kill \(name) (pid \(pid))?"
  }

  /// What the verb does now, given the process's current name (nil when it
  /// is gone or not this user's to inspect).
  static func step(pid: pid_t, name: String?, confirmed: Bool) -> ConfirmationStep {
    guard pid > 1 else { return .refuse("refusing pid \(pid)") }
    guard let name else { return .refuse("no process with pid \(pid)") }
    return confirmed ? .run : .ask(prompt(name: name, pid: pid))
  }
}
