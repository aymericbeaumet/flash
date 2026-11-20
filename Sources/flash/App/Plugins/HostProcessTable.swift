import Darwin
import FlashCore
import Foundation

/// One `proc_pid_rusage` read of a pid.
struct ProcessUsage: Equatable {
  /// Cumulative user and system CPU time, in nanoseconds.
  var cpuNs: UInt64
  var residentBytes: UInt64
  var diskReadBytes: UInt64
  var diskWriteBytes: UInt64
  /// When the process started, in Mach absolute time: with the pid, the
  /// identity of one process, which a reused pid does not share.
  var startAbstime: UInt64
}

/// What `host.process_table` asks the kernel about a process: its figures,
/// its counts and its executable's path. No requirement reads a process's
/// arguments or its environment, and none may be added: they never cross
/// the wire because the host never holds them (guardrail-enforced).
///
/// The resident wires `LibprocKernel` at launch. Nothing is wired inside the
/// test runner, where a test injects a scripted kernel, or reads through the
/// live one only its own process and the children it spawned.
protocol ProcessKernel {
  /// The monotonic clock, in nanoseconds: what a CPU share divides by.
  func now() -> UInt64
  /// Every visible pid, in the kernel's order.
  func pids() -> [pid_t]
  func children(of parent: pid_t) -> [pid_t]
  /// Nil when the pid is gone or not this user's to measure.
  func usage(of pid: pid_t) -> ProcessUsage?
  /// The executable's path.
  func path(of pid: pid_t) -> String?
  func threadCount(of pid: pid_t) -> Int
  /// Open socket descriptors, unix-domain ones included.
  func socketCount(of pid: pid_t) -> Int
  /// When the process started, in Unix seconds.
  func startTime(of pid: pid_t) -> Int?
}

/// The process table for `host.process_table`: plugins never read another
/// process themselves, and no sandbox profile lets one. Every read runs on
/// one serial queue, never main and never a plugin's own queue.
///
/// A reply is bounded twice, by count and by bytes; what does not fit is
/// left out and the reply says so. A process is its pid, its start, its CPU
/// time and its resident memory, and its executable's name when it was
/// asked for by pid or belongs to a tree; a tree adds each process's thread
/// and socket counts and disk I/O, and the root's path and start time
/// (`protocol.json` `process_table`, `process`).
struct HostProcessTable {
  /// The most pids one `list` names.
  static let maxPids = 4_096
  /// The most processes, and the most bytes of them, one reply holds.
  static let maxProcesses = 4_096
  static let maxReplyBytes = 1_048_576
  /// A name or a path longer than these is left out of its process.
  static let maxNameBytes = 255
  static let maxPathBytes = 4_096

  let kernel: any ProcessKernel
  /// `.userInitiated`: a plugin's reply, and through it a value on screen
  /// or a query someone typed, waits on a read.
  let queue: DispatchQueue

  init(
    kernel: any ProcessKernel,
    queue: DispatchQueue = DispatchQueue(label: "flash.process-table", qos: .userInitiated)
  ) {
    self.kernel = kernel
    self.queue = queue
  }

  /// One process as a reply carries it.
  struct Process: Equatable {
    var pid: pid_t
    var usage: ProcessUsage
    /// The last component of the executable's path.
    var name: String?
    var detail: Detail?

    /// What a tree adds: the disk figures come from `usage`.
    struct Detail: Equatable {
      var threads: Int
      var sockets: Int
    }
  }

  /// What one read found.
  struct Snapshot: Equatable {
    /// `ProcessKernel.now()` as the read began.
    var at: UInt64
    var processes: [Process] = []
    /// A tree's root alone.
    var path: String?
    var startedAt: Int?
    /// Later processes were left out of the reply.
    var truncated = false
  }

  /// Every process the user may measure, in the kernel's order, as its
  /// figures alone; with `pids`, only those, in the order asked, each with
  /// its name. A name costs the kernel a path lookup per process, which a
  /// sweep repeated every two seconds does not pay: a reader names a
  /// process once, by pid. A pid that is gone, or not the user's to
  /// measure, is left out. Runs on `queue`.
  func list(pids: [pid_t]?) -> Snapshot {
    var snapshot = Snapshot(at: kernel.now())
    var budget = ReplyBudget()
    for pid in pids ?? kernel.pids() {
      guard let usage = kernel.usage(of: pid) else { continue }
      let process = Process(pid: pid, usage: usage, name: pids == nil ? nil : name(of: pid))
      guard budget.admit(process) else {
        snapshot.truncated = true
        break
      }
      snapshot.processes.append(process)
    }
    return snapshot
  }

  /// `root` and every descendant reachable now, breadth first, each with
  /// its detail. Browser and Electron work lives mostly in helpers, so a
  /// root-only figure would under-report the app. No process at all when
  /// `root` is gone or not the user's to measure. Runs on `queue`.
  func tree(root: pid_t) -> Snapshot {
    var snapshot = Snapshot(at: kernel.now())
    guard kernel.usage(of: root) != nil else { return snapshot }
    var budget = ReplyBudget()
    var ordered = [root]
    var seen: Set<pid_t> = [root]
    var index = 0
    while index < ordered.count {
      let pid = ordered[index]
      index += 1
      for child in kernel.children(of: pid) where child > 0 && seen.insert(child).inserted {
        ordered.append(child)
      }
      guard let usage = kernel.usage(of: pid) else { continue }
      let process = Process(
        pid: pid, usage: usage, name: name(of: pid),
        detail: Process.Detail(
          threads: kernel.threadCount(of: pid), sockets: kernel.socketCount(of: pid)))
      guard budget.admit(process) else {
        snapshot.truncated = true
        break
      }
      snapshot.processes.append(process)
    }
    snapshot.path = kernel.path(of: root).flatMap {
      $0.utf8.count <= Self.maxPathBytes && !$0.isEmpty ? $0 : nil
    }
    snapshot.startedAt = kernel.startTime(of: root)
    return snapshot
  }

  private func name(of pid: pid_t) -> String? {
    kernel.path(of: pid).flatMap(Self.name(ofExecutable:))
  }

  /// The last component of an executable's path: the process's name, as
  /// Activity Monitor and `top` show it.
  static func name(ofExecutable path: String) -> String? {
    var trimmed = Substring(path)
    while trimmed.hasSuffix("/") { trimmed.removeLast() }
    guard let name = trimmed.split(separator: "/", omittingEmptySubsequences: false).last,
      !name.isEmpty, name.utf8.count <= maxNameBytes
    else { return nil }
    return String(name)
  }

  /// The count and the bytes a reply's processes may still take.
  private struct ReplyBudget {
    private var count = 0
    /// The array's two brackets.
    private var bytes = 2

    mutating func admit(_ process: Process) -> Bool {
      let size = HostProcessTable.encodedBytes(process) + 1
      guard count < HostProcessTable.maxProcesses,
        bytes + size <= HostProcessTable.maxReplyBytes
      else { return false }
      count += 1
      bytes += size
      return true
    }
  }

  // MARK: - The wire shape

  /// The reply to a `list` or a `tree`.
  static func wire(_ snapshot: Snapshot) -> [String: Any] {
    var result: [String: Any] = [
      "ok": true, "at": snapshot.at, "processes": snapshot.processes.map(wire),
    ]
    if let path = snapshot.path { result["path"] = path }
    if let startedAt = snapshot.startedAt { result["started_at"] = startedAt }
    if snapshot.truncated { result["truncated"] = true }
    return result
  }

  /// One process as `protocol.json` `process` shapes it. These keys are
  /// all a process has on the wire.
  static func wire(_ process: Process) -> [String: Any] {
    var object: [String: Any] = [
      "pid": Int(process.pid), "start": process.usage.startAbstime,
      "cpu_ns": process.usage.cpuNs, "resident_bytes": process.usage.residentBytes,
    ]
    if let name = process.name { object["name"] = name }
    if let detail = process.detail {
      object["threads"] = detail.threads
      object["sockets"] = detail.sockets
      object["disk_read_bytes"] = process.usage.diskReadBytes
      object["disk_write_bytes"] = process.usage.diskWriteBytes
    }
    return object
  }

  /// The bytes of `wire(process)` in its compact encoding, counted without
  /// encoding it: a sweep of the whole table is not encoded twice.
  static func encodedBytes(_ process: Process) -> Int {
    // `{"pid":,"start":,"cpu_ns":,"resident_bytes":}`
    var bytes = 45
    bytes += digits(UInt64(max(0, process.pid)))
    bytes += digits(process.usage.startAbstime)
    bytes += digits(process.usage.cpuNs)
    bytes += digits(process.usage.residentBytes)
    if let name = process.name {
      // `,"name":`
      bytes += 8 + encodedBytes(name)
    }
    if let detail = process.detail {
      // `,"threads":,"sockets":,"disk_read_bytes":,"disk_write_bytes":`
      bytes += 61
      bytes += digits(UInt64(max(0, detail.threads)))
      bytes += digits(UInt64(max(0, detail.sockets)))
      bytes += digits(process.usage.diskReadBytes)
      bytes += digits(process.usage.diskWriteBytes)
    }
    return bytes
  }

  private static func digits(_ value: UInt64) -> Int {
    var count = 1
    var rest = value / 10
    while rest > 0 {
      count += 1
      rest /= 10
    }
    return count
  }

  /// A JSON string's bytes with its quotes: a quote, a backslash and the
  /// five named control characters take two bytes, every other control
  /// character six, and anything else its UTF-8.
  static func encodedBytes(_ text: String) -> Int {
    var bytes = 2
    for byte in text.utf8 {
      switch byte {
      case UInt8(ascii: "\""), UInt8(ascii: "\\"), 0x08, 0x09, 0x0A, 0x0C, 0x0D: bytes += 2
      case 0..<0x20: bytes += 6
      default: bytes += 1
      }
    }
    return bytes
  }
}

/// The resident's kernel: libproc, with no `/bin/ps` and no subprocess. It
/// reads resource use, task counters, a descriptor list and an executable's
/// path, and never the node that holds a process's arguments and
/// environment: they stay where they are.
struct LibprocKernel: ProcessKernel {
  func now() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
  }

  func pids() -> [pid_t] {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    // Headroom for processes started between the two calls.
    var pids = [pid_t](repeating: 0, count: Int(count) + 64)
    let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard filled > 0 else { return [] }
    return pids.prefix(Int(filled)).filter { $0 > 0 }
  }

  func children(of parent: pid_t) -> [pid_t] {
    let count = proc_listchildpids(parent, nil, 0)
    guard count > 0 else { return [] }
    // Headroom for children started between the two calls.
    var children = [pid_t](repeating: 0, count: Int(count) + 16)
    let filled = proc_listchildpids(
      parent, &children, Int32(children.count * MemoryLayout<pid_t>.size))
    guard filled > 0 else { return [] }
    return children.prefix(Int(filled)).filter { $0 > 0 }
  }

  func usage(of pid: pid_t) -> ProcessUsage? {
    var info = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
      }
    }
    guard status == 0 else { return nil }
    return ProcessUsage(
      cpuNs: MachTime.nanoseconds(fromTicks: info.ri_user_time &+ info.ri_system_time),
      residentBytes: info.ri_resident_size,
      diskReadBytes: info.ri_diskio_bytesread,
      diskWriteBytes: info.ri_diskio_byteswritten,
      startAbstime: info.ri_proc_start_abstime)
  }

  func path(of pid: pid_t) -> String? {
    // `PROC_PIDPATHINFO_MAXSIZE`.
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    let path = String(cString: buffer)
    return path.isEmpty ? nil : path
  }

  func threadCount(of pid: pid_t) -> Int {
    var info = proc_taskinfo()
    let size = Int32(MemoryLayout<proc_taskinfo>.size)
    let read = withUnsafeMutablePointer(to: &info) {
      proc_pidinfo(pid, PROC_PIDTASKINFO, 0, $0, size)
    }
    return read == size ? max(0, Int(info.pti_threadnum)) : 0
  }

  /// From the descriptor list alone. Resolving each socket's family costs
  /// one `proc_pidfdinfo` per descriptor, tens of thousands of syscalls per
  /// sample for a browser's helper tree, so the count includes unix-domain
  /// sockets and stays two syscalls per pid. No descriptor is examined.
  func socketCount(of pid: pid_t) -> Int {
    let required = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard required > 0 else { return 0 }
    let stride = MemoryLayout<proc_fdinfo>.stride
    var descriptors = [proc_fdinfo](
      repeating: proc_fdinfo(), count: Int(required) / stride + 16)
    let filled = descriptors.withUnsafeMutableBytes { buffer in
      proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
    }
    guard filled > 0 else { return 0 }
    return descriptors.prefix(min(Int(filled) / stride, descriptors.count)).reduce(into: 0) {
      total, descriptor in
      if descriptor.proc_fdtype == PROX_FDTYPE_SOCKET { total += 1 }
    }
  }

  func startTime(of pid: pid_t) -> Int? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    let read = withUnsafeMutablePointer(to: &info) {
      proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size)
    }
    return read == size ? Int(exactly: info.pbi_start_tvsec) : nil
  }
}
