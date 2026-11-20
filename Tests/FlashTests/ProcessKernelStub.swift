import Darwin
import Foundation

@testable import flash

/// A scripted kernel for `host.process_table`: the processes a test
/// declares, and nothing of the machine the test runs on. It records what
/// it was asked and from which thread.
final class ProcessKernelStub: ProcessKernel {
  struct Scripted {
    var parent: pid_t
    /// Nil: the kernel names no executable.
    var path: String?
    var usage: ProcessUsage
    var threads = 1
    var sockets = 0
    var startTime: Int?
    /// False: the process exists and is another user's, so only its path
    /// and its place in the tree are readable.
    var measurable = true
  }

  private let lock = NSLock()
  private var processes: [pid_t: Scripted] = [:]
  /// The kernel's order, which is not pid order.
  private var order: [pid_t] = []
  private var clock: UInt64
  private let tick: UInt64
  private var asked: [String] = []
  private var main = false

  /// `clock` is what the first `now()` answers; each later one is `tick`
  /// further.
  init(clock: UInt64 = 1_000_000_000, tick: UInt64 = 0) {
    self.clock = clock
    self.tick = tick
  }

  /// Add or replace `pid`.
  func spawn(
    _ pid: pid_t, parent: pid_t = 1, path: String?, start: UInt64, cpuNs: UInt64 = 0,
    residentBytes: UInt64 = 0, change: (inout Scripted) -> Void = { _ in }
  ) {
    var process = Scripted(
      parent: parent, path: path,
      usage: ProcessUsage(
        cpuNs: cpuNs, residentBytes: residentBytes, diskReadBytes: 0, diskWriteBytes: 0,
        startAbstime: start))
    change(&process)
    lock.lock()
    if processes.updateValue(process, forKey: pid) == nil { order.append(pid) }
    lock.unlock()
  }

  func update(_ pid: pid_t, _ change: (inout Scripted) -> Void) {
    lock.lock()
    defer { lock.unlock() }
    guard var process = processes[pid] else { return }
    change(&process)
    processes[pid] = process
  }

  func exit(_ pid: pid_t) {
    lock.lock()
    processes[pid] = nil
    order.removeAll { $0 == pid }
    lock.unlock()
  }

  /// Every question the kernel was asked, as `<what> <pid>`, in order.
  var questions: [String] {
    lock.lock()
    defer { lock.unlock() }
    return asked
  }

  /// Whether any question arrived on the main thread.
  var askedOnMain: Bool {
    lock.lock()
    defer { lock.unlock() }
    return main
  }

  private func read<Value>(_ what: String, _ body: () -> Value) -> Value {
    lock.lock()
    defer { lock.unlock() }
    asked.append(what)
    if Thread.isMainThread { main = true }
    return body()
  }

  func now() -> UInt64 {
    read("now") {
      defer { clock += tick }
      return clock
    }
  }

  func pids() -> [pid_t] { read("pids") { order } }

  func children(of parent: pid_t) -> [pid_t] {
    read("children \(parent)") { order.filter { processes[$0]?.parent == parent } }
  }

  func usage(of pid: pid_t) -> ProcessUsage? {
    read("usage \(pid)") { processes[pid].flatMap { $0.measurable ? $0.usage : nil } }
  }

  func path(of pid: pid_t) -> String? { read("path \(pid)") { processes[pid]?.path } }

  func threadCount(of pid: pid_t) -> Int {
    read("threads \(pid)") { processes[pid].map { $0.measurable ? $0.threads : 0 } ?? 0 }
  }

  func socketCount(of pid: pid_t) -> Int {
    read("sockets \(pid)") { processes[pid].map { $0.measurable ? $0.sockets : 0 } ?? 0 }
  }

  func startTime(of pid: pid_t) -> Int? {
    read("start \(pid)") { processes[pid].flatMap { $0.measurable ? $0.startTime : nil } }
  }

  /// The table of the conformance corpus (`conformance/README.md`): Safari
  /// and its content process, a shell, and launchd, which is root's.
  static func corpus() -> ProcessKernelStub {
    let kernel = ProcessKernelStub(clock: 90_000_000_000)
    kernel.spawn(1, parent: 0, path: "/sbin/launchd", start: 1) { $0.measurable = false }
    kernel.spawn(
      4242, path: "/Applications/Safari.app/Contents/MacOS/Safari", start: 77_000,
      cpuNs: 1_500_000_000, residentBytes: 268_435_456
    ) {
      $0.threads = 12
      $0.sockets = 3
      $0.usage.diskReadBytes = 4_096
      $0.usage.diskWriteBytes = 8_192
      $0.startTime = 1_799_996_400
    }
    kernel.spawn(
      4243, parent: 4242,
      path:
        "/System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.WebContent.xpc"
        + "/Contents/MacOS/com.apple.WebKit.WebContent",
      start: 78_000, cpuNs: 250_000_000, residentBytes: 67_108_864
    ) {
      $0.threads = 5
      $0.sockets = 1
    }
    kernel.spawn(4300, path: "/bin/zsh", start: 90_000, cpuNs: 20_000_000, residentBytes: 4_194_304)
    return kernel
  }
}

/// The live kernel, held to the processes a test may read: its own, and
/// the children it spawned and names here. Any other pid is answered as
/// gone, and the pid list is that set, followed by the processes of a
/// scripted kernel when a test wants a table longer than its own family.
final class OwnProcessKernel: ProcessKernel {
  private let live = LibprocKernel()
  private let scripted: ProcessKernelStub?
  private let lock = NSLock()
  private var allowed: Set<pid_t> = [getpid()]

  init(children: [Process] = [], scripted: ProcessKernelStub? = nil) {
    self.scripted = scripted
    for child in children { allowed.insert(child.processIdentifier) }
  }

  /// A child the test spawned after the kernel was wired.
  func allow(_ child: Process) {
    lock.lock()
    allowed.insert(child.processIdentifier)
    lock.unlock()
  }

  private func own(_ pid: pid_t) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return allowed.contains(pid)
  }

  func now() -> UInt64 { live.now() }

  func pids() -> [pid_t] {
    lock.lock()
    let own = allowed.sorted()
    lock.unlock()
    return own + (scripted?.pids() ?? [])
  }

  func children(of parent: pid_t) -> [pid_t] {
    own(parent)
      ? live.children(of: parent).filter(own) : scripted?.children(of: parent) ?? []
  }

  func usage(of pid: pid_t) -> ProcessUsage? {
    own(pid) ? live.usage(of: pid) : scripted?.usage(of: pid)
  }

  func path(of pid: pid_t) -> String? {
    own(pid) ? live.path(of: pid) : scripted?.path(of: pid)
  }

  func threadCount(of pid: pid_t) -> Int {
    own(pid) ? live.threadCount(of: pid) : scripted?.threadCount(of: pid) ?? 0
  }

  func socketCount(of pid: pid_t) -> Int {
    own(pid) ? live.socketCount(of: pid) : scripted?.socketCount(of: pid) ?? 0
  }

  func startTime(of pid: pid_t) -> Int? {
    own(pid) ? live.startTime(of: pid) : scripted?.startTime(of: pid)
  }
}
