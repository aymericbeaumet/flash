import Darwin
import FlashCore
import Foundation

/// The resident's one process model: every visible process, and the whole
/// process tree of one app, read through libproc with no `/bin/ps` and no
/// subprocess. A read blocks for up to one sample window, so it never runs on
/// the main thread.
///
/// CPU is a delta. Each pid's cumulative CPU time is cached with the moment it
/// was read, and the next read divides the difference by the time elapsed: the
/// average over the reader's own period, not a lifetime mean. A pid with no
/// usable prior read is read twice, `windowMs` apart, so its first figure is
/// real rather than zero. It is a share of one core, as `top` and Activity
/// Monitor report it.
final class ProcessTable {
  static let shared = ProcessTable()
  /// The bracket for a pid read for the first time.
  static let sampleWindowMs = 150

  /// One row of the full table.
  struct Process: Equatable {
    var pid: pid_t
    var name: String
    var cpuPercent: Double
    var residentBytes: UInt64
  }

  /// One app's process and every currently reachable descendant, summed.
  struct Tree: Equatable {
    var pid: pid_t
    var name: String
    var cpuPercent: Double
    var residentBytes: UInt64
    var processCount: Int
    var threadCount: Int
    var socketCount: Int
    var uptimeSeconds: Int
    var diskReadBytes: UInt64
    var diskWriteBytes: UInt64
  }

  /// One libproc read of a pid, kept so the next read computes CPU as a
  /// delta. `startAbstime` guards against pid reuse; the name is cached
  /// because `proc_pidpath` is the most expensive per-pid call of a sweep.
  private struct Sample {
    var cpuNs: UInt64
    var sampledAtNs: UInt64
    var startAbstime: UInt64
    var name: String
  }

  private struct Usage {
    var cpuNs: UInt64
    var residentBytes: UInt64
    var diskReadBytes: UInt64
    var diskWriteBytes: UInt64
    var startAbstime: UInt64
  }

  private struct Sampled {
    var usage: Usage
    var cpuPercent: Double
    var name: String
  }

  private let lock = NSLock()
  private var samples: [pid_t: Sample] = [:]

  /// Physical memory, the denominator of every memory share.
  static let physicalMemory = max(ProcessInfo.processInfo.physicalMemory, 1)

  /// Every visible process. Empty only when libproc failed: the reading
  /// process itself is always listed.
  func processes(windowMs: Int = ProcessTable.sampleWindowMs) -> [Process] {
    let pids = Self.allPids()
    let sampled = sample(pids, windowMs: windowMs, pruneOthers: true)
    return pids.compactMap { pid in
      sampled[pid].map {
        Process(
          pid: pid, name: $0.name, cpuPercent: $0.cpuPercent,
          residentBytes: $0.usage.residentBytes)
      }
    }
  }

  /// `root` and every descendant reachable now. Browser and Electron work
  /// lives mostly in helpers, so a root-only figure would under-report the
  /// app. Nil when `root` is gone.
  func tree(root: pid_t, windowMs: Int = ProcessTable.sampleWindowMs) -> Tree? {
    let pids = Self.processTree(root: root)
    let sampled = sample(pids, windowMs: windowMs, pruneOthers: false)
    guard let rootSample = sampled[root] else { return nil }
    var tree = Tree(
      pid: root, name: rootSample.name, cpuPercent: 0, residentBytes: 0, processCount: 0,
      threadCount: 0, socketCount: 0, uptimeSeconds: Self.uptimeSeconds(root),
      diskReadBytes: 0, diskWriteBytes: 0)
    for pid in pids {
      guard let process = sampled[pid] else { continue }
      tree.processCount += 1
      tree.cpuPercent += process.cpuPercent
      tree.residentBytes = Self.saturatingAdd(tree.residentBytes, process.usage.residentBytes)
      tree.diskReadBytes = Self.saturatingAdd(tree.diskReadBytes, process.usage.diskReadBytes)
      tree.diskWriteBytes = Self.saturatingAdd(tree.diskWriteBytes, process.usage.diskWriteBytes)
      tree.threadCount += Self.threadCount(pid)
      tree.socketCount += Self.socketDescriptorCount(pid)
    }
    return tree
  }

  /// A pid's executable name, or nil when it is gone or not this user's to
  /// inspect.
  static func name(of pid: pid_t) -> String? {
    executableBasename(pid)
  }

  /// SIGTERM `pid`. Nil on success, else the OS's reason (EPERM: another
  /// user's process; ESRCH: already gone). Pids 0 and 1 are refused.
  static func terminate(_ pid: pid_t) -> String? {
    guard pid > 1 else { return "refusing pid \(pid)" }
    return signalSender(pid) == 0 ? nil : String(cString: strerror(errno))
  }

  /// Test seam for `terminate`: production sends SIGTERM.
  static var signalSender: (pid_t) -> Int32 = { kill($0, SIGTERM) }

  /// Read every pid once; a pid without a usable prior read is read again
  /// after `windowMs`. Prior reads come from the cache whichever caller made
  /// them; a full sweep prunes the pids that are gone.
  private func sample(_ pids: [pid_t], windowMs: Int, pruneOthers: Bool) -> [pid_t: Sampled] {
    var out: [pid_t: Sampled] = [:]
    var needsBracket: [pid_t: Usage] = [:]
    let now = DispatchTime.now().uptimeNanoseconds
    lock.lock()
    for pid in pids {
      guard let usage = Self.usage(pid) else { continue }
      if let prior = samples[pid], prior.startAbstime == usage.startAbstime,
        now > prior.sampledAtNs
      {
        let elapsedNs = Double(now - prior.sampledAtNs)
        let cpuPercent = Double(usage.cpuNs &- min(prior.cpuNs, usage.cpuNs)) / elapsedNs * 100
        out[pid] = Sampled(usage: usage, cpuPercent: cpuPercent, name: prior.name)
        samples[pid] = Sample(
          cpuNs: usage.cpuNs, sampledAtNs: now, startAbstime: usage.startAbstime,
          name: prior.name)
      } else {
        needsBracket[pid] = usage
      }
    }
    if pruneOthers {
      let live = Set(pids)
      samples = samples.filter { live.contains($0.key) }
    }
    lock.unlock()
    guard !needsBracket.isEmpty else { return out }

    Thread.sleep(forTimeInterval: Double(min(max(windowMs, 10), 2_000)) / 1_000)
    let after = DispatchTime.now().uptimeNanoseconds
    let windowNs = Double(after - now)
    lock.lock()
    for (pid, first) in needsBracket {
      guard let usage = Self.usage(pid), usage.startAbstime == first.startAbstime,
        let name = Self.executableBasename(pid)
      else { continue }
      let cpuPercent = Double(usage.cpuNs &- min(first.cpuNs, usage.cpuNs)) / windowNs * 100
      out[pid] = Sampled(usage: usage, cpuPercent: cpuPercent, name: name)
      samples[pid] = Sample(
        cpuNs: usage.cpuNs, sampledAtNs: after, startAbstime: usage.startAbstime, name: name)
    }
    lock.unlock()
    return out
  }

  private static func allPids() -> [pid_t] {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    let capacity = Int(count) + 64
    var pids = [pid_t](repeating: 0, count: capacity)
    let filled = proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size))
    guard filled > 0 else { return [] }
    return Array(pids.prefix(Int(filled))).filter { $0 > 0 }
  }

  private static func processTree(root: pid_t) -> [pid_t] {
    var ordered = [root]
    var seen: Set<pid_t> = [root]
    var index = 0
    while index < ordered.count {
      let parent = ordered[index]
      index += 1
      let count = proc_listchildpids(parent, nil, 0)
      guard count > 0 else { continue }
      let capacity = Int(count) + 16
      var children = [pid_t](repeating: 0, count: capacity)
      let filled = proc_listchildpids(
        parent, &children, Int32(capacity * MemoryLayout<pid_t>.size))
      guard filled > 0 else { continue }
      for child in children.prefix(Int(filled)) where child > 0 && seen.insert(child).inserted {
        ordered.append(child)
      }
    }
    return ordered
  }

  private static func usage(_ pid: pid_t) -> Usage? {
    var info = rusage_info_current()
    let ok = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: (rusage_info_t?).self, capacity: 1) {
        proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0) == 0
      }
    }
    guard ok else { return nil }
    return Usage(
      cpuNs: MachTime.nanoseconds(fromTicks: info.ri_user_time &+ info.ri_system_time),
      residentBytes: info.ri_resident_size,
      diskReadBytes: info.ri_diskio_bytesread,
      diskWriteBytes: info.ri_diskio_byteswritten,
      startAbstime: info.ri_proc_start_abstime)
  }

  private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? UInt64.max : sum
  }

  private static func uptimeSeconds(_ pid: pid_t) -> Int {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    let read = withUnsafeMutablePointer(to: &info) {
      proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size)
    }
    guard read == size else { return 0 }
    let started = Int(min(info.pbi_start_tvsec, UInt64(Int.max)))
    return max(0, Int(Date().timeIntervalSince1970) - started)
  }

  private static func threadCount(_ pid: pid_t) -> Int {
    var info = proc_taskinfo()
    let size = Int32(MemoryLayout<proc_taskinfo>.size)
    let read = withUnsafeMutablePointer(to: &info) {
      proc_pidinfo(pid, PROC_PIDTASKINFO, 0, $0, size)
    }
    guard read == size else { return 0 }
    return max(0, Int(info.pti_threadnum))
  }

  /// Open socket descriptors, from the descriptor list alone. Resolving each
  /// socket's family costs one `proc_pidfdinfo` per descriptor — tens of
  /// thousands of syscalls per sample for a browser's helper tree — so the
  /// count includes unix-domain sockets and stays two syscalls per pid.
  private static func socketDescriptorCount(_ pid: pid_t) -> Int {
    let required = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard required > 0 else { return 0 }
    let stride = MemoryLayout<proc_fdinfo>.stride
    let capacity = Int(required) / stride + 16
    var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
    let filled = descriptors.withUnsafeMutableBytes { buffer in
      proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
    }
    guard filled > 0 else { return 0 }
    let count = min(Int(filled) / stride, descriptors.count)
    return descriptors.prefix(count).reduce(into: 0) { total, descriptor in
      if descriptor.proc_fdtype == PROX_FDTYPE_SOCKET { total += 1 }
    }
  }

  private static func executableBasename(_ pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4 * 1024)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    let path = String(cString: buffer)
    guard !path.isEmpty else { return nil }
    return (path as NSString).lastPathComponent
  }
}
